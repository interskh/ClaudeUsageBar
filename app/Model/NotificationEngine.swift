import Foundation

// §8, the DECISION half. PURE: no AppKit, no NSUserNotification, no delivery — it
// computes WHICH alerts a set of readings should raise and returns them, so the whole
// [25, 50, 75, 90] ladder, hysteresis, per-(account, window) state and lifecycle
// reclamation are exercised in the test target with injected state and nothing reaching
// the notification centre. `Core/AccountNotifier.swift` is the delivery shell; a test
// asserts "these crossings produced these alerts" without a notification being sent.
//
// THE BUG THIS REPLACES: the shipped notifier kept ONE global `lastNotifiedThreshold`
// compared against `max(session, weekly)`. With N accounts that one slot is a race —
// account A crossing 75% writes 75 and suppresses account B's own 75% alert, and
// whichever polls last wins, so the user is silently never told B is nearly exhausted.
// State here is one entry per (account, window), keyed by provider + account +
// the window's FULL identity (both temporal span and scope), so a model-scoped short
// window and a model-scoped long window are distinct alerts and every enabled account
// notifies independently.
//
// @MainActor: this state is mutated on the same single-writer actor as `UsageEngine`
// (§6). It lives BESIDE the registry, not inside it — a notification decision needs only
// the projected windows the store already computes — but under the same actor, so the
// concurrency story is compiler-checked rather than asserted (the class of gap task 6's
// `readFile` lesson and task 7's `@MainActor` decision were both about).

// One alert to deliver. The source is NAMED from the account and the window — never a
// hardcoded string. The shipped notifier hardcoded "5-hour session limit" in three
// places while the reading might have come from the weekly window; naming a window the
// reading did not come from is the false assertion this rework removes.
struct NotificationAlert: Equatable {
    let provider: ProviderKind // which provider the reading came from — TITLES the alert
    let accountLabel: String   // e.g. "work-fiona" — from AccountRef, current discovery
    let windowLabel: String    // e.g. "weekly" — from the window that crossed
    let threshold: Int         // the band crossed: one of [25, 50, 75, 90]

    // The whole point of this rework is to stop asserting things the reading did not say.
    // The delivery shell used to hardcode the TITLE "Claude Usage Alert" for every alert,
    // branding a Codex reading as a Claude one — the thesis violated one layer out. The
    // title is derived from the provider the alert carries, so the shell cannot mislabel
    // it and a test can pin it without a notification being delivered.
    var title: String {
        switch provider {
        case .anthropic: return "Claude Usage Alert"
        case .codex: return "Codex Usage Alert"
        }
    }

    // "work-fiona · weekly hit 75%". A mutation that swaps or hardcodes either label
    // fails `alertTextNamesTheActualSource`.
    var summary: String { "\(accountLabel) · \(windowLabel) hit \(threshold)%" }
}

// One account whose window list is AUTHORITATIVE this cycle — i.e. the account is
// readable (`.active`/`.stale`), so its windows are the complete current set and a slot
// for a window not present here has genuinely retired. The caller MUST pass the account's
// PROJECTED windows (over-horizon → unknown), so a window past its cache horizon neither
// fires nor resets: an unknown reading is no information (see `evaluate`).
//
// An account that CANNOT be read right now (`.pending`/`.expired`/`.failed`/`.signedOut`)
// is deliberately NOT a reading — it goes into the `discovered` roster instead, so its
// slots are HELD rather than reclaimed. `NotificationEngine.inputs(from:)` performs that
// split from `[AccountPresentation]`.
struct NotificationReading {
    let ref: AccountRef
    let isEnabled: Bool          // §7.3 per-account enablement; a disabled account is frozen
    let windows: [UsageWindow]
}

@MainActor
final class NotificationEngine {
    // §8: the bands are fixed. Do not change them here without changing the spec.
    static let bands = [25, 50, 75, 90]

    // account storageKey -> (WindowID -> highest band currently RECORDED as alerted).
    // A missing window means "band 0": low windows carry no slot, so steady traffic
    // below 25% never grows the map. Namespaced by `AccountIdentity.storageKey` (the
    // outer key) so a whole account's notification state drops as a unit exactly the way
    // task 7's `UsageEngine` drops the rest of an account's state — and so one account's
    // slot can NEVER be read for another account, which is the §6 misattribution the
    // global slot committed.
    private var recorded: [String: [WindowID: Int]] = [:]
    // Set whenever `recorded` changes, so the shell re-persists only on a real delta
    // rather than on every 15s publish.
    private var dirty = false

    // The only values a slot may legitimately hold. `0` is never stored (a low window
    // carries no slot), so the persisted members are the four bands; anything else on
    // disk is a corrupt slot.
    static let storableBands: Set<Int> = [25, 50, 75, 90]

    init() {}

