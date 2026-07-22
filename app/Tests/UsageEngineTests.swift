import Foundation

// §6, under test. Every case here is a failure someone can actually reach on a running
// machine, and the reason it is written down is in the comment above it — a test that
// only restates the implementation cannot fail when the implementation is wrong in the
// way that matters.
//
// TIME IS INJECTED THROUGHOUT. Nothing here sleeps: a 30-minute backoff, a 6-hour cache
// horizon and a relaunch are all expressed by moving a `Date` forward.
@MainActor
enum UsageEngineTests {

    // MARK: - Fixtures

    final class Clock {
        private(set) var now: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { now = start }
        @discardableResult func advance(_ seconds: TimeInterval) -> Date {
            now = now.addingTimeInterval(seconds)
            return now
        }
    }

    // The credential re-read of §6, faked. It counts calls as well as answering them:
    // "the first rejection must NOT consult the expiry" is only checkable by observing
    // that this was never asked.
    final class ProbeSpy {
        var facts: [String: CredentialFact] = [:]
        private(set) var calls = 0
        func probe(_ ref: AccountRef) -> CredentialFact {
            calls += 1
            return facts[ref.id.storageKey] ?? CredentialFact()
        }
    }

    static func ref(_ provider: ProviderKind, _ identifier: String, label: String? = nil) -> AccountRef {
        AccountRef(id: AccountIdentity(provider: provider, identifier),
                   label: label ?? identifier)
    }

    static func observation(_ ref: AccountRef,
                            state: AccountState = .pending,
                            location: String,
                            digest: String? = "digest-0") -> AccountObservation {
        AccountObservation(account: DiscoveredAccount(ref: ref, state: state),
                           credentialLocation: location,
                           credential: CredentialFact(digest: digest))
    }

    static func window(_ span: WindowSpan,
                       _ scope: WindowScope = .account,
                       percent: Int?,
                       active: Bool = false,
                       label: String = "w") -> UsageWindow {
        UsageWindow(id: WindowID(span: span, scope: scope),
                    label: label,
                    utilization: percent.map { Utilization.percent($0) } ?? .unknown,
                    resetsAt: nil,
                    isActive: active)
    }

    static func fetched(_ ref: AccountRef,
                        _ windows: [UsageWindow],
                        at moment: Date,
                        body: Data = Data("{}".utf8)) -> Result<FetchedSnapshot, FetchError> {
        .success(FetchedSnapshot(
            snapshot: Snapshot(account: ref, windows: windows, fetchedAt: moment),
            rawBody: body
        ))
    }

    // Completion goes back through the TASK, not the account (§6's claim token), so every
    // test exercises the token check on its way past.
    static func complete(_ engine: UsageEngine,
                         _ tasks: [PollTask],
                         _ ref: AccountRef,
                         _ result: Result<FetchedSnapshot, FetchError>,
                         now: Date,
                         named: String = "completion") {
        guard let task = tasks.first(where: { $0.ref.id == ref.id }) else {
            TestHarness.check("\(named): a task was claimed for \(ref.label)", false)
            return
        }
        TestHarness.check("\(named) for \(ref.label) is accepted",
                          engine.finish(task, result, now: now))
    }

    // Indexing a claim array directly turns "the wrong thing was claimed" into a crash
    // somewhere else entirely. Every lookup goes through here so the failure names itself.
    static func only(_ tasks: [PollTask], _ named: String) -> PollTask? {
        guard tasks.count == 1 else {
            TestHarness.check("\(named): exactly one task was claimed, got \(tasks.count)", false)
            return nil
        }
        return tasks[0]
    }

    // Claim everything due and complete it successfully. Used where the point of the test
    // is the sequence of requests, not what came back.
    static func pollAll(_ engine: UsageEngine, now: Date, percent: Int = 1) {
        for task in engine.claimDueFetches(now: now) {
            _ = engine.finish(task,
                              fetched(task.ref, [window(.session, percent: percent)], at: now),
                              now: now)
        }
    }

    static func describe(_ state: AccountState) -> String {
        switch state {
        case .pending: return "pending"
        case .active: return "active"
        case .stale: return "stale"
        case .signedOut: return "signedOut"
        case .expired: return "expired"
        case .failed: return "failed"
        }
    }

    static func snapshot(in state: AccountState) -> Snapshot? {
        switch state {
        case .active(let snapshot): return snapshot
        case .stale(let snapshot, _): return snapshot
        case .pending, .signedOut, .expired, .failed: return nil
        }
    }

    static func run() {
        policyUnits()
        hysteresisDoesNotSnapBack()
        throttleIsPerAccount()
        sharedCredentialSharesOneBudget()
        budgetIsKeyedOnTheCredentialNotItsLocation()
        budgetLedgerMigratesWhenTheCredentialRotates()
        ledgerStaysBoundedAcrossCredentialFlips()
        anUnchangedLedgerIsNotRewrittenEverySurvey()
        theFloorAppliesToEveryUserIndependentTrigger()
        revivalKeepsWhatTheEndpointTaughtUs()
        budgetBindsAcrossMixedSources()
        manualBypassesIntervalNotFloor()
        disabledAccountsAreNeverPolled()
        abandonedFetchDoesNotStallTheAccountForever()
        staleCompletionsAreRejected()
        mismatchedSnapshotIsRejected()
        authRejectionRereadsImmediately()
        rejectionsMustBeConsecutive()
        secondRejectionWithLapsedExpiryStopsTimer()
        secondRejectionWithoutLapsedExpiryKeepsRetrying()
        secondRejectionWithUnreadableExpiryNeverStops()
        retryAfterIsFloored()
        stoppedAccountRevivedByCredentialChange()
        stoppedAccountRevivedAfterRelaunch()
        cooldownSurvivesRelaunch()
        ledgerSurvivesRelaunchAndAccountRemoval()
        failureWithCacheRendersStale()
        horizonSuppressesAndExcludesFromWorstOf()
        menuBarAndCardAgreePastTheHorizon()
        futureDatedReadingsAreSuppressed()
        vanishedAccountStateIsReclaimed()
        unreadablePersistedStateIsReclaimed()
        differentAccountAtSameLocationInheritsNothing()
        terminalAndTransientFailuresAreDistinguished()
        snapshotsAreReplacedNeverMerged()
        credentialStateOutranksCache()
        menuBarFoldPropagatesUnknown()
        staggerSpreadsFirstPolls()
        suppressionKeepsEverythingButTheFigure()
        theTooltipNamesTheBindingWindow()
        providerOrderIsHonoured()
        persistenceRoundTrip()
    }

    // MARK: - Policy units

    static func policyUnits() {
        // The ladder is §6's 5 → 10 → 20 → 30 with a cap, and the cap is the value the
        // UI quotes in "checking every 30 min". An off-by-one here would silently poll a
        // throttled account twice as often as the card claims.
        var ladder = IntervalLadder()
        TestHarness.expect("ladder starts at 5 min", ladder.interval, 300)
        ladder.throttled(); TestHarness.expect("ladder 1st throttle", ladder.interval, 600)
        ladder.throttled(); TestHarness.expect("ladder 2nd throttle", ladder.interval, 1200)
        ladder.throttled(); TestHarness.expect("ladder 3rd throttle", ladder.interval, 1800)
        ladder.throttled(); TestHarness.expect("ladder caps at 30 min", ladder.interval, 1800)

        // A throttle must DISCARD the successes banked before it. Otherwise a run of good
        // polls that ends in a 429 pays for the step down it did not earn: two successes,
        // a throttle, one success, and the interval halves — resuming the very rate that
        // just produced the throttle.
        var banked = IntervalLadder()
        banked.throttled(); banked.throttled()
        banked.succeeded(); banked.succeeded()
        banked.throttled()
        TestHarness.expect("a throttle after banked successes lengthens", banked.interval, 1800)
        banked.succeeded()
        TestHarness.expect("and the banked successes do not survive it", banked.interval, 1800)

        // The same rule for the OTHER interruption: "only after sustained success" has to
        // mean uninterrupted, or three successes scattered across a dozen failures step
        // the interval down.
        var interrupted = IntervalLadder()
        interrupted.throttled()
        interrupted.succeeded(); interrupted.succeeded()
        interrupted.interrupted()
        interrupted.succeeded()
        TestHarness.expect("a failure between successes breaks the run", interrupted.interval, 600)
        interrupted.succeeded(); interrupted.succeeded()
        TestHarness.expect("three uninterrupted successes then step down",
                           interrupted.interval, 300)

        // The measured threshold (§6, `UsagePolicy`): five requests were tolerated and
        // the sixth was refused with Retry-After: 300. The budget is that observation.
        var budget = RequestBudget()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<RequestBudget.capacity {
            TestHarness.check("budget slot \(index) free",
                              budget.availableAt(now: start.addingTimeInterval(Double(index))) == nil)
            budget.spend(by: "a", at: start.addingTimeInterval(Double(index)))
        }
        TestHarness.expect("budget refuses the 6th request in the span",
                           budget.availableAt(now: start.addingTimeInterval(10)),
                           start.addingTimeInterval(RequestBudget.span))
        TestHarness.check("budget frees a slot once the span rolls past",
                          budget.availableAt(now: start.addingTimeInterval(301)) == nil)
        TestHarness.check("the ledger stays bounded by the span",
                          budget.spends.count <= RequestBudget.capacity)

        // A ROLLING window, not a fixed one. A fixed window would let 2×capacity requests
        // straddle its boundary in an instant — precisely the burst the endpoint refused.
        var rolling = RequestBudget()
        for index in 0..<RequestBudget.capacity {
            rolling.spend(by: "a", at: start.addingTimeInterval(Double(index)))
        }
        TestHarness.check("rolling budget still refuses just before the span elapses",
                          rolling.availableAt(now: start.addingTimeInterval(299)) != nil)

        // Availability is the OLDEST live spend plus the span — not whichever the array
        // happens to hold first. Two accounts sharing a credential contribute spends in
        // whatever order they were claimed and restored in, so the array is not sorted,
        // and a `first`-based answer reports a later availability than the truth.
        var restored = RequestBudget()
        restored.merge([200, 50, 150, 100, 250].map {
                           RequestSpend(account: "a", at: start.addingTimeInterval($0))
                       },
                       now: start.addingTimeInterval(260))
        TestHarness.expect("availability is the oldest spend plus the span, whatever the order",
                           restored.availableAt(now: start.addingTimeInterval(260)),
                           start.addingTimeInterval(50 + RequestBudget.span))

        // Per WINDOW CLASS (§6): a session window ages far faster than a weekly one, so
        // one horizon for both either blanks a good weekly figure or keeps a dangerously
        // old session figure on screen.
        TestHarness.expect("session horizon", CacheHorizon.horizon(for: .session), 1800)
        TestHarness.expect("weekly horizon", CacheHorizon.horizon(for: .weekly), 6 * 3600)
        TestHarness.expect("unstandardised span gets a proportional horizon",
                           CacheHorizon.horizon(for: .other(seconds: 36_000)), 3600)
        TestHarness.expect("unstandardised span has a floor",
                           CacheHorizon.horizon(for: .other(seconds: 0)), 900)
        // Bounded in BOTH directions. Small skew must not blank the UI; a reading stamped
        // far ahead is a clock that was corrected backwards, and its age is permanently
        // negative — so a one-sided bound never suppresses it, however old it really is.
        TestHarness.check("small forward skew is tolerated",
                          !CacheHorizon.isSuppressed(span: .session,
                                                     fetchedAt: start.addingTimeInterval(60),
                                                     now: start))
        TestHarness.check("a reading stamped far in the future is suppressed",
                          CacheHorizon.isSuppressed(span: .weekly,
                                                    fetchedAt: start.addingTimeInterval(5000),
                                                    now: start))

        // Deterministic, not random: a random stagger makes "did this account poll twice
        // inside one budget window?" unanswerable after the fact.
        TestHarness.expect("stagger is stable across calls",
                           PollSchedule.initialDelay(storageKey: "anthropic:a"),
                           PollSchedule.initialDelay(storageKey: "anthropic:a"))
        TestHarness.check("stagger stays inside its span",
                          PollSchedule.initialDelay(storageKey: "anthropic:a") < PollSchedule.staggerSpan)
        TestHarness.expect("failure backoff starts at the 60s floor",
                           PollSchedule.failureBackoff(consecutiveFailures: 1), 60)
        TestHarness.expect("failure backoff caps at the ladder cap",
                           PollSchedule.failureBackoff(consecutiveFailures: 30), 1800)
    }

    // MARK: - Adaptive interval

