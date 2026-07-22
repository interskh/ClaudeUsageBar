import Foundation

// The shared shape both providers normalise to (§3). The UI renders usage without
// branching on provider, so nothing in this file may import a UI framework: it is
// compiled into the pure-logic test target as well as the app.
//
// Everything here is a value type and Sendable: §6 polls accounts concurrently and
// `UsageProvider.fetch` is async, so snapshots cross isolation boundaries on their way
// back to the single writer that owns the registry.

enum ProviderKind: String, Hashable, Sendable {
    case anthropic
    case codex
}

// Identity is resolved BEFORE any request, from credential-side material only, so
// persisted state can be keyed without a network round-trip (§3). It is never derived
// from a response body, never from a user-visible label, and never from the location
// the credential happens to live in — locations and labels both change while the
// account stays the same.
//
// Providers that have no single trustworthy identifier key on a composite of the
// fields they do have (§4.2). The components are held as a list rather than a
// pre-joined string precisely so that a composite cannot collide with a differently
// split one: ("a:b", "c") and ("a", "b:c") are distinct identities, and stay distinct
// once rendered into `storageKey`.
struct AccountIdentity: Hashable, Sendable {
    let provider: ProviderKind
    private let components: [String]

    init(provider: ProviderKind, components: [String]) {
        precondition(!components.isEmpty, "an account identity needs at least one component")
        self.provider = provider
        self.components = components
    }

    init(provider: ProviderKind, _ component: String) {
        self.init(provider: provider, components: [component])
    }

    // Namespace for this account's persisted state (§6: state is dropped as a unit
    // when an account leaves discovery). Consumers only ever compare or key on this —
    // they never parse it back apart, which is why the escaping only has to be
    // injective, not reversible in practice.
    //
    // Both substitutions are load-bearing and so is their ORDER. Escaping the colon
    // alone collides [":"] with ["\\", ""]; escaping the colon before the backslash
    // re-introduces that same collision by doubling the escape character just
    // inserted. Two accounts sharing one persisted-state namespace is the §6
    // misattribution failure, and it is silent.
    var storageKey: String {
        ([provider.rawValue] + components)
            .map { $0.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: ":", with: "\\:") }
            .joined(separator: ":")
    }
}

struct AccountRef: Hashable, Sendable {
    let id: AccountIdentity
    let label: String     // presentation only — renaming it must not orphan history
    let subtitle: String? // email address, when known

    // Derived, never stored: a stored copy could name one provider while `id` named
    // another, filing the account under one provider's menu-bar glyph (§7.1) while its
    // persisted state landed in the other's namespace (§6).
    var provider: ProviderKind { id.provider }

    init(id: AccountIdentity, label: String, subtitle: String? = nil) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
    }

    // Equality and hashing are over `id` ALONE, deliberately. Two refs sharing an
    // identity are the same account REGARDLESS of label and subtitle, because those
    // are presentation and both change while the account does not: a profile directory
    // is renamed, or an email address is discovered on a later poll and a nil subtitle
    // becomes populated. Synthesized conformance would fold those fields in, so
    // `[AccountRef: …]` — the obvious key for threshold state (§8) and cached snapshots
    // (§6) — would silently orphan an account's history the moment it was relabelled.
    static func == (lhs: AccountRef, rhs: AccountRef) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// Temporal class and scope are INDEPENDENT dimensions. Collapsing them into one axis
// cannot represent a model-scoped limit that has both a short and a long window, and
// it collides the keys such a pair would need (§3, §8).
enum WindowSpan: Hashable, Sendable {
    case session              // short rolling window
    case weekly               // long rolling window
    case other(seconds: Int)  // spans the providers have not standardised

