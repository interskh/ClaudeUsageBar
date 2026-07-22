import Foundation

// Codex usage fetch and projection (§5.2). PURE: the credential reader and the network
// both arrive through injected protocols, so the whole of this file — headers, status
// mapping, the endpoint fallback, parsing — compiles into the test target and runs
// against recorded fixtures with no machine underneath it. The networking seam is the
// one task 5 built (`HTTPRequesting`); there is no second one.
//
// THE REGRESSION THIS FILE EXISTS TO PREVENT is the sibling's, arriving through a
// different door. On the other provider a flat key was read where a self-describing
// array had taken over. Here the payload is self-describing from the start, and the
// blindness is one level down: EACH BUCKET HOLDS ITS OWN SET OF TEMPORAL WINDOWS, so a
// parser that maps one bucket to one window reads the right key and keeps only the first
// thing in it. It still returns 200 OK, still parses cleanly, and still under-reports.
// Normalisation is therefore a FLATTENING: one `UsageWindow` per (scope, span) pair
// actually present, scope from the bucket and span from each window inside it.
//
// And ingestion is EXHAUSTIVE OVER QUOTA-BEARING GROUPS, not over a fixed list of two.
// The account-level bucket and the named feature list are not the whole payload — the
// observed response carries a third named quota class alongside them, and a client that
// models only the two enumerated groups omits a live limit silently.
//
// THE RULE THAT GOVERNS EVERYTHING BELOW INGESTION, inherited from the sibling where it
// cost two fix rounds to learn: NOTHING BELOW INGESTION MAY DELETE A WINDOW IT MANAGED TO
// READ. The worst it may do is give it a degraded, DISTINCT identity and say so in
// `Snapshot.warnings`. Stating that is not enforcing it, so the projection functions
// below are written to make it structurally hard to break: `window(from:…)` returns a
// non-optional, and the only `continue`s in the ingestion loops are on values that carry
// no window at all.

// MARK: - Parsing

enum CodexUsageParser {
    // The two groups the payload is known to publish today. They are NOT an allow-list:
    // every other top-level value is examined for the same window shape and ingested as
    // its own scoped bucket if it carries one (see `parse`). These two are named only
    // because their SCOPE is special — the first is the account itself, the second
    // publishes a per-entry feature discriminator.
    static let accountBucketKey = "rate_limit"
    static let featureListKey = "additional_rate_limits"

    // A window whose duration the payload did not state. NOT a guess at one: guessing
    // would fold an unknown class onto a canonical span and merge its threshold history
    // (§8) with a window it has nothing to do with. Two such windows in one bucket
    // collide, which is why `parse` runs a duplicate-identity detector.
    static let unstatedWindowSeconds = 0

    // Magnitude bounds. A "window" longer than ten years, a countdown longer than ten
    // years, or an epoch past the year 2100 is not a figure this app can present as a
    // fact — and an unbounded one reaches §7's date formatting and the span identity. Ten
    // years is three orders of magnitude above the longest window either vendor
    // publishes, so a legitimate value cannot trip it.
    static let maximumWindowSeconds = 10 * 366 * 24 * 3_600
    static let maximumResetSeconds = 10 * 366 * 24 * 3_600
    static let maximumResetEpoch: Double = 4_102_444_800  // 2100-01-01T00:00:00Z

    struct Parsed: Equatable {
        let windows: [UsageWindow]
        let spend: Spend?
        let planLabel: String?
        // The identifiers the RESPONSE publishes. Never used as identity — §3 resolves
        // identity from credential-side material before any request — only to notice a
        // disagreement, which is a warning and never an error (§5.2, and the reason
        // `Snapshot` has a warnings channel at all).
        let accountIdentifier: String?
        let userIdentifier: String?
        let warnings: [String]
    }

    enum Outcome: Equatable {
        case parsed(Parsed)
        // Names the failure mode only. The body is retained by the caller (§5), not
        // quoted here: it carries account identifiers, an email address and plan details.
        case malformed(String)
    }

    // Warnings reach the USER through §7's card, not a log, so they are phrased for one
    // and deduplicated, and they never quote the payload.
    enum Warning {
        static let unreadableBucket = "Some Codex usage limits could not be read and are not shown."
        static let unreadableWindow =
            "A Codex usage limit arrived in a form this version cannot read."
        static let unstatedDuration =
            "A Codex usage limit did not say what period it covers; it is shown on its own."
        static let unrecognisedGroup =
            "Codex reported a kind of usage limit this version does not recognise; "
            + "it is shown under its own name."
        static let unreadableResetTime = "A Codex usage limit arrived without a usable reset time."
        static let unreadableCredits = "The Codex credit balance could not be read."
        static let noLimits = "This Codex account reported no usage limits."
        static let limitReached = "A Codex usage limit has been reached."
        static let notAllowed = "Codex is currently refusing requests for this account."
        static let collidingIdentities =
            "Two Codex usage limits arrived with the same identity; they are shown separately."
    }

    // A window on its way out of ingestion, still carrying WHERE it came from. The origin
    // is unique across the whole payload — a bucket ordinal plus the path the window sat
    // at inside that bucket — and it exists for exactly one purpose: to make a degraded
    // identity DISTINCT when two windows would otherwise share a `WindowID`.
    struct Ingested {
        let window: UsageWindow
        let origin: String
        let scopeToken: String
    }

