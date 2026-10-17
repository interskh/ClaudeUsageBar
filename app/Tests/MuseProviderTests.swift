import Foundation

// Muse provider tests. Everything runs against sanitised fixtures, an in-memory
// filesystem, a fake token source, and a fake HTTP client. No token material is
// spelled out here; expected headers are rebuilt from the fixtures.
enum MuseProviderTests {

    private final class FakeFileSystem: ProfileFileSystem, @unchecked Sendable {
        var homeDirectoryPath: String
        var environment: [String: String] = [:]
        var directories: Set<String> = []
        var files: [String: Data] = [:]
        var unreadablePaths: Set<String> = []

        init(homeDirectoryPath: String) { self.homeDirectoryPath = homeDirectoryPath }

        func readFile(atPath path: String) -> FileReadResult {
            if unreadablePaths.contains(path) { return .unreadable("could not be read") }
            guard let data = files[path] else { return .missing }
            return .contents(data)
        }
        func environmentVariable(_ name: String) -> String? {
            guard let value = environment[name], !value.isEmpty else { return nil }
            return value
        }
        func isDirectory(atPath path: String) -> Bool { directories.contains(path) }
        func directoryEntries(atPath path: String) -> [String] { [] }
        func fileContents(atPath path: String) -> Data? { files[path] }
    }

    private final class FakeTokenSource: ClaudeCredentialSource, @unchecked Sendable {
        var lookup: CredentialLookup = .absent
        private(set) var services: [String] = []
        func lookupCredential(service: String) -> CredentialLookup {
            services.append(service)
            return lookup
        }
    }

    private final class FakeHTTP: HTTPRequesting, @unchecked Sendable {
        var outcome: HTTPOutcome = .failure(message: "not configured")
        private(set) var gets: [HTTPRequest] = []
        private(set) var posts: [HTTPRequest] = []

        func get(_ request: HTTPRequest) async -> HTTPOutcome {
            gets.append(request)
            return outcome
        }
        func post(_ request: HTTPRequest) async -> HTTPOutcome {
            posts.append(request)
            return outcome
        }
    }

    private static let home = "/fake/home"
    private static let configDirectory = home + "/.config/muse"
    private static let authPath = configDirectory + "/auth.json"
    private static let now = Date(timeIntervalSince1970: 1_784_800_000)

