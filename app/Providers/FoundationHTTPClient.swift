import Foundation

// The one place in the app that opens a socket. APP-ONLY: §10 keeps networking out of
// the test target, `build.sh` excludes this file by name and additionally greps the
// collected test sources for networking symbols, so a provider that reached for the
// system session directly would fail the build rather than quietly acquiring a
// dependency on the network in its unit tests.
//
// It contains no logic worth testing, by design: every decision — which headers to send,
// how to read a status, how to normalise `Retry-After`, how to project a body — lives in
// the pure provider. This type only moves bytes.
//
// SECRETS: the request headers carry a bearer token. Nothing here logs a request, a
// header, or a body; the error path carries `localizedDescription` of a transport error
// only (acceptance criterion 16's sibling rule in §5).
struct FoundationHTTPClient: HTTPRequesting {
    // Read-only by construction: `.get` is the only method ever set, and there is no
    // parameter that could change it.
    static let httpMethod = "GET"

    let timeout: TimeInterval

    private let session: URLSession

    init(timeout: TimeInterval = 15) {
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        // Ephemeral, and caching disabled outright: a cached 200 would present a stale
        // quota reading as a fresh one, which §6 spends a whole validity horizon
        // preventing on the storage side.
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    func get(_ request: HTTPRequest) async -> HTTPOutcome {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = FoundationHTTPClient.httpMethod
        urlRequest.timeoutInterval = timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (body, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "the response was not an HTTP response")
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                guard let name = name as? String, let value = value as? String else { continue }
                headers[name] = value
            }
            return .response(status: http.statusCode, headers: headers, body: body)
        } catch {
            // Names the failure, not the request: the request holds the token.
            return .failure(message: error.localizedDescription)
        }
    }
}
