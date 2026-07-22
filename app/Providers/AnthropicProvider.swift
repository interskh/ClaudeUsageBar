import Foundation

// Anthropic usage fetch and projection (§5.1). PURE: discovery, the credential store and
// the network all arrive through injected protocols, so the whole of this file — headers,
// status mapping, parsing — compiles into the test target and runs against recorded
// fixtures with no machine underneath it.
//
// THE REGRESSION THIS FILE EXISTS TO PREVENT. The payload migrated from flat named keys
// to a self-describing `limits[]` array. The flat keys were left in place and now return
// `null` while the corresponding array entries are live and non-zero, so a client written
// against them still gets `200 OK`, still parses cleanly, and silently under-reports.
// Nothing fails. NOTHING IN THIS FILE MAY READ A FLAT PER-WINDOW KEY, and the same trap
// is set a second time on the money side: the legacy `extra_usage` object was observed
// fully null on an account whose `spend.used` was populated.

// MARK: - Parsing

enum AnthropicUsageParser {
    // Canonical window durations. Classification goes through `WindowSpan(seconds:)` so
    // the two providers cannot spell one span two ways (§3) — §5.2 reads a duration
    // directly from its payload, and this one derives it from `kind`.
    static let sessionWindowSeconds = 18_000
    static let hourlyWindowSeconds = 3_600
    static let dailyWindowSeconds = 86_400
    static let weeklyWindowSeconds = 604_800

    // A quota class whose duration the payload never states. NOT a guess at a duration:
    // guessing would fold an unknown class onto a canonical span and merge its history
    // with a window it has nothing to do with.
    static let unstatedWindowSeconds = 0

    struct Parsed: Equatable {
        let windows: [UsageWindow]
        let spend: Spend?
        // An account identifier published by the RESPONSE, when one is present. Never
        // used as identity (§3 resolves identity from credential-side material before any
        // request) — only to notice a disagreement, which is a warning and never an error.
        let accountIdentifier: String?
        let warnings: [String]
    }

    enum Outcome: Equatable {
        case parsed(Parsed)
        // Names the failure mode only. The body is retained by the caller (§5), not
        // quoted here: it carries account identifiers and plan details.
        case malformed(String)
    }

    // Warnings reach the USER through §7's card, not a log, so they are phrased for one
    // and DEDUPLICATED: a payload with twenty malformed entries must not produce twenty
    // identical lines in a menu-bar popover. They also never quote the payload — the
    // response carries account identifiers and plan details, and the raw body is retained
    // (§5) for anyone who needs the specifics.
    enum Warning {
        static let unreadableEntry = "Some usage limits could not be read and are not shown."
        static let unidentifiedScope =
            "A usage limit did not say which model or feature it applies to; "
            + "it is shown on its own."
        // Distinct from `unreadableEntry`, and the distinction is the point: this limit IS
        // shown. Saying "not shown" about a window that is on screen is the sort of wrong
        // that erodes trust in every other warning here.
        static let unidentifiedLimit =
            "A usage limit did not say what kind of limit it is; it is shown on its own."
        static let unreadableResetTime = "A usage limit arrived without a usable reset time."
        static let noLimits = "This account reported no usage limits."
        static let unreadableSpend = "Some spending figures could not be read."
        static let collidingIdentities =
            "Two usage limits arrived with the same identity; one of them may be hidden."
    }

    // Order-preserving and self-deduplicating. A `Set` alone would make the order depend
    // on hashing, and §7 renders these in sequence.
    struct WarningLog {
        private(set) var messages: [String] = []
        private var seen: Set<String> = []

        mutating func add(_ message: String) {
            guard seen.insert(message).inserted else { return }
            messages.append(message)
        }
    }

    static func parse(_ data: Data) -> Outcome {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed("usage response is not a JSON object")
        }
        // The array IS the payload. Its absence is the schema drift §5 exists to catch,
        // so it fails loud here rather than degrading to an empty — and therefore
        // reassuring — snapshot.
        guard let entries = root["limits"] as? [Any] else {
            return .malformed("usage response carries no `limits` array")
        }

