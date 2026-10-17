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
        var delay: TimeInterval = 0
        private(set) var services: [String] = []
        func lookupCredential(service: String) -> CredentialLookup {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
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
                               _ tokens: ClaudeCredentialSource = FakeTokenSource()) -> MuseAuthReader {
        MuseAuthReader(fileSystem: fs, tokens: tokens, log: { _ in })
    }

    private static func provider(_ fs: FakeFileSystem,
                                 _ tokens: ClaudeCredentialSource,
                                 _ http: FakeHTTP) -> MuseProvider {
        MuseProvider(reader: reader(fs, tokens), http: http, clock: { now })
    }

    private static func keychainTokens() -> FakeTokenSource {
        let tokens = FakeTokenSource()
        tokens.lookup = .found(fixture("keychain-blob.json"))
        return tokens
    }

    private static func discoveredRef(_ fs: FakeFileSystem,
                                      _ tokens: ClaudeCredentialSource) -> AccountRef {
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

    static func keychainFaultPointsAtTheConnectInstruction() {
        let tokens = FakeTokenSource()
        let fault = "keychain read for service \(MuseAuthReader.keychainService) timed out after 5s"
        tokens.lookup = .failed(fault)
        guard case .unreadable(let message) = reader(world(), tokens).read() else {
            TestHarness.check("a keychain fault is unreadable", false)
            return
        }
        TestHarness.check("the keychain fault is kept", message.contains(fault))
        TestHarness.check("the fault points at the connect instruction",
                          message.contains(MuseAuthReader.connectInstruction))
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

    // MARK: - Keychain gate

    private static let email = "user@example.com"

    // What the shell does for a user Refresh: record the arm, then let the owning survey
    // activate it as it starts.
    @discardableResult
    private static func activate(_ gate: MuseKeychainGate) -> MuseKeychainGate.ArmTicket? {
        let ticket = gate.arm()
        gate.beginSurvey(ticket)
        return ticket
    }

    private static func gated(_ inner: FakeTokenSource) -> MuseKeychainGate {
        MuseKeychainGate(inner: inner)
    }

    private static func cardState(_ fs: FakeFileSystem, _ gate: MuseKeychainGate) -> AccountState? {
        MuseProvider(reader: reader(fs, gate), http: FakeHTTP(), clock: { now })
            .discoverAccounts().first?.state
    }

    private static func isFailed(_ state: AccountState?, _ message: String) -> Bool {
        if case .failed(let text)? = state { return text == message }
        return false
    }

    static func unarmedGateNeverReadsAndAsksToConnect() {
        let inner = keychainTokens()
        let gate = gated(inner)
        let state = cardState(world(), gate)
        TestHarness.check("an unarmed gate never reads the keychain", inner.services.isEmpty)
        TestHarness.check("the card shows the connect instruction alone",
                          isFailed(state, MuseAuthReader.connectInstruction))
        TestHarness.expect("the read maps to notConnected",
                           reader(world(), gate).read(), .notConnected)
        let http = FakeHTTP()
        let fs = world()
        let ref = MuseProvider.reference(for: reader(fs, gate).read())
        let result = awaitResult { await provider(fs, gate, http).fetch(ref) }
        TestHarness.expect("an unconnected fetch is not an authentication rejection",
                           result.failureValue,
                           .transport(message: MuseAuthReader.connectInstruction))
        TestHarness.check("an unconnected fetch sends nothing", http.posts.isEmpty)
        TestHarness.check("the fetch did not read the keychain either", inner.services.isEmpty)
    }

    static func armedGateReadsOnceThenServesTheCache() {
        let inner = keychainTokens()
        let gate = gated(inner)
        TestHarness.check("arming an empty gate reports it", activate(gate) != nil)
        guard case .usable(let first) = reader(world(), gate).read() else {
            TestHarness.check("an armed read is usable", false)
            return
        }
        TestHarness.expect("the armed read returns the token", first.accessToken, "device-token-from-keychain")
        TestHarness.expect("exactly one real read per arm", inner.services.count, 1)
        TestHarness.check("the arm is spent", !gate.isArmed)
        for _ in 0..<3 { _ = reader(world(), gate).read() }
        TestHarness.expect("later reads hit the cache", inner.services.count, 1)
        TestHarness.check("arming while cached is a no-op", gate.arm() == nil && !gate.isArmed)
    }

    static func concurrentCallersShareOneRead() {
        let inner = keychainTokens()
        inner.delay = 0.05
        let gate = gated(inner)
        activate(gate)
        let found = Box<Int>()
        found.value = 0
        let tally = NSLock()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if case .found = gate.lookupCredential(service: MuseAuthReader.keychainService, boundTo: email) {
                tally.lock()
                found.value = (found.value ?? 0) + 1
                tally.unlock()
            }
        }
        TestHarness.expect("concurrent callers issue one real read", inner.services.count, 1)
        TestHarness.expect("concurrent callers wait and then see the cache", found.value, 8)
    }

    static func cachedBlobCarriesOnlyTheAccessToken() {
        let gate = gated(keychainTokens())
        activate(gate)
        for round in ["armed", "cached"] {
            guard case .found(let blob) = gate.lookupCredential(service: MuseAuthReader.keychainService, boundTo: email),
                  let object = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any]
            else {
                TestHarness.check("\(round) lookup returns a blob", false)
                continue
            }
            TestHarness.expect("\(round) blob carries only access_token",
                               Array(object.keys), ["access_token"])
            TestHarness.expect("\(round) blob keeps the token",
                               MuseAuthReader.token(inKeychainBlob: blob), "device-token-from-keychain")
            TestHarness.check("\(round) blob drops sibling secrets",
                              !String(decoding: blob, as: UTF8.self).contains("minted-key-must-not-leak"))
        }
    }

    static func failedReadIsNotCached() {
        let inner = FakeTokenSource()
        let fault = "keychain read for service \(MuseAuthReader.keychainService) timed out after 5s"
        inner.lookup = .failed(fault)
        let gate = gated(inner)
        activate(gate)
        let state = cardState(world(), gate)
        TestHarness.check("the card shows the fault and the connect instruction",
                          isFailed(state, fault + "; " + MuseAuthReader.connectInstruction))
        TestHarness.expect("the denied read happened once", inner.services.count, 1)
        TestHarness.check("a denied card still invites a Refresh to connect",
                          MuseAuthReader.isWaitingToConnect(state ?? .pending))
        TestHarness.check("the bare connect state invites a Refresh",
                          MuseAuthReader.isWaitingToConnect(.failed(MuseAuthReader.connectInstruction)))
        TestHarness.check("other failures do not arm",
                          !MuseAuthReader.isWaitingToConnect(.failed("network: down"))
                              && !MuseAuthReader.isWaitingToConnect(.signedOut))
        TestHarness.check("a failed read spends the arm", !gate.isArmed)
        TestHarness.expect("the next unarmed read is not connected",
                           reader(world(), gate).read(), .notConnected)
        TestHarness.expect("and does not touch the keychain", inner.services.count, 1)
    }

    static func absentItemIsSignedOutAndNotCached() {
        let inner = FakeTokenSource()
        let gate = gated(inner)
        activate(gate)
        guard case .signedOut? = cardState(world(), gate) else {
            TestHarness.check("an absent item reads as signed out", false)
            return
        }
        TestHarness.check("an absent item reads as signed out", true)
        TestHarness.expect("the next unarmed read is not connected",
                           reader(world(), gate).read(), .notConnected)
        TestHarness.expect("and does not touch the keychain", inner.services.count, 1)
    }

    static func invalidateReturnsToTheConnectState() {
        let inner = keychainTokens()
        let gate = gated(inner)
        activate(gate)
        _ = reader(world(), gate).read()
        gate.invalidate()
        TestHarness.check("the card asks to connect again",
                          isFailed(cardState(world(), gate), MuseAuthReader.connectInstruction))
        TestHarness.expect("invalidation never re-reads", inner.services.count, 1)
        TestHarness.check("invalidation does not arm", !gate.isArmed)
    }

    static func inlineTokenNeverTouchesTheTokenSource() {
        let inner = keychainTokens()
        let inlineWorld = world(auth: "auth-inline.json")
        let inlineReader = reader(inlineWorld, inner)
        TestHarness.expect("an inline token digests the auth file",
                           inlineReader.credentialMaterial(), fixture("auth-inline.json"))
        TestHarness.check("the keychain is not consulted for the digest", inner.services.isEmpty)

        TestHarness.expect("a keychain-backed login digests the token source",
                           reader(world(), inner).credentialMaterial(), fixture("keychain-blob.json"))
        TestHarness.expect("the token source was consulted", inner.services.count, 1)
        inner.lookup = .failed("denied")
        TestHarness.expect("a failed token source falls back to the auth file",
                           reader(world(), inner).credentialMaterial(), fixture("auth-keychain.json"))
    }

    static func surveyThatNeverReachesTheGateWithdrawsItsArm() {
        let inner = keychainTokens()
        let gate = gated(inner)
        let ticket = activate(gate)
        TestHarness.check("a begun survey activates the arm", gate.isArmed)
        gate.endSurvey(ticket)
        TestHarness.check("the survey's end withdraws the arm", !gate.isArmed)
        TestHarness.expect("a later background lookup is not connected",
                           reader(world(), gate).read(), .notConnected)
        TestHarness.check("and never reads the keychain", inner.services.isEmpty)

        let older = gate.arm()
        let newer = gate.arm()
        gate.beginSurvey(older)
        TestHarness.check("a superseded ticket activates nothing", !gate.isArmed)
        gate.beginSurvey(newer)
        gate.endSurvey(older)
        TestHarness.check("a stale survey's end does not withdraw the newer arm", gate.isArmed)
        gate.endSurvey(newer)
        TestHarness.check("the newer arm is withdrawn by its own survey", !gate.isArmed)
        gate.endSurvey(nil)
    }

    static func pendingArmIsOnlyConsumedByItsOwnSurvey() {
        let inner = FakeTokenSource()
        let fault = "keychain read for service \(MuseAuthReader.keychainService) timed out after 5s"
        inner.lookup = .failed(fault)
        let gate = gated(inner)
        let ticket = gate.arm()
        TestHarness.expect("a survey that did not start with the ticket reads nothing",
                           reader(world(), gate).read(), .notConnected)
        TestHarness.check("so the pending arm is untouched by it", inner.services.isEmpty)
        gate.beginSurvey(ticket)
        guard case .unreadable(let message) = reader(world(), gate).read() else {
            TestHarness.check("the owning survey reads under the arm", false)
            return
        }
        TestHarness.check("the denial message is kept", message.hasPrefix(fault))
        TestHarness.expect("the arm is consumed exactly once", inner.services.count, 1)
        _ = reader(world(), gate).read()
        TestHarness.expect("a second lookup in the same survey does not read again",
                           inner.services.count, 1)
        gate.endSurvey(ticket)
        TestHarness.check("ending the consumed survey is harmless", !gate.isArmed)
    }

    static func cachedTokenIsBoundToItsAccount() {
        let inner = keychainTokens()
        let gate = gated(inner)
        activate(gate)
        TestHarness.check("the owner account connects", {
            if case .usable = reader(world(), gate).read() { return true }
            return false
        }())
        let other = FakeFileSystem(homeDirectoryPath: home)
        other.directories = [home, configDirectory]
        other.files[authPath] = Data(String(decoding: fixture("auth-keychain.json"), as: UTF8.self)
            .replacingOccurrences(of: "user@example.com", with: "other@example.com").utf8)
        TestHarness.expect("a different login never gets the cached token",
                           reader(other, gate).read(), .notConnected)
        TestHarness.expect("and the cache is dropped, so the first account is not served either",
                           reader(world(), gate).read(), .notConnected)
        TestHarness.expect("no read happened for the new login", inner.services.count, 1)
        TestHarness.expect("an email-less file is a cache miss",
                           reader(world(auth: "auth-no-email.json"), gate).read(), .notConnected)
        let retry = gated(keychainTokens())
        activate(retry)
        TestHarness.expect("an email-less login has no durable identity",
                           reader(world(auth: "auth-no-email.json"), retry).read(), .noDurableIdentity)
        TestHarness.check("and its token is not cached, so the user can retry", retry.arm() != nil)
    }

    static func signedOutStatesDropTheCachedToken() {
        func connected() -> (MuseKeychainGate, FakeTokenSource) {
            let inner = keychainTokens()
            let gate = gated(inner)
            activate(gate)
            _ = reader(world(), gate).read()
            return (gate, inner)
        }
        for (name, fs) in [("missing auth file", world(auth: nil)),
                           ("api-key login", world(auth: "auth-api-key.json")),
                           ("inline token", world(auth: "auth-inline.json"))] {
            let (gate, _) = connected()
            _ = reader(fs, gate).read()
            TestHarness.expect("\(name) drops the cache",
                               reader(world(), gate).read(), .notConnected)
        }
    }

    static func invalidateDuringAReadWinsAndNeverBlocks() {
        let inner = keychainTokens()
        inner.delay = 0.3
        let gate = gated(inner)
        activate(gate)
        let reading = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = gate.lookupCredential(service: MuseAuthReader.keychainService, boundTo: email)
            reading.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        let started = Date()
        gate.invalidate()
        let ticket = gate.arm()
        _ = gate.isArmed
        gate.endSurvey(ticket)
        TestHarness.check("main-actor calls do not wait on the in-flight read",
                          Date().timeIntervalSince(started) < 0.1)
        reading.wait()
        TestHarness.expect("the read happened once", inner.services.count, 1)
        TestHarness.expect("a mid-read invalidation leaves the cache empty",
                           reader(world(), gate).read(), .notConnected)
        TestHarness.expect("and nothing re-reads", inner.services.count, 1)
    }

    static func notConnectedKeepsTheEmailIdentity() {
        let fs = world()
        let gate = gated(keychainTokens())
        let account = MuseProvider(reader: reader(fs, gate), http: FakeHTTP(), clock: { now })
            .discoverAccounts()[0]
        TestHarness.expect("the not-connected card keys on the email",
                           account.ref.id.storageKey,
                           AccountIdentity(provider: .muse, components: ["email:user@example.com"]).storageKey)
        activate(gate)
        TestHarness.expect("connecting keeps the same identity",
                           discoveredRef(fs, gate).id.storageKey, account.ref.id.storageKey)
        TestHarness.expect("an email-less file stays on the sentinel",
                           MuseProvider(reader: reader(world(auth: "auth-no-email.json"), gated(keychainTokens())),
                                        http: FakeHTTP(), clock: { now })
                               .discoverAccounts()[0].ref.id.storageKey,
                           AccountIdentity(provider: .muse, MuseCredential.unresolvedIdentityComponent).storageKey)
    }

    static func materialSkipsTheTokenSourceWhenReadWould() {
        for (name, fs) in [("api-key", world(auth: "auth-api-key.json")),
                           ("missing file", world(auth: nil)),
                           ("no provider block", { () -> FakeFileSystem in
                               let fs = world(auth: nil)
                               fs.files[authPath] = Data("{}".utf8)
                               return fs
                           }())] {
            let inner = keychainTokens()
            _ = reader(fs, inner).credentialMaterial()
            TestHarness.check("\(name) never consults the token source", inner.services.isEmpty)
            TestHarness.check("\(name) is also rejected by read()",
                              reader(fs, inner).read() != .noAccessToken && inner.services.isEmpty)
        }
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
        keychainFaultPointsAtTheConnectInstruction()
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
        unarmedGateNeverReadsAndAsksToConnect()
        armedGateReadsOnceThenServesTheCache()
        concurrentCallersShareOneRead()
        cachedBlobCarriesOnlyTheAccessToken()
        failedReadIsNotCached()
        absentItemIsSignedOutAndNotCached()
        invalidateReturnsToTheConnectState()
        inlineTokenNeverTouchesTheTokenSource()
        surveyThatNeverReachesTheGateWithdrawsItsArm()
        pendingArmIsOnlyConsumedByItsOwnSurvey()
        cachedTokenIsBoundToItsAccount()
        signedOutStatesDropTheCachedToken()
        invalidateDuringAReadWinsAndNeverBlocks()
        notConnectedKeepsTheEmailIdentity()
        materialSkipsTheTokenSourceWhenReadWould()
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