    // Providers that classify by duration (§5.2 reads Codex's `limit_window_seconds`)
    // MUST come through here rather than constructing `.other` directly. The canonical
    // durations fold onto the canonical cases, so one provider cannot emit
    // `.other(seconds: 18000)` for the window another emits as `.session`. Because §8
    // keys threshold state on the whole WindowID, two spellings of one span would mean
    // that later unifying them resets every stored threshold and re-fires the entire
    // [25, 50, 75, 90] ladder.
    init(seconds: Int) {
        switch seconds {
        case 18_000: self = .session
        case 604_800: self = .weekly
        default: self = .other(seconds: seconds)
        }
    }
}

// Scope identity uses the provider's STABLE discriminator, never its display text.
// Labels are renamed and reused by providers; keying on them would split one history
// in two on a rename, or merge two histories on a collision.
enum WindowScope: Hashable, Sendable {
    case account              // applies to the account as a whole
    case model(id: String)    // stable model discriminator
    case feature(id: String)  // stable metered-feature discriminator
}

struct WindowID: Hashable, Sendable {
    let span: WindowSpan
    let scope: WindowScope
}

// Absent, unknown, and zero are three different facts and must stay distinguishable.
// Coercing an unknown utilization to zero manufactures headroom that may not exist.
// There is deliberately no `Int?` accessor here: one would put `?? 0` a single
// keystroke away, and §3 requires every consumer to handle unknown explicitly.
//
// CONTRACT: `known` carries a whole percentage in 0...100. Values outside that range
// are meaningless and actively dangerous — a negative one wins a `min` and one above
// 100 wins a `max`, quietly displacing the real binding figure. Providers therefore
// construct through `Utilization.percent(_:)`, which is also the single place the
// rounding rule lives: §5.1 says the figure arrives as Int OR Double, and
// round-vs-truncate straddles the 90% red / notification band, so the two providers
// must not each pick their own.
enum Utilization: Equatable, Sendable {
    case known(Int)
    case unknown  // provider returned null, or omitted the figure

    static func percent(_ value: Int) -> Utilization {
        .known(min(100, max(0, value)))
    }

    // Half away from zero, matching how a percentage is read aloud: 89.5 is 90, and
    // therefore red. A non-finite figure is no figure at all, not 0%.
    static func percent(_ value: Double) -> Utilization {
        guard value.isFinite else { return .unknown }
        return percent(Int(value.rounded()))
    }
}

struct UsageWindow: Equatable, Sendable {
    let id: WindowID          // stable; drives persistence and keying
    let label: String         // presentation only; may change without changing identity
    let utilization: Utilization
    let resetsAt: Date?       // nil => window has never started
    let isActive: Bool        // provider marks this the currently binding limit
}

// Monetary metadata is NOT uniformly available (§3). One provider supplies fully
// qualified minor units with currency and exponent; the other exposes a bare balance
// with no currency and no scale. An amount therefore carries its own qualification,
// and an unqualified amount must be displayed as the provider stated it — without a
// currency symbol implying precision that is absent. Never a Double.
enum MonetaryAmount: Equatable, Sendable {
    case qualified(minor: Int, currency: String, exponent: Int)
    case unqualified(raw: String)  // provider gave a bare figure; never inferred
}

struct Spend: Equatable, Sendable {
    let used: MonetaryAmount?
    let limit: MonetaryAmount?
    let balance: MonetaryAmount?  // remaining prepaid / free credits

    init(used: MonetaryAmount? = nil, limit: MonetaryAmount? = nil, balance: MonetaryAmount? = nil) {
        self.used = used
        self.limit = limit
        self.balance = balance
    }
}

struct Snapshot: Equatable, Sendable {
    // The account AS IT LOOKED WHEN THIS SNAPSHOT WAS FETCHED. A persisted snapshot
    // resurfaced as `.stale` therefore carries a label and subtitle from that moment,
    // which may since have changed. A row renders `ref.label` from current discovery,
    // never `snapshot.account.label`; only `.id` is safe to read from here.
    let account: AccountRef
    let planLabel: String?  // "Max 20x", "pro"
    let windows: [UsageWindow]
    let spend: Spend?
    let fetchedAt: Date