    static func scopeToken(_ scope: WindowScope) -> String {
        switch scope {
        case .account: return "account"
        case .model(let id): return "model:" + id
        case .feature(let id): return id
        }
    }

    // Order-preserving and self-deduplicating. A `Set` alone would make the order depend
    // on hashing, and §7 renders these in sequence. Deliberately a local copy of the
    // sibling's rather than a shared type: the two providers' warning machinery is the
    // one place a change made for one vendor could silently alter the other's output.
    struct WarningLog {
        private(set) var messages: [String] = []
        private var seen: Set<String> = []

        mutating func add(_ message: String) {
            guard seen.insert(message).inserted else { return }
            messages.append(message)
        }
    }

    static func parse(_ data: Data, now: Date) -> Outcome {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed("usage response is not a JSON object")
        }
        // The account-level bucket IS the payload. Its total absence is the schema drift
        // §5 exists to catch, so it fails loud here rather than degrading to an empty —
        // and therefore reassuring — snapshot. Presence is tested on the KEY, not on the
        // value: `rate_limit: null` is a live shape meaning "no account-level data", and
        // rejecting it would fail the whole fetch over a window that has not started.
        guard root.keys.contains(accountBucketKey) else {
            return .malformed("usage response carries no `\(accountBucketKey)` object")
        }

        var ingested: [Ingested] = []
        var warnings = WarningLog()
        var ordinal = 0

        // 1. The account-level bucket. A NULL bucket falls through both branches in
        // silence — §5.2: null is "no data", not a read failure and not a zero.
        if let object = root[accountBucketKey] as? [String: Any] {
            ingested += project(object, scope: .account, name: nil,
                                ordinal: &ordinal, now: now, warnings: &warnings)
        } else if present(root[accountBucketKey]) {
            ingested += rescue(key: accountBucketKey, value: root[accountBucketKey],
                               ordinal: &ordinal, now: now, warnings: &warnings)
        }

        // 2. The named feature list. Each entry is a WRAPPER — its windows sit one level
        // further down — and carries the stable discriminator the scope keys on.
        if let entries = root[featureListKey] as? [Any] {
            for (index, raw) in entries.enumerated() {
                guard let entry = raw as? [String: Any] else {
                    // The one place an entry is dropped, and the only one where there is
                    // nothing to degrade TO: the element is not an object, so it carries
                    // no figure, no duration and no discriminator.
                    warnings.add(Warning.unreadableBucket)
                    continue
                }
                let identity = featureIdentity(of: entry, index: index)
                ingested += project(entry, scope: .feature(id: identity.id), name: identity.name,
                                    ordinal: &ordinal, now: now, warnings: &warnings)
            }
        } else if present(root[featureListKey]) {
            ingested += rescue(key: featureListKey, value: root[featureListKey],
                               ordinal: &ordinal, now: now, warnings: &warnings)
        }

        // 3. EVERY OTHER TOP-LEVEL VALUE, examined for the same window shape. This is what
        // makes ingestion exhaustive over quota-bearing groups rather than over the two
        // named above: the observed payload carries `code_review_rate_limit` beside them,
        // and the next release will carry something else. A value that holds no window is
        // not a quota group and is skipped in silence (`credits`, `promo`, and the rest);
        // a value that holds one is ingested under its own namespaced scope AND surfaced,
        // because a limit this build has never seen is worth telling the user about.
        //
        // Keys are sorted so the projection does not depend on dictionary ordering: an
        // order that varies between runs would make the popover's window order jitter.
        for key in root.keys.sorted() where key != accountBucketKey && key != featureListKey {
            ingested += genericGroup(key: key, value: root[key],
                                     ordinal: &ordinal, now: now, warnings: &warnings)
        }

        // Nothing below ingestion may delete a window, so collisions are resolved by
        // splitting identities rather than by dropping one side.
        let windows = disambiguated(ingested, warnings: &warnings)

        // Syntactically fine and semantically alarming: §7 drops an account with no
        // windows out of the popover and the menu-bar worst-of entirely, so a
        // scope-reduced token looks exactly like a healthy account with nothing to report.
        if windows.isEmpty { warnings.add(Warning.noLimits) }

