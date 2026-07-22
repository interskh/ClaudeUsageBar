import Foundation

// §6's persisted per-account state, and the codec that turns it into bytes. PURE: the
// engine that owns this state compiles into the test target, so "does a cooldown
// survive a relaunch?" is answerable without restarting anything — a test round-trips
// the payload and builds a second engine from it.
//
// Everything here is keyed by `AccountIdentity.storageKey` and by nothing else, which
// is what makes §6's lifecycle rule enforceable: a whole account's state is one
// namespace and is dropped as a unit when the account leaves discovery. Storing these
// fields as loose per-field keys — the shape the app shipped with — is what let five
// orphan entries accumulate for directories that no longer exist.

// The model types are deliberately not `Codable` (§3 keeps them free of any concern
// but the shape both providers normalise to), so the mirrors live here. They are
// TAGGED rather than positional: a bare `Int` for a span would make `.other(seconds:
// 18000)` and `.session` the same stored value, and a bare string for a scope would
// make `.model(id: "x")` and `.feature(id: "x")` collide — either one silently merges
// two windows' histories on the next restore.
struct PersistedWindowSpan: Codable, Equatable {
    let kind: String
    let seconds: Int?

    init(_ span: WindowSpan) {
        switch span {
        case .session: (kind, seconds) = ("session", nil)
        case .weekly: (kind, seconds) = ("weekly", nil)
        case .other(let value): (kind, seconds) = ("other", value)
        }
    }

    var model: WindowSpan? {
        switch kind {
        case "session": return .session
        case "weekly": return .weekly
        // NOT `WindowSpan(seconds:)`: that canonicalises, and a stored `.other(18000)`
        // would come back as `.session`, changing a WindowID across a restart and
        // re-firing every threshold keyed on it.
        case "other": return seconds.map { .other(seconds: $0) }
        default: return nil
        }
    }
}

struct PersistedWindowScope: Codable, Equatable {
    let kind: String
    let id: String?

    init(_ scope: WindowScope) {
        switch scope {
        case .account: (kind, id) = ("account", nil)
        case .model(let value): (kind, id) = ("model", value)
        case .feature(let value): (kind, id) = ("feature", value)
        }
    }

    var model: WindowScope? {
        switch kind {
        case "account": return .account
        case "model": return id.map { .model(id: $0) }
        case "feature": return id.map { .feature(id: $0) }
        default: return nil
        }
    }
}

struct PersistedUtilization: Codable, Equatable {
    let known: Int?

    init(_ utilization: Utilization) {
        switch utilization {
        case .known(let percent): known = percent
        case .unknown: known = nil
        }
    }

    // Absent stays unknown rather than becoming zero: §3's invariant survives the disk.
    var model: Utilization {
        guard let known else { return .unknown }
        return .known(known)
    }
}

struct PersistedAmount: Codable, Equatable {
    let kind: String
    let minor: Int?
    let currency: String?
    let exponent: Int?
    let raw: String?

    init(_ amount: MonetaryAmount) {
        switch amount {
        case .qualified(let minor, let currency, let exponent):
            self.kind = "qualified"
            self.minor = minor
            self.currency = currency
            self.exponent = exponent
            self.raw = nil
        case .unqualified(let raw):
            self.kind = "unqualified"
            self.minor = nil
            self.currency = nil
            self.exponent = nil
            self.raw = raw
        }
    }

    var model: MonetaryAmount? {
        switch kind {
        case "qualified":
            guard let minor, let currency, let exponent else { return nil }
            return .qualified(minor: minor, currency: currency, exponent: exponent)
        case "unqualified":
            return raw.map { .unqualified(raw: $0) }
        default:
            return nil
        }
    }
}

struct PersistedSpend: Codable, Equatable {
    let used: PersistedAmount?
    let limit: PersistedAmount?
    let balance: PersistedAmount?

    init(_ spend: Spend) {
        used = spend.used.map(PersistedAmount.init)
        limit = spend.limit.map(PersistedAmount.init)
        balance = spend.balance.map(PersistedAmount.init)
    }