        var windows: [UsageWindow] = []
        var warnings = WarningLog()

        // EXHAUSTIVE over the array, with no allow-list of kinds. The three kinds
        // observed today are not the three kinds that will exist tomorrow, and a filter
        // written against them drops a live limit silently — the same blindness the flat
        // keys caused, arriving through a different door.
        //
        // Exhaustive at INGESTION is only half the job: an entry that is ingested and then
        // dropped, merged into another window, or rescaled reproduces the identical silent
        // under-report one layer lower. So nothing below deletes a window it managed to
        // read — the worst it does is give it a degraded identity and say so.
        for (index, raw) in entries.enumerated() {
            guard let entry = raw as? [String: Any] else {
                // The ONE place an entry is dropped for being unreadable, and the only one
                // where there is nothing to degrade TO: the element is not an object, so it
                // carries no figure, no reset time and no scope. Per-key permissiveness
                // (§5) means the rest of the payload still parses.
                warnings.add(Warning.unreadableEntry)
                continue
            }
            if let window = window(from: entry, index: index, warnings: &warnings) {
                windows.append(window)
            }
        }

        // An empty array is syntactically fine and semantically alarming: §7 drops an
        // account with no windows out of the popover and the menu-bar worst-of entirely,
        // so a scope-reduced token looks exactly like a healthy account with nothing to
        // report. Say which one it is.
        if entries.isEmpty { warnings.add(Warning.noLimits) }

        // Belt and braces for the rules below. Two windows sharing a `WindowID` means §8
        // keys one account's threshold ladder on another window's readings, and any
        // dictionary built from this list silently keeps one. The rules above are meant to
        // make this unreachable; if it ever fires, the payload has outgrown them.
        if Set(windows.map(\.id)).count != windows.count {
            warnings.add(Warning.collidingIdentities)
        }

