import Foundation

// Muse usage fetch and projection. PURE: the credential reader and the network both
// arrive through injected protocols, so this file compiles into the test target.
//
// Muse publishes no GET usage endpoint. The CLI's own startup call —
// `POST https://api.meta.ai/muse-code/key`, made with the `muse login` device token —
// returns the subscription block (`subs_usage`) beside the key it mints: a rolling
// window (300 minutes today) and a weekly window, each a used percent plus a reset
// epoch. That call is the quota source. The minted key in the same response is a
// secret this app has no use for: it is never retained, never logged, and never
// included in the retained diagnostic body (see `sanitizedDiagnostic`).
//
// The response is also the reason this seam needed a POST at all. The OAuth device
// token itself is only ever read, never written, refreshed, or rotated — locally this
// app stays read-only exactly as with the other providers.

enum MuseUsageParser {
    static let weeklyWindowSeconds = 604_800
    static let defaultWindowMinutes = 300
    static let maximumResetEpoch: Double = 4_102_444_800  // 2100-01-01T00:00:00Z

    struct Parsed: Equatable {
        let windows: [UsageWindow]
        let planLabel: String?
        let warnings: [String]
    }

    enum Outcome: Equatable {
        case parsed(Parsed)
        case malformed(String)
    }

    enum Warning {
        static let idle =
            "Muse reported no active usage window; the account may be idle."
        static let inactive = "This Muse subscription is not active."
        static let requirePayment = "This Muse subscription needs a payment method."
        static let unreadableWindow =
            "A Muse usage limit arrived in a form this version cannot read."
    }

    static func parse(_ data: Data) -> Outcome {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed("usage response is not a JSON object")
        }
        // The subscription block IS the payload. Its total absence across every known
        // key is schema drift, so it fails loud rather than degrading to an empty —
        // and therefore reassuring — snapshot.
        guard root.keys.contains("subs_usage") || root.keys.contains("is_subs_active")
                || root.keys.contains("subs_tier_name") else {
            return .malformed("usage response carries no subscription block")
        }

        var warnings: [String] = []
        let subsActive = bool(root["is_subs_active"])
        if subsActive == false { warnings.append(Warning.inactive) }
        if bool(root["require_payment"]) == true { warnings.append(Warning.requirePayment) }

        var windows: [UsageWindow] = []
        if subsActive != false, let usage = root["subs_usage"] as? [String: Any] {
            if let rolling = window(from: usage["window"], isWeekly: false) {
                windows.append(rolling)
            } else if present(usage["window"]) {
                warnings.append(Warning.unreadableWindow)
            }
            if let weekly = window(from: usage["weekly"], isWeekly: true) {
                windows.append(weekly)
            } else if present(usage["weekly"]) {
                warnings.append(Warning.unreadableWindow)
            }
        }
        if windows.isEmpty, subsActive != false, !warnings.contains(Warning.idle) {
            // Meta omits `subs_usage` while the rolling window has never started. An
            // idle account is a fact to say out loud, not a 0% to invent.
            warnings.append(Warning.idle)
        }

        return .parsed(Parsed(windows: windows,
                              planLabel: string(root["subs_tier_name"]),
                              warnings: warnings))
    }

    private static func window(from value: Any?, isWeekly: Bool) -> UsageWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let minutes = exactInteger(object["window_duration_mins"]) ?? (isWeekly ? nil : defaultWindowMinutes)
        let span: WindowSpan
        if isWeekly {
            span = .weekly
        } else if let minutes, minutes > 0 {
            span = WindowSpan(seconds: minutes * 60)
        } else {
            span = WindowSpan(seconds: defaultWindowMinutes * 60)
        }
        let resetsAt: Date?
        if let epoch = numeric(object["resets_at"])?.doubleValue,
           epoch.isFinite, (0...maximumResetEpoch).contains(epoch) {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else {
            resetsAt = nil
        }
        return UsageWindow(
            id: WindowID(span: span, scope: .account),
            label: isWeekly ? "Weekly" : "Session",
            utilization: utilization(object["used_percent"]),
            resetsAt: resetsAt,
            isActive: false
        )
    }

    // `null` and absent both mean UNKNOWN, never zero. A negative figure is no figure
    // at all; an over-100 figure is clamped by the model's single rounding entry.
    static func utilization(_ value: Any?) -> Utilization {
        guard let number = numeric(value) else { return .unknown }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 0 else { return .unknown }
        return Utilization.percent(min(100, raw))
    }

    // The retained diagnostic body (§5) must never carry the minted key or any token
    // material from this response. Only the subscription block survives sanitising.
    static func sanitizedDiagnostic(_ data: Data) -> Data {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Data()
        }
        var safe: [String: Any] = [:]
        for key in ["subs_usage", "subs_tier_name", "subs_tier_id", "is_subs_active",
                    "require_payment", "has_payment_method", "can_subscribe"] {
            if let value = root[key] { safe[key] = value }
        }
        return (try? JSONSerialization.data(withJSONObject: safe)) ?? Data()
    }

    static func present(_ value: Any?) -> Bool {
        value != nil && !(value is NSNull)
    }

    static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    static func exactInteger(_ value: Any?) -> Int? {
        guard let number = numeric(value) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, abs(double) <= 9_007_199_254_740_992 else { return nil }
        let integer = number.intValue
        guard Double(integer) == double else { return nil }
        return integer
    }

    static func numeric(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return number
    }
}

