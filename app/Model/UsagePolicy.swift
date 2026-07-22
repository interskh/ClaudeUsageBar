import Foundation

// The rate-limit policy of §6, isolated from everything that owns state so it can be
// exercised without a clock, a timer, or a network. PURE: this file compiles into the
// test target, so no dependency here may reach the machine — every function is a
// deterministic transform of its arguments plus an injected `now`.
//
// MEASURED, 2026-07-23, against the real Anthropic OAuth usage endpoint with the
// default profile's live access token (§6 requires the cadence stay traceable to
// evidence):
//
//     #1 t+ 0.0s  200      #4 t+ 8.0s  200
//     #2 t+ 2.7s  200      #5 t+10.7s  200
//     #3 t+ 5.3s  200      #6 t+13.3s  429  Retry-After: 300
//
// Two numbers came out of that and both are used below: the endpoint tolerated FIVE
// requests before refusing, and its own stated penalty span is 300 seconds. So the
// budget is 5 requests per 300s rolling (`RequestBudget`), and the base interval of
// 300s spends exactly one of those five — leaving four for manual refreshes, the
// authentication re-read retry, and a second account sharing the same credential.
// The measurement did NOT establish a sustained rate, only the burst ceiling; the
// probe stopped at the first 429 rather than continuing to characterise recovery,
// because every further request was spent from a real account's real allowance.

// Why a fetch is being attempted. The trigger changes ONE thing — whether the
// scheduled interval applies — and nothing else. Every other gate in §6 (the 60s
// floor, a server-stated Retry-After, the credential budget) binds identically
// whatever asked, which is the point of "the budget is the binding constraint; the
// interval is merely how it is normally spent".
enum PollTrigger: String, Equatable, Sendable {
    case scheduled   // the account's own timer came due
    case manual      // §6's Refresh: bypasses the interval, keeps the 60s floor
    case discovery   // an account just appeared; fetch it rather than wait an interval
    case retry       // §6's one re-read-and-retry after an authentication rejection
}

// Why a fetch was refused. Every case carries the moment it stops applying where one
// exists, so a caller never has to guess a retry time and the UI can say what is going
// on rather than showing a row that silently never updates.
enum PollBlock: Equatable, Sendable {
    case unknownAccount
    case disabled              // §7.3: disabled accounts are never polled
    case credentialUnusable    // signed out / locally expired / unreadable — nothing to send
    case stopped               // §6 stopped this account's timer; revived by a credential change
    case inFlight
    case notDue(until: Date)
    case cooldown(until: Date)        // the 60s floor
    case serverBackoff(until: Date)   // an upstream Retry-After we were told to honour
    case budgetExhausted(until: Date) // the credential's own budget, not this account's
}

// §6's adaptive interval, and the hysteresis rule that keeps it from oscillating.
//
// A single success MUST NOT restore the most aggressive cadence. The condition that
// produced the throttle is a sustained request rate, so resuming that rate immediately
// reproduces it — throttle, recover, throttle — which is strictly worse for the user
// than a steady slower cadence, because every cycle spends a real 5-minute lockout.
// Stepping back one rung per `successesPerStepDown` successes means the walk down from
// the cap costs nine consecutive good polls, and the walk up costs three bad ones.
struct IntervalLadder: Equatable, Sendable {
    // 5 → 10 → 20 → 30 minutes (§6), cap included.
    static let rungs: [TimeInterval] = [300, 600, 1200, 1800]
    static let successesPerStepDown = 3

    private(set) var rung: Int
    private(set) var successStreak: Int

    init(rung: Int = 0, successStreak: Int = 0) {
        self.rung = min(max(rung, 0), IntervalLadder.rungs.count - 1)
        self.successStreak = max(successStreak, 0)
    }

    var interval: TimeInterval { IntervalLadder.rungs[rung] }
    var isDegraded: Bool { rung > 0 }

    // Only a throttle lengthens the interval. A transport failure is not evidence that
    // the endpoint wants fewer requests, and treating it as such would push a user on a
    // flaky connection to a 30-minute cadence they never earned.
    mutating func throttled() {
        rung = min(rung + 1, IntervalLadder.rungs.count - 1)
        successStreak = 0
    }

