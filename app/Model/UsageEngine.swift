import Foundation

// The account registry and the whole of §6's polling policy, with nothing impure in it.
// PURE: this file compiles into the test target, so adaptive backoff, hysteretic
// recovery, the credential budget, the cache horizon and the state lifecycle are all
// exercised with an injected `now` and no timer, no network, no defaults database, and
// no sleeping. `Core/UsageStore.swift` is the shell that owns those four things and
// does nothing else.
//
// SINGLE WRITER (§6), and `@MainActor` is how that is CHECKED rather than asserted.
// Accounts fetch concurrently and independently, but every mutation of the registry, of
// the menu-bar projection and of persisted state is serialised onto the main actor by
// the type system — a comment saying "call this on one thread" is the shape of defect
// task 6 spent a round on. Fetches themselves are `nonisolated async` on the providers
// and run off the main actor; only their results come back here.
//
// TIME IS ALWAYS A PARAMETER. There is no stored clock and no `Date()` anywhere below.

// What the app can currently see of an account's stored credential, WITHOUT holding any
// of it. §6 forbids retaining the blob: a real entry on the target machine carries an
// `mcpOAuth` section with live client secrets for unrelated third-party servers, so the
// comparison value is a digest and the blob is discarded by whoever read it.
struct CredentialFact: Equatable, Sendable {
    let digest: String?     // nil when there is no credential to observe
    let expiresAt: Date?    // the credential's OWN recorded expiry, not a guess

    init(digest: String? = nil, expiresAt: Date? = nil) {
        self.digest = digest
        self.expiresAt = expiresAt
    }
}

// One account as the periodic local survey found it. §6 asks for two things that are
// both cheap and both local — re-running discovery on a schedule, and watching for a
// stored credential to change — and this is deliberately ONE shape carrying both, so
// they cannot drift apart or run on schedules that disagree. A stopped account is
// surveyed exactly like a live one, which is what gives it a path back to life.
struct AccountObservation: Sendable {
    let account: DiscoveredAccount
    // How the credential is ADDRESSED — the Anthropic service name, the Codex file path.
    // This is a FALLBACK for the budget key, not the budget key itself: see below.
    let credentialLocation: String
    let credential: CredentialFact

    init(account: DiscoveredAccount,
         credentialLocation: String,
         credential: CredentialFact = CredentialFact()) {
        self.account = account
        self.credentialLocation = credentialLocation
        self.credential = credential
    }

    // §6: "the budget is scoped to the CREDENTIAL, not to the logical account", because
    // throttling is enforced upstream PER ACCESS TOKEN.
    //
    // The location is not the token. An Anthropic service name is a digest of a
    // configuration PATH, so two directories holding the same credential — a copied
    // configuration, the exact scenario §6 names — resolve to two different service
    // names and would each be granted a full budget: ten requests in 300s against the
    // one limit that binds. Task 4's handoff recommended keying on the service name and
    // that recommendation named the wrong identifier; this is the correction.
    //
    // The digest is the same value §6 already compares for change detection, so nothing
    // new is read or held. The location survives as the fallback for the case where
    // there is no credential to digest, and the two are namespaced so a digest can never
    // collide with a path.
    var budgetKey: String {
        if let digest = credential.digest { return "digest:" + digest }
        return "location:" + credentialLocation
    }
}

// A claim on one fetch. §6 makes the store the single writer, and this is what lets it
// stay one: a completion carries the token it was issued, so a fetch that was abandoned,
// superseded, disabled, or belongs to a previous occupant of the same identity is
// REJECTED rather than allowed to overwrite newer state. Tracking only WHETHER a fetch
// is in flight is an ABA: the replacement's marker is cleared by the original's late
// return.
struct PollTask: Equatable, Sendable {
    let ref: AccountRef
    let trigger: PollTrigger
    let token: Int
}

// What a row needs (§7.2) — and nothing a row does not. The raw response body of §5 is
// reachable only through `UsageEngine.retainedRawBody(for:)`, deliberately not from
// here, so no display path can grow a dependency on it and turn a diagnostic into a
// shadow parser.
struct AccountPresentation {
    let ref: AccountRef
    let state: AccountState      // already projected: over-horizon windows read unknown
    let isEnabled: Bool
    let isPollingStopped: Bool
    let lastSuccessAt: Date?
    // "rate limited · checking every 20 min" (§6): the degradation must be visible in
    // the account's own card. An account whose cadence has been stretched must never
    // just appear fresh.
    let degradationNote: String?
    let nextPollAt: Date?
    let warnings: [String]
    // §7.2 / §6: whether this account's card is expanded. It is PER-ACCOUNT state that
    // must survive a popover close and an app restart, and it rides inside the runtime
    // (and the persisted account blob) precisely so the account-lifecycle reclaim drops
    // it with the rest of the account's state — no parallel UI-owned map that would
    // orphan on departure or misattribute one account's expansion to another.
    let isExpanded: Bool
}

// §7.1's one figure per provider. `utilization` is never optional-as-zero: a provider
// with nothing to report is ABSENT from the array rather than present at 0%.
struct ProviderFigure: Equatable {
    let provider: ProviderKind
    let utilization: Utilization
    let accountLabel: String   // tooltip: which account the figure came from
    let windowLabel: String    // tooltip: which window
}