// MARK: - Provider

struct MuseProvider: UsageProvider {
    static let keyEndpoint = URL(string: "https://api.meta.ai/muse-code/key")!
    static let apiVersion = "1.0.0"

    let kind: ProviderKind = .muse
    let presentation = ProviderPresentation(glyph: "✦", sectionTitle: "MUSE", sortOrder: 2)

    static let accountLabel = "Muse"

    private let reader: MuseAuthReader
    private let http: HTTPRequesting
    private let clock: () -> Date

    init(reader: MuseAuthReader,
         http: HTTPRequesting,
         clock: @escaping () -> Date = { Date() }) {
        self.reader = reader
        self.http = http
        self.clock = clock
    }

    func discoverAccounts() -> [DiscoveredAccount] {
        guard reader.isInstalled else { return [] }
        let read = reader.read()
        return [DiscoveredAccount(ref: MuseProvider.reference(for: read),
                                  state: MuseProvider.state(for: read))]
    }

    static func reference(for read: MuseAuthRead) -> AccountRef {
        switch read {
        case .usable(let credential):
            return AccountRef(
                id: AccountIdentity(provider: .muse, components: credential.identityComponents),
                label: accountLabel,
                subtitle: credential.emailAddress
            )
        case .fileMissing, .unsupportedMechanism, .noAccessToken, .noDurableIdentity, .unreadable:
            // Shared sentinel, as with Codex: `fetch` fails for every one of these
            // reads, so nothing is ever persisted under it.
            return AccountRef(
                id: AccountIdentity(provider: .muse, MuseCredential.unresolvedIdentityComponent),
                label: accountLabel
            )
        }
    }

    static func state(for read: MuseAuthRead) -> AccountState {
        switch read {
        case .usable: return .pending
        case .fileMissing, .unsupportedMechanism, .noAccessToken: return .signedOut
        case .unreadable(let fault): return .failed(fault)
        case .noDurableIdentity:
            return .failed("this Muse sign-in published no durable account identifier")
        }
    }

    func fetch(_ account: AccountRef) async -> Result<FetchedSnapshot, FetchError> {
        let now = clock()
        guard reader.isInstalled else { return .failure(.accountUnknown) }

        let read = reader.read()
        guard case .usable(let credential) = read else {
            switch read {
            case .usable:
                return .failure(.transport(message: "credential state changed mid-read"))
            case .fileMissing, .unsupportedMechanism, .noAccessToken:
                return .failure(.authenticationRejected)
            case .noDurableIdentity:
                return .failure(.accountUnknown)
            case .unreadable(let fault):
                return .failure(.transport(message: fault))
            }
        }
        guard MuseProvider.reference(for: read).id == account.id else {
            return .failure(.accountUnknown)
        }

        let request = HTTPRequest(
            url: MuseProvider.keyEndpoint,
            headers: [
                "Authorization": "Bearer \(credential.accessToken)",
                "X-Api-Version": MuseProvider.apiVersion,
                "Accept": "application/json",
                "Content-Type": "application/json",
            ],
            method: "POST",
            body: Data("{}".utf8)
        )

        switch await http.post(request) {
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
                return .failure(.unexpectedStatus(code: status))
            }
            switch MuseUsageParser.parse(body) {
            case .malformed(let fault):
                return .failure(.malformedResponse(
                    message: fault, rawBody: MuseUsageParser.sanitizedDiagnostic(body)))
            case .parsed(let parsed):
                let snapshot = Snapshot(
                    account: account,
                    planLabel: parsed.planLabel,
                    windows: parsed.windows,
                    fetchedAt: now,
                    warnings: parsed.warnings
                )
                return .success(FetchedSnapshot(
                    snapshot: snapshot, rawBody: MuseUsageParser.sanitizedDiagnostic(body)))
            }
        }
    }
}