        return .parsed(Parsed(windows: windows,
                              spend: spend(from: root, warnings: &warnings),
                              accountIdentifier: accountIdentifier(in: root),
                              warnings: warnings.messages))
    }

    // nil => the entry describes a window that has never started. That is the ONLY reason
    // this function returns nothing: it is a statement about the window, not a failure to
    // read one. Every unreadable FIELD degrades the identity and keeps the figure.
    private static func window(from entry: [String: Any],
                               index: Int,
                               warnings: inout WarningLog) -> UsageWindow? {
        let utilization = self.utilization(entry["percent"])
        let reset = timestamp(entry["resets_at"])

        // §5.1: a scoped bar is real on presence of a RESET TIME, not on a non-zero
        // figure. An unused model reports zero and a freshly-reset but genuinely active
        // window also reports zero — utilization cannot tell them apart, the reset time
        // can. An unknown utilization is NOT zero and is kept: dropping it would make
        // "the provider declined to say" indistinguishable from "this never started".
        //
        // Only a genuinely ABSENT reset time qualifies as never-started. A reset time that
        // is present but unreadable says the window HAS started and we failed to read
        // when — treating that as dormant would hide a live window on nothing more than a
        // format change, silently, which is how a single stray timestamp format could blank
        // an account's whole card.
        //
        // THIS TEST COMES FIRST so that the warnings below describe only windows that are
        // actually kept. A dormant entry that also lost its `kind` would otherwise tell the
        // user a limit "is shown on its own" while nothing is on screen, which is the kind
        // of small wrongness that teaches people to ignore the other warnings.
        if reset == .absent, utilization == .known(0) { return nil }
        if reset == .unreadable { warnings.add(Warning.unreadableResetTime) }

        // Absent, empty, or not a string. An entry whose `kind` cannot be read is exactly
        // as real as one whose `scope` cannot be read, and it is handled the same way:
        // kept, with a degraded but distinct identity. Discarding it deleted a live
        // reading — measured, a 95% limit with no `kind` alongside a 10% account-wide one
        // reported a binding utilization of 10%, the identical 85-point under-report the
        // scope path was fixed for, through the adjacent field.
        let kind = string(entry["kind"])
        if kind == nil { warnings.add(Warning.unidentifiedLimit) }

        let scopeValue = entry["scope"]
        let scopePresent = scopeValue != nil && !(scopeValue is NSNull)
        let resolvedScope = scope(from: scopeValue as? [String: Any])
        if scopePresent && resolvedScope == nil {
            // Scoped, but nothing in the scope identifies what it is scoped TO — either
            // because every dimension is null (observed shape, both fields nil) or because
            // `scope` is not an object at all.
            //
            // The entry is NOT discarded. Discarding it deletes a real, possibly binding
            // reading — an unidentifiable 95% limit vanishing while a 10% account-wide one
            // remains is an 85-point under-report, precisely the failure this provider was
            // rewritten to eliminate. Nor is it folded onto `.account`, which would merge a
            // scoped quota into the account-wide window of the same span. It keeps its
            // usage and takes the degraded-but-distinct identity of its own class.
            warnings.add(Warning.unidentifiedScope)
        }

        let span = self.span(of: entry, kind: kind)
        let group = string(entry["group"])
        return UsageWindow(
            id: WindowID(span: span,
                         scope: resolvedScope?.scope
                             ?? fallbackScope(kind: kind, group: group, index: index, span: span)),
            label: resolvedScope?.label ?? humanised(group ?? kind ?? Label.unidentified),
            utilization: utilization,
            resetsAt: reset.date,
            isActive: entry["is_active"] as? Bool ?? false
        )
    }

    enum Label {
        // Used only when the payload supplied neither a scope, nor a group, nor a kind.
        // Not a label map (§5.1 forbids one): it names the absence, and it is the only
        // alternative to rendering a bar with a blank name.
        static let unidentified = "Unnamed limit"
    }

    // The identity an entry takes when its own `scope` did not supply one.
    //
    // `.account` is claimed ONLY by a class that is genuinely account-wide: a recognised
    // temporal token with nothing after it (`session`) or with the payload's own aggregate
    // marker (`weekly_all`). Everything else keys on its own `kind`.
    //
    // This is not defensive tidiness — it is the same collision the scope rules avoid,
    // reached from the other side. `weekly_all` and a sibling `weekly_<something>_all`
    // share a span and would both take `.account`, producing two windows with a
    // byte-identical `WindowID`. §8 keys threshold state on that ID, so one window's
    // ladder would be armed and cleared by the other's readings, and every `[WindowID: …]`
    // built downstream keeps exactly one of the two. Semantically the narrower class is
    // not the account-wide limit anyway.
    static let accountWideKindRemainders: Set<String> = ["", "all"]

    // Each branch is namespaced, so a class named `x` cannot alias a scope dimension or a
    // group whose value is also `x` (see `scope(from:)`).
    private static func fallbackScope(kind: String?,
                                      group: String?,
                                      index: Int,
                                      span: WindowSpan) -> WindowScope {
        guard let kind else {
            // No `kind`, and `scope` did not resolve either. The identity has to come from
            // whatever the payload DID supply, because two such entries must not collapse
            // onto one another any more than two named classes may.
            if let group { return .feature(id: "group:" + group) }
            // Last resort, and the only identity in this file derived from position. It is
            // unstable if the vendor reorders the array — which costs that window's
            // threshold history (§8) — and that is deliberately preferred to the
            // alternative, which is deleting a live reading. Under-reporting is the failure
            // this provider exists to prevent; a re-fired notification ladder is not.
            return .feature(id: "index:\(index)")
        }
        let tokens = kind.split(separator: "_").map(String.init)
        let remainder = tokens.dropFirst().joined(separator: "_")
        // A class whose duration the payload never stated cannot be account-wide either:
        // those all land on one `.other(seconds:)` span, so `.account` would collide them
        // with each other.
        if span != WindowSpan(seconds: unstatedWindowSeconds),
           accountWideKindRemainders.contains(remainder) {
            return .account
        }
        return .feature(id: "kind:" + kind)
    }

    // BY DURATION, NEVER BY POSITION (§5.2's rule, which applies to any self-describing
    // bucket list): the entry's place in the array carries no meaning, and an
    // implementation that assumed "first is the session window" was observed wrong on the
    // sibling provider, where the first slot held the weekly window.
    private static func span(of entry: [String: Any], kind: String?) -> WindowSpan {
        // A duration stated outright always wins over one inferred from a name. These key
        // names are GUESSES, not observations: no Anthropic payload seen carries any of
        // them (the field belongs to §5.2's provider). They cost nothing and would catch
        // the vendor converging on the sibling's shape — and it is the ONLY way an entry
        // with no readable `kind` can still be classified by duration rather than dropped.
        for key in ["limit_window_seconds", "window_seconds", "duration_seconds"] {
            if let seconds = exactInteger(entry[key]), seconds > 0 {
                return WindowSpan(seconds: seconds)
            }
        }
        // No name to infer from either: the duration is unstated, which is a fact about the
        // payload and not a reason to invent one.
        guard let kind else { return WindowSpan(seconds: unstatedWindowSeconds) }
        return WindowSpan(seconds: seconds(forKind: kind))
    }

    // The leading token of `kind` names the temporal class; the remainder names the
    // scope, which is read from `scope` rather than from the name. Matching on the token
    // rather than the whole string is what lets an unseen `<class>_<something>` still
    // classify correctly.
    private static func seconds(forKind kind: String) -> Int {
        switch kind.split(separator: "_").first.map(String.init) ?? kind {
        case "session": return sessionWindowSeconds
        case "hourly": return hourlyWindowSeconds
        case "daily": return dailyWindowSeconds
        case "weekly": return weeklyWindowSeconds
        default: return unstatedWindowSeconds
        }
    }

    private struct ResolvedScope {
        let scope: WindowScope
        let label: String
    }

    // §3/§5.1: scope identity comes from the provider's STABLE discriminator, never from
    // display text — labels get renamed and reused, and keying on them splits one history
    // in two on a rename.
    //
    // ACKNOWLEDGED SHORTFALL, recorded rather than hidden: this provider publishes both an
    // identifier and a display name for a scoped limit, and the identifier has been
    // OBSERVED NULL while the display name was populated. Identity therefore prefers the
    // identifier and falls back to the display name only when there is no identifier at
    // all. A provider-side rename of a model whose identifier is null WILL split that
    // window's history. Keying everything on display text would make the same breakage
    // invisible instead of merely known.
    //
    // The scope object is read as a bag of dimensions rather than a fixed pair of fields,
    // so a dimension this client has never seen still yields a usable scope instead of
    // being dropped.
    //
    // PRECEDENCE IS FIXED AND EXPLICIT, not alphabetical. Ranking unknown dimensions by
    // sort order makes identity depend on the SET of dimensions present: a payload
    // carrying `surface` keys on it, and the day the vendor adds an `agent` dimension the
    // same window keys on that instead. Every `WindowID` changes at once, which is exactly
    // what §8 warns about — every stored threshold is reclaimed and the whole
    // [25, 50, 75, 90] ladder re-fires for every window on every account. Known dimensions
    // therefore always outrank unknown ones, and a newly introduced dimension can only
    // ever be consulted when the ones above it are absent.
    static let scopeDimensionPrecedence = ["model", "surface"]

    private static func scope(from object: [String: Any]?) -> ResolvedScope? {
        guard let object else { return nil }
        let known = scopeDimensionPrecedence
        let unknown = object.keys.filter { !known.contains($0) }.sorted()
        for key in known + unknown {
            guard let dimension = object[key] as? [String: Any] else { continue }
            let identifier = string(dimension["id"])
            let displayName = string(dimension["display_name"])
            guard let discriminator = identifier ?? displayName else { continue }
            let label = displayName ?? discriminator
            // Non-model dimensions carry their KEY in the identity. Without it,
            // `surface.id == "x"` and `workspace.id == "x"` are one feature as far as §8
            // is concerned, so two unrelated quotas share a threshold ladder.
            return ResolvedScope(
                scope: key == "model" ? .model(id: discriminator)
                                      : .feature(id: key + ":" + discriminator),
                label: label
            )
        }
        return nil
    }

    // Presentation only, and derived from the payload's own words — §5.1 forbids a
    // client-side label map, so a new quota class arrives with a usable label and no
    // build.
    private static func humanised(_ token: String) -> String {
        let words = token.split(separator: "_").map(String.init)
        guard let first = words.first, !first.isEmpty else { return token }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }

    // MARK: Scalars

    // `null` and absent both mean UNKNOWN, never zero (§3). There is no `?? 0` anywhere
    // in this file, and `Utilization` deliberately offers no accessor that would allow
    // one.
    //
    // The figure arrives as Int OR Double. Both go through the model's single rounding
    // entry point, because round-vs-truncate straddles the 90% red band and the two
    // providers must not each pick their own.
    //
    // THE MAGNITUDE IS BOUNDED HERE, BEFORE THE MODEL SEES IT. `Utilization.percent(Double)`
    // guards `isFinite` and then does `Int(value.rounded())`, and `Int(_: Double)` TRAPS
    // on anything outside `Int`'s range — so a payload carrying `1e30` does not
    // under-report, it kills the process mid-poll. Measured: exit 133. The `Int` overload
    // clamps, so this door is the only one open; it is shut on the provider side because
    // the trap is in a Foundation conversion the model cannot catch.
    static func utilization(_ value: Any?) -> Utilization {
        guard let number = numeric(value) else { return .unknown }
        let raw = number.doubleValue
        guard raw.isFinite else { return .unknown }
        return Utilization.percent(min(100, max(0, raw)))
    }

    // Bounds the scale so a nonsense exponent cannot be presented as a fact. Twelve
    // decimal places is already three more than any real currency (and more than the
    // smallest crypto denomination); beyond it the field is not a scale.
    static let maximumExponent = 12

    // Money is minor units plus an exponent, never a Double (§3). An amount that arrives
    // without a currency stays UNQUALIFIED: inferring "USD" presents a guess as a fact,
    // and the sibling provider genuinely publishes a bare balance with no currency at all.
    //
    // THE SCALE IS NOT THE CURRENCY, and losing it is the expensive mistake. An amount of
    // `{amount_minor: 1500, exponent: 2}` with no currency is fifteen units, not fifteen
    // hundred — emitting the bare minor-unit integer over-reports by 10^exponent, and
    // `unqualified` renders exactly what it is handed. So when the scale survives and the
    // currency does not, the figure is rendered AT ITS OWN SCALE and only the currency is
    // withheld. `unqualified(raw:)` means "the provider stated no currency", never "the
    // provider stated no scale".
    static func amount(_ value: Any?) -> MonetaryAmount? {
        if let object = value as? [String: Any] {
            // Exact only: `NSNumber.intValue` WRAPS on overflow and TRUNCATES a fraction,
            // both of which turn an unreadable figure into a confident wrong one. Measured:
            // `99999999999999999999` became `7766279631452241919`, presented as qualified
            // money with no warning at all.
            guard let minor = exactInteger(object["amount_minor"]) else { return nil }
            // A negative figure is kept deliberately: a refund or a credit is legitimately
            // below zero, and rejecting it would drop a real balance.
            let currency = currencyCode(object["currency"])
            let exponent = exactInteger(object["exponent"])
                .flatMap { (0...maximumExponent).contains($0) ? $0 : nil }
            if let currency, let exponent {
                return .qualified(minor: minor, currency: currency, exponent: exponent)
            }
            if let exponent {
                return .unqualified(raw: decimalString(minor: minor, exponent: exponent))
            }
            return .unqualified(raw: String(minor))
        }
        // A bare figure, as either a String ("0") or a Number (0). Both shapes have been
        // observed for the same field, so a parser that binds only one of them fails on
        // the real payload.
        if let number = numeric(value) { return .unqualified(raw: number.stringValue) }
        if let raw = string(value) { return .unqualified(raw: raw) }
        return nil
    }

    // Whitespace-only is not a currency code. Accepting it would render an amount as
    // qualified — implying the provider named a currency — against a blank symbol.
    private static func currencyCode(_ value: Any?) -> String? {
        guard let raw = string(value) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Integer string manipulation, never a Double: the whole point of minor units is that
    // the value never touches binary floating point (§3).
    static func decimalString(minor: Int, exponent: Int) -> String {
        guard exponent > 0 else { return String(minor) }
        let digits = String(minor.magnitude)
        let padded = String(repeating: "0", count: max(0, exponent + 1 - digits.count)) + digits
        let point = padded.index(padded.endIndex, offsetBy: -exponent)
        return (minor < 0 ? "-" : "") + padded[..<point] + "." + padded[point...]
    }

    private static func spend(from root: [String: Any], warnings: inout WarningLog) -> Spend? {
        guard let object = root["spend"] as? [String: Any] else {
            // Present but not an object is a read failure, not an absence, and it was
            // silently indistinguishable from "this plan has no spending" — the same
            // present-but-unreadable-so-vanished shape as the entry rules above. There is
            // nothing to degrade to (no field is readable), so it warns and yields nothing.
            let value = root["spend"]
            if value != nil && !(value is NSNull) { warnings.add(Warning.unreadableSpend) }
            return nil
        }
        let used = amount(object["used"])
        let limit = amount(object["limit"])
        let balance = amount(object["balance"])
        // A field that is PRESENT but could not be read is not the same as an absent one,
        // and silently showing no figure where the provider stated one is the same silent
        // under-report the window rules exist to prevent.
        for (value, parsed) in [(object["used"], used),
                                (object["limit"], limit),
                                (object["balance"], balance)]
        where parsed == nil && value != nil && !(value is NSNull) {
            warnings.add(Warning.unreadableSpend)
        }
        // Presence of the object does not prove the feature is live — it is present and
        // fully zeroed on plans that cannot purchase credits (§5.1). An object with no
        // readable amount at all yields no spend rather than a row of blanks.
        guard used != nil || limit != nil || balance != nil else { return nil }
        return Spend(used: used, limit: limit, balance: balance)
    }

    // These key names are GUESSES too: no observed Anthropic payload publishes an account
    // identifier at all, so the disagreement path below is exercised only against a
    // fixture written for it. Kept because §5.2 requires a disagreement to be surfaced
    // rather than reconciled, and because the cost of being wrong is that it never fires.
    private static func accountIdentifier(in root: [String: Any]) -> String? {
        for key in ["account_uuid", "account_id"] {
            if let value = string(root[key]) { return value }
        }
        if let account = root["account"] as? [String: Any] {
            for key in ["uuid", "id"] {
                if let value = string(account[key]) { return value }
            }
        }
        return nil
    }

    // THREE OUTCOMES, NOT AN OPTIONAL. "The provider did not give a reset time" and "the
    // provider gave one and we could not read it" mean opposite things: the first says the
    // window has never started (§3), the second says it HAS and we failed on the format.
    // Collapsing them into `nil` makes a single unrecognised timestamp spelling silently
    // hide a live window — measured with `"2026-07-23 07:00:00"` (a space instead of `T`)
    // at 0%, which vanished with no warning at all.
    enum Timestamp: Equatable {
        case absent            // key missing, or explicitly null
        case parsed(Date)
        case unreadable        // present, but not a timestamp this build can read

        var date: Date? {
            if case .parsed(let date) = self { return date }
            return nil
        }
    }

    // Timestamps arrive WITH fractional seconds in the observed payload and without them
    // in the documented shape. `ISO8601DateFormatter` parses exactly one of the two per
    // option set — measured — so a single-formatter implementation silently drops every
    // reset time the moment the vendor stops emitting microseconds.
    static func timestamp(_ value: Any?) -> Timestamp {
        guard let value, !(value is NSNull) else { return .absent }
        guard let raw = string(value) else { return .unreadable }
        for options in [[ISO8601DateFormatter.Options.withInternetDateTime, .withFractionalSeconds],
                        [ISO8601DateFormatter.Options.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = ISO8601DateFormatter.Options(options)
            if let date = formatter.date(from: raw) { return .parsed(date) }
        }
        return .unreadable
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    // The ONLY integer conversion in this file. `NSNumber.intValue` silently wraps on
    // overflow and truncates a fraction, so every call site that used it — minor units,
    // exponents, window durations — could turn an unreadable figure into a confident
    // wrong one. A value that does not survive the round trip is not an integer we can
    // report, and reporting nothing is the honest outcome.
    static func exactInteger(_ value: Any?) -> Int? {
        guard let number = numeric(value) else { return nil }
        let double = number.doubleValue
        // Beyond 2^53 a Double cannot represent consecutive integers, so the round-trip
        // check below stops being able to detect a wrap.
        guard double.isFinite, abs(double) <= 9_007_199_254_740_992 else { return nil }
        let integer = number.intValue
        guard Double(integer) == double else { return nil }
        return integer
    }

    // JSON booleans bridge to `NSNumber` and `as? NSNumber` accepts them, so `true` would
    // otherwise read as 1% used or one minor unit spent.
    private static func numeric(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return number
    }
}

// MARK: - Provider

struct AnthropicProvider: UsageProvider {
    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    // Load-bearing: the endpoint rejects the request without it (§5.1).
    static let betaHeaderValue = "oauth-2025-04-20"

    let kind: ProviderKind = .anthropic
    let presentation = ProviderPresentation(glyph: "⚡", sectionTitle: "CLAUDE", sortOrder: 0)

    private let discovery: ClaudeProfileDiscovery
    private let http: HTTPRequesting
    private let agentVersion: AgentVersionCache
    private let registeredLocations: () -> [String]
    private let clock: () -> Date

    init(discovery: ClaudeProfileDiscovery,
         http: HTTPRequesting,
         agentVersion: AgentVersionCache,
         registeredLocations: @escaping () -> [String] = { [] },
         clock: @escaping () -> Date = { Date() }) {
        self.discovery = discovery
        self.http = http
        self.agentVersion = agentVersion
        self.registeredLocations = registeredLocations
        self.clock = clock
    }

    func discoverAccounts() -> [DiscoveredAccount] {
        discovery.discover(registeredLocations: registeredLocations(), now: clock())
    }

    // §3: credential freshness is an invariant of THIS call. The access token rotates
    // roughly 8-hourly, so the credential is re-read from the store on every fetch and
    // nothing here retains it — the token lives in a local for the length of one request.
    //
    // Discovery is re-run rather than cached because an `AccountRef` deliberately carries
    // no location (§3), and the credential's service name is derived from one. It also
    // re-applies the duplicate-identity resolution, so a fetch cannot end up reading the
    // stale copy of a configuration that discovery already decided against. The cost is a
    // local directory scan plus one credential lookup per profile; §6 already calls
    // discovery cheap enough to run on every popover open.
    func fetch(_ account: AccountRef) async -> Result<FetchedSnapshot, FetchError> {
        let now = clock()
        let profiles = discovery.resolveProfiles(registeredLocations: registeredLocations(), now: now)
        guard let profile = profiles.first(where: { $0.account.ref.id == account.id }) else {
            // Terminal, not transport: retrying an account that has left discovery is a
            // timer that never stops.
            return .failure(.accountUnknown)
        }

        let credential: ClaudeCredential
        switch discovery.credentials.lookupCredential(service: profile.service) {
        case .absent:
            // §6: this is NOT resolved to expired-vs-revoked here. The provider does not
            // hold the re-read expiry at rejection time; the store does, and it is the
            // store that re-reads once and retries before concluding anything.
            return .failure(.authenticationRejected)
        case .failed(let fault):
            return .failure(.transport(message: fault))
        case .found(let blob):
            switch ClaudeCredential.decode(blob) {
            case .usable(let usable): credential = usable
            case .noOAuthMaterial: return .failure(.authenticationRejected)
            case .unreadable(let fault): return .failure(.transport(message: fault))
            }
        }
        // The stored expiry is deliberately NOT checked here. A token that looks lapsed
        // locally may have been rotated between the read and the request, and §6 requires
        // upstream to be the one that says no.

        let request = HTTPRequest(
            url: AnthropicProvider.usageEndpoint,
            headers: [
                "Authorization": "Bearer \(credential.accessToken)",
                "anthropic-beta": AnthropicProvider.betaHeaderValue,
                "User-Agent": AgentVersion.userAgent(version: await agentVersion.current(now: now)),
                "Content-Type": "application/json",
            ]
        )

        switch await http.get(request) {
        case .failure(let message):
            return .failure(.transport(message: message))

        case .response(let status, let headers, let body):
            switch status {
            case 200...299:
                break
            case 401, 403:
                return .failure(.authenticationRejected)
            case 429:
                return .failure(.rateLimited(retryAfter: RetryAfter.seconds(
                    from: HTTPHeaders.value("Retry-After", in: headers), now: now
                )))
            default:
                // Names the status only. The endpoint's error bodies are not ours to
                // quote and the request's headers hold a bearer token.
                return .failure(.unexpectedStatus(code: status))
            }

            switch AnthropicUsageParser.parse(body) {
            case .malformed(let fault):
                // The body travels WITH the failure: this is exactly the silent schema
                // drift §5's retention exists to diagnose, so discarding it here would
                // throw the evidence away in the one case that most needs it.
                return .failure(.malformedResponse(message: fault, rawBody: body))

            case .parsed(let parsed):
                var warnings = parsed.warnings
                if let published = parsed.accountIdentifier,
                   let expected = expectedAccountIdentifier(for: profile),
                   published != expected {
                    // Surfaced, NEVER fatal (§5.2, and the same rule applies here): on the
                    // target machine the sibling provider's equivalent disagreement is the
                    // normal state, so a provider that treats it as an error renders a
                    // live account as broken. The identifiers themselves are not quoted —
                    // they are account identifiers, and warnings are user-visible.
                    warnings.append("the account identifier in the usage response does not "
                                    + "match the one recorded alongside this profile")
                }
                let snapshot = Snapshot(
                    account: account,
                    // The payload publishes no plan; the credential does. Read from the
                    // credential just read, so it tracks a plan change without a restart.
                    planLabel: credential.subscriptionType,
                    windows: parsed.windows,
                    spend: parsed.spend,
                    fetchedAt: now,
                    warnings: warnings
                )
                return .success(FetchedSnapshot(snapshot: snapshot, rawBody: body))
            }
        }
    }

    private func expectedAccountIdentifier(for profile: ResolvedClaudeProfile) -> String? {
        guard let home = ClaudeProfileDiscovery
            .lexicallyStandardized(discovery.fileSystem.homeDirectoryPath)
        else { return nil }
        return discovery.identityFile(for: profile.directory, home: home)?.accountUUID
    }
}