    var model: Spend {
        Spend(used: used?.model, limit: limit?.model, balance: balance?.model)
    }
}

struct PersistedWindow: Codable, Equatable {
    let span: PersistedWindowSpan
    let scope: PersistedWindowScope
    let label: String
    let utilization: PersistedUtilization
    let resetsAt: Date?
    let isActive: Bool

    init(_ window: UsageWindow) {
        span = PersistedWindowSpan(window.id.span)
        scope = PersistedWindowScope(window.id.scope)
        label = window.label
        utilization = PersistedUtilization(window.utilization)
        resetsAt = window.resetsAt
        isActive = window.isActive
    }

    var model: UsageWindow? {
        guard let span = span.model, let scope = scope.model else { return nil }
        return UsageWindow(id: WindowID(span: span, scope: scope),
                           label: label,
                           utilization: utilization.model,
                           resetsAt: resetsAt,
                           isActive: isActive)
    }
}

// The snapshot WITHOUT its `AccountRef`. Deliberate: §3 says a row renders the label
// from CURRENT discovery, never the one frozen into a cached snapshot, and the identity
// is already the key this payload is stored under. Persisting the ref as well would
// create a second copy of the identity that could disagree with the key — and would
// need `AccountIdentity` to expose its components, which it does not.
struct PersistedSnapshot: Codable, Equatable {
    let planLabel: String?
    let windows: [PersistedWindow]
    let spend: PersistedSpend?
    let fetchedAt: Date
    let warnings: [String]

    init(_ snapshot: Snapshot) {
        planLabel = snapshot.planLabel
        windows = snapshot.windows.map(PersistedWindow.init)
        spend = snapshot.spend.map(PersistedSpend.init)
        fetchedAt = snapshot.fetchedAt
        warnings = snapshot.warnings
    }

    // A window that cannot be reconstructed is DROPPED, and its loss is bounded to one
    // window of one cached reading — the next successful fetch replaces the whole
    // snapshot. It cannot happen for anything this version wrote; it exists for a
    // payload written by a future version with a span or scope kind this one has never
    // heard of.
    func model(account: AccountRef) -> Snapshot {
        Snapshot(account: account,
                 planLabel: planLabel,
                 windows: windows.compactMap { $0.model },
                 spend: spend?.model,
                 fetchedAt: fetchedAt,
                 warnings: warnings)
    }
}

// One account's entire persisted footprint (§6: "per-account state is namespaced so a
// whole account's state can be dropped as a unit").
//
// `lastFetchAttempt` is here for the reason §6 gives explicitly: cooldown must survive a
// relaunch. Without it, quitting and relaunching resets that gate, and a user watching a
// throttled account would reach for exactly that.
//
// A payload that this version cannot read is a `VersionedPayload` mismatch, and the
// codec rejects it — which makes it indistinguishable from an absent one to everything
// downstream. That is deliberate: the cost is one account's cached reading, and the
// alternative is an app that will not start because of a byte on disk.
struct PersistedAccountState: Codable, Equatable, VersionedPayload {
    // 2: the budget ledger moved OUT of the account namespace (§6 scopes it to the
    // credential, and a ledger deleted with its account lets a sibling account relaunch
    // with a full allowance inside the same window). A version 1 payload is unreadable
    // to this build and is reclaimed at load rather than left behind.
    static let currentVersion = 2

    var version: Int = PersistedAccountState.currentVersion
    var enabled: Bool = true
    var rung: Int = 0
    var successStreak: Int = 0
    var consecutiveFailures: Int = 0
    var lastFetchAttempt: Date?
    var lastSuccessAt: Date?
    var failingSince: Date?
    var notBefore: Date?
    var stoppedExpiry: Date?
    var lastFailureNote: String?
    // §6 revives a stopped account by observing that its stored credential CHANGED, and
    // the comparison value is a DIGEST — never the blob, which carries live third-party
    // `mcpOAuth` secrets for unrelated servers. Persisting the blob here to diff it
    // across launches is the exact mistake §6 was written to forbid.
    var credentialDigest: String?
    var snapshot: PersistedSnapshot?