    mutating func succeeded() {
        guard rung > 0 else {
            successStreak = 0
            return
        }
        successStreak += 1
        guard successStreak >= IntervalLadder.successesPerStepDown else { return }
        rung -= 1
        successStreak = 0
    }

    // A non-throttle failure breaks the run of sustained success without lengthening the
    // interval: "only after sustained success" has to mean uninterrupted, or a ladder at
    // the cap steps down on three successes spread across a dozen failures.
    mutating func interrupted() {
        successStreak = 0
    }
}

// The budget, keyed OUTSIDE this type by the credential rather than the account (§6):
// throttling is enforced upstream per access token, so two accounts resolving to one
// credential must share one of these or they jointly exceed the single limit that binds.
//
// A rolling window of spend timestamps rather than a counter with a reset instant: a
// fixed window lets 2N requests straddle its boundary in an instant, which is precisely
// the burst the measurement above shows the endpoint refusing.
// ONE request, identified by who made it and when. The identity is what makes merging two
// ledgers IDEMPOTENT, and idempotence is not a nicety here:
//
//   - A credential's key changes whenever its token rotates, and §4.1's health-ranked
//     duplicate resolution can flip the winning directory back and forth between surveys.
//     Every flip migrates the ledger, so `P → Q → P` merges a ledger into a copy of
//     itself. Merging bare timestamps grows the array Fibonacci-style — measured, a
//     5-second flip cadence produced a 695 MB persisted payload in 40 flips.
//   - Deduplicating bare timestamps instead would be WRONG: two accounts sharing one
//     credential are claimed in the same `claimDueFetches` pass and therefore spend at
//     the identical instant, so collapsing equal timestamps silently discards a real
//     request and lets the budget admit more than the endpoint tolerates.
//
// So a spend carries the account that made it. Two accounts at one instant are two
// spends; the same spend seen twice is one.
struct RequestSpend: Hashable, Codable, Sendable {
    let account: String   // the spending account's storage key
    let at: Date
}

struct RequestBudget: Equatable, Sendable {
    static let span: TimeInterval = 300
    static let capacity = 5

    private(set) var spends: [RequestSpend]

    init(spends: [RequestSpend] = []) {
        self.spends = spends
    }

    // `nil` means a request may go now. Otherwise: the moment the oldest spend leaves
    // the rolling window, which is the earliest a slot exists.
    func availableAt(now: Date) -> Date? {
        let live = spends.filter { now.timeIntervalSince($0.at) < RequestBudget.span }
        guard live.count >= RequestBudget.capacity else { return nil }
        // `live` is not necessarily sorted — spends restored from disk arrive in
        // whatever order the accounts sharing this credential were restored in.
        guard let oldest = live.map({ $0.at }).min() else { return nil }
        return oldest.addingTimeInterval(RequestBudget.span)
    }

    mutating func spend(by account: String, at moment: Date) {
        spends.append(RequestSpend(account: account, at: moment))
        prune(now: moment)
    }

    mutating func prune(now: Date) {
        spends = spends.filter { now.timeIntervalSince($0.at) < RequestBudget.span }
    }

    // A MULTISET union — for each identity, keep the larger of the two counts. A plain
    // set union is not enough and the difference is a real request:
    //
    //   - Idempotence needs multiplicity to be capped, so merging a ledger into a copy of
    //     itself keeps count 2 at 2 rather than doubling it. That is what bounds the
    //     `P → Q → P` flip.
    //   - But one account genuinely CAN spend twice at the same instant: §6's
    //     authentication re-read is exempt from the 60s floor, so a claim, its rejection
    //     and the immediate retry can all land on one timestamp. A set union collapses
    //     those two requests into one and hands the budget a slot it never had.
    //
    // Taking the maximum count per identity satisfies both: two ledgers each holding the
    // same spend once contribute one (it is the same request), while a ledger holding it
    // twice keeps both.
    mutating func merge(_ incoming: [RequestSpend], now: Date) {
        var held: [RequestSpend: Int] = [:]
        for spend in spends { held[spend, default: 0] += 1 }
        var arriving: [RequestSpend: Int] = [:]
        for spend in incoming { arriving[spend, default: 0] += 1 }
        for (spend, count) in arriving {
            let deficit = count - (held[spend] ?? 0)
            guard deficit > 0 else { continue }
            spends.append(contentsOf: repeatElement(spend, count: deficit))
        }
        prune(now: now)
    }
}