@MainActor
final class UsageEngine {
    // Everything one account needs to be polled, displayed and persisted. One struct so
    // that "drop this account's state as a unit" is a single dictionary removal plus one
    // delete op, rather than N parallel dictionaries that can disagree about which
    // accounts exist.
    private struct Runtime {
        var ref: AccountRef
        var discoveryState: AccountState
        var budgetKey: String
        var enabled: Bool
        var ladder: IntervalLadder
        var attempts: Int
        var consecutiveFailures: Int
        var authRejections: Int
        var lastFetchAttempt: Date?
        var lastSuccessAt: Date?
        var failingSince: Date?
        var lastFailureNote: String?
        var notBefore: Date?
        var nextDueAt: Date
        var pendingTrigger: PollTrigger?
        var inFlightSince: Date?
        var inFlightToken: Int?
        var stoppedExpiry: Date?
        var credentialDigest: String?
        var credentialExpiry: Date?
        var snapshot: Snapshot?
        var rawBody: Data?
        var lastBlock: PollBlock?
        // §7.2 card expansion. In-memory here, persisted in the account blob, reclaimed
        // with the account — never keyed outside the runtime.
        var expanded: Bool = false

        // §4.1 resolves an included account to exactly one of four credential states,
        // and only ONE of them means "there is something to send upstream". Everything
        // else — absent, locally lapsed, unreadable — has no token, so polling it would
        // spend a budget slot to be told what the local read already said.
        var credentialUsable: Bool {
            if case .pending = discoveryState { return true }
            return false
        }
    }

    // A task the shell claimed but never reported back on — a crash inside the provider,
    // a cancelled task. Without this an account sticks on `inFlight` forever and stops
    // polling silently, which is the failure mode hardest to notice from the UI. The
    // claim token is what makes releasing it safe: the abandoned fetch's late completion
    // no longer matches and is discarded.
    static let inFlightExpiry: TimeInterval = 180

    private var runtimes: [String: Runtime] = [:]
    private var order: [String] = []
    private var budgets: [String: RequestBudget] = [:]
    private var pendingOps: [String: PersistenceOp] = [:]
    // Persisted payloads read at launch whose account has not been discovered yet. They
    // are claimed by the first survey that finds the matching identity, and reclaimed by
    // the first survey that covers their provider without finding it.
    private var unclaimed: [String: PersistedAccountState] = [:]
    private let providerOrder: [ProviderKind]
    // Monotonic and never reset, so a token cannot be reused by a later occupant of the
    // same identity after a drop and re-discovery.
    private var nextToken = 1
    // §6's second-rejection test needs the credential's expiry AS OF THAT MOMENT, not as
    // of the last survey: the token rotates roughly 8-hourly and the whole point of the
    // re-read is that the survey's copy may be the stale one.
    private let credentialProbe: (AccountRef) -> CredentialFact

    init(providerOrder: [ProviderKind] = [.anthropic, .codex],
         restoring: [String: PersistedAccountState] = [:],
         restoringLedgers: [String: PersistedCredentialLedger] = [:],
         now: Date = Date(timeIntervalSince1970: 0),
         credentialProbe: @escaping (AccountRef) -> CredentialFact = { _ in CredentialFact() }) {
        self.providerOrder = providerOrder
        self.unclaimed = restoring
        self.credentialProbe = credentialProbe
        for (key, ledger) in restoringLedgers {
            var budget = RequestBudget()
            budget.merge(ledger.spends, now: now)
            guard !budget.spends.isEmpty else {
                // Nothing live left in it: reclaim rather than carry an empty namespace
                // forward, which is how the keyspace grows without bound.
                pendingOps[PersistedStore.ledgerNamespace + key] =
                    .delete(storageKey: PersistedStore.ledgerNamespace + key)
                continue
            }
            budgets[key] = budget
        }
    }

    // MARK: - Survey (periodic re-discovery + credential observation)

    // §6: discovery re-runs on a schedule and on popover open, "adding and removing
    // accounts without disturbing existing accounts' polling state". So an account
    // already in the registry has its ref, credential state and digest refreshed and
    // NOTHING else — not its interval, not its ladder, not its next due time.
    //
    // `covering` names the providers this survey actually ran, and it is load-bearing:
    // reclaiming state for every account not in `observations` would wipe Codex's
    // history any time an Anthropic-only refresh happened to be what ran.
    func ingest(_ observations: [AccountObservation],
                covering providers: Set<ProviderKind>,
                now: Date) {
        var seen = Set<String>()

        for observation in observations {
            let ref = observation.account.ref
            let key = ref.id.storageKey
            seen.insert(key)

            if var runtime = runtimes[key] {
                runtime.ref = ref
                runtime.discoveryState = observation.account.state
                rekeyBudget(&runtime, to: observation.budgetKey, now: now)
                apply(observation.credential, to: &runtime, now: now, armImmediately: true)
                runtimes[key] = runtime
                persist(key)
            } else {
                var runtime = fresh(ref: ref,
                                    state: observation.account.state,
                                    budgetKey: observation.budgetKey,
                                    now: now)
                if let restored = unclaimed.removeValue(forKey: key) {
                    restore(restored, into: &runtime, key: key, now: now)
                }
                // A runtime seen for the FIRST time takes its staggered first-poll time
                // rather than an immediate one: its digest necessarily "changes" from
                // nothing to something, and arming on that would fire every account in
                // the same instant — the exact simultaneity §6's stagger exists to stop.
                apply(observation.credential, to: &runtime, now: now, armImmediately: false)
                runtimes[key] = runtime
                order.append(key)
                persist(key)
            }
        }

        // §6's lifecycle: state for an account absent from discovery is RECLAIMED rather
        // than left in place. Five credential entries on this machine already belong to
        // directories that no longer exist; without this the keyspace grows without
        // bound and a stale entry silently resurrects the day an identifier is reused.
        for key in Array(order) where !seen.contains(key) {
            guard let runtime = runtimes[key], providers.contains(runtime.ref.provider) else {
                continue
            }
            drop(key)
        }
        // The same rule one layer up, where the guarantee above would never run: a
        // payload restored from disk whose account no discovery pass ever produced is
        // exactly the orphan case, and it is invisible to a sweep over `runtimes`
        // because it never became a runtime at all.
        for key in Array(unclaimed.keys) where !seen.contains(key) {
            guard let provider = UsageEngine.provider(ofStorageKey: key),
                  providers.contains(provider) else { continue }
            unclaimed.removeValue(forKey: key)
            pendingOps[key] = .delete(storageKey: key)
        }

        reclaimUnreferencedBudgets(now: now)
    }