    // Rebuilds state from a persisted blob. A window whose span/scope kind this build
    // cannot decode is DROPPED (bounded to one window's re-armed ladder), never
    // resurrected as garbage — mirrors `PersistedSnapshot.model`.
    //
    // A stored threshold that is NOT one of the four bands is a corrupt slot and is
    // dropped (re-armed to 0), not trusted: a persisted `99` would mean no band `<= 99`
    // ever counts as a fresh crossing, so 90% would silently never fire — the exact
    // suppression this task removes, arriving through the persistence door. Re-arming is
    // the safe reading of a corrupt slot: at worst the ladder re-fires (accepted noise),
    // never a missed alert.
    init(restoring state: PersistedNotificationState) {
        for (key, entries) in state.accounts {
            var slots: [WindowID: Int] = [:]
            for entry in entries {
                guard let span = entry.span.model, let scope = entry.scope.model else { continue }
                guard NotificationEngine.storableBands.contains(entry.threshold) else { continue }
                slots[WindowID(span: span, scope: scope)] = entry.threshold
            }
            if !slots.isEmpty { recorded[key] = slots }
        }
    }

    // The one decision point. Returns the alerts to deliver for THIS cycle and mutates
    // the per-(account, window) state.
    //
    // `discovered` is the AUTHORITATIVE roster: the identities of every account currently
    // in discovery, enabled or not, readable or not. Account-level reclamation drops any
    // recorded account NOT in it — so it, and NOT the readings, is what decides who is
    // gone. This is deliberately a separate parameter rather than "reclaim everyone not in
    // `readings`": `readings` carries only readable accounts (see `NotificationReading`),
    // and a caller checking a subset must still be able to declare the full roster so the
    // omitted accounts are HELD, not wiped. Task 9 wires a second caller
    // (`notifier.evaluate(store.accounts)`); making the roster explicit makes the
    // full-set property safe rather than lucky. A reading whose account is absent from the
    // roster is a caller bug and traps loudly.
    func evaluate(_ readings: [NotificationReading],
                  discovered roster: Set<AccountIdentity>) -> [NotificationAlert] {
        var alerts: [NotificationAlert] = []
        let rosterKeys = Set(roster.map { $0.storageKey })

        for reading in readings {
            let key = reading.ref.id.storageKey
            precondition(rosterKeys.contains(key),
                         "a reading was passed for an account absent from the discovered roster")
            var slots = recorded[key] ?? [:]

            // Reclaim windows that have LEFT this account (§6 churn: model-scoped windows
            // appear and retire). A window that read `.unknown` THIS cycle is still
            // present — its slot survives. Distinguishing "gone" from "present but
            // unknown" is why the unknown case below must leave the slot untouched rather
            // than look like a vanished window.
            let liveIDs = Set(reading.windows.map { $0.id })
            for id in slots.keys where !liveIDs.contains(id) {
                slots.removeValue(forKey: id)
                dirty = true
            }

            if reading.isEnabled {
                for window in reading.windows {
                    guard case .known(let percent) = window.utilization else {
                        // Unknown is NEITHER a crossing NOR a reset — it is no
                        // information. Leaving the recorded band untouched is load-bearing
                        // both ways: coercing to 0 would fire a spurious "dropped below
                        // threshold" reset, and on a genuinely high window that briefly
                        // read unknown it would later re-fire the whole ladder. §3 forbids
                        // `.unknown` becoming 0 for exactly this reason.
                        continue
                    }
                    let previous = slots[window.id] ?? 0

                    // Every band newly met fires, ascending — matching the shipped
                    // hysteresis (`Core/Notifier.swift`), now per window. A window that
                    // jumps from below 25% to 90% fires 25, 50, 75 and 90.
                    for band in NotificationEngine.bands where percent >= band && previous < band {
                        alerts.append(NotificationAlert(provider: reading.ref.provider,
                                                        accountLabel: reading.ref.label,
                                                        windowLabel: window.label,
                                                        threshold: band))
                    }

                    // The recorded band is always the highest band still met (§8: when
                    // usage drops below the recorded threshold it is lowered to the
                    // highest band still met, re-arming the alerts a reset clears). Above
                    // it only ever rose through the fire loop; here it also falls.
                    let met = NotificationEngine.bands.last { $0 <= percent } ?? 0
                    if met == 0 {
                        if slots[window.id] != nil { slots.removeValue(forKey: window.id); dirty = true }
                    } else if slots[window.id] != met {
                        slots[window.id] = met
                        dirty = true
                    }
                }
            }

            if slots.isEmpty {
                if recorded[key] != nil { recorded.removeValue(forKey: key); dirty = true }
            } else {
                recorded[key] = slots
            }
        }

        // §6 lifecycle, account level: state for an account absent from DISCOVERY is
        // reclaimed as a unit, keyed on `storageKey` — the same key and the same rule
        // task 7's engine uses, so a different account arriving at the same location can
        // never inherit the previous occupant's thresholds. Reclamation keys on the
        // authoritative roster, NOT on which accounts were readable this cycle: an
        // account that is discovered but merely unreadable right now (expired, failing)
        // holds its slots so recovery does not replay the whole ladder.
        for key in recorded.keys where !rosterKeys.contains(key) {
            recorded.removeValue(forKey: key)
            dirty = true
        }

        return alerts
    }