        return .parsed(Parsed(windows: windows,
                              spend: spend(from: root, warnings: &warnings),
                              planLabel: string(root["plan_type"]),
                              accountIdentifier: string(root["account_id"]),
                              userIdentifier: string(root["user_id"]),
                              warnings: warnings.messages))
    }

    // An ENUMERATED key whose shape has drifted. Step 3 excludes `rate_limit` and
    // `additional_rate_limits` so they are not ingested twice — which made them the only
    // two keys in the payload that the exhaustive scan, built precisely to survive drift,
    // could never rescue. `{"rate_limit": [ …two live windows… ]}` reported nothing at
    // all. They are routed through the generic path instead, so a shape change degrades
    // the identity and surfaces a warning rather than deleting the figures.
    private static func rescue(key: String, value: Any?, ordinal: inout Int,
                               now: Date, warnings: inout WarningLog) -> [Ingested] {
        let rescued = genericGroup(key: key, value: value,
                                   ordinal: &ordinal, now: now, warnings: &warnings)
        // Present, not the documented shape, and nothing recoverable inside it.
        if rescued.isEmpty { warnings.add(Warning.unreadableBucket) }
        return rescued
    }

    // Any top-level value that carries the window shape, whether or not this build has
    // heard of it, and in either of the two shapes such a group could arrive in: a bucket
    // object, or a list of them.
    private static func genericGroup(key: String, value: Any?, ordinal: inout Int,
                                     now: Date, warnings: inout WarningLog) -> [Ingested] {
        if let object = value as? [String: Any] {
            let flat = flatten(object)
            guard flat.hasWindows else {
                // Not quota-bearing — but say so if it LOOKED like it was and we could not
                // read it, rather than skipping a live limit in silence.
                if flat.unreadableWindow { warnings.add(Warning.unreadableWindow) }
                return []
            }
            warnings.add(Warning.unrecognisedGroup)
            return project(object, scope: .feature(id: "group:" + key), name: humanised(key),
                           ordinal: &ordinal, now: now, warnings: &warnings)
        }

        guard let entries = value as? [Any] else { return [] }
        let objects = entries.map { $0 as? [String: Any] }
        let flats = objects.map { $0.map(flatten) }
        // Whether this list is a quota group AT ALL is decided before any warning is
        // emitted about its elements. Without that, an ordinary top-level list of strings
        // would report "some usage limits could not be read", which is false and trains
        // users to ignore the warning when it is true.
        guard flats.contains(where: { $0?.hasWindows == true || $0?.unreadableWindow == true })
        else { return [] }

        var result: [Ingested] = []
        for (index, entry) in objects.enumerated() {
            guard let entry, let flat = flats[index] else {
                // The SAME rule the enumerated feature list applies to a non-object
                // element. Two twinned branches disagreeing on one input is how the last
                // round's asymmetry got in.
                warnings.add(Warning.unreadableBucket)
                continue
            }
            guard flat.hasWindows else {
                if flat.unreadableWindow { warnings.add(Warning.unreadableWindow) }
                continue
            }
            warnings.add(Warning.unrecognisedGroup)
            let identity = featureIdentity(of: entry, index: index)
            // Hoisted out of the call below deliberately: a three-operand `+` chain inside
            // a multi-argument call is the classic type-checker blow-up.
            let scopeID = "group:\(key):\(identity.id)"
            result += project(entry, scope: .feature(id: scopeID),
                              name: identity.name ?? humanised(key),
                              ordinal: &ordinal, now: now, warnings: &warnings)
        }
        return result
    }

    // §8 keys threshold state on the whole `WindowID`, and every `[WindowID: …]` built
    // downstream keeps exactly one of a colliding pair — so A WARNING IS NOT ENOUGH. The
    // invariant demands a degraded identity that is DISTINCT, and this is where that is
    // produced: two windows that would otherwise share an ID both take one built from
    // their origin, which is unique across the payload by construction.
    //
    // EVERY member of a colliding group is re-keyed, not merely the later ones. Letting
    // the first keep the clean ID would make one window's identity depend on the arrival
    // order of an unrelated one, so a payload that started colliding would silently move
    // only half of the pair.
    //
    // `dup:` is a prefix no natural scope id can take — they are all `feature:`, `name:`,
    // `index:` or `group:` prefixed — so a degraded identity cannot alias a real one.
    // These identities are knowingly volatile under vendor reordering, which costs those
    // windows' threshold history (§8); that is deliberately preferred to merging two live
    // readings into one, which is the under-report this provider exists to prevent.
    private static func disambiguated(_ ingested: [Ingested],
                                      warnings: inout WarningLog) -> [UsageWindow] {
        var occurrences: [WindowID: Int] = [:]
        for item in ingested { occurrences[item.window.id, default: 0] += 1 }
        guard occurrences.values.contains(where: { $0 > 1 }) else {
            return ingested.map(\.window)
        }
        warnings.add(Warning.collidingIdentities)
        return ingested.map { item in
            guard occurrences[item.window.id, default: 0] > 1 else { return item.window }
            let window = item.window
            return UsageWindow(
                id: WindowID(span: window.id.span,
                             scope: .feature(id: "dup:\(item.origin):\(item.scopeToken)")),
                label: window.label,
                utilization: window.utilization,
                resetsAt: window.resetsAt,
                isActive: window.isActive
            )
        }
    }

    // MARK: Buckets

    // One bucket's contents, flattened. Windows are collected at BOTH depths, always:
    // the account-level bucket holds its windows directly, a feature-list entry holds
    // them under a nested rate-limit object, and an "if none at depth one, try depth two"
    // shortcut would silently delete the nested windows of any bucket that had both.
    struct Flattened {
        // Key is the path the window was found at. Used for ordering and diagnostics
        // ONLY — never for identity, because a vendor rename of `primary_window` would
        // then reset that window's threshold history.
        var windows: [(key: String, object: [String: Any])] = []
        var allowed: Bool?
        var limitReached: Bool?
        // A value sitting under a window-shaped KEY that could not be read as a window.
        // Distinct from "no windows here": one is a group we cannot read, the other is a
        // group that simply is not about quota.
        var unreadableWindow = false

        var hasWindows: Bool { !windows.isEmpty }
    }

    // An object is a temporal window if it carries either of the two fields a window is
    // FOR — how long it covers, or how much of it is used. Detection is by field rather
    // than by key name, so a bucket that grows a third window under a name this build has
    // never seen is still ingested.
    static func isTemporalWindow(_ object: [String: Any]) -> Bool {
        object.keys.contains("limit_window_seconds") || object.keys.contains("used_percent")
    }

    // Used ONLY to decide whether an unreadable value deserves a warning. It never gates
    // ingestion: a window is recognised by its fields, above.
    static func looksLikeWindowKey(_ key: String) -> Bool {
        key == "window" || key == "windows"
            || key.hasSuffix("_window") || key.hasSuffix("_windows")
    }

    static func flatten(_ object: [String: Any]) -> Flattened {
        var result = Flattened()

        func absorbThrottle(_ o: [String: Any]) {
            if result.allowed == nil, let value = bool(o["allowed"]) { result.allowed = value }
            if result.limitReached == nil, let value = bool(o["limit_reached"]) {
                result.limitReached = value
            }
        }
        absorbThrottle(object)

        // THE BUCKET MAY ITSELF BE A WINDOW, and this line is where the last round's
        // worst bug was. `isTemporalWindow` was applied to the bucket's children and
        // grandchildren but never to the bucket itself, so a group published as a bare
        // window — `{"rate_limit": {"limit_window_seconds": 18000, "used_percent": 91}}` —
        // ingested NOTHING. A 91% limit rendered as an idle account, and in the
        // unmodelled-group case it did so with no warning at all: the invariant about not
        // deleting a window below ingestion never ran, because the window was deleted AT
        // ingestion. Detection is by field, so this costs one test and closes the whole
        // class.
        if isTemporalWindow(object) { result.windows.append(("self", object)) }

        for key in object.keys.sorted() {
            let value = object[key]
            guard let child = value as? [String: Any] else {
                if looksLikeWindowKey(key), present(value) { result.unreadableWindow = true }
                continue
            }
            if isTemporalWindow(child) {
                result.windows.append((key, child))
                continue
            }
            // Not a window itself — so it may be a wrapper around one (the shape every
            // feature-list entry uses).
            absorbThrottle(child)
            var contributed = false
            for inner in child.keys.sorted() {
                if let grandchild = child[inner] as? [String: Any], isTemporalWindow(grandchild) {
                    result.windows.append((key + "." + inner, grandchild))
                    contributed = true
                } else if looksLikeWindowKey(inner), present(child[inner]) {
                    result.unreadableWindow = true
                }
            }
            // SYMMETRY with the branch above, and it was missing: an object under a
            // window-shaped key that yielded no window is a window we failed to recognise,
            // exactly as a non-object under one is. Without this a vendor rename of the
            // two detection fields warned one level down and was silent one level up.
            if !contributed, looksLikeWindowKey(key) { result.unreadableWindow = true }
        }
        return result
    }

    // Projects one bucket into ZERO OR MORE windows. Zero happens only when the bucket
    // holds no window at all — a `null` bucket, or one whose windows are all `null`.
    // §5.2: A NULL WINDOW MEANS "NO DATA", NOT "0% USED". A window does not begin until a
    // real generation request is made, so a dormant window is genuinely absent rather
    // than zeroed, and rendering it as an empty bar would claim headroom nobody measured.
    // (Nothing in this app may start one: that would spend the user's real quota, which
    // is why the whole networking seam is GET-only.)
    private static func project(_ object: [String: Any],
                                scope: WindowScope,
                                name: String?,
                                ordinal: inout Int,
                                now: Date,
                                warnings: inout WarningLog) -> [Ingested] {
        let flat = flatten(object)
        if flat.unreadableWindow { warnings.add(Warning.unreadableWindow) }
        if flat.limitReached == true { warnings.add(Warning.limitReached) }
        if flat.allowed == false { warnings.add(Warning.notAllowed) }

        ordinal += 1
        let bucket = ordinal
        // ONE WINDOW PER TEMPORAL WINDOW FOUND — this loop is the flattening §5.2
        // requires, and the reason it iterates rather than taking the first is the entire
        // point of this file.
        var result: [Ingested] = []
        for entry in flat.windows {
            result.append(Ingested(
                window: window(from: entry.object,
                               scope: scope,
                               name: name,
                               multiple: flat.windows.count > 1,
                               limitReached: flat.limitReached == true,
                               now: now,
                               warnings: &warnings),
                // Unique across the payload: bucket ordinals are assigned once per bucket
                // and a window's path is unique within its bucket.
                origin: "b\(bucket).\(entry.key)",
                scopeToken: scopeToken(scope)
            ))
        }
        return result
    }

    // NON-OPTIONAL, deliberately: a window that reached this function has already been
    // recognised as one, and there is no field whose unreadability justifies deleting it.
    // Every degradation below keeps the figure and says so.
    private static func window(from object: [String: Any],
                               scope: WindowScope,
                               name: String?,
                               multiple: Bool,
                               limitReached: Bool,
                               now: Date,
                               warnings: inout WarningLog) -> UsageWindow {
        // §5.2: CLASSIFY BY DURATION, NEVER BY POSITION. On the observed Pro account
        // `primary_window` holds the WEEKLY window and `secondary_window` is null, so
        // "first is the session window" is wrong on the only real payload there is.
        // `WindowSpan(seconds:)` is the model's canonicalising factory, so this provider
        // cannot spell a span differently from the sibling (§3).
        let span: WindowSpan
        if let seconds = exactInteger(object["limit_window_seconds"]),
           (1...maximumWindowSeconds).contains(seconds) {
            span = WindowSpan(seconds: seconds)
        } else {
            span = WindowSpan(seconds: unstatedWindowSeconds)
            warnings.add(Warning.unstatedDuration)
        }

        let reset = timestamp(object, now: now)
        if reset == .unreadable { warnings.add(Warning.unreadableResetTime) }

        let utilization = self.utilization(object["used_percent"])
        return UsageWindow(
            id: WindowID(span: span, scope: scope),
            label: label(span: span, bucketName: name, multiple: multiple),
            utilization: utilization,
            resetsAt: reset.date,
            // The payload flags throttle state per BUCKET, not per window: `limit_reached`
            // says this bucket is what is currently binding. Marking its windows active
            // lets §7.2's single figure come from the constraint rather than from a
            // heuristic; when nothing is flagged, `bindingUtilization` falls back to the
            // worst known window, which is the correct answer for an unthrottled account.
            //
            // ONLY A WINDOW WITH A KNOWN FIGURE MAY BE MARKED BINDING. `bindingUtilization`
            // returns `.unknown` if ANY active window is unknown — deliberately, so an
            // unreadable constraint never hides behind a readable one — so marking a
            // bucket's null-percent window active blanks the figure of the very account
            // that is rate-limited. Measured: a throttled bucket with a null session
            // window and a 95% weekly window reported `.unknown` instead of 95%.
            isActive: limitReached && utilization != .unknown
        )
    }

    // Presentation only. The span word is derived from the model's own canonical cases,
    // not from a client-side map of vendor names (§5.1 forbids that) — a new feature
    // arrives with its payload-supplied label and no build.
    //
    // A bucket that contributes MORE THAN ONE window gets its span in the label, and only
    // then. Without it the popover shows one bucket's two windows under one identical
    // name, which is the one-bucket-many-windows case rendered as though the bug were
    // still present.
    static func label(span: WindowSpan, bucketName: String?, multiple: Bool) -> String {
        guard let bucketName, !bucketName.isEmpty else { return spanLabel(span) }
        return multiple ? spanLabel(span) + " · " + bucketName : bucketName
    }

    static func spanLabel(_ span: WindowSpan) -> String {
        switch span {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .other(let seconds): return seconds > 0 ? "\(seconds)s limit" : "Limit"
        }
    }

    // MARK: Scope identity

    // §3/§5.2: scope identity comes from the bucket's STABLE feature discriminator; its
    // display name supplies the LABEL only. Keying on display text splits one window's
    // history in two the day the vendor renames the feature.
    //
    // The chain degrades but never gives up, and every branch is namespaced so one branch
    // cannot alias another: a feature literally named `index:0` still cannot collide with
    // the positional fallback, because that one is `index:0` in a scope built from the
    // `index:` branch only when no discriminator existed at all.
    static func featureIdentity(of entry: [String: Any], index: Int) -> (id: String, name: String?) {
        let displayName = string(entry["limit_name"])
        if let feature = string(entry["metered_feature"]) {
            return ("feature:" + feature, displayName ?? humanised(feature))
        }
        if let displayName {
            // Display text as identity is a KNOWN weakness, taken deliberately over the
            // alternative, which is deleting a live reading. A rename splits this window's
            // threshold history; dropping it under-reports the account's usage, and
            // under-reporting is the failure this provider exists to prevent.
            return ("name:" + displayName, displayName)
        }
        // Last resort, and the only identity here derived from position: unstable under
        // vendor reordering, which costs that window's threshold state (§8). Accepted for
        // the same reason as above. Anything persisting per-window state must treat this
        // case as intentionally volatile.
        return ("index:\(index)", nil)
    }

    // Presentation only, derived from the payload's own words.
    static func humanised(_ token: String) -> String {
        let words = token.split(separator: "_").map(String.init)
        guard let first = words.first, !first.isEmpty else { return token }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }

    // MARK: Money

    // §5.2: `credits.balance` is a String (`"0"`) in observed payloads, and a Number in
    // others. Both shapes bind.
    //
    // ALWAYS UNQUALIFIED. This provider states no currency and no scale, so NEITHER may be
    // inferred (§3) — there is genuinely no scale here to preserve, and manufacturing one
    // would be the mirror image of the sibling's fix round, where a scale that WAS stated
    // got thrown away and rendered a 100× over-report that a test asserted was correct.
    static func unqualifiedAmount(_ value: Any?) -> MonetaryAmount? {
        if let number = numeric(value) { return .unqualified(raw: number.stringValue) }
        if let raw = string(value) { return .unqualified(raw: raw) }
        return nil
    }

    private static func spend(from root: [String: Any], warnings: inout WarningLog) -> Spend? {
        guard let credits = root["credits"] as? [String: Any] else {
            // Present but not an object is a read failure, not an absence, and the two
            // were silently indistinguishable.
            if present(root["credits"]) { warnings.add(Warning.unreadableCredits) }
            return nil
        }
        guard let balance = unqualifiedAmount(credits["balance"]) else {
            if present(credits["balance"]) { warnings.add(Warning.unreadableCredits) }
            return nil
        }
        // `used` and `limit` stay nil ON PURPOSE. The payload's other money-shaped field
        // (`spend_control.individual_limit`) was observed null and states neither a unit
        // nor a scale, so projecting it would require inventing both.
        return Spend(balance: balance)
    }

    // MARK: Scalars

    // `null` and absent both mean UNKNOWN, never zero (§3). There is no `?? 0` in this
    // file, and `Utilization` deliberately offers no accessor that would allow one.
    //
    // THE MAGNITUDE IS BOUNDED HERE, BEFORE THE MODEL SEES IT. `Utilization.percent(Double)`
    // guards `isFinite` and then does `Int(value.rounded())`, and that conversion TRAPS
    // outside `Int`'s range — measured on the sibling, a payload carrying `1e30` did not
    // under-report, it killed the process mid-poll (exit 133). The model's contract is
    // deliberately narrow; clamping belongs on this side of it.
    static func utilization(_ value: Any?) -> Utilization {
        guard let number = numeric(value) else { return .unknown }
        let raw = number.doubleValue
        guard raw.isFinite else { return .unknown }
        // The clamp is ASYMMETRIC on purpose. Clamping an over-large figure to 100 is
        // safe — it over-reports, and this provider exists to prevent under-reporting.
        // Clamping a NEGATIVE one to 0 is not: it turns a figure nobody can interpret into
        // a confident "0% used", manufacturing headroom, which is the one error §3 calls
        // out as actively misleading. A negative percentage is no percentage at all.
        guard raw >= 0 else { return .unknown }
        return Utilization.percent(min(100, raw))
    }

    // THREE OUTCOMES, NOT AN OPTIONAL. "No reset time was given" and "a reset time was
    // given and we could not read it" mean opposite things, and collapsing them lets an
    // unreadable value pass silently for a window that has never started.
    enum Timestamp: Equatable {
        case absent
        case parsed(Date)
        case unreadable

        var date: Date? {
            if case .parsed(let date) = self { return date }
            return nil
        }
    }

    // Two sources, and the RELATIVE one wins (§5.2). `reset_after_seconds` is a countdown
    // from the moment the response was produced, so it needs no agreement between this
    // machine's clock and the vendor's; `reset_at` is an absolute epoch second and
    // inherits whatever skew exists between them. Both are read, because a payload that
    // drops either must not lose its reset time.
    // BOTH FIELDS ARE READ, AND ONE UNREADABLE FIELD DOES NOT VETO THE OTHER. The first
    // draft returned `.unreadable` from the countdown branch without ever consulting the
    // epoch — so `{"reset_after_seconds": "soon", "reset_at": 1785000000}` produced no
    // reset time at all with a perfectly good absolute one sitting beside it. That is the
    // comment above contradicting the code beneath it, which is how the sibling's bug in
    // the same function survived its own review.
    //
    // Magnitudes are bounded for the same reason percentages are: `1e300` is not a reset
    // time, and handing §7 a date 1e300 seconds out is a figure presented as a fact.
    static func timestamp(_ object: [String: Any], now: Date) -> Timestamp {
        var unreadable = false

        let after = object["reset_after_seconds"]
        if present(after) {
            if let seconds = numeric(after)?.doubleValue,
               seconds.isFinite, (0...Double(maximumResetSeconds)).contains(seconds) {
                return .parsed(now.addingTimeInterval(seconds))
            }
            unreadable = true
        }

        let at = object["reset_at"]
        if present(at) {
            if let epoch = numeric(at)?.doubleValue,
               epoch.isFinite, (0...maximumResetEpoch).contains(epoch) {
                return .parsed(Date(timeIntervalSince1970: epoch))
            }
            unreadable = true
        }

        // Present and unreadable is NOT absent: the first says the window has started and
        // we failed to read when, the second says it has never started.
        return unreadable ? .unreadable : .absent
    }

    static func present(_ value: Any?) -> Bool {
        value != nil && !(value is NSNull)
    }

    static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    // JSON booleans bridge to `NSNumber`, so a plain `as? Bool` would also accept `1`.
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    // The ONLY integer conversion in this file. `NSNumber.intValue` silently wraps on
    // overflow and truncates a fraction, either of which turns an unreadable figure into a
    // confident wrong one — and here it would silently reclassify a window's span.
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
    // otherwise read as 1% used.
    static func numeric(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return number
    }
}