    // `AccountIdentity.storageKey` puts the provider's raw value first, separated by a
    // colon, and escapes colons and backslashes inside every component AFTER it — so a
    // prefix test against a known provider name cannot be spoofed by a component.
    static func provider(ofStorageKey key: String) -> ProviderKind? {
        for provider in [ProviderKind.anthropic, .codex]
        where key.hasPrefix(provider.rawValue + ":") {
            return provider
        }
        return nil
    }

    private func fresh(ref: AccountRef, state: AccountState, budgetKey: String, now: Date) -> Runtime {
        Runtime(ref: ref,
                discoveryState: state,
                budgetKey: budgetKey,
                enabled: true,
                ladder: IntervalLadder(),
                attempts: 0,
                consecutiveFailures: 0,
                authRejections: 0,
                lastFetchAttempt: nil,
                lastSuccessAt: nil,
                failingSince: nil,
                lastFailureNote: nil,
                notBefore: nil,
                // Staggered (§6): N accounts appearing at launch must not fire together.
                nextDueAt: now.addingTimeInterval(
                    PollSchedule.initialDelay(storageKey: ref.id.storageKey)
                ),
                pendingTrigger: nil,
                inFlightSince: nil,
                inFlightToken: nil,
                stoppedExpiry: nil,
                credentialDigest: nil,
                credentialExpiry: nil,
                snapshot: nil,
                rawBody: nil,
                lastBlock: nil)
    }

    private func restore(_ state: PersistedAccountState,
                         into runtime: inout Runtime,
                         key: String,
                         now: Date) {
        runtime.enabled = state.enabled
        runtime.ladder = IntervalLadder(rung: state.rung, successStreak: state.successStreak)
        runtime.consecutiveFailures = state.consecutiveFailures
        runtime.lastFetchAttempt = state.lastFetchAttempt
        runtime.lastSuccessAt = state.lastSuccessAt
        runtime.failingSince = state.failingSince
        runtime.lastFailureNote = state.lastFailureNote
        runtime.notBefore = state.notBefore
        runtime.stoppedExpiry = state.stoppedExpiry
        runtime.credentialDigest = state.credentialDigest
        runtime.snapshot = state.snapshot?.model(account: runtime.ref)
        runtime.expanded = state.expanded ?? false
        // A restored account's first poll is still staggered, but never earlier than the
        // 60s floor its persisted `lastFetchAttempt` implies — that is what "cooldown
        // survives relaunch" means in practice.
        runtime.nextDueAt = now.addingTimeInterval(PollSchedule.initialDelay(storageKey: key))
    }

    // The credential the account is addressed by has changed identity — a token rotation,
    // or a duplicate-identity resolution picking the other directory (§4.1 ranks by
    // credential health, so the winner can flip between surveys). Carry the ledger over:
    // issuing a fresh allowance here is a hole in the budget that opens every 8 hours.
    //
    // The OLD ledger is deliberately left in place. It may still be referenced by another
    // account that has not migrated — two accounts sharing a credential do not necessarily
    // observe its rotation in the same survey — and clearing it would hand that account a
    // fresh allowance, which is the very hole this function exists to close.
    // `reclaimUnreferencedBudgets` collects it once it is both unreferenced and empty.
    // What keeps that safe is that `RequestBudget.merge` is idempotent over spend
    // identity, so a key flipping back and forth re-merges the same spends into the same
    // set rather than doubling the array on every flip.
    private func rekeyBudget(_ runtime: inout Runtime, to newKey: String, now: Date) {
        let oldKey = runtime.budgetKey
        guard oldKey != newKey else { return }
        runtime.budgetKey = newKey
        guard let carried = budgets[oldKey]?.spends, !carried.isEmpty else { return }
        budgets[newKey, default: RequestBudget()].merge(carried, now: now)
        persistLedger(newKey)
    }

    private func apply(_ fact: CredentialFact,
                       to runtime: inout Runtime,
                       now: Date,
                       armImmediately: Bool) {
        runtime.credentialExpiry = fact.expiresAt
        let changed = runtime.credentialDigest != fact.digest
        runtime.credentialDigest = fact.digest
        guard changed else { return }
        revive(&runtime, now: now, armImmediately: armImmediately)
    }

