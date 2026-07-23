import Foundation

// §11: on the first run of 2.0.0, purge the cookie-era UserDefaults keys the deleted
// `LegacyUsageManager` / `Settings` wrote, which nothing reads any more. The keyspace
// interleaves dead and live keys by name, so the danger is purging a LIVE key — a
// wildcard that catches `notifications_enabled`, a `usage.v2.account.*` snapshot, a
// `credential:*` ledger or `notify.v1.state` is silent data loss on every upgrade.
//
// The decision is a PURE function over the currently-present keys plus the once-only
// gate, so it is tested exhaustively (every dead key purged, every live key survives,
// idempotent on a second run, no-op on a fresh install). The impure application — read
// present keys, remove, set the marker — lives in the app-only shell (`AppSettings`).
enum DefaultsMigration {
    // The marker gating the one-time purge. A new LIVE key: written once, read every
    // launch, never itself purged.
    static let markerKey = "migrated_2_0_0"

    // Dead keys, enumerated EXPLICITLY from what the deleted legacy files actually wrote
    // (verified against `git show` of `LegacyUsageManager.swift` and `Settings.swift`) —
    // deliberately NOT a `cached_*` prefix wildcard. No live key shares the `cached_`
    // prefix today, but an explicit allowlist cannot catch a future one that does.
    static let deadKeys: [String] = [
        // Cookie auth — LegacyUsageManager.
        "claude_session_cookie",
        // Single-account cached usage — LegacyUsageManager.
        "has_cached_usage",
        "cached_session_usage",
        "cached_weekly_usage",
        "cached_weekly_sonnet_usage",
        "cached_has_weekly_sonnet",
        "cached_last_updated",
        "cached_last_fetch_attempt",
        // Global single-slot notification state — Settings / LegacyUsageManager.
        // No value is migrated: §8's per-(account, window) hysteresis re-arms, so the
        // old global slot is dropped, not carried into `notify.v1.state`.
        "last_notified_threshold",
        "has_set_notifications",
    ]

    // Pure: given the keys currently present in defaults and whether the migration has
    // already run, return exactly which keys to remove. Removes only keys that are BOTH
    // dead AND present, and never on a second run — so re-running is idempotent and a
    // fresh install (no dead keys present) is a no-op.
    static func keysToPurge(present: Set<String>, alreadyMigrated: Bool) -> [String] {
        guard !alreadyMigrated else { return [] }
        return deadKeys.filter { present.contains($0) }
    }
}