// MARK: - Endpoint

// §5.2: on 404, retry the alternate path and CACHE WHICHEVER ANSWERED — the path has
// moved before, and paying two round trips on every poll for the rest of the app's life
// is the cost of not remembering. An actor because §6 polls accounts concurrently.
actor CodexEndpointCache {
    private var chosen: URL?

    init(chosen: URL? = nil) {
        self.chosen = chosen
    }

    func current(default fallback: URL) -> URL { chosen ?? fallback }

    func record(_ url: URL) { chosen = url }
}

// MARK: - Provider

struct CodexProvider: UsageProvider {
    static let primaryEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let alternateEndpoint = URL(string: "https://chatgpt.com/api/codex/usage")!

    let kind: ProviderKind = .codex
    let presentation = ProviderPresentation(glyph: "✳", sectionTitle: "CODEX", sortOrder: 1)

    // Presentation only. §4.2 makes this a single-account provider, so there is no
    // directory name to label it with the way the sibling labels a profile.
    static let accountLabel = "Codex"

    private let reader: CodexAuthReader
    private let http: HTTPRequesting
    private let endpoints: CodexEndpointCache
    private let clock: () -> Date

    init(reader: CodexAuthReader,
         http: HTTPRequesting,
         endpoints: CodexEndpointCache = CodexEndpointCache(),
         clock: @escaping () -> Date = { Date() }) {
        self.reader = reader
        self.http = http
        self.endpoints = endpoints
        self.clock = clock
    }