    // §6: "a stopped account must have a defined path back to life". The app cannot renew
    // a credential, so recovery depends entirely on the provider's CLI writing the store
    // at an unpredictable time — stopping the timer without a wake-up contract makes
    // expiry permanent, and the user signs in again while the app never notices.
    //
    // ANY change of the observed digest counts, INCLUDING the first one seen after a
    // relaunch. An earlier draft required a previously-observed digest before treating a
    // change as a change, which swallowed exactly the sequence that matters: an account
    // stops on a lapsed expiry, the user signs out (so the survey persists a nil digest),
    // the app is quit, the user signs back in, and the app comes up treating the new
    // credential as a baseline — the re-login invisible until the next rotation.
    //
    // Reviving is not a reset. The interval ladder is deliberately kept: it records what
    // the ENDPOINT tolerates, which a new credential does not change. `notBefore` is kept
    // for the same reason — it is an instruction we were given and it is still in force.
    // `failingSince` is kept deliberately too: a re-credentialed account has a cached
    // reading and no new one, which is exactly what `.stale` means, and clearing it would
    // present old data as fresh. The backoff EXPONENT is cleared, because carrying it
    // over makes the first failure after a recovery wait half an hour.
    private func revive(_ runtime: inout Runtime, now: Date, armImmediately: Bool) {
        runtime.stoppedExpiry = nil
        runtime.authRejections = 0
        runtime.consecutiveFailures = 0
        runtime.lastBlock = nil
        // Clearing the stop is what revival IS; firing immediately is a convenience on
        // top of it, and it is withheld on an account's first observation so the stagger
        // holds. An account revived without it polls on its own staggered schedule.
        if armImmediately { runtime.pendingTrigger = .discovery }
    }

    // MARK: - Settings

    // §7.3 / acceptance criterion 9: a disabled account leaves the popover, the menu-bar
    // worst-of and the polling schedule — but keeps its persisted state, because it is
    // still a discovered account and re-enabling it must not have cost its history.
    func setEnabled(_ enabled: Bool, for identity: AccountIdentity) {
        let key = identity.storageKey
        guard var runtime = runtimes[key] else { return }
        runtime.enabled = enabled
        if !enabled {
            runtime.pendingTrigger = nil
            // Any fetch already running for this account is disowned: the user has said
            // stop, and a completion landing afterwards must not write a reading in.
            runtime.inFlightToken = nil
            runtime.inFlightSince = nil
        }
        runtimes[key] = runtime
        persist(key)
    }

    func isEnabled(_ identity: AccountIdentity) -> Bool {
        runtimes[identity.storageKey]?.enabled ?? false
    }

    // §7.2: card expansion persists across popover opens and app restarts. It is keyed on
    // the durable identity and stored inside the account's own blob, so task 7's
    // lifecycle reclaims it on departure and a reused identifier cannot resurrect a stale
    // expansion — the runtime is rebuilt `fresh` (expanded == false) when an identity
    // reappears after a reclaim.
    func setExpanded(_ expanded: Bool, for identity: AccountIdentity) {
        let key = identity.storageKey
        guard var runtime = runtimes[key], runtime.expanded != expanded else { return }
        runtime.expanded = expanded
        runtimes[key] = runtime
        persist(key)
    }

    // MARK: - Requesting fetches

    // §6's manual Refresh: bypasses the interval, keeps every other gate. It is the same
    // request the scheduler makes with a different trigger — there is deliberately no
    // second admission path for it, because a manual refresh that skipped the budget
    // would be an unbounded hole in the one constraint that actually binds.
    func requestManualRefresh(now: Date) {
        for key in order { request(.manual, for: key) }
    }

    func requestManualRefresh(_ identity: AccountIdentity, now: Date) {
        request(.manual, for: identity.storageKey)
    }

    private func request(_ trigger: PollTrigger, for key: String) {
        guard var runtime = runtimes[key] else { return }
        runtime.pendingTrigger = trigger
        runtimes[key] = runtime
    }

    // Admission. THE single gate: scheduled polls, manual refreshes, the fetch a newly
    // discovered account gets, and the authentication re-read retry all pass through
    // here, and the trigger changes exactly two clauses — whether the interval applies,
    // and whether the 60s floor does.
    func block(for identity: AccountIdentity, trigger: PollTrigger, now: Date) -> PollBlock? {
        guard let runtime = runtimes[identity.storageKey] else { return .unknownAccount }
        return block(for: runtime, trigger: trigger, now: now)
    }

    private func block(for runtime: Runtime, trigger: PollTrigger, now: Date) -> PollBlock? {
        guard runtime.enabled else { return .disabled }
        guard runtime.stoppedExpiry == nil else { return .stopped }
        guard runtime.credentialUsable else { return .credentialUnusable }
        if let since = runtime.inFlightSince,
           now.timeIntervalSince(since) < UsageEngine.inFlightExpiry {
            return .inFlight
        }
        if trigger == .scheduled, now < runtime.nextDueAt {
            return .notDue(until: runtime.nextDueAt)
        }
        // The 60s floor of §6 — which exists to protect the endpoint from USER-DRIVEN
        // refreshes. The authentication re-read is neither user-driven nor optional: §6
        // requires ONE IMMEDIATE re-read and retry, because the token rotates roughly
        // 8-hourly and the retry is what tells a rotated credential apart from a dead
        // one. Deferring it by a minute is a minute of a healthy account rendering as
        // failed, for no protection the budget below does not already give.
        if trigger != .retry, let last = runtime.lastFetchAttempt {
            let floorEnds = last.addingTimeInterval(PollSchedule.manualFloor)
            if now < floorEnds { return .cooldown(until: floorEnds) }
        }
        if let notBefore = runtime.notBefore, now < notBefore {
            return .serverBackoff(until: notBefore)
        }
        if let free = budgets[runtime.budgetKey]?.availableAt(now: now), now < free {
            return .budgetExhausted(until: free)
        }
        return nil
    }