    // §6: "a single success must not restore the most aggressive cadence". The condition
    // that produced the throttle is a sustained request rate, so snapping back to base
    // reproduces it — throttle, recover, throttle — and every cycle costs a real
    // five-minute lockout. This is the test that fails if `succeeded()` sets rung to 0.
    static func hysteresisDoesNotSnapBack() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "hyst")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)

        func poll(_ result: Result<FetchedSnapshot, FetchError>) {
            clock.advance(3600)  // past any interval and clear of the budget window
            let claimed = engine.claimDueFetches(now: clock.now)
            TestHarness.expect("hysteresis: a poll is claimed", claimed.count, 1)
            complete(engine, claimed, account, result, now: clock.now, named: "hysteresis")
        }

        for _ in 0..<3 { poll(.failure(.rateLimited(retryAfter: nil))) }
        TestHarness.expect("three throttles reach the 30 min cap",
                           engine.interval(for: account.id), 1800)

        poll(fetched(account, [window(.session, percent: 10)], at: clock.now))
        TestHarness.expect("ONE success does not restore base cadence",
                           engine.interval(for: account.id), 1800)
        poll(fetched(account, [window(.session, percent: 10)], at: clock.now))
        TestHarness.expect("two successes still do not step down",
                           engine.interval(for: account.id), 1800)
        poll(fetched(account, [window(.session, percent: 10)], at: clock.now))
        TestHarness.expect("three sustained successes step back ONE rung",
                           engine.interval(for: account.id), 1200)

        // A failure between successes breaks the run. Otherwise "only after sustained
        // success" degenerates into "after any three successes, however interleaved".
        poll(.failure(.transport(message: "x")))
        poll(fetched(account, [window(.session, percent: 10)], at: clock.now))
        poll(fetched(account, [window(.session, percent: 10)], at: clock.now))
        TestHarness.expect("an interruption resets the success streak",
                           engine.interval(for: account.id), 1200)

        // The degradation is visible in the card (§6): a stretched cadence must never
        // just look fresh.
        let card = engine.presentation(for: account.id, now: clock.now)
        TestHarness.expect("the degraded cadence is surfaced on the card",
                           card?.degradationNote, "rate limited · checking every 20 min")
    }

    // §6: backoff, cooldown and interval state are PER ACCOUNT — one rate-limited
    // account must never stall the others. Two accounts on separate credentials.
    static func throttleIsPerAccount() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let hot = ref(.anthropic, "hot")
        let calm = ref(.anthropic, "calm")
        engine.ingest([observation(hot, location: "svc-hot", digest: "hot"),
                       observation(calm, location: "svc-calm", digest: "calm")],
                      covering: [.anthropic], now: clock.now)

        clock.advance(31)
        let first = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("both accounts poll", first.count, 2)
        complete(engine, first, hot, .failure(.rateLimited(retryAfter: 900)), now: clock.now)
        complete(engine, first, calm, fetched(calm, [window(.session, percent: 20)], at: clock.now),
                 now: clock.now)

        clock.advance(400)
        let claimed = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("the throttled account is still held back",
                           engine.block(for: hot.id, trigger: .manual, now: clock.now),
                           .serverBackoff(until: clock.now.addingTimeInterval(500)))
        TestHarness.check("the healthy account polled on schedule regardless",
                          claimed.contains { $0.ref.id == calm.id })
        TestHarness.expect("the healthy account keeps base cadence",
                           engine.interval(for: calm.id), 300)
        TestHarness.expect("only the throttled account's interval lengthened",
                           engine.interval(for: hot.id), 600)
    }

    // §6: "the budget is scoped to the credential, not to the logical account". Throttling
    // is enforced upstream per access token, so two accounts resolving to one credential
    // would each be granted a full budget and jointly exceed the one limit that binds.
    static func sharedCredentialSharesOneBudget() {
        func exhaust(sharing: Bool) -> PollBlock? {
            let clock = Clock()
            let engine = UsageEngine(providerOrder: [.anthropic])
            let first = ref(.anthropic, "one")
            let second = ref(.anthropic, "two")
            engine.ingest([observation(first, location: "shared", digest: "same-token"),
                           observation(second, location: "shared",
                                       digest: sharing ? "same-token" : "other-token")],
                          covering: [.anthropic], now: clock.now)
            // Five claims inside one 300s span, alternating between the two accounts.
            // Each claim is completed, so nothing here is refused merely for being in
            // flight — the only gate left standing is the budget.
            clock.advance(31)
            pollAll(engine, now: clock.now)                       // 2 spends
            clock.advance(64)
            engine.requestManualRefresh(now: clock.now)
            pollAll(engine, now: clock.now)                       // 4 spends
            clock.advance(64)
            engine.requestManualRefresh(now: clock.now)
            pollAll(engine, now: clock.now)                       // 5th spend, then refusal
            return engine.lastBlock(for: second.id)
        }

        let shared = exhaust(sharing: true)
        switch shared {
        case .budgetExhausted: TestHarness.check("shared credential exhausts one budget", true)
        default: TestHarness.check("shared credential exhausts one budget: got \(String(describing: shared))", false)
        }
        // The control: the SAME sequence against two separate credentials is admitted,
        // so the refusal above is the budget and not some other gate.
        TestHarness.check("separate credentials each get their own budget",
                          exhaust(sharing: false) == nil)
    }

    // §6 scopes the budget to the CREDENTIAL, and the credential is the access token —
    // not the place it is stored. An Anthropic service name digests a configuration
    // PATH, so a copied configuration (the scenario §6 names) yields two service names
    // for one token: five requests through each is ten in 300s against the one limit
    // that binds. Task 4's handoff recommended the service name; the recommendation
    // named the wrong identifier.
    static func budgetIsKeyedOnTheCredentialNotItsLocation() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let first = ref(.anthropic, "copy-a")
        let second = ref(.anthropic, "copy-b")
        // TWO DIRECTORIES, ONE TOKEN: distinct service names, identical credential.
        engine.ingest([observation(first, location: "Claude Code-credentials", digest: "one-token"),
                       observation(second, location: "Claude Code-credentials-6c3a8789",
                                   digest: "one-token")],
                      covering: [.anthropic], now: clock.now)

        TestHarness.expect("both accounts resolve to one budget key",
                           engine.budgetKey(for: first.id), engine.budgetKey(for: second.id))
        TestHarness.expect("and the key is the credential, not either location",
                           engine.budgetKey(for: first.id), "digest:one-token")

        clock.advance(31)
        pollAll(engine, now: clock.now)
        clock.advance(64)
        engine.requestManualRefresh(now: clock.now)
        pollAll(engine, now: clock.now)
        clock.advance(64)
        engine.requestManualRefresh(now: clock.now)
        pollAll(engine, now: clock.now)
        switch engine.lastBlock(for: second.id) {
        case .budgetExhausted:
            TestHarness.check("two locations holding one token share one allowance", true)
        case let other:
            TestHarness.check("two locations holding one token share one allowance: "
                              + "got \(String(describing: other))", false)
        }

        // With no credential to digest there is nothing better than the location, and
        // that fallback must be namespaced so it can never be mistaken for a digest.
        let unreadable = ref(.anthropic, "no-credential")
        engine.ingest([observation(unreadable, location: "some/path", digest: nil)],
                      covering: [.codex], now: clock.now)
        TestHarness.expect("the location is the namespaced fallback",
                           engine.budgetKey(for: unreadable.id), "location:some/path")
    }

    // The credential digest IS the token's digest, so it changes on every ~8-hourly
    // rotation. A rotation that issued a fresh allowance would be a hole in the budget
    // that opens several times a day; the ledger has to move with the key. And two
    // accounts sharing the credential must migrate it ONCE between them, not merge the
    // same spends twice.
    static func budgetLedgerMigratesWhenTheCredentialRotates() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let first = ref(.anthropic, "rot-a")
        let second = ref(.anthropic, "rot-b")
        engine.ingest([observation(first, location: "svc-a", digest: "token-1"),
                       observation(second, location: "svc-b", digest: "token-1")],
                      covering: [.anthropic], now: clock.now)
        clock.advance(31)
        pollAll(engine, now: clock.now)                       // 2 spends
        clock.advance(64)
        engine.requestManualRefresh(now: clock.now)
        pollAll(engine, now: clock.now)                       // 4 spends

        // The CLI rotated the token.
        clock.advance(64)
        engine.ingest([observation(first, location: "svc-a", digest: "token-2"),
                       observation(second, location: "svc-b", digest: "token-2")],
                      covering: [.anthropic], now: clock.now)
        TestHarness.expect("the accounts follow the credential to its new key",
                           engine.budgetKey(for: first.id), "digest:token-2")

        // The rotation re-armed both accounts (a changed digest is a revival), so this
        // pass claims the fifth slot and then refuses — which is only true if the four
        // earlier spends came across with the key, and came across ONCE.
        pollAll(engine, now: clock.now)
        switch engine.lastBlock(for: second.id) {
        case .budgetExhausted:
            TestHarness.check("a rotation carries the ledger rather than resetting it", true)
        case let other:
            TestHarness.check("a rotation carries the ledger rather than resetting it: "
                              + "got \(String(describing: other))", false)
        }
        clock.advance(RequestBudget.span + 1)
        engine.ingest([observation(first, location: "svc-a", digest: "token-2"),
                       observation(second, location: "svc-b", digest: "token-2")],
                      covering: [.anthropic], now: clock.now)
        TestHarness.check("and the old key is reclaimed once it is empty",
                          !engine.trackedBudgetKeys.contains("digest:token-1"))
    }

    // The ledger has to stay BOUNDED, and the shape that breaks it is a credential key
    // that flips back and forth: §4.1 resolves duplicate identities by credential health,
    // so the winning directory can change between surveys, and every change migrates the
    // ledger. Merging a ledger into a copy of itself is the operation that must be
    // idempotent. Measured before the fix, at a 5-second flip cadence: a 695 MB persisted
    // payload after 40 flips, written to UserDefaults on the main actor.
    //
    // The property is "bounded", so this asserts a bound rather than an exact count.
    static func ledgerStaysBoundedAcrossCredentialFlips() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "flipping")
        var largestPayload = 0
        var largestLedger = 0

        for step in 0..<80 {
            engine.ingest([observation(account, location: "svc",
                                       digest: step % 2 == 0 ? "P" : "Q")],
                          covering: [.anthropic], now: clock.now)
            pollAll(engine, now: clock.now)
            for op in engine.drainPersistence() {
                guard case .write(let key, let payload) = op,
                      PersistedStore.ledgerKey(of: key) != nil else { continue }
                largestPayload = max(largestPayload, payload.count)
                if let ledger = PersistedCodec.decode(PersistedCredentialLedger.self,
                                                      from: payload) {
                    largestLedger = max(largestLedger, ledger.spends.count)
                }
            }
            clock.advance(5)
        }

        TestHarness.check("a flipping credential key never accumulates more spends than "
                          + "the budget allows (saw \(largestLedger))",
                          largestLedger <= RequestBudget.capacity)
        TestHarness.check("so the persisted ledger stays small (saw \(largestPayload) bytes)",
                          largestPayload < 4096)

        // The other half of the same property: two accounts sharing a credential spend at
        // the SAME instant, and those are two requests, not one. A merge that deduped by
        // timestamp would collapse them and hand the budget a slot it never had.
        var budget = RequestBudget()
        let moment = Date(timeIntervalSince1970: 0)
        budget.spend(by: "anthropic:a", at: moment)
        budget.spend(by: "anthropic:b", at: moment)
        TestHarness.expect("two accounts spending at one instant are two spends",
                           budget.spends.count, 2)
        var copy = budget
        copy.merge(budget.spends, now: moment)
        TestHarness.expect("and merging a ledger into a copy of itself changes nothing",
                           copy.spends.count, 2)

        // The account is part of the spend's IDENTITY, and it has to be: two accounts
        // each spending once at the same instant, on ledgers that later merge — a
        // migration, or a restore — are two requests. If the spend were keyed on the
        // timestamp alone the merge would collapse them to one and hand the budget back
        // a slot it never had.
        var fromA = RequestBudget()
        fromA.spend(by: "anthropic:a", at: moment)
        var fromB = RequestBudget()
        fromB.spend(by: "anthropic:b", at: moment)
        fromA.merge(fromB.spends, now: moment)
        TestHarness.expect("two accounts' spends at one instant survive a merge as two",
                           fromA.spends.count, 2)
        // One account CAN spend twice at one instant: the re-read retry is exempt from
        // the 60s floor, so a claim and its retry can share a timestamp. Multiplicity has
        // to survive the merge or that second request is forgotten.
        var doubled = RequestBudget()
        doubled.spend(by: "anthropic:a", at: moment)
        doubled.spend(by: "anthropic:a", at: moment)
        var receiver = RequestBudget()
        receiver.merge(doubled.spends, now: moment)
        TestHarness.expect("a genuine repeat spend survives the merge", receiver.spends.count, 2)
        receiver.merge(doubled.spends, now: moment)
        TestHarness.expect("and merging it again still changes nothing", receiver.spends.count, 2)
    }

    // Write amplification, and the reason the growth bug did disk damage rather than
    // merely wasting memory: a ledger whose account has left discovery is retained until
    // its spends expire (its allowance is real whoever made it), but it must not be
    // re-persisted on every 60s survey while nothing about it has changed.
    static func anUnchangedLedgerIsNotRewrittenEverySurvey() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let solo = ref(.anthropic, "solo")
        engine.ingest([observation(solo, location: "svc", digest: "one")],
                      covering: [.anthropic], now: clock.now)
        clock.advance(PollSchedule.staggerSpan + 1)
        pollAll(engine, now: clock.now)

        // The account leaves discovery. Its ledger is now unreferenced but its single
        // spend is still live, so the ledger is kept.
        clock.advance(10)
        engine.ingest([], covering: [.anthropic], now: clock.now)
        _ = engine.drainPersistence()

        // A survey a few seconds later, still inside the rolling span, changes nothing
        // about the ledger — so nothing about it should be written.
        clock.advance(10)
        engine.ingest([], covering: [.anthropic], now: clock.now)
        let ops = engine.drainPersistence()
        let ledgerWrites = ops.filter {
            if case .write(let key, _) = $0 { return PersistedStore.ledgerKey(of: key) != nil }
            return false
        }
        TestHarness.expect("an unchanged unreferenced ledger is not re-persisted", ledgerWrites.count, 0)

        // But once the span rolls past and the ledger empties, it IS reclaimed — the
        // write path is silenced, not broken.
        clock.advance(RequestBudget.span)
        engine.ingest([], covering: [.anthropic], now: clock.now)
        TestHarness.check("an emptied ledger is reclaimed",
                          engine.drainPersistence().contains {
                              if case .delete(let key) = $0 {
                                  return PersistedStore.ledgerKey(of: key) != nil
                              }
                              return false
                          })
    }

    // The 60s floor applies to every trigger except the authentication re-read — including
    // the discovery-triggered fetch a credential rotation arms. Stated in `block`, and
    // unpinned until now: a rotation seconds after a poll must be held, not sent.
    static func theFloorAppliesToEveryUserIndependentTrigger() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "floored")
        engine.ingest([observation(account, location: "svc", digest: "one")],
                      covering: [.anthropic], now: clock.now)
        clock.advance(PollSchedule.staggerSpan + 1)
        let claimed = engine.claimDueFetches(now: clock.now)
        let polledAt = clock.now
        complete(engine, claimed, account,
                 fetched(account, [window(.session, percent: 3)], at: clock.now), now: clock.now)

        clock.advance(5)
        engine.ingest([observation(account, location: "svc", digest: "rotated")],
                      covering: [.anthropic], now: clock.now)
        TestHarness.expect("a rotation seconds after a poll does not fetch immediately",
                           engine.claimDueFetches(now: clock.now).count, 0)
        TestHarness.expect("the floor is what holds it",
                           engine.lastBlock(for: account.id),
                           .cooldown(until: polledAt.addingTimeInterval(PollSchedule.manualFloor)))

        // Held, not cancelled — and it still arrives as the discovery-triggered fetch.
        clock.advance(PollSchedule.manualFloor)
        let released = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("and it runs once the floor elapses", released.count, 1)
        TestHarness.expect("still tagged as discovery", released.first?.trigger, .discovery)
    }

    // Revival clears what the CREDENTIAL invalidated and keeps what the ENDPOINT taught
    // us. Both halves are stated in `revive`'s comment and neither was pinned.
    static func revivalKeepsWhatTheEndpointTaughtUs() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "recovered")
        engine.ingest([observation(account, location: "svc", digest: "one")],
                      covering: [.anthropic], now: clock.now)

        // Throttle twice to reach 20 minutes, then take a good reading, then start failing.
        func poll(_ result: Result<FetchedSnapshot, FetchError>) {
            clock.advance(3600)
            let claimed = engine.claimDueFetches(now: clock.now)
            complete(engine, claimed, account, result, now: clock.now, named: "revival")
        }
        poll(.failure(.rateLimited(retryAfter: nil)))
        poll(.failure(.rateLimited(retryAfter: nil)))
        TestHarness.expect("the endpoint stretched the interval", engine.interval(for: account.id), 1200)
        poll(fetched(account, [window(.session, percent: 44, active: true)], at: clock.now))
        poll(.failure(.transport(message: "offline")))
        TestHarness.expect("and the account is stale on its cached reading",
                           describe(engine.presentation(for: account.id, now: clock.now)?.state
                                    ?? .pending),
                           "stale")

        clock.advance(60)
        engine.ingest([observation(account, location: "svc", digest: "two")],
                      covering: [.anthropic], now: clock.now)

        // The ladder records what the ENDPOINT tolerates. A new credential does not change
        // that, and resetting it here walks straight back into the throttle.
        TestHarness.expect("a credential change does not restore the aggressive cadence",
                           engine.interval(for: account.id), 1200)
        // And the cached reading is still the last thing we actually know. Clearing
        // `failingSince` would render it `.active` — old data presented as fresh.
        TestHarness.expect("nor does it present the old reading as fresh",
                           describe(engine.presentation(for: account.id, now: clock.now)?.state
                                    ?? .pending),
                           "stale")
    }

    // §6: "no combination of scheduled polls, manual refreshes, discovery-triggered
    // fetches, and retries can exceed the rate the endpoint tolerates". All four sources
    // spend from the same ledger here; the sixth request is refused whichever asked.
    static func budgetBindsAcrossMixedSources() {
        let clock = Clock()
        let probe = ProbeSpy()
        let first = ref(.anthropic, "mix-a")
        let second = ref(.anthropic, "mix-b")
        probe.facts[second.id.storageKey] =
            CredentialFact(expiresAt: clock.now.addingTimeInterval(3600))
        let engine = UsageEngine(providerOrder: [.anthropic], credentialProbe: probe.probe)
        engine.ingest([observation(first, location: "svc-a", digest: "shared"),
                       observation(second, location: "svc-b", digest: "shared")],
                      covering: [.anthropic], now: clock.now)

        // 1 + 2: two scheduled polls.
        let opened = clock.advance(31)
        let scheduled = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("scheduled polls spend two slots", scheduled.count, 2)
        complete(engine, scheduled, first,
                 fetched(first, [window(.session, percent: 5)], at: clock.now), now: clock.now)
        complete(engine, scheduled, second, .failure(.authenticationRejected), now: clock.now)

        // 3: the authentication re-read retry — immediate, per §6.
        let retries = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("the retry is one of the sources that spends", retries.count, 1)
        TestHarness.expect("and it is tagged as a retry", retries.first?.trigger, .retry)
        complete(engine, retries, second, .failure(.authenticationRejected), now: clock.now)

        // 4: a manual refresh.
        clock.advance(65)
        engine.requestManualRefresh(first.id, now: clock.now)
        let manual = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("a manual refresh spends too", manual.count, 1)
        complete(engine, manual, first,
                 fetched(first, [window(.session, percent: 5)], at: clock.now), now: clock.now)

        // 5: a discovery-triggered fetch (the credential rotated, so the account is
        // re-armed by the survey). The ledger migrates with the key, so the spend count
        // carries across.
        clock.advance(65)
        engine.ingest([observation(first, location: "svc-a", digest: "rotated"),
                       observation(second, location: "svc-b", digest: "rotated")],
                      covering: [.anthropic], now: clock.now)
        let revived = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("a discovery-triggered fetch spends too", revived.count, 1)
        TestHarness.expect("and it is tagged as discovery", revived.first?.trigger, .discovery)

        // 6: refused — five spends are live in the rolling span, whoever made them.
        clock.advance(65)
        engine.requestManualRefresh(second.id, now: clock.now)
        TestHarness.expect("the sixth request in the span is refused",
                           engine.claimDueFetches(now: clock.now).count, 0)
        TestHarness.expect("and the reason names the budget, not the interval",
                           engine.lastBlock(for: second.id),
                           .budgetExhausted(until: opened.addingTimeInterval(RequestBudget.span)))
    }

    // §6: manual Refresh bypasses the interval but keeps a 60s floor. Both halves matter:
    // without the bypass the button does nothing for five minutes, and without the floor
    // it is an unbounded hole in the rate policy.
    static func manualBypassesIntervalNotFloor() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "manual")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let claimed = engine.claimDueFetches(now: clock.now)
        complete(engine, claimed, account,
                 fetched(account, [window(.session, percent: 1)], at: clock.now), now: clock.now)

        clock.advance(30)
        engine.requestManualRefresh(now: clock.now)
        TestHarness.expect("a manual refresh inside the 60s floor is refused",
                           engine.claimDueFetches(now: clock.now).count, 0)
        switch engine.lastBlock(for: account.id) {
        case .cooldown: TestHarness.check("and the reason is the floor", true)
        case let other: TestHarness.check("and the reason is the floor: got \(String(describing: other))", false)
        }
        clock.advance(31)
        // The request is still pending: a refusal by the floor is a delay, not a
        // cancellation, and the user asked for this.
        TestHarness.expect("the manual refresh runs as soon as the floor allows",
                           engine.claimDueFetches(now: clock.now).count, 1)
        TestHarness.check("well before the 5-minute interval would have come due",
                          clock.now.timeIntervalSince(engine.nextPollDate(for: account.id) ?? clock.now) < 0)
    }

    // Acceptance criterion 9 / §7.3. A disabled account leaves the schedule entirely —
    // including for a manual refresh, which would otherwise be a way to poll an account
    // the user switched off.
    static func disabledAccountsAreNeverPolled() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "off")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        engine.setEnabled(false, for: account.id)
        clock.advance(600)
        TestHarness.expect("a disabled account is not polled on schedule",
                           engine.claimDueFetches(now: clock.now).count, 0)
        engine.requestManualRefresh(now: clock.now)
        TestHarness.expect("nor by a manual refresh",
                           engine.claimDueFetches(now: clock.now).count, 0)
        TestHarness.expect("and the reason says so", engine.lastBlock(for: account.id), .disabled)
        TestHarness.check("a disabled account advertises no next poll",
                          engine.presentation(for: account.id, now: clock.now)?.nextPollAt == nil)

        engine.setEnabled(true, for: account.id)
        // The stale manual request from while it was disabled must NOT fire now: the user
        // asked for it minutes ago about an account that was switched off. Pinned by the
        // TRIGGER, not the count — a scheduled fetch is also due at this instant, so a
        // count alone passes whether or not the stale request was replayed.
        let claimed = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("re-enabling polls once", claimed.count, 1)
        TestHarness.expect("and it is the schedule, not the refusal being replayed",
                           claimed.first?.trigger, .scheduled)
    }

    // A claimed fetch that never reports back — a provider task cancelled at sleep, a
    // crash inside the shell — must not park the account forever. This is the failure
    // mode hardest to see from the UI: the row simply stops updating and every gate says
    // it is fine, so it looks like a network problem the user cannot act on.
    static func abandonedFetchDoesNotStallTheAccountForever() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "abandoned")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let abandoned = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("the fetch is claimed", abandoned.count, 1)
        // …and `finish` is never called for it.

        clock.advance(90)
        engine.requestManualRefresh(now: clock.now)
        TestHarness.expect("a second fetch is not started while one is genuinely in flight",
                           engine.claimDueFetches(now: clock.now).count, 0)
        TestHarness.expect("and the reason names it", engine.lastBlock(for: account.id), .inFlight)

        clock.advance(UsageEngine.inFlightExpiry)
        let replacement = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("but an abandoned one is eventually released", replacement.count, 1)

        // AND THEN THE ABANDONED ONE COMES BACK. Releasing the marker without a claim
        // token is a straight ABA: this completion would clear the REPLACEMENT's in-flight
        // marker and write its own, older, result over newer state.
        guard let abandonedTask = only(abandoned, "the abandoned fetch"),
              let replacementTask = only(replacement, "the replacement fetch") else { return }
        TestHarness.check("the abandoned fetch's late completion is rejected",
                          engine.finish(abandonedTask,
                                        fetched(account, [window(.session, percent: 99)],
                                                at: clock.now),
                                        now: clock.now) == false)
        TestHarness.expect("so it writes no reading",
                           describe(engine.presentation(for: account.id, now: clock.now)?.state
                                    ?? .signedOut),
                           "pending")
        TestHarness.expect("and the replacement is still in flight",
                           engine.block(for: account.id, trigger: .manual, now: clock.now),
                           .inFlight)
        TestHarness.check("while the replacement's own completion is accepted",
                          engine.finish(replacementTask,
                                        fetched(account, [window(.session, percent: 12)],
                                                at: clock.now),
                                        now: clock.now))
    }

    // The other two shapes of a stale completion, both reachable without any 180s wait:
    // a fetch running when the user disables the account, and a fetch running when the
    // account leaves discovery and is re-registered under the same identity.
    static func staleCompletionsAreRejected() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let disabled = ref(.anthropic, "racing")
        let departing = ref(.anthropic, "departing")
        engine.ingest([observation(disabled, location: "svc-a", digest: "a"),
                       observation(departing, location: "svc-b", digest: "b")],
                      covering: [.anthropic], now: clock.now)
        clock.advance(PollSchedule.staggerSpan + 1)
        let inFlight = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("both accounts have a fetch running", inFlight.count, 2)
        guard let disabledTask = inFlight.first(where: { $0.ref.id == disabled.id }),
              let departingTask = inFlight.first(where: { $0.ref.id == departing.id })
        else {
            TestHarness.check("both accounts have a fetch running", false)
            return
        }

        engine.setEnabled(false, for: disabled.id)
        TestHarness.check("a completion for an account the user just disabled is rejected",
                          engine.finish(disabledTask,
                                        fetched(disabled, [window(.session, percent: 77)],
                                                at: clock.now),
                                        now: clock.now) == false)
        engine.setEnabled(true, for: disabled.id)
        TestHarness.expect("so no reading was written",
                           describe(engine.presentation(for: disabled.id, now: clock.now)?.state
                                    ?? .signedOut),
                           "pending")

        // The other account leaves discovery and is re-registered under the SAME identity
        // — a different occupant, or the same one returning. Its FIRST fetch is still
        // outstanding, and the re-registration's first fetch is also a first fetch: a
        // token that were merely a per-account counter would issue the same value to
        // both, so the stale completion would match and overwrite the live one.
        engine.ingest([observation(disabled, location: "svc-a", digest: "a")],
                      covering: [.anthropic], now: clock.now)
        engine.ingest([observation(disabled, location: "svc-a", digest: "a"),
                       observation(departing, location: "svc-b", digest: "b")],
                      covering: [.anthropic], now: clock.now)
        clock.advance(PollSchedule.staggerSpan + 1)
        let reborn = engine.claimDueFetches(now: clock.now)
        guard let rebornTask = reborn.first(where: { $0.ref.id == departing.id }) else {
            TestHarness.check("the re-registered account starts its own fetch", false)
            return
        }
        TestHarness.check("a completion issued to the previous registration is rejected",
                          engine.finish(departingTask,
                                        fetched(departing, [window(.session, percent: 88)],
                                                at: clock.now),
                                        now: clock.now) == false)
        TestHarness.expect("and the re-registered account is still awaiting its own reading",
                           describe(engine.presentation(for: departing.id, now: clock.now)?.state
                                    ?? .signedOut),
                           "pending")
        TestHarness.check("whose completion is the one that is accepted",
                          engine.finish(rebornTask,
                                        fetched(departing, [window(.session, percent: 5)],
                                                at: clock.now),
                                        now: clock.now))
    }

    // §6 tolerates losing history and does not tolerate misattributing it. Persistence
    // strips the snapshot's embedded identity and rebuilds it from the KEY, so a snapshot
    // cached under the wrong account is indistinguishable from that account's own after a
    // relaunch — the one failure §6 calls unacceptable.
    static func mismatchedSnapshotIsRejected() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let asked = ref(.anthropic, "asked-for")
        let other = ref(.anthropic, "somebody-else")
        engine.ingest([observation(asked, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let claimed = engine.claimDueFetches(now: clock.now)
        guard let task = only(claimed, "the fetch for the account that was asked for") else { return }
        // A provider mix-up: the reading is projected for a different account.
        _ = engine.finish(task,
                          fetched(other, [window(.session, percent: 90, active: true)], at: clock.now),
                          now: clock.now)

        let card = engine.presentation(for: asked.id, now: clock.now)
        TestHarness.expect("another account's reading is not cached under this one",
                           describe(card?.state ?? .pending), "failed")
        TestHarness.expect("and it never reaches the menu bar",
                           engine.menuBarFigures(now: clock.now).count, 0)
        TestHarness.check("the account keeps retrying rather than stopping",
                          card?.nextPollAt != nil)
    }

    // MARK: - Authentication

    // §6: the token is re-read on every fetch and rotates roughly 8-hourly, so ONE
    // rejection is ambiguous — genuinely dead, or merely rotated between read and
    // request. Treating the first as terminal permanently parks healthy accounts, and
    // that is the bug this test exists for. §6 says the re-read is IMMEDIATE: the 60s
    // floor protects the endpoint from user-driven refreshes, and a minute of a healthy
    // account rendering as failed buys nothing the budget does not already give.
    static func authRejectionRereadsImmediately() {
        let clock = Clock()
        let probe = ProbeSpy()
        let account = ref(.anthropic, "rotating")
        // A credential that lapsed an hour ago — so if the first rejection were treated
        // as terminal, this account WOULD be parked. It must not be.
        probe.facts[account.id.storageKey] =
            CredentialFact(expiresAt: clock.now.addingTimeInterval(-3600))
        let engine = UsageEngine(providerOrder: [.anthropic], credentialProbe: probe.probe)
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)

        clock.advance(31)
        let first = engine.claimDueFetches(now: clock.now)
        complete(engine, first, account, .failure(.authenticationRejected), now: clock.now)
        TestHarness.expect("the first rejection does not consult the expiry at all",
                           probe.calls, 0)
        TestHarness.check("and does not stop the account",
                          engine.presentation(for: account.id, now: clock.now)?.isPollingStopped == false)

        // NO CLOCK ADVANCE. §6 says the re-read is immediate.
        let retry = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("the re-read retry runs immediately, not a minute later",
                           retry.count, 1)
        TestHarness.expect("tagged as the re-read retry", retry.first?.trigger, .retry)

        // The exemption is for the RETRY alone: a manual refresh at the same instant is
        // still refused by the floor.
        engine.requestManualRefresh(now: clock.now)
        TestHarness.expect("a manual refresh at the same instant is still floored",
                           engine.claimDueFetches(now: clock.now).count, 0)

        // The token had merely rotated: the retry succeeds and the account is healthy.
        complete(engine, retry, account,
                 fetched(account, [window(.session, percent: 42)], at: clock.now), now: clock.now)
        let card = engine.presentation(for: account.id, now: clock.now)
        TestHarness.expect("the rotated token's retry restores the account",
                           describe(card?.state ?? .signedOut), "active")
        TestHarness.expect("the expiry was never consulted on a path that recovered",
                           probe.calls, 0)

        // And the rejection count is cleared, so a LATER single rejection gets its own
        // re-read rather than being treated as the second of a pair.
        clock.advance(400)
        let later = engine.claimDueFetches(now: clock.now)
        complete(engine, later, account, .failure(.authenticationRejected), now: clock.now)
        TestHarness.expect("a success re-arms the one-retry allowance", probe.calls, 0)
    }

    // §6 says a SECOND CONSECUTIVE rejection concludes anything. A transport failure in
    // between means the disambiguating re-read never actually ran against a rejection, so
    // the next rejection is a first one and is owed its own re-read. Without this,
    // `rejection → offline → rejection an hour later` parks a healthy account.
    static func rejectionsMustBeConsecutive() {
        let clock = Clock()
        let probe = ProbeSpy()
        let account = ref(.anthropic, "intermittent")
        probe.facts[account.id.storageKey] =
            CredentialFact(digest: "d", expiresAt: clock.now.addingTimeInterval(-60))
        let engine = UsageEngine(providerOrder: [.anthropic], credentialProbe: probe.probe)
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)

        clock.advance(31)
        let first = engine.claimDueFetches(now: clock.now)
        complete(engine, first, account, .failure(.authenticationRejected), now: clock.now)

        // The retry does not reach the endpoint at all.
        let retry = engine.claimDueFetches(now: clock.now)
        complete(engine, retry, account, .failure(.transport(message: "offline")), now: clock.now)

        clock.advance(3600)
        let later = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("the account is still polling an hour later", later.count, 1)
        complete(engine, later, account, .failure(.authenticationRejected), now: clock.now)
        TestHarness.check("a rejection after an unrelated failure is a FIRST rejection",
                          engine.presentation(for: account.id, now: clock.now)?.isPollingStopped == false)
        TestHarness.expect("so it is owed its own re-read, not a verdict", probe.calls, 0)
        TestHarness.expect("and the re-read is what runs next",
                           engine.claimDueFetches(now: clock.now).first?.trigger, .retry)
    }

    // §6: "only a second consecutive rejection with a credential whose stored expiry has
    // genuinely passed marks the account expired and stops its timer".
    static func secondRejectionWithLapsedExpiryStopsTimer() {
        let clock = Clock()
        let probe = ProbeSpy()
        let dead = ref(.anthropic, "dead")
        let live = ref(.anthropic, "live")
        let expiry = clock.now.addingTimeInterval(-60)
        probe.facts[dead.id.storageKey] = CredentialFact(digest: "d", expiresAt: expiry)
        let engine = UsageEngine(providerOrder: [.anthropic], credentialProbe: probe.probe)
        engine.ingest([observation(dead, location: "svc-dead", digest: "dead"),
                       observation(live, location: "svc-live", digest: "live")],
                      covering: [.anthropic], now: clock.now)

        clock.advance(31)
        let first = engine.claimDueFetches(now: clock.now)
        complete(engine, first, dead, .failure(.authenticationRejected), now: clock.now)
        complete(engine, first, live, fetched(live, [window(.session, percent: 7)], at: clock.now),
                 now: clock.now)

        let retry = engine.claimDueFetches(now: clock.now)
        complete(engine, retry, dead, .failure(.authenticationRejected), now: clock.now)

        let card = engine.presentation(for: dead.id, now: clock.now)
        TestHarness.expect("a second rejection with a lapsed expiry renders expired",
                           describe(card?.state ?? .pending), "expired")
        TestHarness.check("and stops that account's timer", card?.isPollingStopped == true)
        TestHarness.expect("the expiry was consulted exactly once, on the second rejection",
                           probe.calls, 1)

        // Acceptance criterion 10: "while other accounts keep updating".
        clock.advance(3600)
        let claimed = engine.claimDueFetches(now: clock.now)
        TestHarness.check("the stopped account is not polled again",
                          !claimed.contains { $0.ref.id == dead.id })
        TestHarness.check("the healthy sibling keeps polling",
                          claimed.contains { $0.ref.id == live.id })
    }

    // The twin of the case above, and §6 requires they stay distinct: "an authorization
    // failure that is not an expiry — a revoked or scope-reduced credential — is
    // distinguished from transient upstream blocking, which backs off and retries rather
    // than stopping". Collapsing the two parks an account that a retry would recover.
    static func secondRejectionWithoutLapsedExpiryKeepsRetrying() {
        let clock = Clock()
        let probe = ProbeSpy()
        let account = ref(.anthropic, "revoked")
        probe.facts[account.id.storageKey] =
            CredentialFact(digest: "d", expiresAt: clock.now.addingTimeInterval(8 * 3600))
        let engine = UsageEngine(providerOrder: [.anthropic], credentialProbe: probe.probe)
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)

        clock.advance(31)
        let first = engine.claimDueFetches(now: clock.now)
        complete(engine, first, account, .failure(.authenticationRejected), now: clock.now)
        let retry = engine.claimDueFetches(now: clock.now)
        complete(engine, retry, account, .failure(.authenticationRejected), now: clock.now)

        let card = engine.presentation(for: account.id, now: clock.now)
        TestHarness.expect("a rejection with an unexpired credential is not expiry",
                           describe(card?.state ?? .pending), "failed")
        TestHarness.check("and the timer keeps running", card?.isPollingStopped == false)
        clock.advance(3600)
        TestHarness.expect("so the account is retried",
                           engine.claimDueFetches(now: clock.now).count, 1)
    }

    // The THIRD shape of a second rejection, and the one that matters most for Codex:
    // a credential whose expiry cannot be read at all. `auth.json` publishes no expiry
    // this app can read, so `expiresAt` is nil on every Codex rejection — and §6 stops a
    // timer only on an expiry that has GENUINELY passed. Treating an unreadable expiry as
    // a lapsed one would park the machine's only Codex account permanently, revivable
    // only by a credential change it may never get.
    static func secondRejectionWithUnreadableExpiryNeverStops() {
        let clock = Clock()
        let probe = ProbeSpy()   // answers with no expiry at all
        let account = ref(.codex, "codex-acct")
        let engine = UsageEngine(providerOrder: [.codex], credentialProbe: probe.probe)
        engine.ingest([observation(account, location: "auth.json")],
                      covering: [.codex], now: clock.now)

        clock.advance(31)
        let first = engine.claimDueFetches(now: clock.now)
        complete(engine, first, account, .failure(.authenticationRejected), now: clock.now)
        let retry = engine.claimDueFetches(now: clock.now)
        complete(engine, retry, account, .failure(.authenticationRejected), now: clock.now)

        TestHarness.expect("the expiry was asked for", probe.calls, 1)
        let card = engine.presentation(for: account.id, now: clock.now)
        TestHarness.check("an unreadable expiry never stops the timer",
                          card?.isPollingStopped == false)
        TestHarness.expect("and the row does not claim the credential expired",
                           describe(card?.state ?? .pending), "failed")
        clock.advance(3600)
        TestHarness.expect("the account keeps being retried",
                           engine.claimDueFetches(now: clock.now).count, 1)
    }

    // §6 floors `Retry-After` at 60 seconds. The floor is invisible while a fetch returns
    // instantly — the 60s cooldown covers the same span — and it binds the moment a
    // request takes real time: a slow request that ends in a throttle with no usable
    // Retry-After would otherwise be retried the instant it returned.
    static func retryAfterIsFloored() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "slow")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let claimed = engine.claimDueFetches(now: clock.now)

        // The request took two minutes and came back throttled with no usable header.
        clock.advance(120)
        let refusedAt = clock.now
        complete(engine, claimed, account, .failure(.rateLimited(retryAfter: nil)), now: clock.now)

        clock.advance(10)
        engine.requestManualRefresh(now: clock.now)
        TestHarness.expect("a refusal with no Retry-After still holds for 60s",
                           engine.claimDueFetches(now: clock.now).count, 0)
        TestHarness.expect("and the hold is the server backoff, not the cooldown",
                           engine.lastBlock(for: account.id),
                           .serverBackoff(until: refusedAt.addingTimeInterval(60)))
    }

    // §6: "a stopped account must have a defined path back to life". The app cannot renew
    // a credential; recovery depends on the CLI writing the store at an unpredictable
    // time. Stopping the timer without this contract makes expiry permanent — the user
    // signs in again and the app never notices.
    static func stoppedAccountRevivedByCredentialChange() {
        let clock = Clock()
        let probe = ProbeSpy()
        let account = ref(.anthropic, "revivable")
        probe.facts[account.id.storageKey] =
            CredentialFact(digest: "old", expiresAt: clock.now.addingTimeInterval(-1))
        let engine = UsageEngine(providerOrder: [.anthropic], credentialProbe: probe.probe)
        engine.ingest([observation(account, location: "svc", digest: "old")],
                      covering: [.anthropic], now: clock.now)

        clock.advance(31)
        let first = engine.claimDueFetches(now: clock.now)
        complete(engine, first, account, .failure(.authenticationRejected), now: clock.now)
        let retry = engine.claimDueFetches(now: clock.now)
        complete(engine, retry, account, .failure(.authenticationRejected), now: clock.now)
        TestHarness.check("account is stopped",
                          engine.presentation(for: account.id, now: clock.now)?.isPollingStopped == true)

        // The survey keeps running for stopped accounts — it is local and costs no
        // upstream request, which is exactly why it is safe under a rate-limit budget.
        clock.advance(120)
        engine.ingest([observation(account, location: "svc", digest: "old")],
                      covering: [.anthropic], now: clock.now)
        TestHarness.check("an unchanged credential does NOT revive it",
                          engine.presentation(for: account.id, now: clock.now)?.isPollingStopped == true)
        TestHarness.expect("and nothing is polled", engine.claimDueFetches(now: clock.now).count, 0)

        clock.advance(120)
        engine.ingest([observation(account, location: "svc", digest: "written-by-the-cli")],
                      covering: [.anthropic], now: clock.now)
        let card = engine.presentation(for: account.id, now: clock.now)
        TestHarness.check("a changed credential digest revives the account",
                          card?.isPollingStopped == false)
        let claimed = engine.claimDueFetches(now: clock.now)
        TestHarness.expect("and it polls again without a restart or a manual refresh",
                           claimed.count, 1)
        TestHarness.expect("as a discovery-triggered fetch", claimed.first?.trigger, .discovery)
        // A revived account must not carry the old backoff exponent into its next
        // failure: the failures before the stop would otherwise make the first failure
        // after recovery wait many minutes.
        complete(engine, claimed, account, .failure(.transport(message: "x")), now: clock.now)
        TestHarness.check("and its backoff starts over rather than resuming where it left off",
                          (engine.nextPollDate(for: account.id) ?? clock.now)
                            .timeIntervalSince(clock.now) < 120)
    }

    // The same wake-up contract ACROSS A RELAUNCH, which is where it was broken. An
    // earlier draft required a previously-observed digest before treating a change as a
    // change, so the first credential seen after a restart was swallowed as a baseline.
    // The sequence that reaches it is ordinary: the account stops on a lapsed expiry, the
    // user signs out (the survey persists a nil digest), the app is quit, the user signs
    // back in, and the app comes up — with the re-login invisible until the next rotation.
    static func stoppedAccountRevivedAfterRelaunch() {
        let clock = Clock()
        var stopped = PersistedAccountState()
        stopped.stoppedExpiry = clock.now.addingTimeInterval(-3600)
        stopped.credentialDigest = nil    // signed out at the moment the app last looked
        let account = ref(.anthropic, "relaunched-stopped")

        let engine = UsageEngine(providerOrder: [.anthropic],
                                 restoring: [account.id.storageKey: stopped],
                                 now: clock.now)
        engine.ingest([observation(account, location: "svc", digest: "signed-in-again")],
                      covering: [.anthropic], now: clock.now)

        let card = engine.presentation(for: account.id, now: clock.now)
        TestHarness.check("the first credential seen after a relaunch revives the account",
                          card?.isPollingStopped == false)
        // On its own staggered schedule rather than in the same instant: the revival is
        // the stop being cleared, and §6's stagger still applies to when it fires.
        clock.advance(PollSchedule.staggerSpan + 1)
        TestHarness.expect("and it polls without waiting for another rotation",
                           engine.claimDueFetches(now: clock.now).count, 1)

        // The control: an account restored with the SAME digest it is then observed with
        // stays stopped, so the revival above is a change and not merely "any survey".
        let unchanged = ref(.anthropic, "still-stopped")
        var same = PersistedAccountState()
        same.stoppedExpiry = clock.now.addingTimeInterval(-3600)
        same.credentialDigest = "unchanged"
        let control = UsageEngine(providerOrder: [.anthropic],
                                  restoring: [unchanged.id.storageKey: same],
                                  now: clock.now)
        control.ingest([observation(unchanged, location: "svc", digest: "unchanged")],
                       covering: [.anthropic], now: clock.now)
        TestHarness.check("an unchanged credential across a relaunch stays stopped",
                          control.presentation(for: unchanged.id, now: clock.now)?
                            .isPollingStopped == true)
    }

    // §6: "a lastFetchAttempt timestamp persists across restarts so cooldown survives
    // relaunch". Otherwise quit-and-relaunch is an unlimited bypass of every rate gate
    // the app has — and it is the first thing a user does to an app that looks stuck.
    static func cooldownSurvivesRelaunch() {
        let clock = Clock()
        let account = ref(.anthropic, "restarted")
        let first = UsageEngine(providerOrder: [.anthropic])
        first.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let claimed = first.claimDueFetches(now: clock.now)
        complete(first, claimed, account,
                 fetched(account, [window(.session, percent: 55)], at: clock.now), now: clock.now)

        var restored: [String: PersistedAccountState] = [:]
        for op in first.drainPersistence() {
            guard case .write(let key, let payload) = op,
                  PersistedStore.ledgerKey(of: key) == nil,
                  let state = PersistedCodec.decode(PersistedAccountState.self, from: payload)
            else { continue }
            restored[key] = state
        }
        TestHarness.expect("the account's namespace was persisted", restored.count, 1)

        // The relaunch.
        let second = UsageEngine(providerOrder: [.anthropic], restoring: restored, now: clock.now)
        clock.advance(5)
        second.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        second.requestManualRefresh(now: clock.now)
        TestHarness.expect("the cooldown from before the relaunch still binds",
                           second.claimDueFetches(now: clock.now).count, 0)
        switch second.lastBlock(for: account.id) {
        case .cooldown: TestHarness.check("and it is the cooldown that binds", true)
        case let other: TestHarness.check("and it is the cooldown that binds: got \(String(describing: other))", false)
        }
        // The cached reading came back with it, so a restart does not blank the UI.
        let card = second.presentation(for: account.id, now: clock.now)
        TestHarness.expect("the cached snapshot survived the relaunch",
                           snapshot(in: card?.state ?? .pending)?.bindingUtilization, .known(55))

        clock.advance(60)
        TestHarness.expect("and once the floor elapses the refresh runs",
                           second.claimDueFetches(now: clock.now).count, 1)
    }

    // The budget is the BINDING constraint (§6), so it has to survive a relaunch — and it
    // has to survive an ACCOUNT REMOVAL, which is the harder half. The ledger belongs to
    // the credential, not to any account: persisted inside one account's namespace it is
    // deleted when that account leaves discovery, and a sibling sharing the credential
    // relaunches with a full allowance inside the window the spends were made in.
    static func ledgerSurvivesRelaunchAndAccountRemoval() {
        let clock = Clock()
        let leaving = ref(.anthropic, "ledger-a")
        let staying = ref(.anthropic, "ledger-b")
        let observations = [observation(leaving, location: "svc-a", digest: "one-token"),
                            observation(staying, location: "svc-b", digest: "one-token")]

        let before = UsageEngine(providerOrder: [.anthropic])
        before.ingest(observations, covering: [.anthropic], now: clock.now)
        clock.advance(31)
        pollAll(before, now: clock.now)                                                // 2 spends
        clock.advance(64)
        before.requestManualRefresh(now: clock.now); pollAll(before, now: clock.now)    // 4
        clock.advance(64)
        before.requestManualRefresh(now: clock.now); pollAll(before, now: clock.now)    // 5

        // One of the two accounts leaves discovery entirely, taking its namespace with it.
        before.ingest([observations[1]], covering: [.anthropic], now: clock.now)

        var accounts: [String: PersistedAccountState] = [:]
        var ledgers: [String: PersistedCredentialLedger] = [:]
        var index: [String] = []
        for op in before.drainPersistence() {
            switch op {
            case .write(let key, let payload):
                index.append(key)
                if let ledgerKey = PersistedStore.ledgerKey(of: key) {
                    ledgers[ledgerKey] = PersistedCodec.decode(PersistedCredentialLedger.self,
                                                               from: payload)
                } else {
                    accounts[key] = PersistedCodec.decode(PersistedAccountState.self, from: payload)
                }
            case .delete(let key):
                index.removeAll { $0 == key }
            }
        }
        TestHarness.expect("the ledger is persisted in its own namespace", ledgers.count, 1)
        TestHarness.check("outside the departed account's namespace",
                          !index.contains(leaving.id.storageKey))
        TestHarness.expect("and it carries every spend, from both accounts",
                           ledgers["digest:one-token"]?.spends.count, 5)
        TestHarness.check("bounded by the rolling span rather than growing forever",
                          (ledgers["digest:one-token"]?.spends.count ?? 99)
                            <= RequestBudget.capacity)

        clock.advance(70)
        let after = UsageEngine(providerOrder: [.anthropic],
                                restoring: accounts,
                                restoringLedgers: ledgers,
                                now: clock.now)
        after.ingest([observations[1]], covering: [.anthropic], now: clock.now)
        after.requestManualRefresh(now: clock.now)
        TestHarness.expect("the surviving account cannot spend the departed one's allowance",
                           after.claimDueFetches(now: clock.now).count, 0)
        switch after.lastBlock(for: staying.id) {
        case .budgetExhausted: TestHarness.check("and it is the budget that binds", true)
        case let other: TestHarness.check("and it is the budget that binds: got \(String(describing: other))", false)
        }

        // The control: the same account with no restored ledger is admitted, so the
        // refusal above is the persisted ledger and not the shape of the test.
        let clean = UsageEngine(providerOrder: [.anthropic], restoring: accounts, now: clock.now)
        clean.ingest([observations[1]], covering: [.anthropic], now: clock.now)
        clean.requestManualRefresh(now: clock.now)
        TestHarness.expect("without a restored ledger the same request is admitted",
                           clean.claimDueFetches(now: clock.now).count, 1)

        // And a ledger with nothing live left in it is reclaimed at load rather than
        // carried forward as a namespace nobody will ever delete.
        clock.advance(RequestBudget.span + 1)
        let later = UsageEngine(providerOrder: [.anthropic],
                                restoringLedgers: ledgers,
                                now: clock.now)
        TestHarness.check("an expired ledger is reclaimed on load",
                          later.drainPersistence()
                            .contains(.delete(storageKey: "credential:digest:one-token")))
    }

    // §6: "on failure, present `.stale(snapshot, since:)` with an 'as of HH:mm' label
    // rather than blanking". Blanking a working account because one poll failed is the
    // most common thing this cache exists to prevent, and `since` must be when the
    // failures STARTED — a value that walks forward with every retry tells the user the
    // data is fresh at the exact moment it is getting older.
    static func failureWithCacheRendersStale() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "wobbly")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        var claimed = engine.claimDueFetches(now: clock.now)
        let readingAt = clock.now
        complete(engine, claimed, account,
                 fetched(account, [window(.session, percent: 71, active: true)], at: readingAt),
                 now: clock.now)

        clock.advance(400)
        claimed = engine.claimDueFetches(now: clock.now)
        let firstFailure = clock.now
        complete(engine, claimed, account, .failure(.transport(message: "offline")), now: clock.now)

        var card = engine.presentation(for: account.id, now: clock.now)
        TestHarness.expect("a failure with a cached reading is stale, not blank",
                           describe(card?.state ?? .pending), "stale")
        guard case .stale(let cached, let since)? = card?.state else {
            TestHarness.check("stale carries its snapshot and its since date", false)
            return
        }
        TestHarness.expect("the cached figure is still shown", cached.bindingUtilization, .known(71))
        TestHarness.expect("as of when it was actually read", cached.fetchedAt, readingAt)
        TestHarness.expect("and `since` is when the failures started", since, firstFailure)
        TestHarness.expect("a cached reading inside its horizon still drives the menu bar",
                           engine.menuBarFigures(now: clock.now).first?.utilization, .known(71))

        // A second failure must not move `since` forward.
        clock.advance(200)
        claimed = engine.claimDueFetches(now: clock.now)
        complete(engine, claimed, account, .failure(.transport(message: "offline")), now: clock.now)
        if case .stale(_, let laterSince)? = engine.presentation(for: account.id, now: clock.now)?.state {
            TestHarness.expect("`since` does not walk forward with each retry",
                               laterSince, firstFailure)
        } else {
            TestHarness.check("`since` does not walk forward with each retry", false)
        }

        clock.advance(200)
        claimed = engine.claimDueFetches(now: clock.now)
        complete(engine, claimed, account,
                 fetched(account, [window(.session, percent: 74, active: true)], at: clock.now),
                 now: clock.now)
        card = engine.presentation(for: account.id, now: clock.now)
        TestHarness.expect("and a success clears the stale marker",
                           describe(card?.state ?? .pending), "active")
    }

    // MARK: - Cache horizon

    // §6: "beyond it, a cached figure is suppressed rather than displayed — a quota
    // reading hours or days old is misleading in the one direction that matters, implying
    // headroom the user may not have. Past the horizon the account renders as unknown
    // with its last-seen time, and it never contributes to the menu-bar worst-of."
    static func horizonSuppressesAndExcludesFromWorstOf() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "aging", label: "aging")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let claimed = engine.claimDueFetches(now: clock.now)
        let fetchedAt = clock.now
        complete(engine, claimed, account,
                 fetched(account,
                         [window(.session, percent: 80, active: true, label: "Session 5h"),
                          window(.weekly, percent: 40, label: "Weekly 7d")],
                         at: fetchedAt),
                 now: clock.now)

        let figures = engine.menuBarFigures(now: fetchedAt.addingTimeInterval(60))
        TestHarness.expect("a fresh reading reports the binding window",
                           figures.first?.utilization, .known(80))
        TestHarness.expect("and names it in the tooltip", figures.first?.windowLabel, "Session 5h")

        // Past the SESSION horizon only. The weekly window is younger than its own
        // horizon and is still good — which is the whole reason the horizon is per class.
        let aged = fetchedAt.addingTimeInterval(CacheHorizon.sessionHorizon + 1)
        let card = engine.presentation(for: account.id, now: aged)
        let projected = snapshot(in: card?.state ?? .pending)
        TestHarness.expect("the aged session window reads unknown, not its old figure",
                           projected?.windows.first(where: { $0.id.span == .session })?.utilization,
                           .unknown)
        TestHarness.expect("the still-valid weekly window keeps its figure",
                           projected?.windows.first(where: { $0.id.span == .weekly })?.utilization,
                           .known(40))

        // Past every horizon: the account contributes NOTHING. It does not contribute an
        // `unknown` either — that would make the whole provider read unknown on the
        // strength of a reading that should have been ignored outright.
        let stale = fetchedAt.addingTimeInterval(CacheHorizon.weeklyHorizon + 1)
        TestHarness.expect("past every horizon the account leaves the menu bar entirely",
                           engine.menuBarFigures(now: stale).count, 0)
        let staleCard = engine.presentation(for: account.id, now: stale)
        TestHarness.expect("but the row is still there, with its last-seen time",
                           staleCard?.lastSuccessAt, fetchedAt)
        TestHarness.check("and every window on it reads unknown",
                          snapshot(in: staleCard?.state ?? .pending)?
                            .windows.allSatisfy { $0.utilization == .unknown } == true)

        // A suppressed window that was NOT the binding one must not poison a live one:
        // suppression is per window class, and the remaining active window is still a
        // real reading.
        let mixedEngine = UsageEngine(providerOrder: [.anthropic])
        let mixed = ref(.anthropic, "mixed", label: "mixed")
        mixedEngine.ingest([observation(mixed, location: "svc-mixed", digest: "m")],
                           covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let mixedClaim = mixedEngine.claimDueFetches(now: clock.now)
        let mixedAt = clock.now
        complete(mixedEngine, mixedClaim, mixed,
                 fetched(mixed,
                         [window(.other(seconds: 9000), .feature(id: "f"), percent: 10,
                                 label: "Short"),
                          window(.weekly, percent: 55, active: true, label: "Weekly 7d")],
                         at: mixedAt),
                 now: clock.now)
        let partially = mixedAt.addingTimeInterval(
            CacheHorizon.horizon(for: .other(seconds: 9000)) + 1
        )
        let mixedFigure = mixedEngine.menuBarFigures(now: partially).first
        TestHarness.expect("a suppressed NON-binding window leaves the live figure alone",
                           mixedFigure?.utilization, .known(55))
    }

    // The two §6 sentences about the horizon are not the same rule, and reading them as
    // one produced a measured contradiction: with the binding window suppressed and a
    // lower non-binding one still live, DELETING the suppressed window before the fold
    // reported the non-binding figure — in green — while the same account's own card said
    // unknown at the same instant. The 95% existed nowhere on screen.
    //
    // Reachability is not exotic: `CacheHorizon.sessionHorizon` and the ladder's 30-minute
    // cap are the same number, so a throttled account is past its session horizon for
    // roughly half of every cycle.
    static func menuBarAndCardAgreePastTheHorizon() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "contradiction", label: "contradiction")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let claimed = engine.claimDueFetches(now: clock.now)
        let fetchedAt = clock.now
        complete(engine, claimed, account,
                 fetched(account,
                         [window(.session, percent: 95, active: true, label: "Session 5h"),
                          window(.weekly, percent: 10, label: "Weekly 7d")],
                         at: fetchedAt),
                 now: clock.now)

        let aged = fetchedAt.addingTimeInterval(CacheHorizon.sessionHorizon + 1)
        let card = engine.presentation(for: account.id, now: aged)
        let cardFigure = snapshot(in: card?.state ?? .pending)?.bindingUtilization
        let menuFigure = engine.menuBarFigures(now: aged).first?.utilization

        TestHarness.expect("the card reports unknown once the binding window is suppressed",
                           cardFigure, .unknown)
        TestHarness.expect("and the menu bar reports the same thing at the same instant",
                           menuFigure, .unknown)
        TestHarness.check("the menu bar never reports the non-binding window as the figure",
                          menuFigure != .known(10))
        // The account is still present in the fold — it has a live window — it is simply
        // unknown. That is the difference between this and the past-every-horizon case.
        TestHarness.expect("the provider is still represented",
                           engine.menuBarFigures(now: aged).count, 1)
    }

    // A clock corrected backwards after a fetch leaves a reading whose age is permanently
    // negative. Bounding only the past looks complete and gives that reading no upper
    // limit at all — it stays on the menu bar for as long as the skew lasts, however old
    // it really is.
    static func futureDatedReadingsAreSuppressed() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "skewed")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let claimed = engine.claimDueFetches(now: clock.now)
        // Stamped an hour ahead: the machine's clock was corrected backwards afterwards.
        complete(engine, claimed, account,
                 fetched(account, [window(.session, percent: 90, active: true)],
                         at: clock.now.addingTimeInterval(3600)),
                 now: clock.now)

        TestHarness.expect("a far-future reading does not sit on the menu bar",
                           engine.menuBarFigures(now: clock.now).count, 0)
        TestHarness.expect("and the card reads unknown rather than 90%",
                           snapshot(in: engine.presentation(for: account.id, now: clock.now)?.state
                                    ?? .pending)?.bindingUtilization,
                           .unknown)
    }

    // MARK: - Lifecycle

    // §6: "state for an account absent from discovery is reclaimed rather than left in
    // place". This machine already carries five credential entries for directories that
    // no longer exist; without a lifecycle the keyspace grows without bound and a stale
    // entry silently resurrects when an identifier is reused.
    static func vanishedAccountStateIsReclaimed() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic, .codex])
        let staying = ref(.anthropic, "staying")
        let leaving = ref(.anthropic, "leaving")
        let codex = ref(.codex, "codex-acct")
        engine.ingest([observation(staying, location: "a", digest: "a"),
                       observation(leaving, location: "b", digest: "b"),
                       observation(codex, location: "c", digest: "c")],
                      covering: [.anthropic, .codex], now: clock.now)
        clock.advance(31)
        TestHarness.expect("all three accounts poll once",
                           engine.claimDueFetches(now: clock.now).count, 3)
        _ = engine.drainPersistence()

        clock.advance(120)
        engine.ingest([observation(staying, location: "a", digest: "a"),
                       observation(codex, location: "c", digest: "c")],
                      covering: [.anthropic, .codex], now: clock.now)
        let ops = engine.drainPersistence()
        TestHarness.check("the vanished account's namespace is deleted",
                          ops.contains(.delete(storageKey: leaving.id.storageKey)))
        TestHarness.check("and it is gone from the registry",
                          !engine.knownStorageKeys.contains(leaving.id.storageKey))
        TestHarness.check("while the surviving account is untouched",
                          engine.knownStorageKeys.contains(staying.id.storageKey))

        // A survey that covered only ONE provider must not reclaim the other's accounts —
        // otherwise an Anthropic-only refresh silently wipes Codex's history.
        clock.advance(120)
        engine.ingest([observation(staying, location: "a", digest: "a")],
                      covering: [.anthropic], now: clock.now)
        TestHarness.check("a partial survey does not reclaim an uncovered provider",
                          engine.knownStorageKeys.contains(codex.id.storageKey))

        // A THIRD layer, and one a sweep over accounts structurally cannot reach: the
        // budget ledger is keyed by CREDENTIAL, so it belongs to no account and no
        // account's removal drops it. Left alone it is the one keyspace here that grows
        // without bound as profiles churn — but it must not be released while it still
        // holds live spends, or an account that leaves and returns inside the rolling
        // span starts again with a full allowance.
        TestHarness.check("the departed account's credential is still tracked while its "
                          + "spends are live",
                          engine.trackedBudgetKeys.contains("digest:b"))
        clock.advance(RequestBudget.span + 1)
        engine.ingest([observation(staying, location: "a", digest: "a"),
                       observation(codex, location: "c", digest: "c")],
                      covering: [.anthropic, .codex], now: clock.now)
        TestHarness.check("and is reclaimed once it has nothing live left in it",
                          !engine.trackedBudgetKeys.contains("digest:b"))
        TestHarness.check("with its persisted namespace",
                          engine.drainPersistence()
                            .contains(.delete(storageKey: "credential:digest:b")))
        TestHarness.check("while a credential still in use is kept",
                          engine.trackedBudgetKeys.contains("digest:a"))

        // The same rule ONE LAYER UP, where a sweep over live accounts never runs: a
        // payload restored from disk whose account no discovery pass ever produced. This
        // is the orphan that accumulates across reinstalls, and it never becomes a
        // registry entry to be swept.
        let orphanKey = AccountIdentity(provider: .anthropic, "long-gone").storageKey
        let reborn = UsageEngine(providerOrder: [.anthropic, .codex],
                                 restoring: [orphanKey: PersistedAccountState()])
        reborn.ingest([], covering: [.codex], now: clock.now)
        TestHarness.check("a codex-only survey leaves an anthropic orphan alone",
                          !reborn.drainPersistence().contains(.delete(storageKey: orphanKey)))
        reborn.ingest([], covering: [.anthropic], now: clock.now)
        TestHarness.check("an anthropic survey reclaims the orphan",
                          reborn.drainPersistence().contains(.delete(storageKey: orphanKey)))
    }

    // A FOURTH orphan class, one layer above every sweep the engine can run: a persisted
    // key whose bytes are corrupt, or whose version this build cannot read, never becomes
    // an account payload at all — so it never enters the unclaimed map and the orphan
    // sweep structurally cannot see it. Left alone the index keeps naming it and its blob
    // keeps sitting under it forever, which is the same failure §6 names about five stale
    // credential entries.
    static func unreadablePersistedStateIsReclaimed() {
        let good = AccountIdentity(provider: .anthropic, "readable").storageKey
        let corrupt = AccountIdentity(provider: .anthropic, "corrupt").storageKey
        let ancient = AccountIdentity(provider: .codex, "old-version").storageKey
        let missing = AccountIdentity(provider: .anthropic, "indexed-but-absent").storageKey
        let ledgerKey = PersistedStore.ledgerNamespace + "digest:abc"
        let brokenLedger = PersistedStore.ledgerNamespace + "digest:broken"

        var state = PersistedAccountState()
        state.rung = 1
        var ledger = PersistedCredentialLedger()
        ledger.spends = [RequestSpend(account: "anthropic:x", at: Date(timeIntervalSince1970: 10))]

        let blobs: [String: Data] = [
            good: PersistedCodec.encode(state)!,
            corrupt: Data("{ not json".utf8),
            ancient: Data(#"{"version":1,"enabled":true,"rung":0,"successStreak":0,"consecutiveFailures":0}"#.utf8),
            ledgerKey: PersistedCodec.encode(ledger)!,
            brokenLedger: Data("{}".utf8),
        ]
        let index = [good, corrupt, ancient, missing, ledgerKey, brokenLedger]

        let contents = PersistedStore.load(index: index) { blobs[$0] }
        TestHarness.expect("the readable account is restored", contents.accounts.count, 1)
        TestHarness.expect("with its state intact", contents.accounts[good]?.rung, 1)
        TestHarness.expect("the readable ledger is restored", contents.ledgers.count, 1)
        TestHarness.check("under its credential key, not its storage key",
                          contents.ledgers["digest:abc"] != nil)
        TestHarness.expect("and everything unreadable is named for reclamation",
                           Set(contents.unreadable),
                           Set([corrupt, ancient, missing, brokenLedger]))

        // A payload from a version this build does not understand is unreadable, not
        // merely empty: silently treating it as a fresh account would keep the key alive
        // forever while ignoring what it says.
        TestHarness.check("a version mismatch is a decode failure",
                          PersistedCodec.decode(PersistedAccountState.self,
                                                from: blobs[ancient]!) == nil)
    }

    // §6: "a different account signing into the same location is a different account, and
    // the previous occupant's state is reclaimed rather than inherited. Losing threshold
    // history is acceptable; silent misattribution of one account's usage to another is
    // not." Both accounts here share a location, and therefore a credential service name
    // and a budget key — everything except identity.
    static func differentAccountAtSameLocationInheritsNothing() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let previous = ref(.anthropic, "uuid-previous", label: "default")
        engine.ingest([observation(previous, location: "Claude Code-credentials")],
                      covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let claimed = engine.claimDueFetches(now: clock.now)
        complete(engine, claimed, previous,
                 fetched(previous, [window(.session, percent: 93, active: true)], at: clock.now),
                 now: clock.now)
        TestHarness.expect("the previous occupant had a reading",
                           engine.menuBarFigures(now: clock.now).first?.utilization, .known(93))

        // Same directory, same label, same credential — different account.
        clock.advance(60)
        let successor = ref(.anthropic, "uuid-successor", label: "default")
        engine.ingest([observation(successor, location: "Claude Code-credentials")],
                      covering: [.anthropic], now: clock.now)
        let card = engine.presentation(for: successor.id, now: clock.now)
        TestHarness.expect("the new occupant starts with no reading at all",
                           describe(card?.state ?? .active(
                            Snapshot(account: successor, windows: [], fetchedAt: clock.now))),
                           "pending")
        TestHarness.expect("and the menu bar reports nothing for it",
                           engine.menuBarFigures(now: clock.now).count, 0)
        TestHarness.check("the previous occupant's namespace was reclaimed",
                          !engine.knownStorageKeys.contains(previous.id.storageKey))
    }

    // Every `FetchError` case handled explicitly (§5 added `.accountUnknown` precisely
    // because folding a new case into the retry path retried a departed account forever).
    static func terminalAndTransientFailuresAreDistinguished() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let gone = ref(.anthropic, "gone")
        let flaky = ref(.anthropic, "flaky")
        engine.ingest([observation(gone, location: "a", digest: "a"),
                       observation(flaky, location: "b", digest: "b")],
                      covering: [.anthropic], now: clock.now)
        clock.advance(31)
        var claimed = engine.claimDueFetches(now: clock.now)
        _ = engine.drainPersistence()

        complete(engine, claimed, gone, .failure(.accountUnknown), now: clock.now)
        TestHarness.check("an account that left discovery is dropped, not retried",
                          !engine.knownStorageKeys.contains(gone.id.storageKey))
        TestHarness.check("and its namespace goes with it",
                          engine.drainPersistence().contains(.delete(storageKey: gone.id.storageKey)))

        // A malformed response is where §5's retention matters most: this is exactly the
        // silent schema drift the raw body exists to diagnose.
        complete(engine, claimed, flaky,
                 .failure(.malformedResponse(message: "no limits[]",
                                             rawBody: Data("{\"x\":1}".utf8))),
                 now: clock.now)
        TestHarness.expect("the raw body is retained on the malformed path",
                           engine.retainedRawBody(for: flaky.id), Data("{\"x\":1}".utf8))
        TestHarness.expect("a malformed response does not lengthen the interval",
                           engine.interval(for: flaky.id), 300)
        TestHarness.check("but it does back off",
                          (engine.nextPollDate(for: flaky.id) ?? clock.now) > clock.now)

        clock.advance(120)
        claimed = engine.claimDueFetches(now: clock.now)
        complete(engine, claimed, flaky, .failure(.unexpectedStatus(code: 500)), now: clock.now)
        TestHarness.expect("an unexpected status does not lengthen the interval either",
                           engine.interval(for: flaky.id), 300)
        let card = engine.presentation(for: flaky.id, now: clock.now)
        TestHarness.expect("an account failing with no cached reading is `failed`",
                           describe(card?.state ?? .pending), "failed")
        TestHarness.check("and it is still scheduled to retry", card?.nextPollAt != nil)
    }

    // Some window identities are DELIBERATELY volatile across polls — Anthropic's
    // positional `index:n` and Codex's `dup:<ordinal>` (tasks 5 and 6 both recorded this).
    // A cache that merged windows by id would keep a window the provider has stopped
    // sending, forever, under an id it has since given to something else.
    static func snapshotsAreReplacedNeverMerged() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "volatile")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        var claimed = engine.claimDueFetches(now: clock.now)
        complete(engine, claimed, account,
                 fetched(account, [window(.weekly, .feature(id: "index:0"), percent: 90),
                                   window(.session, percent: 10)],
                         at: clock.now),
                 now: clock.now)
        clock.advance(400)
        claimed = engine.claimDueFetches(now: clock.now)
        complete(engine, claimed, account,
                 fetched(account, [window(.session, percent: 12)], at: clock.now), now: clock.now)

        let windows = snapshot(in: engine.presentation(for: account.id, now: clock.now)?.state
                                ?? .pending)?.windows ?? []
        TestHarness.expect("the snapshot is replaced wholesale", windows.count, 1)
        TestHarness.check("so a window the provider stopped sending does not persist",
                          !windows.contains { $0.id.scope == .feature(id: "index:0") })
        TestHarness.expect("and the menu bar reflects only the current reading",
                           engine.menuBarFigures(now: clock.now).first?.utilization, .known(12))
    }

    // A credential that is gone outranks a cached reading. Showing yesterday's
    // percentages for an account that has since signed out is the same
    // manufactured-headroom failure the horizon exists to prevent, reached by a different
    // door — and §7.2 requires the row read "Signed out" with its sign-in hint.
    static func credentialStateOutranksCache() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "leaver")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(31)
        let claimed = engine.claimDueFetches(now: clock.now)
        complete(engine, claimed, account,
                 fetched(account, [window(.session, percent: 66)], at: clock.now), now: clock.now)

        clock.advance(60)
        engine.ingest([observation(account, state: .signedOut, location: "svc", digest: nil)],
                      covering: [.anthropic], now: clock.now)
        let card = engine.presentation(for: account.id, now: clock.now)
        TestHarness.expect("a signed-out credential is what the row says",
                           describe(card?.state ?? .pending), "signedOut")
        TestHarness.expect("a signed-out account is never polled",
                           engine.claimDueFetches(now: clock.now).count, 0)
        TestHarness.expect("nor does its cached reading reach the menu bar",
                           engine.menuBarFigures(now: clock.now).count, 0)
    }

    // §7.1 / §3: an unknown binding figure makes the aggregate unknown — it does not fall
    // through to the next-highest known window, which would present a non-binding number
    // as though it were the constraint. The same rule has to hold ACROSS accounts, or the
    // fold reintroduces exactly the manufactured headroom the model rules out per account.
    static func menuBarFoldPropagatesUnknown() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic, .codex])
        // Labels are deliberately chosen so BOTH sides of the comparison are covered:
        // `aaa` sorts before `known`, so the unknown account is the INCUMBENT when the
        // known one arrives; `murky` sorts after, so it is the CANDIDATE. Covering one
        // side only is this run's twinned-branch failure applied to a two-line switch.
        let early = ref(.anthropic, "aaa", label: "aaa")
        let known = ref(.anthropic, "known", label: "known")
        let late = ref(.anthropic, "murky", label: "murky")
        let codex = ref(.codex, "codex", label: "codex")
        engine.ingest([observation(early, location: "w", digest: "w"),
                       observation(known, location: "x", digest: "x"),
                       observation(late, location: "y", digest: "y"),
                       observation(codex, location: "z", digest: "z")],
                      covering: [.anthropic, .codex], now: clock.now)
        clock.advance(31)
        let claimed = engine.claimDueFetches(now: clock.now)
        complete(engine, claimed, known,
                 fetched(known, [window(.session, percent: 61, active: true)], at: clock.now),
                 now: clock.now)
        complete(engine, claimed, codex,
                 fetched(codex, [window(.session, percent: 31, active: true)], at: clock.now),
                 now: clock.now)

        var figures = engine.menuBarFigures(now: clock.now)
        TestHarness.expect("one figure per provider that has a reading", figures.count, 2)
        TestHarness.expect("providers are ordered", figures.first?.provider, .anthropic)
        TestHarness.expect("codex reports its own account", figures.last?.utilization, .known(31))
        TestHarness.expect("a pending account contributes nothing",
                           figures.first?.utilization, .known(61))

        // CANDIDATE unknown, incumbent known.
        complete(engine, claimed, late,
                 fetched(late, [window(.session, percent: nil, active: true)], at: clock.now),
                 now: clock.now)
        figures = engine.menuBarFigures(now: clock.now)
        TestHarness.expect("an unknown CANDIDATE makes the provider unknown",
                           figures.first?.utilization, .unknown)
        TestHarness.expect("the other provider is unaffected", figures.last?.utilization, .known(31))
        engine.setEnabled(false, for: late.id)

        // INCUMBENT unknown, candidate known — the branch that survived mutation.
        complete(engine, claimed, early,
                 fetched(early, [window(.session, percent: nil, active: true)], at: clock.now),
                 now: clock.now)
        figures = engine.menuBarFigures(now: clock.now)
        TestHarness.expect("an unknown INCUMBENT is not displaced by a known candidate",
                           figures.first?.utilization, .unknown)

        // Disabling the unknown account is the user saying "do not track this one" —
        // it must leave the fold as well as the popover (acceptance criterion 9).
        engine.setEnabled(false, for: early.id)
        TestHarness.expect("a disabled account leaves the menu-bar fold",
                           engine.menuBarFigures(now: clock.now).first?.utilization, .known(61))
    }

    // §6: jittered and STAGGERED so N accounts never fire together. Asserted through
    // `claimDueFetches`, not through `nextPollDate`: the due date is a neighbouring
    // object, and a pending trigger short-circuits it entirely, so a mutant that fires
    // all four at once still reports staggered due dates.
    static func staggerSpreadsFirstPolls() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let refs = (0..<4).map { ref(.anthropic, "stagger-\($0)") }
        engine.ingest(refs.map { observation($0, location: "svc-\($0.label)", digest: $0.label) },
                      covering: [.anthropic], now: clock.now)

        TestHarness.expect("nothing fires in the instant the accounts appear",
                           engine.claimDueFetches(now: clock.now).count, 0)
        var firedAt: [String: Date] = [:]
        for _ in 0...Int(PollSchedule.staggerSpan) {
            for task in engine.claimDueFetches(now: clock.now) {
                firedAt[task.ref.id.storageKey] = clock.now
                _ = engine.finish(task,
                                  fetched(task.ref, [window(.session, percent: 1)], at: clock.now),
                                  now: clock.now)
            }
            clock.advance(1)
        }
        TestHarness.expect("every account eventually polled", firedAt.count, 4)
        TestHarness.check("and they did not all poll in the same instant",
                          Set(firedAt.values).count > 1)

        // Successive polls are jittered around the interval rather than landing exactly
        // on it, so two accounts that collide once do not stay collided.
        var nextDue: [Date] = []
        for account in refs {
            guard let fired = firedAt[account.id.storageKey],
                  let next = engine.nextPollDate(for: account.id) else { continue }
            nextDue.append(next)
            TestHarness.check("\(account.label)'s next poll is within 10% of the base interval",
                              abs(next.timeIntervalSince(fired) - 300) <= 30.0001)
        }
        TestHarness.check("and the next round is spread too", Set(nextDue).count > 1)

        // Stagger alone keeps accounts apart only while nothing synchronises them. A
        // shared credential's throttle does exactly that: both accounts are refused in
        // the same instant with the same Retry-After, so without jitter their next
        // attempts land on the same instant — and stay locked together for good, which
        // is the simultaneity §6 asks for jitter to prevent.
        let together = UsageEngine(providerOrder: [.anthropic])
        let twinA = ref(.anthropic, "twin-a")
        let twinB = ref(.anthropic, "twin-b")
        together.ingest([observation(twinA, location: "svc", digest: "same"),
                         observation(twinB, location: "svc", digest: "same")],
                        covering: [.anthropic], now: clock.now)
        clock.advance(PollSchedule.staggerSpan + 1)
        let both = together.claimDueFetches(now: clock.now)
        TestHarness.expect("both accounts are in flight together", both.count, 2)
        for task in both {
            _ = together.finish(task, .failure(.rateLimited(retryAfter: 600)), now: clock.now)
        }
        TestHarness.check("a shared throttle does not leave them firing in the same instant",
                          together.nextPollDate(for: twinA.id)
                            != together.nextPollDate(for: twinB.id))
    }

    // Suppression takes the FIGURE and nothing else. The label, the scope, the active
    // flag and — the part that was unpinned — the reset time all survive, because a row
    // that still says when the window resets is the difference between "we cannot see
    // this right now" and "this window is gone".
    static func suppressionKeepsEverythingButTheFigure() {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resets = fetchedAt.addingTimeInterval(4000)
        let original = Snapshot(
            account: ref(.anthropic, "keeper"),
            windows: [UsageWindow(id: WindowID(span: .session, scope: .model(id: "m")),
                                  label: "Session · M",
                                  utilization: .known(88),
                                  resetsAt: resets,
                                  isActive: true)],
            fetchedAt: fetchedAt
        )
        let projected = UsageEngine.project(
            original, now: fetchedAt.addingTimeInterval(CacheHorizon.sessionHorizon + 1)
        )
        guard let window = projected.windows.first else {
            TestHarness.check("the suppressed window is still present", false)
            return
        }
        TestHarness.expect("the figure is suppressed", window.utilization, .unknown)
        TestHarness.expect("the reset time survives", window.resetsAt, resets)
        TestHarness.expect("so does the label", window.label, "Session · M")
        TestHarness.check("so does the identity", window.id.scope == .model(id: "m"))
        TestHarness.check("and so does the binding flag", window.isActive)
        TestHarness.expect("the snapshot keeps its own timestamp", projected.fetchedAt, fetchedAt)
    }

    // The tooltip names the window the figure came from, which means it has to prefer the
    // window the PROVIDER marked binding — not merely the first window that happens to
    // carry the same number. Cosmetic, but it is the only thing telling the user which
    // limit is the constraint.
    static func theTooltipNamesTheBindingWindow() {
        let clock = Clock()
        let engine = UsageEngine(providerOrder: [.anthropic])
        let account = ref(.anthropic, "tooltip")
        engine.ingest([observation(account, location: "svc")], covering: [.anthropic], now: clock.now)
        clock.advance(PollSchedule.staggerSpan + 1)
        let claimed = engine.claimDueFetches(now: clock.now)
        // Same figure on both windows, the non-binding one listed FIRST.
        complete(engine, claimed, account,
                 fetched(account,
                         [window(.weekly, percent: 40, label: "Weekly 7d"),
                          window(.session, percent: 40, active: true, label: "Session 5h")],
                         at: clock.now),
                 now: clock.now)
        let figure = engine.menuBarFigures(now: clock.now).first
        TestHarness.expect("the figure is the binding window's", figure?.utilization, .known(40))
        TestHarness.expect("and the tooltip names the binding window, not the first match",
                           figure?.windowLabel, "Session 5h")
    }

    // §7.1 orders the menu bar by provider, and the popover's sections with it. Entirely
    // unpinned until now — and it is the kind of thing that "looks right" on a machine
    // where the alphabetical order happens to agree.
    static func providerOrderIsHonoured() {
        let clock = Clock()
        let anthropic = ref(.anthropic, "zeta", label: "zeta")
        let codex = ref(.codex, "alpha", label: "alpha")
        let observations = [observation(anthropic, location: "a", digest: "a"),
                            observation(codex, location: "c", digest: "c")]

        func figures(order: [ProviderKind]) -> ([ProviderKind], [ProviderKind]) {
            let engine = UsageEngine(providerOrder: order)
            engine.ingest(observations, covering: [.anthropic, .codex], now: clock.now)
            let at = clock.now.addingTimeInterval(PollSchedule.staggerSpan + 1)
            for task in engine.claimDueFetches(now: at) {
                _ = engine.finish(task,
                                  fetched(task.ref, [window(.session, percent: 20, active: true)],
                                          at: at),
                                  now: at)
            }
            return (engine.presentations(now: at).map { $0.ref.provider },
                    engine.menuBarFigures(now: at).map { $0.provider })
        }

        let (rows, bar) = figures(order: [.anthropic, .codex])
        TestHarness.expect("rows follow the provider order", rows, [.anthropic, .codex])
        TestHarness.expect("and so does the menu bar", bar, [.anthropic, .codex])
        // Reversed, so the assertion cannot be passing on the labels' alphabetical order:
        // `alpha` (codex) sorts before `zeta` (anthropic), so a name-ordered
        // implementation gives the same answer both times.
        let (reversedRows, reversedBar) = figures(order: [.codex, .anthropic])
        TestHarness.expect("reversing the provider order reverses the rows",
                           reversedRows, [.codex, .anthropic])
        TestHarness.expect("and reverses the menu bar", reversedBar, [.codex, .anthropic])
    }

    // The persisted mirrors are TAGGED, not positional. A bare integer for a span would
    // make `.other(seconds: 18000)` restore as `.session`, and a bare string for a scope
    // would make `.model(id: "x")` and `.feature(id: "x")` the same key — either one
    // silently merges two windows' histories the next time the app starts.
    static func persistenceRoundTrip() {
        let account = ref(.anthropic, "codec")
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let original = Snapshot(
            account: account,
            planLabel: "Max 20x",
            windows: [
                UsageWindow(id: WindowID(span: .session, scope: .account),
                            label: "Session 5h",
                            utilization: .known(62),
                            resetsAt: fetchedAt.addingTimeInterval(900),
                            isActive: true),
                UsageWindow(id: WindowID(span: .weekly, scope: .model(id: "claude-x")),
                            label: "Weekly · X",
                            utilization: .unknown,
                            resetsAt: nil,
                            isActive: false),
                UsageWindow(id: WindowID(span: .other(seconds: 18_000), scope: .feature(id: "claude-x")),
                            label: "Odd",
                            utilization: .known(3),
                            resetsAt: nil,
                            isActive: false),
            ],
            spend: Spend(used: .qualified(minor: 1500, currency: "USD", exponent: 2),
                         limit: nil,
                         balance: .unqualified(raw: "0")),
            fetchedAt: fetchedAt,
            warnings: ["a warning"]
        )
        var state = PersistedAccountState()
        state.snapshot = PersistedSnapshot(original)
        state.lastFetchAttempt = fetchedAt
        state.rung = 2
        state.credentialDigest = "abc"

        guard let payload = PersistedCodec.encode(state),
              let decoded = PersistedCodec.decode(PersistedAccountState.self, from: payload) else {
            TestHarness.check("persisted state round-trips", false)
            return
        }
        let restored = decoded.snapshot?.model(account: account)
        TestHarness.expect("every window survives", restored?.windows.count, 3)
        TestHarness.expect("a spelled-out span is not canonicalised on the way back",
                           restored?.windows.last?.id.span, .other(seconds: 18_000))
        TestHarness.check("a model scope does not become a feature scope",
                          restored?.windows[1].id.scope == .model(id: "claude-x"))
        TestHarness.check("and a feature scope does not become a model scope",
                          restored?.windows[2].id.scope == .feature(id: "claude-x"))
        TestHarness.expect("unknown utilization stays unknown rather than becoming zero",
                           restored?.windows[1].utilization, .unknown)
        TestHarness.expect("qualified money keeps its currency and exponent",
                           restored?.spend?.used, .qualified(minor: 1500, currency: "USD", exponent: 2))
        TestHarness.expect("an unqualified balance stays unqualified",
                           restored?.spend?.balance, .unqualified(raw: "0"))
        TestHarness.expect("the rate-limit rung survives", decoded.rung, 2)
        TestHarness.expect("so does the cooldown timestamp", decoded.lastFetchAttempt, fetchedAt)
        // §6 forbids retaining the credential blob — only a digest may cross the disk.
        TestHarness.check("no credential material is persisted beyond a digest",
                          !String(decoding: payload, as: UTF8.self).contains("accessToken"))

        // A payload from a version this build cannot read is treated as ABSENT rather
        // than crashing the app over a byte on disk.
        TestHarness.check("an unreadable payload is ignored",
                          PersistedCodec.decode(PersistedAccountState.self,
                                                from: Data("not json".utf8)) == nil)

        // The ledger round-trips through the same codec — one codec, so a check added to
        // one payload type cannot go missing from the other.
        var ledger = PersistedCredentialLedger()
        ledger.spends = [RequestSpend(account: "anthropic:codec", at: fetchedAt),
                         RequestSpend(account: "anthropic:codec", at: fetchedAt.addingTimeInterval(30))]
        let ledgerPayload = PersistedCodec.encode(ledger)!
        TestHarness.expect("the ledger round-trips",
                           PersistedCodec.decode(PersistedCredentialLedger.self,
                                                 from: ledgerPayload)?.spends.count, 2)
    }
}