// §6's validity horizon, per WINDOW CLASS. Beyond it a cached figure is SUPPRESSED, not
// displayed: a quota reading hours old is not merely imprecise, it is misleading in the
// one direction that matters, implying headroom the account may not have.
//
// Per class because a session window ages far faster than a weekly one — a 5-hour window
// can go from 40% to 100% inside the horizon a weekly window comfortably tolerates. The
// unstandardised spans get the same rule expressed as a fraction of their own length
// rather than a table, so a span nobody anticipated is still governed.
enum CacheHorizon {
    static let sessionHorizon: TimeInterval = 1800        // 30 min
    static let weeklyHorizon: TimeInterval = 6 * 3600
    static let minimumHorizon: TimeInterval = 900
    static let horizonFractionOfSpan = 10.0

    static func horizon(for span: WindowSpan) -> TimeInterval {
        switch span {
        case .session: return sessionHorizon
        case .weekly: return weeklyHorizon
        case .other(let seconds):
            let proportional = TimeInterval(seconds) / horizonFractionOfSpan
            return min(max(proportional, minimumHorizon), weeklyHorizon)
        }
    }

    // How far into the future a reading may be stamped before it is treated as
    // unusable rather than merely skewed. Small clock disagreement between this machine
    // and the vendor is normal and must not blank the UI; a reading stamped an hour
    // ahead is not skew, it is a clock that was corrected backwards afterwards.
    static let futureTolerance: TimeInterval = 300

    // Bounded in BOTH directions. Only bounding the past looks complete and leaves a
    // hole with no upper limit at all: a clock corrected backwards after a fetch — an
    // NTP step, a timezone-confused restore, a laptop waking with a bad RTC — leaves a
    // quota figure whose age is permanently negative, so it is never suppressed and
    // never leaves the menu bar, however old it really is.
    static func isSuppressed(span: WindowSpan, fetchedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        if age < -futureTolerance { return true }
        return age > horizon(for: span)
    }
}

// Stagger and jitter (§6): N accounts must never fire together. Deterministic rather
// than random so a test can assert the spread, and so two runs of the same registry
// schedule identically — a random offset makes "did this account poll twice in one
// window?" unanswerable.
enum PollSchedule {
    static let jitterFraction = 0.1
    static let staggerSpan: TimeInterval = 30
    static let manualFloor: TimeInterval = 60

    // FNV-1a. Swift's own `hashValue` is seeded per process, so it would produce a
    // different stagger on every launch and could not be reasoned about at all.
    static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private static func fraction(_ value: String) -> Double {
        Double(stableHash(value) % 10_000) / 10_000.0
    }

    // The first fetch of a newly discovered account. Spread across `staggerSpan` so a
    // launch with four accounts does not open four connections in the same millisecond.
    static func initialDelay(storageKey: String) -> TimeInterval {
        fraction("initial:" + storageKey) * staggerSpan
    }

    // ±`jitterFraction` around the interval, varying per attempt so two accounts that
    // happen to collide once do not stay collided.
    static func nextDue(after now: Date,
                        interval: TimeInterval,
                        storageKey: String,
                        attempt: Int) -> Date {
        let offset = (fraction("\(attempt):" + storageKey) * 2 - 1) * jitterFraction * interval
        return now.addingTimeInterval(max(interval + offset, 0))
    }

    // Exponential backoff for failures that are NOT throttles. Floored at the same 60s
    // as everything else and capped at the ladder's own cap, so no failure path can
    // schedule a retry the budget would only refuse anyway.
    static func failureBackoff(consecutiveFailures: Int) -> TimeInterval {
        let clamped = min(max(consecutiveFailures, 1), 10)
        let delay = manualFloor * pow(2.0, Double(clamped - 1))
        return min(delay, IntervalLadder.rungs[IntervalLadder.rungs.count - 1])
    }
}