    // Claims every account that may fetch right now, recording the attempt and spending
    // the budget in the SAME step. Deliberately not a separate `due()` + `begin()` pair:
    // a caller that asked which accounts were due and then forgot to record the attempt
    // would poll the same account on every tick, and the budget would never see it.
    func claimDueFetches(now: Date) -> [PollTask] {
        var claimed: [PollTask] = []
        for key in order {
            guard var runtime = runtimes[key] else { continue }
            guard let trigger = trigger(for: runtime, now: now) else { continue }

            if let block = block(for: runtime, trigger: trigger, now: now) {
                runtime.lastBlock = block
                // A request that can never be admitted as asked is dropped rather than
                // left pending: re-enabling a disabled account, or reviving a stopped
                // one, would otherwise immediately fire a refresh the user asked for
                // minutes or hours earlier.
                switch block {
                case .disabled, .credentialUnusable, .stopped, .unknownAccount:
                    runtime.pendingTrigger = nil
                case .inFlight, .notDue, .cooldown, .serverBackoff, .budgetExhausted:
                    break
                }
                runtimes[key] = runtime
                continue
            }

            let token = nextToken
            nextToken += 1
            runtime.lastBlock = nil
            runtime.pendingTrigger = nil
            runtime.inFlightSince = now
            runtime.inFlightToken = token
            runtime.lastFetchAttempt = now
            runtime.attempts += 1
            // Spent inside the loop, so a second account sharing this credential sees
            // the slot gone on this very pass (§6: accounts sharing a credential share
            // one budget).
            budgets[runtime.budgetKey, default: RequestBudget()].spend(by: key, at: now)
            runtimes[key] = runtime
            persist(key)
            persistLedger(runtime.budgetKey)
            claimed.append(PollTask(ref: runtime.ref, trigger: trigger, token: token))
        }
        return claimed
    }

    private func trigger(for runtime: Runtime, now: Date) -> PollTrigger? {
        if let pending = runtime.pendingTrigger { return pending }
        return now >= runtime.nextDueAt ? .scheduled : nil
    }

    // MARK: - Outcomes

    // The single place an outcome is applied. Success and failure share the bookkeeping
    // that must not disagree between them — clearing the in-flight mark, scheduling the
    // next attempt, persisting — and differ only where §6 says they differ.
    //
    // The TASK is passed back, not just the account: a completion whose claim token is no
    // longer current belongs to a fetch that was abandoned, superseded, disabled, or
    // issued to a previous occupant of this identity, and applying it would overwrite
    // newer state with older.
    @discardableResult
    func finish(_ task: PollTask,
                _ result: Result<FetchedSnapshot, FetchError>,
                now: Date) -> Bool {
        let key = task.ref.id.storageKey
        guard var runtime = runtimes[key], runtime.inFlightToken == task.token else {
            return false
        }
        runtime.inFlightSince = nil
        runtime.inFlightToken = nil

        switch result {
        case .success(let fetched):
            // §6 tolerates losing history and does not tolerate misattributing it. A
            // snapshot projected for a different account must never be cached under this
            // one: persistence strips the embedded ref and rebuilds it from the KEY, so
            // after a relaunch the wrong account's readings would be indistinguishable
            // from this account's own.
            guard fetched.snapshot.account.id == task.ref.id else {
                transientFailure(&runtime,
                                 note: "provider returned a reading for a different account",
                                 now: now)
                break
            }
            runtime.ladder.succeeded()
            runtime.consecutiveFailures = 0
            runtime.authRejections = 0
            runtime.failingSince = nil
            runtime.lastFailureNote = nil
            runtime.notBefore = nil
            // The snapshot REPLACES the cached one; it is never merged into it. Some
            // window identities are deliberately volatile across polls — Anthropic's
            // positional `index:n` and Codex's `dup:<ordinal>` — so a merge would let a
            // window that no longer exists survive forever under an id the provider has
            // since given to something else.
            runtime.snapshot = fetched.snapshot
            runtime.rawBody = fetched.rawBody
            runtime.lastSuccessAt = now
            schedule(&runtime, after: runtime.ladder.interval, now: now)

        case .failure(let error):
            apply(error, to: &runtime, key: key, now: now)
        }

        if runtimes[key] != nil {
            runtimes[key] = runtime
            persist(key)
        }
        return true
    }