    // Hands the shell a blob to persist, or nil when nothing changed since the last
    // drain. Resets the dirty flag: persistence is a side effect the pure engine
    // describes and the impure shell performs.
    func drainPersistence() -> PersistedNotificationState? {
        guard dirty else { return nil }
        dirty = false
        return snapshot()
    }

    func snapshot() -> PersistedNotificationState {
        var accounts: [String: [PersistedWindowThreshold]] = [:]
        for (key, slots) in recorded {
            accounts[key] = slots
                .sorted { $0.value < $1.value }
                .map { PersistedWindowThreshold(span: PersistedWindowSpan($0.key.span),
                                                scope: PersistedWindowScope($0.key.scope),
                                                threshold: $0.value) }
        }
        return PersistedNotificationState(accounts: accounts)
    }

    // Test-only introspection: the recorded band for one (account, window), 0 if none.
    func recordedThreshold(_ identity: AccountIdentity, _ window: WindowID) -> Int {
        recorded[identity.storageKey]?[window] ?? 0
    }

    var trackedAccountKeys: [String] { recorded.keys.sorted() }
}

extension NotificationEngine {
    // The bridge from the store's projections to `evaluate`'s two arguments. Every
    // presentation contributes its identity to the roster (so a discovered-but-unreadable
    // account is HELD, not reclaimed), and only a readable one becomes a reading. Pure and
    // testable, so the §6/§8 lifecycle at the seam is pinned rather than eyeballed.
    static func inputs(
        from presentations: [AccountPresentation]
    ) -> (readings: [NotificationReading], discovered: Set<AccountIdentity>) {
        var readings: [NotificationReading] = []
        var discovered: Set<AccountIdentity> = []
        for presentation in presentations {
            discovered.insert(presentation.ref.id)
            guard let windows = presentation.state.authoritativeWindows else { continue }
            readings.append(NotificationReading(ref: presentation.ref,
                                                isEnabled: presentation.isEnabled,
                                                windows: windows))
        }
        return (readings, discovered)
    }
}

extension AccountState {
    // The windows the caller may treat as this account's COMPLETE current list. Only
    // `.active` and `.stale` expose one: for every other state the account cannot be read
    // right now, and its absence of windows must NOT be read as "the windows retired" — a
    // reclaim there would replay 25/50/75/90 for every window the moment the account
    // recovers. `.stale` already presents its windows as `.unknown` and holds its slots;
    // `nil` here makes `.expired`/`.failed`/`.signedOut`/`.pending` hold theirs the same
    // way. Task 7's auth path makes `.expired` recoverable (a single rejection re-reads
    // before expiring), so replaying the ladder on every re-login would be pure noise.
    var authoritativeWindows: [UsageWindow]? {
        switch self {
        case .active(let snapshot): return snapshot.windows
        case .stale(let snapshot, _): return snapshot.windows
        case .pending, .signedOut, .expired, .failed: return nil
        }
    }
}

// The restore DECISION, pure so the shell's `UserDefaults` read has no untested logic
// behind it (the shell is app-only and compiled by no test target). `.reclaim` means a
// blob was present but unreadable — a corrupt or old-version payload — and must be
// removed rather than left to be re-read and re-fail every launch.
enum NotificationRestore: Equatable {
    case empty                             // nothing persisted
    case restore(PersistedNotificationState)
    case reclaim                           // present but undecodable → delete it

    static func decide(_ data: Data?) -> NotificationRestore {
        guard let data else { return .empty }
        if let state = PersistedCodec.decode(PersistedNotificationState.self, from: data) {
            return .restore(state)
        }
        return .reclaim
    }
}

// The persisted shape (§8 state survives a relaunch). Kept next to the engine that owns
// it, PURE, so the round-trip is answerable in the test target. It reuses task 7's
// `PersistedWindowSpan`/`PersistedWindowScope` — the TAGGED mirrors that keep
// `.other(seconds: 18000)` distinct from `.session` and `.model(id:)` distinct from
// `.feature(id:)` across the disk — and goes through the same `PersistedCodec`, so an
// undecodable or old-version blob is rejected (treated as absent) rather than
// resurrected as garbage.
struct PersistedWindowThreshold: Codable, Equatable {
    let span: PersistedWindowSpan
    let scope: PersistedWindowScope
    let threshold: Int
}

struct PersistedNotificationState: Codable, Equatable, VersionedPayload {
    // 1: new namespace in this task. There is no version-0 to migrate — the shipped
    // single global `last_notified_threshold` key carries no per-account structure worth
    // salvaging, and reading it would re-import the very race being removed.
    static let currentVersion = 1

    var version: Int
    // account storageKey -> its window thresholds.
    var accounts: [String: [PersistedWindowThreshold]]

    init(accounts: [String: [PersistedWindowThreshold]]) {
        self.version = PersistedNotificationState.currentVersion
        self.accounts = accounts
    }
}
