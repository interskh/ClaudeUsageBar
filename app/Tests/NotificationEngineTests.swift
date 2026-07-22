import Foundation

// §8, under test. The shipped notifier kept ONE global `lastNotifiedThreshold`; the
// headline test here is the race that made it wrong — two accounts crossing the same
// band, where the global slot suppressed one. Every test names the production change
// that makes it fail.
//
// @MainActor because `NotificationEngine` is @MainActor (§6's single-writer domain,
// compiler-checked). Nothing here sleeps or delivers a notification: the pure engine
// returns the alerts and the tests assert on them.
@MainActor
enum NotificationEngineTests {

    // MARK: - Fixtures

    static func ref(_ provider: ProviderKind, _ id: String, label: String? = nil) -> AccountRef {
        AccountRef(id: AccountIdentity(provider: provider, id), label: label ?? id)
    }

    static func window(_ span: WindowSpan,
                       _ scope: WindowScope,
                       _ percent: Int?,
                       label: String = "w") -> UsageWindow {
        UsageWindow(id: WindowID(span: span, scope: scope),
                    label: label,
                    utilization: percent.map { Utilization.percent($0) } ?? .unknown,
                    resetsAt: nil,
                    isActive: false)
    }

    static func window(_ span: WindowSpan,
                       _ percent: Int?,
                       label: String = "w") -> UsageWindow {
        window(span, .account, percent, label: label)
    }

    static func reading(_ ref: AccountRef,
                        enabled: Bool = true,
                        _ windows: [UsageWindow]) -> NotificationReading {
        NotificationReading(ref: ref, isEnabled: enabled, windows: windows)
    }

    // Evaluate with an explicit roster. Defaults the roster to exactly the readings'
    // accounts — the common case — while letting a test declare a wider roster (e.g. an
    // expired account that is discovered but not a reading).
    @discardableResult
    static func eval(_ engine: NotificationEngine,
                     _ readings: [NotificationReading],
                     discovered: Set<AccountIdentity>? = nil) -> [NotificationAlert] {
        engine.evaluate(readings, discovered: discovered ?? Set(readings.map { $0.ref.id }))
    }

    // How many slots the engine holds for an account — distinguishes "removed" from
    // "stored as 0", which `recordedThreshold` cannot.
    static func slots(_ engine: NotificationEngine, _ ref: AccountRef) -> Int {
        engine.snapshot().accounts[ref.id.storageKey]?.count ?? 0
    }

    // Bands (ascending) the given alerts fired for one account label.
    static func bands(_ alerts: [NotificationAlert], _ label: String) -> [Int] {
        alerts.filter { $0.accountLabel == label }.map { $0.threshold }.sorted()
    }

    static func bands(_ alerts: [NotificationAlert], _ label: String, window: String) -> [Int] {
        alerts.filter { $0.accountLabel == label && $0.windowLabel == window }
            .map { $0.threshold }.sorted()
    }

    // MARK: - Suite

    static func run() {
        raceTwoAccountsSameBandDoNotSuppress()
        modelScopedShortAndLongAreDistinctAlerts()
        sameSpanDifferentScopeKindAreDistinct()
        hysteresisPerWindow()
        unknownIsNeitherCrossingNorReset()
        alertTextNamesTheActualSource()
        alertTitleIsPerProvider()
        volatileIdentityRefiresWhileStableTwinDoesNot()
        vanishedAccountStateReclaimed()
        retiredWindowSlotReclaimed()
        lowWindowCarriesNoSlot()
        differentAccountDoesNotInheritThresholds()
        disabledAccountIsFrozen()
        discoveredButUnreadableAccountHoldsSlots()
        inputsSplitsReadableFromRoster()
        fullLadderFromZeroToNinety()
        persistRestoreRoundTrip()
        persistDeltaAndReclaimDirties()
        corruptStoredThresholdReArms()
        undecodableBlobReclaimedNotResurrected()
        restoreDecisionReclaimsOnlyUndecodable()
    }