    // Every case handled explicitly and no `default:` — §5 added `.accountUnknown`
    // precisely because a new case silently folded into a retry path is what made an
    // account that had left discovery get retried forever.
    private func apply(_ error: FetchError, to runtime: inout Runtime, key: String, now: Date) {
        // §6 says a SECOND CONSECUTIVE rejection is what concludes anything. Anything
        // else in between breaks the run: after a transport failure the disambiguating
        // re-read never actually ran against a rejection, so the next rejection is a
        // first one and is owed its own re-read. Without this, `rejection → offline →
        // rejection an hour later` parks a healthy account.
        if case .authenticationRejected = error {} else { runtime.authRejections = 0 }

        switch error {
        case .rateLimited(let retryAfter):
            // The ONLY error that lengthens the interval, and it lengthens THIS
            // account's interval alone — §6's per-account isolation means a throttled
            // account must never stall the others, so nothing here touches any other
            // runtime. The shared budget is per credential, not per provider.
            runtime.ladder.throttled()
            let wait = max(retryAfter ?? 0, PollSchedule.manualFloor)
            runtime.notBefore = now.addingTimeInterval(wait)
            runtime.consecutiveFailures += 1
            fail(&runtime, note: "rate limited", now: now)
            schedule(&runtime, after: max(wait, runtime.ladder.interval), now: now)

        case .authenticationRejected:
            runtime.ladder.interrupted()
            runtime.authRejections += 1
            runtime.consecutiveFailures += 1
            fail(&runtime, note: "authentication refused", now: now)
            if runtime.authRejections == 1 {
                // §6: the token is re-read on every fetch and rotates roughly 8-hourly,
                // so ONE rejection is ambiguous — dead credential, or merely one that
                // rotated between the read and the request. Treating the first as
                // terminal permanently parks healthy accounts. The retry is exempt from
                // the 60s floor (see `block`) and still spends a budget slot, which is
                // the protection that actually matters.
                runtime.pendingTrigger = .retry
                schedule(&runtime, after: 0, now: now)
            } else if let expiry = credentialProbe(runtime.ref).expiresAt, expiry <= now {
                // A SECOND consecutive rejection AND a stored expiry that has genuinely
                // passed. Only now is the account expired and only now does its timer
                // stop — with the wake-up contract of `apply(_ credential:)` behind it.
                runtime.stoppedExpiry = expiry
                runtime.pendingTrigger = nil
            } else {
                // Rejected twice with a credential that has NOT lapsed, or whose expiry
                // cannot be read at all (Codex publishes none this app can read). §6
                // requires these be distinguished from expiry rather than collapsed into
                // it — so the account keeps its timer and keeps retrying, backed off.
                runtime.lastFailureNote = "authorization refused"
                schedule(&runtime,
                         after: PollSchedule.failureBackoff(
                            consecutiveFailures: runtime.consecutiveFailures),
                         now: now)
            }

        case .accountUnknown:
            // TERMINAL by construction (§5): the account left local discovery between
            // the poll being scheduled and it running. Retrying is a timer nothing ever
            // stops, so the account and its whole namespace go. A later survey brings it
            // back as a new registration if it returns.
            drop(key)

        case .malformedResponse(let message, let rawBody):
            // §5: retain the body on THIS path above all. Silent schema drift is what
            // the retention exists to diagnose, and this is the case that most needs it.
            runtime.rawBody = rawBody
            transientFailure(&runtime, note: "unreadable response: \(message)", now: now)

        case .transport(let message):
            transientFailure(&runtime, note: "network: \(message)", now: now)

        case .unexpectedStatus(let code):
            transientFailure(&runtime, note: "HTTP \(code)", now: now)
        }
    }

    private func transientFailure(_ runtime: inout Runtime, note: String, now: Date) {
        runtime.ladder.interrupted()
        runtime.consecutiveFailures += 1
        fail(&runtime, note: note, now: now)
        schedule(&runtime,
                 after: PollSchedule.failureBackoff(
                    consecutiveFailures: runtime.consecutiveFailures),
                 now: now)
    }

    private func fail(_ runtime: inout Runtime, note: String, now: Date) {
        if runtime.failingSince == nil { runtime.failingSince = now }
        runtime.lastFailureNote = note
    }

    private func schedule(_ runtime: inout Runtime, after delay: TimeInterval, now: Date) {
        guard delay > 0 else {
            runtime.nextDueAt = now
            return
        }
        runtime.nextDueAt = PollSchedule.nextDue(after: now,
                                                 interval: delay,
                                                 storageKey: runtime.ref.id.storageKey,
                                                 attempt: runtime.attempts)
    }

    // MARK: - Lifecycle

    // Drop an account and EVERYTHING keyed to it, in one step: the runtime, the retained
    // raw body, and the persisted namespace. §6's rule is that state for an account
    // absent from discovery is reclaimed rather than left in place; the reason it is one
    // function is that a partial reclamation is how an identifier reuse silently
    // resurrects a previous occupant's readings.
    //
    // The credential LEDGER is deliberately not dropped here: it belongs to the
    // credential, which may still be in use by another account and whose spends are real
    // whoever made them.
    private func drop(_ key: String) {
        runtimes.removeValue(forKey: key)
        order.removeAll { $0 == key }
        unclaimed.removeValue(forKey: key)
        pendingOps[key] = .delete(storageKey: key)
    }

    // The budget map is keyed by CREDENTIAL, so it is not any one account's state to drop
    // — which is exactly why a sweep over accounts never reaches it, and why it would
    // otherwise be the one keyspace here that grows without bound as profiles churn.
    // A ledger is only discarded once it has nothing live left in it: releasing a
    // credential's spends early would let an account that left and came back inside the
    // rolling span start again with a full allowance.
    private func reclaimUnreferencedBudgets(now: Date) {
        let referenced = Set(runtimes.values.map { $0.budgetKey })
        for (key, budget) in budgets where !referenced.contains(key) {
            var pruned = budget
            pruned.prune(now: now)
            if pruned.spends.isEmpty {
                budgets.removeValue(forKey: key)
                pendingOps[PersistedStore.ledgerNamespace + key] =
                    .delete(storageKey: PersistedStore.ledgerNamespace + key)
            } else if pruned != budget {
                // Only when pruning actually removed something. Re-persisting an
                // unchanged ledger on every 60s survey is pure write amplification, and
                // it is what turns a large ledger into continuous disk traffic.
                budgets[key] = pruned
                persistLedger(key)
            }
        }
    }

