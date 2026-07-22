import Foundation

// Where presentation must differ per provider (section grouping, menu-bar glyph,
// ordering), that identity is supplied BY the provider as data rather than discovered
// by the UI through a type switch — so adding a third provider touches no view code
// (§3). These are plain values, never UI types: colour is derived by the view from
// utilization, not carried here.
struct ProviderPresentation: Equatable, Sendable {
    let glyph: String        // menu-bar prefix, e.g. "⚡"
    let sectionTitle: String // popover section header, e.g. "CLAUDE"
    let sortOrder: Int       // stable ordering across menu bar and popover
}

// A successful fetch yields the projected model AND the response it was projected
// from. §5 requires retaining the most recent raw body per account, because both
// vendors add and retire fields without notice and the resulting drift fails SILENTLY
// — a client written against the retired shape still returns 200 OK and still parses.
// The raw body is the only way to answer "was this field ever present, and when did it
// change shape?" without shipping a new build to find out.
//
// It is RETURNED rather than written by the provider because §6 makes providers pure
// with respect to persisted state: they return a snapshot and never mutate the
// registry. Retention is the single writer's job, and it is bounded (latest per
// account, not a history) and diagnostic-only — no display path may read it, so it can
// never become a shadow parser. §5 also makes the body sensitive: it carries account
// identifiers and plan details, so it is stored with the same care as a credential,
// never logged wholesale, and discarded when an account is removed.
struct FetchedSnapshot: Sendable {
    let snapshot: Snapshot
    let rawBody: Data
}

// Read-only operation means every failure is cosmetic (§3). `signedOut` and `expired`
// are display states carried by `AccountState`, NOT errors — they are resolved from
// the credential itself, so they never appear here.
//
// Neither does §5.2's identity disagreement: it is the OBSERVED NORMAL STATE on the
// target machine and belongs in `Snapshot.warnings`. Adding a case for it here would
// render the only real Codex account as a hard fetch failure.
enum FetchError: Error, Equatable, Sendable {
    // Upstream rejected the credential. Deliberately does not itself claim the account
    // is expired: §6 requires one credential re-read and retry first, because the token
    // rotates roughly 8-hourly and may simply have changed between read and request.
    // Only the caller, holding the re-read credential's stored expiry, can tell an
    // expiry from a revoked or scope-reduced credential.
    case authenticationRejected

    // Throttled upstream. `retryAfter` is already normalised to seconds by the provider
    // (the header carries seconds OR an HTTP-date); the 60s floor and the adaptive
    // interval are the caller's business (§6).
    case rateLimited(retryAfter: TimeInterval?)

    case transport(message: String)  // no response reached us

    // The account this fetch was asked for is no longer present in local discovery — its
    // configuration directory was removed or signed out between the poll being scheduled
    // and it running. TERMINAL, and deliberately not `transport`: §6 backs off and retries
    // a transport failure, so an account that has genuinely left would be retried forever
    // on a timer nothing ever stops. The caller drops it instead; §6's periodic
    // re-discovery is what brings it back if it returns.
    case accountUnknown

    // A response arrived but could not be projected. It carries the body for the same
    // reason the success path does — this is precisely the schema drift §5's retention
    // exists to diagnose, so discarding the payload here would throw the evidence away
    // in the one case that most needs it.
    case malformedResponse(message: String, rawBody: Data)

    case unexpectedStatus(code: Int)
}

protocol UsageProvider {
    var kind: ProviderKind { get }
    var presentation: ProviderPresentation { get }

    // Cheap and local: re-run on a schedule, not only at launch (§6). Returns every
    // account that passes the identity gate, each paired with the state its credential
    // resolves to — an unusable credential yields a present, signed-out account rather
    // than an omission.
    func discoverAccounts() -> [DiscoveredAccount]

    // Credential freshness is an invariant of `fetch`, not of `discoverAccounts` (§3):
    // an implementation re-reads the credential from its store on every call and never
    // caches an access token across polls.
    func fetch(_ account: AccountRef) async -> Result<FetchedSnapshot, FetchError>
}