    // The INCLUSION gate is the configuration directory; the STATE gate is the credential
    // (§4.1's split, applied here). A machine with no Codex configuration shows no Codex
    // account at all; one that has a configuration but no usable credential shows a
    // present account in a state that says which of the four things went wrong.
    func discoverAccounts() -> [DiscoveredAccount] {
        guard reader.isInstalled else { return [] }
        let read = reader.read()
        return [DiscoveredAccount(ref: CodexProvider.reference(for: read),
                                  state: CodexProvider.state(for: read))]
    }

    static func reference(for read: CodexAuthRead) -> AccountRef {
        switch read {
        case .usable(let credential):
            return AccountRef(
                id: AccountIdentity(provider: .codex, components: credential.identityComponents),
                label: accountLabel,
                subtitle: credential.emailAddress
            )
        case .fileMissing, .unsupportedAuthMode, .noAccessToken, .noDurableIdentity, .unreadable:
            // No credential to key on, and §3 forbids falling back to the location. The
            // sentinel cannot alias a real composite, which always has two differently
            // prefixed components.
            //
            // THE SENTINEL IS SHARED BETWEEN THESE STATES, so nothing may ever be
            // PERSISTED under it — otherwise two unrelated sign-ins would inherit each
            // other's cached readings and notification history, which is precisely the
            // misattribution §4.2 exists to prevent. That is not a convention: `fetch`
            // returns a failure for every one of these reads, so no `Snapshot` can be
            // produced carrying this identity, and §8 arms no threshold without one.
            return AccountRef(
                id: AccountIdentity(provider: .codex,
                                    CodexCredential.unresolvedIdentityComponent),
                label: accountLabel
            )
        }
    }