    var trackedBudgetKeys: [String] { budgets.keys.sorted() }

    // MARK: - Persistence

    private func persist(_ key: String) {
        guard let runtime = runtimes[key] else { return }
        var state = PersistedAccountState()
        state.enabled = runtime.enabled
        state.rung = runtime.ladder.rung
        state.successStreak = runtime.ladder.successStreak
        state.consecutiveFailures = runtime.consecutiveFailures
        state.lastFetchAttempt = runtime.lastFetchAttempt
        state.lastSuccessAt = runtime.lastSuccessAt
        state.failingSince = runtime.failingSince
        state.lastFailureNote = runtime.lastFailureNote
        state.notBefore = runtime.notBefore
        state.stoppedExpiry = runtime.stoppedExpiry
        state.credentialDigest = runtime.credentialDigest
        state.snapshot = runtime.snapshot.map(PersistedSnapshot.init)
        state.expanded = runtime.expanded
        guard let payload = PersistedCodec.encode(state) else { return }
        pendingOps[key] = .write(storageKey: key, payload: payload)
    }

    private func persistLedger(_ budgetKey: String) {
        guard let budget = budgets[budgetKey] else { return }
        var ledger = PersistedCredentialLedger()
        ledger.spends = budget.spends
        guard let payload = PersistedCodec.encode(ledger) else { return }
        let key = PersistedStore.ledgerNamespace + budgetKey
        pendingOps[key] = .write(storageKey: key, payload: payload)
    }

    // The shell applies these to whatever store it owns. Draining rather than writing
    // directly is what keeps this file free of a defaults database and therefore inside
    // the test target.
    func drainPersistence() -> [PersistenceOp] {
        let ops = pendingOps
        pendingOps = [:]
        return ops.keys.sorted().compactMap { ops[$0] }
    }

    // MARK: - Reading

    func presentations(now: Date) -> [AccountPresentation] {
        sortedKeys().compactMap { key in
            guard let runtime = runtimes[key] else { return nil }
            return presentation(of: runtime, now: now)
        }
    }

    func presentation(for identity: AccountIdentity, now: Date) -> AccountPresentation? {
        runtimes[identity.storageKey].map { presentation(of: $0, now: now) }
    }

    private func sortedKeys() -> [String] {
        order.sorted { left, right in
            guard let a = runtimes[left], let b = runtimes[right] else { return left < right }
            let orderA = providerOrder.firstIndex(of: a.ref.provider) ?? providerOrder.count
            let orderB = providerOrder.firstIndex(of: b.ref.provider) ?? providerOrder.count
            if orderA != orderB { return orderA < orderB }
            if a.ref.label != b.ref.label { return a.ref.label < b.ref.label }
            return left < right
        }
    }

    private func presentation(of runtime: Runtime, now: Date) -> AccountPresentation {
        AccountPresentation(
            ref: runtime.ref,
            state: displayState(of: runtime, now: now),
            isEnabled: runtime.enabled,
            isPollingStopped: runtime.stoppedExpiry != nil,
            lastSuccessAt: runtime.lastSuccessAt,
            degradationNote: degradationNote(of: runtime),
            nextPollAt: runtime.stoppedExpiry == nil && runtime.enabled && runtime.credentialUsable
                ? runtime.nextDueAt : nil,
            warnings: runtime.snapshot?.warnings ?? [],
            isExpanded: runtime.expanded
        )
    }

    private func degradationNote(of runtime: Runtime) -> String? {
        guard runtime.ladder.isDegraded else { return nil }
        let minutes = Int(runtime.ladder.interval / 60)
        return "rate limited · checking every \(minutes) min"
    }

    // The one place a display state is decided, for every account and every condition —
    // so `active` and `stale` cannot disagree about the horizon, and a stopped account
    // cannot be rendered from one branch as expired and from another as stale data.
    private func displayState(of runtime: Runtime, now: Date) -> AccountState {
        if let expiry = runtime.stoppedExpiry { return .expired(expiry) }
        // The credential itself says there is nothing to fetch. That verdict outranks a
        // cached reading: showing last week's percentages to an account that has since
        // signed out is exactly the misleading-headroom failure the horizon exists for,
        // arriving through a different door.
        guard runtime.credentialUsable else { return runtime.discoveryState }
        if let snapshot = runtime.snapshot {
            let projected = UsageEngine.project(snapshot, now: now)
            if let since = runtime.failingSince { return .stale(projected, since: since) }
            return .active(projected)
        }
        if let note = runtime.lastFailureNote { return .failed(note) }
        return .pending
    }