    // Conditions the provider must SURFACE without failing the fetch. §5.2's identity
    // disagreement is the motivating case, and it is the OBSERVED NORMAL STATE on the
    // target machine — the response's `account_id` equals its `user_id` while the
    // request sent a different UUID. It must therefore NEVER become a `FetchError`;
    // doing so would render the only real Codex account as a hard failure. §6's
    // degraded polling interval and §5.2's `limit_reached` belong on this same shelf.
    let warnings: [String]

    init(account: AccountRef,
         planLabel: String? = nil,
         windows: [UsageWindow],
         spend: Spend? = nil,
         fetchedAt: Date,
         warnings: [String] = []) {
        self.account = account
        self.planLabel = planLabel
        self.windows = windows
        self.spend = spend
        self.fetchedAt = fetchedAt
        self.warnings = warnings
    }
}

extension Snapshot {
    // The single figure for THIS ACCOUNT's row (§7.2). `nil` means the account has no
    // windows at all and must be omitted rather than shown as 0% — absent, unknown and
    // zero stay three distinct facts.
    //
    // This is not the menu bar. §7.1's per-provider fold ACROSS accounts is task 9's,
    // and that still owns per-account enablement (§7.3), the §6 validity horizon that
    // suppresses an over-aged reading, and the rule that a provider with no usable
    // account is omitted entirely rather than shown at 0%.
    var bindingUtilization: Utilization? {
        Snapshot.bindingUtilization(of: windows)
    }

    static func bindingUtilization(of windows: [UsageWindow]) -> Utilization? {
        guard !windows.isEmpty else { return nil }

        // Prefer the window the provider marked as binding; providers flag it precisely
        // so a single-number UI needs no heuristics.
        let binding = windows.filter { $0.isActive }
        if !binding.isEmpty {
            // An unknown binding window makes the aggregate unknown — it does NOT fall
            // through to the next-highest known window, which would present a
            // non-binding figure as though it were the constraint (§7.1).
            //
            // This deliberately lets `unknown` beat a known 95: a red figure
            // disappearing is the accepted cost of never under-reporting, because the
            // opposite error invents headroom the account may not have. Do not "fix"
            // it by falling through. Notifications are unaffected — §8 arms per
            // (account, window), so that known 95 still fires its own threshold; only
            // this one-number summary goes unknown.
            if binding.contains(where: { $0.utilization == .unknown }) { return .unknown }
            return worstKnown(of: binding)
        }

        // Nothing flagged: fall back to the highest known utilization. Unknown windows
        // contribute nothing to the aggregate rather than counting as zero, so windows
        // with no known figure among them yield unknown, never 0%.
        return worstKnown(of: windows) ?? .unknown
    }

    private static func worstKnown(of windows: [UsageWindow]) -> Utilization? {
        let known = windows.compactMap { window -> Int? in
            if case .known(let percent) = window.utilization { return percent }
            return nil
        }
        guard let worst = known.max() else { return nil }
        return .known(worst)
    }
}

enum AccountState: Sendable {
    // Credential is usable but no telemetry has been retrieved yet. Discovery resolves
    // to this, NOT to `active` — an account is authenticated well before it has a
    // reading, and collapsing the two would force discovery to either fabricate a
    // snapshot or misreport a healthy account as unauthenticated. A `pending` row is
    // never rendered as a zeroed bar (§7.2).
    case pending
    case active(Snapshot)
    case stale(Snapshot, since: Date)  // last good data; fetches currently failing
    case signedOut                     // no credential, or credential unusable
    case expired(Date)                 // access token past its own expiry; use the CLI
    case failed(String)
}

// Discovery yields an account TOGETHER with its resolved state. Returning bare
// references could not express a signed-out or expired account, which the inclusion/
// state gate split (§4.1) explicitly requires be present rather than filtered away.
struct DiscoveredAccount: Sendable {
    let ref: AccountRef
    let state: AccountState  // `.pending` when the credential is usable but unfetched
}