    // THE headline. Two accounts each with a session window at 75%. The shipped global
    // `lastNotifiedThreshold` recorded A's 75 and suppressed B's — so B's near-exhaustion
    // was silent. Both must alert independently.
    //   Mutation that fails this: dropping the account from the state key (one shared
    //   slot), or `previous < band` weakened so the second write suppresses the first.
    static func raceTwoAccountsSameBandDoNotSuppress() {
        let engine = NotificationEngine()
        let a = ref(.anthropic, "acct-a", label: "work-fiona")
        let b = ref(.anthropic, "acct-b", label: "work-ethan")
        let alerts = eval(engine, [
            reading(a, [window(.session, 75, label: "session")]),
            reading(b, [window(.session, 75, label: "session")]),
        ])
        TestHarness.expect("race: account A fires the full ladder to 75",
                           bands(alerts, "work-fiona"), [25, 50, 75])
        TestHarness.expect("race: account B is NOT suppressed by A",
                           bands(alerts, "work-ethan"), [25, 50, 75])
    }

    // A model-scoped SHORT window and a model-scoped LONG window at the same percent are
    // two distinct alerts. Fails if the key collapses span (or scope) — the exact
    // collision §3/§8 keep span and scope as independent axes to prevent.
    static func modelScopedShortAndLongAreDistinctAlerts() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")
        let alerts = eval(engine, [reading(acct, [
            window(.session, .model(id: "opus"), 75, label: "opus 5h"),
            window(.weekly, .model(id: "opus"), 75, label: "opus weekly"),
        ])])
        TestHarness.expect("distinct span: short window alerts",
                           bands(alerts, "acct", window: "opus 5h"), [25, 50, 75])
        TestHarness.expect("distinct span: long window alerts separately",
                           bands(alerts, "acct", window: "opus weekly"), [25, 50, 75])
    }

    // Cross 75 → drop to 60 (slot lowers to 50) → cross 75 again re-alerts 75. The
    // lowering is what re-arms the alert. Fails if the recorded band does not fall on a
    // drop (no re-alert) or falls to 0 (re-fires the whole ladder).
    static func hysteresisPerWindow() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")
        let id = WindowID(span: .session, scope: .account)

        _ = eval(engine, [reading(acct, [window(.session, 75, label: "s")])])
        TestHarness.expect("hysteresis: recorded 75 after crossing",
                           engine.recordedThreshold(acct.id, id), 75)

        let dropped = eval(engine, [reading(acct, [window(.session, 60, label: "s")])])
        TestHarness.expect("hysteresis: no alert on a drop", bands(dropped, "acct"), [])
        TestHarness.expect("hysteresis: recorded lowered to 50, not 0",
                           engine.recordedThreshold(acct.id, id), 50)

        let recrossed = eval(engine, [reading(acct, [window(.session, 75, label: "s")])])
        TestHarness.expect("hysteresis: 75 re-alerts (only 75, not 25/50)",
                           bands(recrossed, "acct"), [75])

        // A drop landing EXACTLY on a band lowers to that band, not below it. A strict-`<`
        // reset bug would record 25 here (re-arming 50), which every non-boundary drop
        // test misses.
        _ = eval(engine, [reading(acct, [window(.session, 50, label: "s")])])
        TestHarness.expect("hysteresis: drop exactly onto 50 records 50, not 25",
                           engine.recordedThreshold(acct.id, id), 50)
    }

    // An `.unknown` reading leaves the recorded band untouched — neither a crossing nor a
    // reset. Fails if unknown is coerced to 0 (which would re-fire the ladder next time)
    // or treated as a crossing.
    static func unknownIsNeitherCrossingNorReset() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")
        let id = WindowID(span: .session, scope: .account)

        _ = eval(engine, [reading(acct, [window(.session, 75, label: "s")])])
        let unknown = eval(engine, [reading(acct, [window(.session, nil, label: "s")])])
        TestHarness.expect("unknown: no alert", bands(unknown, "acct"), [])
        TestHarness.expect("unknown: recorded band unchanged at 75",
                           engine.recordedThreshold(acct.id, id), 75)

        // Prove the slot was truly untouched: a subsequent real drop lowers from 75 to
        // 50, which only holds if unknown did NOT reset it to 0 in between.
        let dropped = eval(engine, [reading(acct, [window(.session, 60, label: "s")])])
        TestHarness.expect("unknown: later drop lowers 75→50 (slot survived unknown)",
                           engine.recordedThreshold(acct.id, id), 50)
        TestHarness.expect("unknown: the drop itself does not alert", bands(dropped, "acct"), [])
    }

    // The alert names the actual account and window. Fails if either label is hardcoded
    // or swapped — the "5-hour session limit" false assertion the shipped notifier made
    // for every window including the weekly one.
    static func alertTextNamesTheActualSource() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "work-fiona")
        let alerts = eval(engine, [reading(acct, [window(.weekly, 75, label: "weekly")])])
        guard let top = alerts.first(where: { $0.threshold == 75 }) else {
            TestHarness.check("source: a 75% alert was produced", false)
            return
        }
        TestHarness.expect("source: account label", top.accountLabel, "work-fiona")
        TestHarness.expect("source: window label", top.windowLabel, "weekly")
        TestHarness.expect("source: rendered summary", top.summary, "work-fiona · weekly hit 75%")
    }

    // The volatile-identity case (§5/§6 carried forward). One account with a STABLE window
    // (session/account) and a VOLATILE one (a positional feature id). After a reorder the
    // volatile id changes and re-fires its ladder — accepted noise — while the stable
    // window across the SAME reorder does NOT re-fire. Fails if a reorder suppresses or
    // duplicates a stable window, or if window reclamation is dropped (stale slot lingers).
    static func volatileIdentityRefiresWhileStableTwinDoesNot() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")

        let first = eval(engine, [reading(acct, [
            window(.session, .account, 90, label: "stable"),
            window(.weekly, .feature(id: "index:0"), 90, label: "vol"),
        ])])
        TestHarness.expect("volatile: stable window fires the ladder first time",
                           bands(first, "acct", window: "stable"), [25, 50, 75, 90])
        TestHarness.expect("volatile: volatile window fires the ladder first time",
                           bands(first, "acct", window: "vol"), [25, 50, 75, 90])

        // Reorder: the positional id moves 0 → 1, the stable id is unchanged.
        let second = eval(engine, [reading(acct, [
            window(.session, .account, 90, label: "stable"),
            window(.weekly, .feature(id: "index:1"), 90, label: "vol"),
        ])])
        TestHarness.expect("volatile: reordered volatile window re-fires (accepted)",
                           bands(second, "acct", window: "vol"), [25, 50, 75, 90])
        TestHarness.expect("volatile: STABLE window does NOT re-fire across the reorder",
                           bands(second, "acct", window: "stable"), [])
        // The OLD positional id must be RECLAIMED, not merely shadowed — otherwise the
        // churned `index:n`/`dup:` slots accumulate without bound. Two live slots (stable +
        // new vol), and the old id absent from the persisted snapshot.
        TestHarness.expect("volatile: old positional id reclaimed, not retained",
                           engine.recordedThreshold(acct.id,
                                                    WindowID(span: .weekly, scope: .feature(id: "index:0"))), 0)
        TestHarness.expect("volatile: exactly two slots survive (no unbounded growth)",
                           slots(engine, acct), 2)
    }

    // A vanished account's threshold state is reclaimed as a unit, so its identity
    // reappearing re-arms from zero rather than resurrecting a stale band. Fails if the
    // account-level reclaim sweep is removed.
    static func vanishedAccountStateReclaimed() {
        let engine = NotificationEngine()
        let a = ref(.anthropic, "acct-a", label: "a")
        let b = ref(.anthropic, "acct-b", label: "b")

        _ = eval(engine, [reading(a, [window(.session, 90, label: "s")])])
        TestHarness.check("vanish: A tracked before it leaves",
                          engine.trackedAccountKeys.contains(a.id.storageKey))

        // A absent from this cycle; only B present.
        _ = eval(engine, [reading(b, [window(.session, 10, label: "s")])])
        TestHarness.check("vanish: A's state reclaimed once it leaves discovery",
                          !engine.trackedAccountKeys.contains(a.id.storageKey))

        // A returns high — re-fires because its history was reclaimed, not resurrected.
        let back = eval(engine, [reading(a, [window(.session, 90, label: "s")])])
        TestHarness.expect("vanish: returning A re-fires the full ladder",
                           bands(back, "a"), [25, 50, 75, 90])
    }

    // A retired model-scoped window's slot is reclaimed even while its account stays. Fails
    // if per-window reclaim is dropped: the retired window's band would linger and suppress
    // the next window that happens to reuse the id.
    static func retiredWindowSlotReclaimed() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")
        let retired = WindowID(span: .session, scope: .model(id: "old"))

        _ = eval(engine, [reading(acct, [window(.session, .model(id: "old"), 90, label: "old")])])
        TestHarness.expect("retire: window recorded 90",
                           engine.recordedThreshold(acct.id, retired), 90)

        // Account still present, but the model-scoped window is gone.
        _ = eval(engine, [reading(acct, [window(.session, .model(id: "new"), 30, label: "new")])])
        TestHarness.expect("retire: retired window's slot reclaimed",
                           engine.recordedThreshold(acct.id, retired), 0)
    }

    // A different account (different identity) never inherits another's thresholds — the
    // misattribution the global slot committed. B starts fresh regardless of A's history.
    static func differentAccountDoesNotInheritThresholds() {
        let engine = NotificationEngine()
        let a = ref(.anthropic, "acct-a", label: "a")
        let b = ref(.anthropic, "acct-b", label: "b")

        _ = eval(engine, [reading(a, [window(.session, 90, label: "s")])])
        // B appears (A gone) at 30% — must fire its OWN 25 alert, not be suppressed by A's
        // recorded 90.
        let alerts = eval(engine, [reading(b, [window(.session, 30, label: "s")])])
        TestHarness.expect("no-inherit: B fires its own 25, not suppressed by A's 90",
                           bands(alerts, "b"), [25])
    }

    // A disabled account produces no alerts (§7.3 / §8: only ENABLED accounts notify). Its
    // presence still protects it from account-level reclaim. Fails if `isEnabled` is
    // ignored.
    static func disabledAccountIsFrozen() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")
        let disabled = eval(engine, [reading(acct, enabled: false,
                                                [window(.session, 90, label: "s")])])
        TestHarness.expect("disabled: no alerts while disabled", bands(disabled, "acct"), [])

        // Re-enabled at the same level: now it fires, since the disabled pass recorded
        // nothing.
        let enabled = eval(engine, [reading(acct, [window(.session, 90, label: "s")])])
        TestHarness.expect("disabled: re-enabling fires the ladder",
                           bands(enabled, "acct"), [25, 50, 75, 90])
    }

    // The exact-boundary and full-ladder behaviour: a jump from below 25 straight to 90
    // fires all four bands once. Fails if `percent >= band` becomes `>` (89.5→90 rounding
    // and the 90 boundary both matter) or the ascending order is broken.
    static func fullLadderFromZeroToNinety() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")
        let alerts = eval(engine, [reading(acct, [window(.session, 90, label: "s")])])
        TestHarness.expect("ladder: 0→90 fires all four bands", bands(alerts, "acct"), [25, 50, 75, 90])

        // Idempotent: a second identical reading fires nothing.
        let again = eval(engine, [reading(acct, [window(.session, 90, label: "s")])])
        TestHarness.expect("ladder: steady 90 does not re-fire", bands(again, "acct"), [])
    }

    // Threshold state survives a simulated relaunch: snapshot → encode → decode → restore,
    // and the restored engine does NOT re-alert a band already recorded. Fails if
    // persistence is dropped or the round-trip loses a window's identity.
    static func persistRestoreRoundTrip() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")
        _ = eval(engine, [reading(acct, [
            window(.session, .account, 75, label: "s"),
            window(.weekly, .model(id: "opus"), 90, label: "w"),
        ])])

        guard let state = engine.drainPersistence(),
              let data = PersistedCodec.encode(state),
              let decoded = PersistedCodec.decode(PersistedNotificationState.self, from: data) else {
            TestHarness.check("relaunch: state encodes and decodes", false)
            return
        }
        let restored = NotificationEngine(restoring: decoded)
        TestHarness.expect("relaunch: session/account band restored",
                           restored.recordedThreshold(acct.id, WindowID(span: .session, scope: .account)), 75)
        TestHarness.expect("relaunch: weekly/model band restored",
                           restored.recordedThreshold(acct.id, WindowID(span: .weekly, scope: .model(id: "opus"))), 90)

        // The same readings after relaunch must NOT re-alert.
        let after = eval(restored, [reading(acct, [
            window(.session, .account, 75, label: "s"),
            window(.weekly, .model(id: "opus"), 90, label: "w"),
        ])])
        TestHarness.expect("relaunch: no re-alert for bands already recorded",
                           bands(after, "acct"), [])
    }

    // An undecodable or old-version blob is reclaimed (decode returns nil), not resurrected
    // as garbage — mirrors task 7's version partitioning. Fails if the codec accepts a
    // wrong-version payload.
    static func undecodableBlobReclaimedNotResurrected() {
        TestHarness.check("blob: garbage bytes decode to nil",
                          PersistedCodec.decode(PersistedNotificationState.self,
                                                from: Data("not json".utf8)) == nil)
        let wrongVersion = Data(#"{"version":99,"accounts":{}}"#.utf8)
        TestHarness.check("blob: wrong-version payload decodes to nil",
                          PersistedCodec.decode(PersistedNotificationState.self,
                                                from: wrongVersion) == nil)
        let current = Data(#"{"version":1,"accounts":{}}"#.utf8)
        TestHarness.check("blob: current-version empty payload decodes",
                          PersistedCodec.decode(PersistedNotificationState.self,
                                                from: current) != nil)
    }

    // Same SPAN, different scope KIND at the same id string: `.model(id:"x")` and
    // `.feature(id:"x")` are distinct windows and distinct alerts. Fails if the key
    // conflates the scope kind — the sibling of the span-collapse bug, which the
    // span-varying test above cannot catch.
    static func sameSpanDifferentScopeKindAreDistinct() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")
        let alerts = eval(engine, [reading(acct, [
            window(.session, .model(id: "x"), 75, label: "model-x"),
            window(.session, .feature(id: "x"), 75, label: "feature-x"),
        ])])
        TestHarness.expect("scope-kind: model-scoped window alerts",
                           bands(alerts, "acct", window: "model-x"), [25, 50, 75])
        TestHarness.expect("scope-kind: feature-scoped window alerts separately",
                           bands(alerts, "acct", window: "feature-x"), [25, 50, 75])
        TestHarness.expect("scope-kind: two distinct slots, not one",
                           slots(engine, acct), 2)
    }

    // FIX 1. The alert TITLES itself from its provider, so the delivery shell brands a
    // Codex reading as Codex — not the hardcoded "Claude Usage Alert" the shipped shell
    // stamped on everything. Delivery is app-only and untestable; the alert carrying
    // enough to title itself is the pinnable half.
    static func alertTitleIsPerProvider() {
        let engine = NotificationEngine()
        let anthropic = ref(.anthropic, "a", label: "a")
        let codex = ref(.codex, "c", label: "c")
        let anthropicAlerts = eval(engine, [reading(anthropic, [window(.session, 25, label: "s")])])
        let codexAlerts = eval(engine, [reading(codex, [window(.session, 25, label: "s")])],
                               discovered: [anthropic.id, codex.id])
        TestHarness.expect("title: anthropic alert titles Claude",
                           anthropicAlerts.first?.title, "Claude Usage Alert")
        TestHarness.expect("title: codex alert titles Codex",
                           codexAlerts.first?.title, "Codex Usage Alert")
    }

    // A window sitting below 25% carries NO slot: steady low traffic must not grow the
    // keyspace, and an account whose every window is below 25% is not kept as an empty
    // dict. `recordedThreshold` returns 0 for both "removed" and "stored as 0", so this
    // asserts the SLOT COUNT — the only thing that distinguishes them.
    static func lowWindowCarriesNoSlot() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")

        _ = eval(engine, [reading(acct, [window(.session, 10, label: "s")])])
        TestHarness.expect("low: a sub-25 window is stored as no slot at all",
                           slots(engine, acct), 0)
        TestHarness.check("low: account with no slots is not tracked",
                          !engine.trackedAccountKeys.contains(acct.id.storageKey))

        // And a window that WAS tracked then drops below 25 is REMOVED, not stored as 0.
        _ = eval(engine, [reading(acct, [window(.session, 30, label: "s")])])
        TestHarness.expect("low: crossing 25 creates one slot", slots(engine, acct), 1)
        _ = eval(engine, [reading(acct, [window(.session, 10, label: "s")])])
        TestHarness.expect("low: dropping back below 25 removes the slot",
                           slots(engine, acct), 0)
    }

    // FIX 4. An account that is DISCOVERED but not readable right now (expired/failed)
    // HOLDS its slots — reclamation keys on the roster, not on which accounts were
    // readable this cycle. Otherwise recovery to `.active` replays 25/50/75/90 for every
    // window, the avoidable twin of the volatile-id noise.
    static func discoveredButUnreadableAccountHoldsSlots() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")

        _ = eval(engine, [reading(acct, [window(.session, 90, label: "s")])])
        TestHarness.expect("hold: recorded 90 while readable",
                           engine.recordedThreshold(acct.id, WindowID(span: .session, scope: .account)), 90)

        // Account still discovered (in roster) but unreadable → NOT a reading this cycle.
        _ = eval(engine, [], discovered: [acct.id])
        TestHarness.expect("hold: slot survives an unreadable cycle",
                           engine.recordedThreshold(acct.id, WindowID(span: .session, scope: .account)), 90)

        // Recovery to active at the same level must NOT replay the ladder.
        let recovered = eval(engine, [reading(acct, [window(.session, 90, label: "s")])])
        TestHarness.expect("hold: recovery does not re-fire the ladder",
                           bands(recovered, "acct"), [])
    }

    // The seam that decides which accounts are readings vs roster-only. `.active`/`.stale`
    // present authoritative windows; every other state is roster-only (its slots held).
    // This pins FIX 4 at the bridge task 9 wires.
    static func inputsSplitsReadableFromRoster() {
        let active = present(ref(.anthropic, "a", label: "a"),
                             .active(snap(ref(.anthropic, "a", label: "a"), [window(.session, 90, label: "s")])))
        let stale = present(ref(.anthropic, "b", label: "b"),
                            .stale(snap(ref(.anthropic, "b", label: "b"), [window(.session, 40, label: "s")]),
                                   since: Date(timeIntervalSince1970: 0)))
        let expired = present(ref(.anthropic, "c", label: "c"), .expired(Date(timeIntervalSince1970: 0)))
        let signedOut = present(ref(.codex, "d", label: "d"), .signedOut)

        let inputs = NotificationEngine.inputs(from: [active, stale, expired, signedOut])
        TestHarness.expect("inputs: only active+stale become readings", inputs.readings.count, 2)
        TestHarness.expect("inputs: every account is in the roster", inputs.discovered.count, 4)
        TestHarness.check("inputs: expired is roster-only, not a reading",
                          inputs.discovered.contains(ref(.anthropic, "c").id)
                          && !inputs.readings.contains { $0.ref.id == ref(.anthropic, "c").id })
    }

    // The dirty-flag persist-delta: `drainPersistence` returns a payload only when state
    // actually changed, and a WINDOW-ONLY reclamation counts as a change (a stale on-disk
    // slot must not linger). Fails on write amplification (task 7's concern for tasks
    // 9-10) or on a reclamation that forgets to mark dirty.
    static func persistDeltaAndReclaimDirties() {
        let engine = NotificationEngine()
        let acct = ref(.anthropic, "acct", label: "acct")

        _ = eval(engine, [reading(acct, [
            window(.session, .account, 90, label: "keep"),
            window(.weekly, .model(id: "gone"), 90, label: "gone"),
        ])])
        TestHarness.check("delta: first drain after a change yields a payload",
                          engine.drainPersistence() != nil)
        TestHarness.check("delta: a second drain with no change yields nil",
                          engine.drainPersistence() == nil)

        // An idempotent re-evaluation changes nothing → still nil.
        _ = eval(engine, [reading(acct, [
            window(.session, .account, 90, label: "keep"),
            window(.weekly, .model(id: "gone"), 90, label: "gone"),
        ])])
        TestHarness.check("delta: an unchanged evaluation does not dirty",
                          engine.drainPersistence() == nil)

        // Retire the model-scoped window: a pure reclamation, no crossing — must dirty.
        _ = eval(engine, [reading(acct, [window(.session, .account, 90, label: "keep")])])
        TestHarness.check("delta: a window-only reclamation dirties the state",
                          engine.drainPersistence() != nil)
    }

    // FIX 2. A persisted threshold outside the four bands is a corrupt slot and re-arms to
    // 0 on restore, rather than being trusted. A stored `99` would otherwise mean no band
    // `<= 99` ever counts as a fresh crossing — 90% silently never fires, the suppression
    // this task removes arriving through the persistence door.
    static func corruptStoredThresholdReArms() {
        let acct = ref(.anthropic, "acct", label: "acct")
        let poisoned = PersistedNotificationState(accounts: [
            acct.id.storageKey: [
                PersistedWindowThreshold(span: PersistedWindowSpan(.session),
                                         scope: PersistedWindowScope(.account),
                                         threshold: 99)
            ]
        ])
        let engine = NotificationEngine(restoring: poisoned)
        TestHarness.expect("corrupt: an out-of-band stored threshold is dropped (re-armed)",
                           engine.recordedThreshold(acct.id, WindowID(span: .session, scope: .account)), 0)

        // And 90% now FIRES rather than being suppressed forever.
        let alerts = eval(engine, [reading(acct, [window(.session, 90, label: "s")])])
        TestHarness.expect("corrupt: 90% fires after re-arming",
                           bands(alerts, "acct"), [25, 50, 75, 90])
    }

    // FIX 2 coverage of the restore SIDE EFFECT decision (the shell's delete is app-only,
    // but the decision is pure). Undecodable → reclaim; nil → empty; valid → restore.
    static func restoreDecisionReclaimsOnlyUndecodable() {
        TestHarness.check("restore-decision: nil → empty",
                          NotificationRestore.decide(nil) == .empty)
        TestHarness.check("restore-decision: garbage → reclaim (delete it)",
                          NotificationRestore.decide(Data("not json".utf8)) == .reclaim)
        TestHarness.check("restore-decision: wrong version → reclaim",
                          NotificationRestore.decide(Data(#"{"version":99,"accounts":{}}"#.utf8)) == .reclaim)
        let valid = PersistedCodec.encode(PersistedNotificationState(accounts: [:]))
        if case .restore = NotificationRestore.decide(valid) {
            TestHarness.check("restore-decision: valid → restore", true)
        } else {
            TestHarness.check("restore-decision: valid → restore", false)
        }
    }

    // MARK: - Presentation fixtures (for the inputs() seam)

    static func snap(_ ref: AccountRef, _ windows: [UsageWindow]) -> Snapshot {
        Snapshot(account: ref, windows: windows, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    static func present(_ ref: AccountRef, _ state: AccountState) -> AccountPresentation {
        AccountPresentation(ref: ref,
                            state: state,
                            isEnabled: true,
                            isPollingStopped: false,
                            lastSuccessAt: nil,
                            degradationNote: nil,
                            nextPollAt: nil,
                            warnings: [])
    }
}