    private static func fixture(_ name: String) -> Data {
        let url = TestHarness.fixturesDirectory
            .appendingPathComponent("muse")
            .appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            fatalError("missing fixture: \(url.path)")
        }
        return data
    }

    private static func world(auth: String? = "auth-keychain.json",
                              installed: Bool = true) -> FakeFileSystem {
        let fs = FakeFileSystem(homeDirectoryPath: home)
        if installed { fs.directories = [home, configDirectory] }
        if let auth { fs.files[authPath] = fixture(auth) }
        return fs
    }

    private static func reader(_ fs: FakeFileSystem,
                               _ tokens: FakeTokenSource = FakeTokenSource()) -> MuseAuthReader {
        MuseAuthReader(fileSystem: fs, tokens: tokens, log: { _ in })
    }

    private static func provider(_ fs: FakeFileSystem,
                                 _ tokens: FakeTokenSource,
                                 _ http: FakeHTTP) -> MuseProvider {
        MuseProvider(reader: reader(fs, tokens), http: http, clock: { now })
    }

    private static func keychainTokens() -> FakeTokenSource {
        let tokens = FakeTokenSource()
        tokens.lookup = .found(fixture("keychain-blob.json"))
        return tokens
    }

    private static func discoveredRef(_ fs: FakeFileSystem,
                                      _ tokens: FakeTokenSource) -> AccountRef {
        MuseProvider(reader: reader(fs, tokens), http: FakeHTTP(), clock: { now })
            .discoverAccounts()[0].ref
    }

    // MARK: - Credential reading

    static func keychainTokenIsReadAndSiblingsAreDropped() {
        let tokens = keychainTokens()
        guard case .usable(let credential) = reader(world(), tokens).read() else {
            TestHarness.check("keychain-backed login is usable", false)
            return
        }
        TestHarness.check("keychain-backed login is usable", true)
        TestHarness.expect("token comes from the keychain blob",
                           credential.accessToken, "device-token-from-keychain")
        TestHarness.expect("identity keys on the auth file's email",
                           credential.identityComponents, ["email:user@example.com"])
        TestHarness.expect("the keychain service is the CLI's own",
                           tokens.services, [MuseAuthReader.keychainService])
        TestHarness.check("description never carries the token",
                          !credential.description.contains(credential.accessToken))
    }

    static func inlineTokenNeedsNoKeychain() {
        let tokens = FakeTokenSource()
        guard case .usable(let credential) = reader(world(auth: "auth-inline.json"), tokens).read() else {
            TestHarness.check("inline-token login is usable", false)
            return
        }
        TestHarness.expect("inline token is used", credential.accessToken, "inline-device-token")
        TestHarness.check("keychain is not consulted for an inline token", tokens.services.isEmpty)
    }

    static func apiKeyLoginIsNotAQuotaCredential() {
        TestHarness.expect("api-key mechanism is unsupported",
                           reader(world(auth: "auth-api-key.json"), keychainTokens()).read(),
                           .unsupportedMechanism)
    }

    static func keychainFaultPointsAtTheOneTimeGrant() {
        let tokens = FakeTokenSource()
        let fault = "keychain read for service \(MuseAuthReader.keychainService) timed out after 5s"
        tokens.lookup = .failed(fault)
        guard case .unreadable(let message) = reader(world(), tokens).read() else {
            TestHarness.check("a keychain fault is unreadable", false)
            return
        }
        TestHarness.check("the keychain fault is kept", message.contains(fault))
        TestHarness.check("the fault points at the one-time Keychain grant",
                          message.contains(MuseAuthReader.keychainGrantHint))
    }

    static func noEmailMeansNoDurableIdentity() {
        TestHarness.expect("a token with no email cannot be keyed",
                           reader(world(auth: "auth-no-email.json"), keychainTokens()).read(),
                           .noDurableIdentity)
    }

    static func missingKeychainItemIsSignedOutNotFailed() {
        let provider = MuseProvider(reader: reader(world(), FakeTokenSource()),
                                    http: FakeHTTP(), clock: { now })
        let accounts = provider.discoverAccounts()
        TestHarness.expect("one account is discovered", accounts.count, 1)
        guard case .signedOut = accounts[0].state else {
            TestHarness.check("absent keychain item reads as signed out", false)
            return
        }
        TestHarness.check("absent keychain item reads as signed out", true)
    }

    static func noConfigDirectoryMeansNoAccount() {
        let provider = MuseProvider(reader: reader(world(installed: false), keychainTokens()),
                                    http: FakeHTTP(), clock: { now })
        TestHarness.check("no config directory, no account",
                          provider.discoverAccounts().isEmpty)
    }

    // MARK: - Parsing

    static func liveShapeProjectsTwoWindowsAndThePlan() {
        guard case .parsed(let parsed) = MuseUsageParser.parse(fixture("usage-live.json")) else {
            TestHarness.check("live shape parses", false)
            return
        }
        TestHarness.expect("two windows are projected", parsed.windows.count, 2)
        TestHarness.expect("rolling window is the session span",
                           parsed.windows[0].id.span, .session)
        TestHarness.expect("rolling window reads 24%",
                           parsed.windows[0].utilization, .known(24))
        TestHarness.expect("rolling reset is projected",
                           parsed.windows[0].resetsAt,
                           Date(timeIntervalSince1970: 1_789_568_145))
        TestHarness.expect("weekly window is the weekly span",
                           parsed.windows[1].id.span, .weekly)
        TestHarness.expect("plan comes from the tier name, not the numeric id",
                           parsed.planLabel, "Muse Code Power Usage")
        TestHarness.check("a healthy payload warns about nothing", parsed.warnings.isEmpty)
    }

    static func idleIsExplainedAndNeverInventedAsZero() {
        guard case .parsed(let parsed) = MuseUsageParser.parse(fixture("usage-idle.json")) else {
            TestHarness.check("idle shape parses", false)
            return
        }
        TestHarness.check("idle projects no windows", parsed.windows.isEmpty)
        TestHarness.expect("idle is explained", parsed.warnings, [MuseUsageParser.Warning.idle])
        TestHarness.expect("the plan still shows while idle",
                           parsed.planLabel, "Muse Code Power Usage")
    }

    static func inactiveSubscriptionShowsNoWindows() {
        guard case .parsed(let parsed) = MuseUsageParser.parse(fixture("usage-inactive.json")) else {
            TestHarness.check("inactive shape parses", false)
            return
        }
        TestHarness.check("inactive projects no windows", parsed.windows.isEmpty)
        TestHarness.expect("inactive is explained",
                           parsed.warnings, [MuseUsageParser.Warning.inactive])
    }

    static func doublePercentsRoundAndOverQuotaClamps() {
        guard case .parsed(let parsed) = MuseUsageParser.parse(fixture("usage-double-percent.json")) else {
            TestHarness.check("double-percent shape parses", false)
            return
        }
        TestHarness.expect("45.5 rounds to 46", parsed.windows[0].utilization, .known(46))
        TestHarness.expect("101 clamps to 100", parsed.windows[1].utilization, .known(100))
    }

    static func missingSubscriptionBlockIsMalformed() {
        guard case .malformed = MuseUsageParser.parse(Data("{}".utf8)) else {
            TestHarness.check("a body with no subscription block is malformed", false)
            return
        }
        TestHarness.check("a body with no subscription block is malformed", true)
    }

    static func sanitizedDiagnosticDropsTheMintedKey() {
        let clean = MuseUsageParser.sanitizedDiagnostic(fixture("usage-live.json"))
        let text = String(decoding: clean, as: UTF8.self)
        TestHarness.check("diagnostic keeps the usage block", text.contains("subs_usage"))
        TestHarness.check("diagnostic drops the minted key", !text.contains("minted-key-must-not-leak"))
        TestHarness.check("diagnostic drops the email", !text.contains("user@example.com"))
    }

    // MARK: - Fetch

    static func fetchPostsTheKeyMintCallWithTheDeviceToken() {
        let http = FakeHTTP()
        http.outcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        let fs = world()
        let tokens = keychainTokens()
        let result = awaitResult { await provider(fs, tokens, http).fetch(discoveredRef(fs, tokens)) }
        guard case .success(let fetched) = result else {
            TestHarness.check("fetch succeeds", false)
            return
        }
        TestHarness.expect("exactly one POST is issued", http.posts.count, 1)
        TestHarness.check("no GET is issued", http.gets.isEmpty)
        TestHarness.expect("the POST goes to the key endpoint",
                           http.posts[0].url, MuseProvider.keyEndpoint)
        TestHarness.expect("the device token is the bearer",
                           http.posts[0].headers["Authorization"], "Bearer device-token-from-keychain")
        TestHarness.expect("the snapshot carries both windows", fetched.snapshot.windows.count, 2)
        let retained = String(decoding: fetched.rawBody, as: UTF8.self)
        TestHarness.check("the retained body drops the minted key",
                          !retained.contains("minted-key-must-not-leak"))
    }

    static func statusCodesMapOntoTheErrorContract() {
        func fetchError(_ status: Int) -> FetchError? {
            let http = FakeHTTP()
            http.outcome = .response(status: status, headers: [:], body: Data())
            let fs = world()
            let tokens = keychainTokens()
            let result = awaitResult { await provider(fs, tokens, http).fetch(discoveredRef(fs, tokens)) }
            guard case .failure(let error) = result else { return nil }
            return error
        }
        TestHarness.expect("401 is an authentication rejection",
                           fetchError(401), .authenticationRejected)
        TestHarness.expect("429 is rate limited",
                           fetchError(429), .rateLimited(retryAfter: nil))
        TestHarness.expect("500 names its status",
                           fetchError(500), .unexpectedStatus(code: 500))
    }

    static func signedOutFetchIsAnAuthenticationRejection() {
        let http = FakeHTTP()
        let fs = world()
        let tokens = FakeTokenSource()
        let ref = MuseProvider.reference(for: reader(fs, tokens).read())
        let result = awaitResult { await provider(fs, tokens, http).fetch(ref) }
        guard case .failure(let error) = result else {
            TestHarness.check("signed-out fetch fails", false)
            return
        }
        TestHarness.expect("signed-out fetch is an authentication rejection",
                           error, .authenticationRejected)
        TestHarness.check("no request is issued without a token", http.posts.isEmpty)
    }

    private static func awaitResult<T>(_ operation: @escaping () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        guard let value = box.value else { fatalError("async operation produced no value") }
        return value
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    static func run() {
        keychainTokenIsReadAndSiblingsAreDropped()
        inlineTokenNeedsNoKeychain()
        apiKeyLoginIsNotAQuotaCredential()
        noEmailMeansNoDurableIdentity()
        keychainFaultPointsAtTheOneTimeGrant()
        missingKeychainItemIsSignedOutNotFailed()
        noConfigDirectoryMeansNoAccount()
        liveShapeProjectsTwoWindowsAndThePlan()
        idleIsExplainedAndNeverInventedAsZero()
        inactiveSubscriptionShowsNoWindows()
        doublePercentsRoundAndOverQuotaClamps()
        missingSubscriptionBlockIsMalformed()
        sanitizedDiagnosticDropsTheMintedKey()
        fetchPostsTheKeyMintCallWithTheDeviceToken()
        statusCodesMapOntoTheErrorContract()
        signedOutFetchIsAnAuthenticationRejection()
    }
}