    static func state(for read: CodexAuthRead) -> AccountState {
        switch read {
        // Authenticated is not the same as fetched (§3): an account reaches `active` only
        // after a successful fetch, never at discovery.
        case .usable: return .pending
        // All three are "there is no usable subscription credential" — normal, and
        // user-actionable by signing in with the CLI.
        case .fileMissing, .unsupportedAuthMode, .noAccessToken: return .signedOut
        // NOT signedOut. Task 4's finding: a read fault rendered as a confident "you are
        // signed out" sends the user to re-authenticate a session that was never broken.
        case .unreadable(let fault): return .failed(fault)
        // Also not signedOut: the token works. It is `failed` because the app declines to
        // track an account whose persisted state it cannot keep apart from the next
        // sign-in's, and the user is told that rather than shown an empty row.
        case .noDurableIdentity:
            return .failed("this Codex sign-in published no durable account identifier")
        }
    }

    // §3: credential freshness is an invariant of THIS call. `auth.json` is re-read on
    // every fetch — the CLI rotates it (the observed file carries its own `last_refresh`)
    // — and nothing here retains the token beyond the length of one request.
    func fetch(_ account: AccountRef) async -> Result<FetchedSnapshot, FetchError> {
        let now = clock()
        // The configuration directory itself has gone: there is no Codex account on this
        // machine any more. TERMINAL — §6 retries a transport failure forever.
        guard reader.isInstalled else { return .failure(.accountUnknown) }

        let read = reader.read()

        // THE ORDER OF THESE TWO TESTS IS THE WHOLE POINT, and getting it wrong made every
        // branch below unreachable. `reference(for:)` resolves a non-usable read to the
        // shared sentinel, so an identity comparison placed FIRST answered "not this
        // account" for every unreadable, absent or wrong-mode credential — and returned
        // `.accountUnknown`, which §6 treats as terminal and drops. The CLI rewrites
        // `auth.json` on every token rotation, so a read landing mid-write is routine: one
        // unlucky poll permanently removed a healthy account, and no test could see it
        // because the classification below never ran. (Proven by the reviewer: replacing
        // both branch bodies with a trap left the suite green.)
        //
        // So the identity test applies ONLY where an identity actually exists. Everything
        // else is classified by what the read said, which is what §6's re-read-and-retry
        // contract needs in order to mean anything.
        guard case .usable(let credential) = read else {
            switch read {
            case .usable:
                // Unreachable: bound above.
                return .failure(.transport(message: "credential state changed mid-read"))
            case .fileMissing, .unsupportedAuthMode, .noAccessToken:
                // §6 decides expiry-vs-revoked, not this file: the store holds the re-read
                // credential and performs the one retry before concluding anything.
                return .failure(.authenticationRejected)
            case .noDurableIdentity:
                // Terminal, and deliberately so: no retry can make this account keyable,
                // and this is the guarantee that nothing is ever persisted under the
                // shared sentinel identity. Discovery keeps showing it as `failed`.
                return .failure(.accountUnknown)
            case .unreadable(let fault):
                // Transient by nature — a rewrite in flight, a locked volume — so §6 backs
                // off and tries again rather than dropping the account.
                return .failure(.transport(message: fault))
            }
        }

        guard CodexProvider.reference(for: read).id == account.id else {
            // A DIFFERENT account is signed in now. This is the only shape that justifies
            // terminal treatment from the credential side: no amount of retrying brings
            // the previous occupant back, and §6's periodic re-discovery is what surfaces
            // the new one.
            return .failure(.accountUnknown)
        }

        var headers = [
            "Authorization": "Bearer \(credential.accessToken)",
            "Accept": "application/json",
        ]
        // Omitted rather than sent empty when the credential published none: an empty
        // account header is a claim about the account, and a wrong one.
        if let accountIdentifier = credential.accountIdentifier {
            headers["X-Account-Id"] = accountIdentifier
        }

        let preferred = await endpoints.current(default: CodexProvider.primaryEndpoint)
        let alternate = preferred == CodexProvider.primaryEndpoint
            ? CodexProvider.alternateEndpoint
            : CodexProvider.primaryEndpoint

        for url in [preferred, alternate] {
            switch await http.get(HTTPRequest(url: url, headers: headers)) {
            case .failure(let message):
                // A network failure is not a moved path. Trying the alternate here would
                // double every timeout on a flaky connection and teach the cache nothing.
                return .failure(.transport(message: message))

            case .response(let status, let responseHeaders, let body):
                if status == 404 {
                    // The path has moved before (§5.2). Try the other one — and do NOT
                    // cache this one: caching a 404 would pin the app to a dead path for
                    // the rest of the process's life.
                    if url != alternate { continue }
                    return .failure(.unexpectedStatus(code: 404))
                }
                // Whichever ANSWERED is remembered, including with an error status: a 401
                // proves the path exists just as well as a 200 does, and paying two round
                // trips on every poll forever is the cost of not remembering.
                await endpoints.record(url)
                return CodexProvider.project(status: status,
                                             headers: responseHeaders,
                                             body: body,
                                             account: account,
                                             credential: credential,
                                             now: now)
            }
        }
        // Unreachable — the loop returns on every path — but the compiler cannot know the
        // list is non-empty. Named as the status it is rather than as a transport failure,
        // which §6 would retry on a timer forever.
        return .failure(.unexpectedStatus(code: 404))
    }