    // §6's horizon, applied at READ time rather than by editing the cache. A suppressed
    // window keeps its label, its scope and its reset time — what it loses is its
    // FIGURE, which becomes `unknown` rather than vanishing. That is the honest rendering
    // of "we knew this an hour ago and do not know it now", and it inherits §3's rule
    // that unknown never counts as zero and never contributes to an aggregate.
    static func project(_ snapshot: Snapshot, now: Date) -> Snapshot {
        Snapshot(
            account: snapshot.account,
            planLabel: snapshot.planLabel,
            windows: snapshot.windows.map { window in
                guard CacheHorizon.isSuppressed(span: window.id.span,
                                                fetchedAt: snapshot.fetchedAt,
                                                now: now) else { return window }
                return UsageWindow(id: window.id,
                                   label: window.label,
                                   utilization: .unknown,
                                   resetsAt: window.resetsAt,
                                   isActive: window.isActive)
            },
            spend: snapshot.spend,
            fetchedAt: snapshot.fetchedAt,
            warnings: snapshot.warnings
        )
    }

    // What this account contributes to §7.1's per-provider fold, or nil if it contributes
    // nothing at all. TWO rules from §6 apply and they are not the same rule:
    //
    //  1. "Past the horizon the account renders as unknown … and it NEVER CONTRIBUTES to
    //     the menu-bar worst-of." So if no window is still inside its own horizon, the
    //     account is absent from the fold entirely — not present as `unknown`.
    //  2. Otherwise the fold sees the PROJECTED windows, suppressed ones included as
    //     `unknown`. Filtering them out instead routes around
    //     `Snapshot.bindingUtilization`'s documented guarantee from one layer up: with a
    //     suppressed 95% active window and a live 10% inactive one, deletion reports 10%
    //     — a non-binding figure presented as the constraint, in green, while the same
    //     account's own card says unknown at the same instant. Measured, and the reason
    //     this function exists rather than a filter at the call site.
    static func menuBarContribution(_ snapshot: Snapshot,
                                    now: Date) -> (utilization: Utilization, windows: [UsageWindow])? {
        let live = snapshot.windows.filter {
            !CacheHorizon.isSuppressed(span: $0.id.span, fetchedAt: snapshot.fetchedAt, now: now)
        }
        guard !live.isEmpty else { return nil }
        let projected = project(snapshot, now: now).windows
        guard let utilization = Snapshot.bindingUtilization(of: projected) else { return nil }
        return (utilization, projected)
    }

    // §7.1: one figure per provider, worst across that provider's enabled accounts. A
    // provider with nothing to report is ABSENT rather than 0%.
    func menuBarFigures(now: Date) -> [ProviderFigure] {
        var figures: [ProviderFigure] = []
        let keys = sortedKeys()
        for provider in providerOrder {
            var best: ProviderFigure?
            for key in keys {
                guard let runtime = runtimes[key],
                      runtime.ref.provider == provider,
                      runtime.enabled,
                      runtime.stoppedExpiry == nil,
                      runtime.credentialUsable,
                      let snapshot = runtime.snapshot,
                      let contribution = UsageEngine.menuBarContribution(snapshot, now: now)
                else { continue }

                let candidate = ProviderFigure(
                    provider: provider,
                    utilization: contribution.utilization,
                    accountLabel: runtime.ref.label,
                    windowLabel: UsageEngine.windowLabel(for: contribution.utilization,
                                                        among: contribution.windows)
                )
                best = UsageEngine.worse(best, candidate)
            }
            if let best { figures.append(best) }
        }
        return figures
    }

    // Unknown BEATS a known figure, exactly as it does within one account (§3, §7.1):
    // reporting the highest known number while another enabled account's binding window
    // is unreadable presents a figure sourced from somewhere other than the constraint,
    // which is the manufactured-headroom failure. A red number disappearing is the
    // accepted cost of never under-reporting.
    private static func worse(_ incumbent: ProviderFigure?,
                              _ candidate: ProviderFigure) -> ProviderFigure {
        guard let incumbent else { return candidate }
        switch (incumbent.utilization, candidate.utilization) {
        case (.unknown, _): return incumbent
        case (_, .unknown): return candidate
        case (.known(let a), .known(let b)): return b > a ? candidate : incumbent
        }
    }

    // Presentation only — which window the number came from, for the tooltip. The number
    // itself always comes from `Snapshot.bindingUtilization`, so a disagreement here is
    // cosmetic and can never change the figure.
    private static func windowLabel(for utilization: Utilization,
                                    among windows: [UsageWindow]) -> String {
        let active = windows.filter { $0.isActive }
        let pool = active.isEmpty ? windows : active
        if let match = pool.first(where: { $0.utilization == utilization }) { return match.label }
        return pool.first?.label ?? ""
    }

    // §5's retained body: bounded to the latest per account, diagnostic-only, and
    // reachable only through this call — which no display path may use. It is dropped
    // with the account by `drop(_:)`, so an account that leaves discovery takes its
    // retained payload with it.
    func retainedRawBody(for identity: AccountIdentity) -> Data? {
        runtimes[identity.storageKey]?.rawBody
    }

    func lastBlock(for identity: AccountIdentity) -> PollBlock? {
        runtimes[identity.storageKey]?.lastBlock
    }

    func nextPollDate(for identity: AccountIdentity) -> Date? {
        runtimes[identity.storageKey]?.nextDueAt
    }

    func interval(for identity: AccountIdentity) -> TimeInterval? {
        runtimes[identity.storageKey]?.ladder.interval
    }

    func budgetKey(for identity: AccountIdentity) -> String? {
        runtimes[identity.storageKey]?.budgetKey
    }

    var knownStorageKeys: [String] { order }
}
