import Foundation

// §11: the migration decision is a pure function, so its correctness is proven here
// rather than resting on a manual upgrade run. The load-bearing invariant is that every
// DEAD key is purged and every LIVE key survives — a wildcard that caught a live key
// would be silent data loss on every 2.0.0 upgrade.
enum DefaultsMigrationTests {
    // The keys the new engine relies on and which MUST survive the purge (§11). Includes
    // representative instances of the namespaced key families.
    private static let liveKeys: Set<String> = [
        "notifications_enabled",
        "shortcut_enabled",
        "open_at_login",
        "registered_config_directories",
        "usage.v2.accounts",
        "usage.v2.account.anthropic|acct-1",
        "credential:digest:abc123",
        "notify.v1.state",
        DefaultsMigration.markerKey,
    ]

    // The dead keys as an INDEPENDENT hardcoded literal — NOT `Set(DefaultsMigration.
    // deadKeys)`. Deriving the expectation from the code under test is tautological: a key
    // dropped from the implementation's `deadKeys` would shrink both sides equally and the
    // test would stay green. This literal is the external oracle (verified against
    // `git show ef8867b^` of the deleted LegacyUsageManager / Settings), so removing a key
    // from the implementation genuinely fails "first run purges every dead key".
    private static let expectedDeadKeys: Set<String> = [
        "claude_session_cookie",
        "has_cached_usage",
        "cached_session_usage",
        "cached_weekly_usage",
        "cached_weekly_sonnet_usage",
        "cached_has_weekly_sonnet",
        "cached_last_updated",
        "cached_last_fetch_attempt",
        "last_notified_threshold",
        "has_set_notifications",
    ]

    static func run() {
        let dead = expectedDeadKeys

        // The implementation's dead list matches the external oracle exactly — a key added
        // to or dropped from `DefaultsMigration.deadKeys` fails here.
        TestHarness.check("deadKeys matches the external oracle",
                          Set(DefaultsMigration.deadKeys) == expectedDeadKeys)

        // No live key is accidentally on the dead list — the two sets are disjoint.
        TestHarness.check("dead and live key sets are disjoint",
                          dead.isDisjoint(with: liveKeys))

        // No live key shares the `cached_` prefix — pins the decision to use an explicit
        // allowlist safely (a `cached_*` wildcard would be safe TODAY, but this asserts
        // the premise rather than assuming it).
        TestHarness.check("no live key shares the cached_ prefix",
                          liveKeys.allSatisfy { !$0.hasPrefix("cached_") })

        // First run, both dead and live keys present: every dead key is purged, every
        // live key survives.
        let present = dead.union(liveKeys)
        let purged = Set(DefaultsMigration.keysToPurge(present: present,
                                                       alreadyMigrated: false))
        TestHarness.check("first run purges every dead key", purged == dead)
        TestHarness.check("first run touches no live key",
                          purged.isDisjoint(with: liveKeys))

        // Idempotent: a second run (marker already set) removes nothing, even though the
        // dead keys are (hypothetically) still present.
        TestHarness.expect("second run is a no-op",
                           DefaultsMigration.keysToPurge(present: present,
                                                         alreadyMigrated: true).count,
                           0)

        // Fresh install: no dead keys present, migration not yet run → nothing to purge.
        TestHarness.expect("fresh install is a no-op",
                           DefaultsMigration.keysToPurge(present: liveKeys,
                                                         alreadyMigrated: false).count,
                           0)

        // Only the PRESENT dead keys are returned — an absent dead key is not resurrected
        // into the removal list.
        let partial: Set<String> = ["claude_session_cookie", "notifications_enabled"]
        TestHarness.expect("only present dead keys are purged",
                           DefaultsMigration.keysToPurge(present: partial,
                                                         alreadyMigrated: false),
                           ["claude_session_cookie"])
    }
}