    private static func project(status: Int,
                                headers: [String: String],
                                body: Data,
                                account: AccountRef,
                                credential: CodexCredential,
                                now: Date) -> Result<FetchedSnapshot, FetchError> {
        switch status {
        case 200...299:
            break
        case 401, 403:
            return .failure(.authenticationRejected)
        case 429:
            // Normalised to seconds here; §6 owns the 60-second floor, and a floor applied
            // in two places is a floor that disagrees with itself.
            return .failure(.rateLimited(retryAfter: RetryAfter.seconds(
                from: HTTPHeaders.value("Retry-After", in: headers), now: now
            )))
        default:
            // Names the status only. The endpoint's error bodies are not ours to quote and
            // the request's headers hold a bearer token.
            return .failure(.unexpectedStatus(code: status))
        }

        switch CodexUsageParser.parse(body, now: now) {
        case .malformed(let fault):
            // The body travels WITH the failure: this is precisely the silent schema drift
            // §5's retention exists to diagnose.
            return .failure(.malformedResponse(message: fault, rawBody: body))

        case .parsed(let parsed):
            let snapshot = Snapshot(
                account: account,
                // §4.2: FROM THE LIVE RESPONSE, never from the credential's `id_token` —
                // the JWT's subscription claims are a cache and were observed a month
                // stale on an active account.
                planLabel: parsed.planLabel,
                windows: parsed.windows,
                spend: parsed.spend,
                fetchedAt: now,
                warnings: parsed.warnings
                    + credential.identityWarnings
                    + identityWarnings(credential: credential, parsed: parsed)
            )
            return .success(FetchedSnapshot(snapshot: snapshot, rawBody: body))
        }
    }