    // The raw response body of §5 is deliberately ABSENT. It is retained in memory,
    // latest-only, for the life of the process: retention is what §5 asks for, and
    // writing a payload carrying account identifiers and plan details to disk on every
    // poll buys nothing beyond it — the retention is latest-only, so there is never more
    // than one body to look at, and it is diagnostic-only, so nothing reads it after a
    // relaunch anyway.
}

// The credential's request ledger (§6), persisted in its OWN namespace rather than
// inside any account's. Two accounts can share one credential and either of them can
// leave discovery at any time; a ledger stored inside the departing account's state is
// deleted with it, and the survivor relaunches with a full allowance inside the window
// the spends were made in — the one gate the measured 429 threshold is enforced by,
// laundered by an ordinary account removal.
struct PersistedCredentialLedger: Codable, Equatable, VersionedPayload {
    // 2: a spend carries the account that made it, so that merging a ledger into a copy
    // of itself — which a credential key flipping back and forth does on every survey —
    // is idempotent rather than doubling the array.
    static let currentVersion = 2

    var version: Int = PersistedCredentialLedger.currentVersion
    var spends: [RequestSpend] = []
}

enum PersistenceOp: Equatable {
    case write(storageKey: String, payload: Data)
    case delete(storageKey: String)
}

// One codec for every persisted payload. Two codecs doing the same job is the twinned
// branch this run keeps producing: the day one of them gains a check the other does not,
// the difference is invisible until a payload written by one is read by the other.
protocol VersionedPayload: Codable {
    static var currentVersion: Int { get }
    var version: Int { get }
}

enum PersistedCodec {
    static func encode<Payload: VersionedPayload>(_ payload: Payload) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(payload)
    }

    // A payload this version cannot read is treated as ABSENT, never as a fatal error.
    static func decode<Payload: VersionedPayload>(_ type: Payload.Type,
                                                  from data: Data) -> Payload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        guard payload.version == Payload.currentVersion else { return nil }
        return payload
    }
}

// Reading the whole persisted keyspace at launch, as a pure function of the index and a
// payload lookup — so the load path is testable rather than living inside the shell,
// which no test target compiles.
//
// `unreadable` is the point of this type. A key whose bytes are corrupt or whose version
// this build cannot read never becomes an account payload, so it never enters the
// engine's unclaimed map, so the engine's orphan sweep — which only walks accounts and
// unclaimed payloads — structurally cannot reach it. The index keeps naming it and the
// blob keeps sitting under it, forever: the third orphan class of this task, and the same
// failure §6 names about five stale credential entries, one layer above where the
// guarantee is installed.
enum PersistedStore {
    // Persisted credential ledgers live under their own prefix, which cannot collide
    // with an account namespace: an `AccountIdentity.storageKey` always begins with a
    // provider's raw value.
    static let ledgerNamespace = "credential:"

    struct Contents {
        var accounts: [String: PersistedAccountState] = [:]
        var ledgers: [String: PersistedCredentialLedger] = [:]
        var unreadable: [String] = []
    }

    static func load(index: [String], payload: (String) -> Data?) -> Contents {
        var contents = Contents()
        for key in index {
            guard let data = payload(key) else {
                // Named in the index with nothing behind it: the index entry is itself
                // the orphan.
                contents.unreadable.append(key)
                continue
            }
            if let ledgerKey = ledgerKey(of: key) {
                if let ledger = PersistedCodec.decode(PersistedCredentialLedger.self, from: data) {
                    contents.ledgers[ledgerKey] = ledger
                } else {
                    contents.unreadable.append(key)
                }
            } else if let account = PersistedCodec.decode(PersistedAccountState.self, from: data) {
                contents.accounts[key] = account
            } else {
                contents.unreadable.append(key)
            }
        }
        return contents
    }

    static func ledgerKey(of storageKey: String) -> String? {
        guard storageKey.hasPrefix(ledgerNamespace) else { return nil }
        return String(storageKey.dropFirst(ledgerNamespace.count))
    }
}
