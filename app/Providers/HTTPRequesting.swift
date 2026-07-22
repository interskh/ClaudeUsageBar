import Foundation

// The seam that keeps providers pure (§10). Providers describe a request and interpret
// a response; the concrete client that actually opens a socket lives in an APP-ONLY
// file, so the test target compiles the whole of a provider — headers, status mapping,
// parsing — without linking any networking at all. `build.sh` greps the collected test
// sources for networking symbols and fails loud, so this seam is enforced rather than
// merely intended.
//
// GET-only, deliberately: §1 makes the app read-only against both vendors, and a
// protocol with no verb but `get` cannot grow a write path by accident.

struct HTTPRequest: Equatable {
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

enum HTTPOutcome {
    // `headers` may arrive in any case; read it through `HTTPHeaders.value(_:in:)`.
    case response(status: Int, headers: [String: String], body: Data)

    // No response reached us at all. Carries a description of the FAILURE — never the
    // request, which holds a bearer token in its headers.
    case failure(message: String)
}

protocol HTTPRequesting {
    func get(_ request: HTTPRequest) async -> HTTPOutcome
}

enum HTTPHeaders {
    // HTTP field names are case-insensitive and the two vendors do not agree on
    // capitalisation. A dictionary subscript is case-SENSITIVE, so the obvious
    // `headers["Retry-After"]` silently misses a `retry-after` and the app then hammers
    // an endpoint that just told it to wait.
    static func value(_ name: String, in headers: [String: String]) -> String? {
        let wanted = name.lowercased()
        for (key, value) in headers where key.lowercased() == wanted { return value }
        return nil
    }
}

// §6 requires `Retry-After` to be honoured, and the header carries EITHER a number of
// seconds OR an HTTP-date. A parser that handles only the numeric form treats the date
// form as "no advice given" and retries immediately, which is the behaviour that earns a
// longer ban.
//
// The value returned here is the provider's normalisation only. §6's 60-second floor and
// the adaptive interval are the store's, so nothing here clamps upward: a floor applied
// in two places is a floor that will disagree with itself.
enum RetryAfter {
    static func seconds(from headerValue: String?, now: Date) -> TimeInterval? {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        // Delta-seconds. Non-negative by the grammar; a negative one is nonsense and
        // becomes "retry now" rather than a date in the past.
        if let delta = TimeInterval(raw), delta.isFinite { return max(0, delta) }

        guard let date = httpDate(raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    // All three forms HTTP allows. The obsolete two are rare, but parsing them costs two
    // format strings and failing to parse them costs an ignored throttle.
    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",   // RFC 1123 (the one anything modern sends)
        "EEEE, dd-MMM-yy HH:mm:ss zzz",    // RFC 850
        "EEE MMM d HH:mm:ss yyyy",         // asctime, no zone — GMT by definition
    ]

    static func httpDate(_ raw: String) -> Date? {
        for format in formats {
            let formatter = DateFormatter()
            // POSIX locale and a fixed zone: an HTTP-date is machine syntax, and reading
            // it through the user's locale makes the parse depend on the device's region.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