    enum Warning {
        // The OBSERVED NORMAL STATE on the target machine: the response's `account_id`
        // equals its own `user_id` while the request sent a UUID. §3 and §5.2 both require
        // this be surfaced and NEVER be a `FetchError` — treating it as one would render
        // the only real Codex account as a hard failure.
        static let ambiguousIdentifiers =
            "Codex reported the same identifier for the account and the user; "
            + "this account's usage is matched on the user identifier."
        // The dangerous one, and the reason the check exists at all: nothing in the
        // response matches the credential we sent, so these readings may belong to a
        // different account than the one on screen.
        static let identityDisagreement =
            "The Codex usage response does not match the signed-in account."
    }

    // §5.2 requires a disagreement between the credential's identifiers and the
    // response's to be SURFACED rather than silently reconciled to one field. The two
    // conditions are kept distinct because they mean different things: the first is the
    // vendor being ambiguous about its own identifiers, the second is a genuine mismatch
    // that would misattribute one account's readings to another.
    static func identityWarnings(credential: CodexCredential,
                                 parsed: CodexUsageParser.Parsed) -> [String] {
        let published = [parsed.accountIdentifier, parsed.userIdentifier].compactMap { $0 }
        guard !published.isEmpty else { return [] }
        var messages: [String] = []
        if let account = parsed.accountIdentifier,
           let user = parsed.userIdentifier,
           account == user {
            messages.append(Warning.ambiguousIdentifiers)
        }
        let known = [credential.accountIdentifier, credential.userIdentifier].compactMap { $0 }
        // ANY published identifier we do not recognise, not merely TOTAL disjointness.
        //
        // The first draft required every published identifier to be unknown, which left a
        // hole that warned about NOTHING in the case that matters most: a response naming
        // our user on one field and a DIFFERENT user on the other — `(user-A, user-B)`
        // against a credential of `(uuid-A, user-A)` — passed silently, because one half
        // matched. That is a partial match, which is the shape a genuine misattribution
        // takes; total disjointness is the shape a wholesale mix-up takes, and only the
        // second was covered.
        //
        // The observed normal state stays quiet, which is the constraint that makes this
        // usable at all: the response publishes its user id in BOTH fields, and both are
        // values we know, so nothing unrecognised appears.
        if !known.isEmpty, published.contains(where: { !known.contains($0) }) {
            messages.append(Warning.identityDisagreement)
        }
        return messages
    }
}
