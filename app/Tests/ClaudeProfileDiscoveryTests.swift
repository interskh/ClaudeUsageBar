import Foundation

// §10: each case names the regression it prevents.
//
// The whole suite runs against an in-memory filesystem and an in-memory credential
// store built from sanitised fixtures. It never reads the real home directory and — by
// construction, since neither the Keychain reader nor the real filesystem is compiled
// into this target — cannot reach the real machine at all.
enum ClaudeProfileDiscoveryTests {

    // MARK: - Fakes

    private struct FakeFileSystem: ProfileFileSystem {
        let homeDirectoryPath: String
        var environment: [String: String] = [:]
        var directories: Set<String> = []
        var files: [String: Data] = [:]

        func environmentVariable(_ name: String) -> String? {
            guard let value = environment[name], !value.isEmpty else { return nil }
            return value
        }

        func isDirectory(atPath path: String) -> Bool {
            directories.contains(path)
        }

        func directoryEntries(atPath path: String) -> [String] {
            directories.compactMap { directory in
                guard directory.hasPrefix(path + "/") else { return nil }
                let remainder = directory.dropFirst(path.count + 1)
                return remainder.contains("/") ? nil : String(remainder)
            }
        }

        func fileContents(atPath path: String) -> Data? {
            files[path]
        }
    }

    // Records every lookup, so a test can assert on the service names discovery did
    // NOT ask for — which is how the default-profile trap and the orphan entries are
    // pinned. `faults` models a store that is present but unreadable (a locked
    // keychain, a denied ACL, a crashed reader).
    private final class FakeCredentialSource: ClaudeCredentialSource {
        var blobs: [String: Data] = [:]
        var faults: [String: String] = [:]
        private(set) var requestedServices: [String] = []

        func lookupCredential(service: String) -> CredentialLookup {
            requestedServices.append(service)
            if let fault = faults[service] { return .failed(fault) }
            if let blob = blobs[service] { return .found(blob) }
            return .absent
        }
    }

    private final class LogCollector {
        private(set) var lines: [String] = []
        func record(_ line: String) { lines.append(line) }
        func contains(_ needle: String) -> Bool { lines.contains { $0.contains(needle) } }
    }

    // MARK: - Fixture world

    private static let home = "/fake/home"

    // Fixed clock: the expiry boundary is a real behaviour, so it is tested against a
    // pinned instant rather than a fixture that silently lapses one day and turns a
    // pending case into an expired one.
    private static let now = Date(timeIntervalSince1970: 1_784_800_000)
    private static let lapsedExpiry = Date(timeIntervalSince1970: 1_784_796_400)

    private static func fixture(_ name: String) -> Data {
        let url = TestHarness.fixturesDirectory
            .appendingPathComponent("anthropic")
            .appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            fatalError("missing fixture: \(url.path)")
        }
        return data
    }

    private static func derivedService(_ directory: String) -> String {
        ClaudeProfileDiscovery.derivedServicePrefix + ClaudeProfileDiscovery.sha256Prefix(directory)
    }

    // Mirrors the shape of the target machine: a default profile whose in-directory
    // config carries no `oauthAccount` (the home-level one does), sibling profiles in
    // every credential state, three directories that are not accounts, and five orphan
    // credential entries with no directory at all.
    private static func world() -> (FakeFileSystem, FakeCredentialSource) {
        var fs = FakeFileSystem(homeDirectoryPath: home)
        fs.directories = [
            home,
            home + "/.claude",
            home + "/.claude-work",
            home + "/.claude-expired",
            home + "/.claude-lapsed",
            home + "/.claude-missing",
            home + "/.claude-anon",
            home + "/.claude-backups",
            home + "/.claude-stub",
            "/opt/fixture-profiles/team-alpha",
        ]
        fs.files = [
            // Verified on the target machine: `~/.claude/.claude.json` exists and holds
            // no `oauthAccount`, while the home-level `~/.claude.json` holds it.
            home + "/.claude/.claude.json": fixture("identity-no-oauth-account.json"),
            home + "/.claude.json": fixture("identity-default.json"),
            home + "/.claude-work/.claude.json": fixture("identity-work.json"),
            home + "/.claude-expired/.claude.json": fixture("identity-expired-credential.json"),
            home + "/.claude-lapsed/.claude.json": fixture("identity-lapsed-credential.json"),
            home + "/.claude-missing/.claude.json": fixture("identity-missing-credential.json"),
            home + "/.claude-anon/.claude.json":
                fixture("identity-oauth-account-no-identifier.json"),
            // `.claude-backups` has no config file at all; `.claude-stub` has one that
            // carries no `oauthAccount`. Neither is an account.
            home + "/.claude-stub/.claude.json": fixture("identity-no-oauth-account.json"),
            "/opt/fixture-profiles/team-alpha/.claude.json": fixture("identity-registered.json"),
        ]

        let credentials = FakeCredentialSource()
        credentials.blobs = [
            ClaudeProfileDiscovery.defaultServiceName: fixture("credential-live.json"),
            // THE TRAP: the derived name for the default directory exists and is
            // non-empty, but carries no OAuth block.
            derivedService(home + "/.claude"): fixture("credential-no-oauth-block.json"),
            derivedService(home + "/.claude-work"): fixture("credential-no-renewal-material.json"),
            derivedService(home + "/.claude-expired"): fixture("credential-lapsed.json"),
            derivedService(home + "/.claude-lapsed"): fixture("credential-zero-expiry.json"),
            derivedService("/opt/fixture-profiles/team-alpha"): fixture("credential-live.json"),
        ]
        // Orphans: entries whose directories no longer exist. The store cannot be
        // enumerated back to an identity, so these must be unreachable.
        for orphan in ["717d1b88", "a8ed8011", "edf4bcd1", "ee4187de", "f51c74b8"] {
            credentials.blobs[ClaudeProfileDiscovery.derivedServicePrefix + orphan] =
                fixture("credential-live.json")
        }
        return (fs, credentials)
    }

    private static func discoverAll() -> ([DiscoveredAccount], FakeCredentialSource, LogCollector) {
        let (fs, credentials) = world()
        let log = LogCollector()
        let discovery = ClaudeProfileDiscovery(fileSystem: fs,
                                               credentials: credentials,
                                               log: log.record)
        // Registered with a trailing slash on purpose: the digest is taken over the
        // path with none, so a normalisation slip would produce a service name that
        // does not exist and silently report the account signed out.
        let accounts = discovery.discover(
            registeredLocations: ["/opt/fixture-profiles/team-alpha/"],
            now: now
        )
        return (accounts, credentials, log)
    }

    private static func describe(_ state: AccountState) -> String {
        switch state {
        case .pending: return "pending"
        case .active: return "active"
        case .stale: return "stale"
        case .signedOut: return "signedOut"
        case .expired(let date): return "expired(\(Int(date.timeIntervalSince1970)))"
        case .failed(let message): return "failed(\(message))"
        }
    }

    private static func state(_ accounts: [DiscoveredAccount], _ label: String) -> String {
        guard let account = accounts.first(where: { $0.ref.label == label }) else {
            return "absent"
        }
        return describe(account.state)
    }

    // MARK: - Cases

    static func run() {
        pathNormalization()
        serviceNameResolution()
        defaultProfileTrap()
        identityGate()
        homeLevelIdentityIsForTheDefaultProfileOnly()
        identityFilePrecedenceForTheDefaultProfile()
        credentialGateDecidesStateNotInclusion()
        aFailedReadIsNotSignedOut()
        renewalMaterialIsNotRequired()
        duplicateIdentityPrefersTheUsableCredential()
        arbitraryRegisteredLocation()
        environmentDesignatedDirectory()
        theHomeDirectoryIsNotAProfile()
        credentialDigestAndUnrelatedSiblings()
        oversizedIdentityFile()
        orphanCredentialEntries()
        labelsAndSubtitles()
    }

    private static func pathNormalization() {
        // Regression: normalising through Foundation, which expands `~` against the
        // PROCESS's home and consults the real filesystem. Both were measured. The
        // first makes the injected home a lie — a test using a ~-relative path would
        // silently read the developer's machine; the second rewrites `/private/tmp/x`
        // to `/tmp/x`, and since the service name is the digest of this string, that
        // yields a name the CLI never wrote and a healthy account renders signedOut.
        TestHarness.expect("~ expands against the INJECTED home, not the process home",
                           ClaudeProfileDiscovery.normalize("~/.claude-x", home: home),
                           "/fake/home/.claude-x")
        TestHarness.expect("a bare ~ is the injected home",
                           ClaudeProfileDiscovery.normalize("~", home: home), home)
        TestHarness.expect("standardisation is LEXICAL — no symlink or firmlink resolution",
                           ClaudeProfileDiscovery.normalize("/private/tmp/profile", home: home),
                           "/private/tmp/profile")
        TestHarness.expect("trailing slashes and . components are removed",
                           ClaudeProfileDiscovery.normalize("/opt//a/./b/", home: home),
                           "/opt/a/b")
        TestHarness.expect(".. is resolved textually",
                           ClaudeProfileDiscovery.normalize("/opt/a/../b", home: home), "/opt/b")

        // Regression: resolving a relative path against whatever the process's working
        // directory happens to be — for a window-server-launched app, `/`. It would
        // hash to a service name that exists nowhere, so a real account would render
        // signedOut with no explanation.
        TestHarness.expect("a relative path is rejected, not resolved",
                           ClaudeProfileDiscovery.normalize(".claude-relative", home: home), nil)

        let log = LogCollector()
        var fs = FakeFileSystem(homeDirectoryPath: home)
        fs.directories = [home]
        let discovery = ClaudeProfileDiscovery(fileSystem: fs,
                                               credentials: FakeCredentialSource(),
                                               log: log.record)
        _ = discovery.candidateDirectories(registeredLocations: ["relative/path"])
        TestHarness.check("and the rejection is explained rather than silent",
                          log.contains("not an absolute path"))
    }

    private static func serviceNameResolution() {
        // Regression: drifting off the digest rule the CLI actually uses. These three
        // vectors were read off the target machine's own Keychain, so they pin the
        // exact input (absolute path, no trailing slash) and the exact truncation
        // (first 8 hex characters of the hex digest). They are string vectors — no
        // filesystem is touched to produce them.
        TestHarness.expect("digest of the default path",
                           ClaudeProfileDiscovery.sha256Prefix("/Users/kyle/.claude"), "6a445fbb")
        TestHarness.expect("digest of a suffixed profile path",
                           ClaudeProfileDiscovery.sha256Prefix("/Users/kyle/.claude-work-fiona"),
                           "6c3a8789")
        TestHarness.expect("digest of a second suffixed profile path",
                           ClaudeProfileDiscovery.sha256Prefix("/Users/kyle/.claude-work-ethan"),
                           "de838ebc")

        // Regression: a trailing slash reaching the digest, which yields a service name
        // that exists nowhere and reports a healthy account signed out.
        TestHarness.expect(
            "a trailing slash does not change the derived service name",
            ClaudeProfileDiscovery.serviceName(forDirectory: home + "/.claude-work/", home: home),
            derivedService(home + "/.claude-work")
        )

        TestHarness.expect(
            "the default directory resolves to the unsuffixed service",
            ClaudeProfileDiscovery.serviceName(forDirectory: home + "/.claude", home: home),
            ClaudeProfileDiscovery.defaultServiceName
        )
    }

    private static func defaultProfileTrap() {
        // THE highest-value case in this file. Regression: reporting the user's PRIMARY
        // account as signed out. On the target machine the derived name for `~/.claude`
        // — 6a445fbb — EXISTS and holds 506 bytes, but carries no OAuth block, so a
        // hash-first implementation binds it and the default profile goes dark.
        let (accounts, credentials, _) = discoverAll()

        TestHarness.expect("default profile is pending, not signed out",
                           state(accounts, "default"), "pending")

        TestHarness.check(
            "the unsuffixed service was consulted for the default profile",
            credentials.requestedServices.contains(ClaudeProfileDiscovery.defaultServiceName)
        )

        // Not merely "the right answer came out": the derived name must never be
        // consulted AT ALL for the default profile (§4.1). A fallback that read it
        // second would pass the assertion above while still being able to bind
        // anomalous material to the primary identity.
        TestHarness.check(
            "the derived service name is never consulted for the default profile",
            !credentials.requestedServices.contains(derivedService(home + "/.claude"))
        )

        // Regression: gating on item existence or non-empty data instead of on usable
        // OAuth material. This fixture is present and 300+ bytes long, and must still
        // decode to nothing — and to `noOAuthMaterial` (a signed-out profile), not to
        // `unreadable` (a fault), because the blob is perfectly well-formed.
        TestHarness.check("the trap fixture is present and non-empty",
                          fixture("credential-no-oauth-block.json").count > 300)
        TestHarness.expect("a well-formed blob with no OAuth block carries no credential",
                           ClaudeCredential.decode(fixture("credential-no-oauth-block.json")),
                           .noOAuthMaterial)
    }

    private static func identityGate() {
        // Regression: non-accounts rendering as broken entries. None of these carries a
        // usable `oauthAccount`, so none is an account in ANY state.
        let (accounts, _, log) = discoverAll()
        TestHarness.expect("a directory with no config file is excluded",
                           state(accounts, "backups"), "absent")
        TestHarness.expect("a directory whose config has no oauthAccount is excluded",
                           state(accounts, "stub"), "absent")

        // Regression: re-admitting an `oauthAccount` that names no account at all. It
        // would key persisted state on an empty component list — which trips
        // AccountIdentity's precondition and crashes the app — or, worse, fall back to
        // the location and misattribute one account's history to the next occupant.
        TestHarness.expect("an oauthAccount with no identifier field is excluded",
                           state(accounts, "anon"), "absent")
        TestHarness.check("and the exclusion is explained, not silent",
                          log.contains("oauthAccount carries no identifier field"))

        TestHarness.expect("exactly the account-bearing directories are discovered",
                           accounts.count, 6)
    }

    private static func homeLevelIdentityIsForTheDefaultProfileOnly() {
        // Regression: widening the default profile's home-level identity fallback to
        // every profile. `.claude-stub`'s own config carries no `oauthAccount` while
        // the home-level file does; if the fallback were not restricted to `~/.claude`,
        // the stub would inherit the DEFAULT ACCOUNT's identity, and two directories
        // would resolve to one account — with the copy able to shadow the original
        // under the dedup rule below.
        //
        // This has its own case because the assertion in `identityGate` describes a
        // different rule: were the fallback widened, that one's failure message would
        // send the next reader after the identity gate rather than after this.
        let (fs, credentials) = world()
        TestHarness.check("the home-level identity file really does carry an oauthAccount",
                          ClaudeAccountIdentityFile.decode(
                              fs.files[home + "/.claude.json"]!) != nil)
        TestHarness.check("and the stub's own config really does not",
                          ClaudeAccountIdentityFile.decode(
                              fs.files[home + "/.claude-stub/.claude.json"]!) == nil)

        let discovery = ClaudeProfileDiscovery(fileSystem: fs, credentials: credentials,
                                               log: { _ in })
        TestHarness.expect("a non-default profile does not inherit the home-level identity",
                           discovery.identityFile(for: home + "/.claude-stub", home: home), nil)
        TestHarness.check("while the default profile does",
                          discovery.identityFile(for: home + "/.claude", home: home) != nil)
    }

    private static func identityFilePrecedenceForTheDefaultProfile() {
        // Regression: leaving the precedence undefined. `~/.claude/.claude.json` is a
        // real, actively-written config that merely lacks `oauthAccount` today; if a
        // future CLI starts writing one there, which file wins decides which account
        // the primary profile IS. Pinned: in-directory first, home-level second.
        var fs = FakeFileSystem(homeDirectoryPath: home)
        fs.directories = [home, home + "/.claude"]
        fs.files = [
            home + "/.claude/.claude.json": fixture("identity-work.json"),
            home + "/.claude.json": fixture("identity-default.json"),
        ]
        let discovery = ClaudeProfileDiscovery(fileSystem: fs,
                                               credentials: FakeCredentialSource(),
                                               log: { _ in })
        TestHarness.expect("the in-directory config wins when both carry an oauthAccount",
                           discovery.identityFile(for: home + "/.claude", home: home)?.emailAddress,
                           "work@example.test")
    }

    private static func credentialGateDecidesStateNotInclusion() {
        // Regression: conflating the inclusion gate with the state gate, which makes
        // signed-out unrepresentable — the account would be filtered away before it
        // could be displayed as signed out.
        let (accounts, _, _) = discoverAll()

        // Unusable: the credential exists but records no expiry (`expiresAt: 0`, the
        // shape observed on `work-ethan`). Not "expired in 1970", and not a fault
        // either — the payload is well-formed and says there is no session.
        TestHarness.expect("an account with an unusable credential is present, signed out",
                           state(accounts, "lapsed"), "signedOut")

        // Absent: no credential entry at all for this profile's service.
        TestHarness.expect("an account with no credential entry is present, signed out",
                           state(accounts, "missing"), "signedOut")

        // Genuinely lapsed expiry — a different fact from an unusable credential, and
        // the UI hint differs ("use the CLI" vs "sign in").
        TestHarness.expect("an account whose own expiry has lapsed is expired",
                           state(accounts, "expired"), "expired(1784796400)")

        // The `<=` boundary is deliberate: a credential expiring exactly now is spent,
        // and calling it pending would send one doomed request per account.
        let (fs, credentials) = world()
        let atBoundary = ClaudeProfileDiscovery(fileSystem: fs, credentials: credentials,
                                                log: { _ in })
            .discover(now: lapsedExpiry)
        TestHarness.expect("an expiry exactly equal to now is already expired",
                           state(atBoundary, "expired"), "expired(1784796400)")
    }

    private static func aFailedReadIsNotSignedOut() {
        // Regression (§4.1, and the reason `failed` exists): a locked login keychain, a
        // denied ACL or a crashed reader all rendering as a confident "you are signed
        // out" — advice that is wrong, and that sends the user to re-authenticate a
        // session that was never broken. `signedOut` must mean the credential is not
        // there; `failed` means the app could not find out.
        let (fs, credentials) = world()
        credentials.faults[ClaudeProfileDiscovery.defaultServiceName] =
            "keychain read exited 51 for service Claude Code-credentials"
        // A present but corrupt payload is the third distinct outcome: also a fault,
        // because the app cannot tell what the credential says.
        credentials.blobs[derivedService(home + "/.claude-work")] =
            fixture("credential-not-json.txt")

        let accounts = ClaudeProfileDiscovery(fileSystem: fs, credentials: credentials,
                                              log: { _ in }).discover(now: now)

        TestHarness.expect("an unreadable store yields failed, naming the fault",
                           state(accounts, "default"),
                           "failed(keychain read exited 51 for service Claude Code-credentials)")
        TestHarness.expect("an unparseable payload yields failed, naming the parse fault",
                           state(accounts, "work"),
                           "failed(credential payload is not valid JSON)")
        TestHarness.expect("while a genuinely absent entry still yields signedOut",
                           state(accounts, "missing"), "signedOut")

        // The fault text is the app's own words. Regression: quoting the payload into a
        // diagnostic — the blob carries third-party client secrets, so an error reading
        // "unparseable payload: <bytes>" would leak someone else's credential.
        TestHarness.expect("a corrupt payload is described, never quoted",
                           ClaudeCredential.decode(fixture("credential-not-json.txt")),
                           .unreadable("credential payload is not valid JSON"))
        TestHarness.expect("valid JSON of the wrong shape is described, never quoted",
                           ClaudeCredential.decode(Data("[\"unexpected\"]".utf8)),
                           .unreadable("credential payload is not a JSON object"))

        // Regression: a JSON boolean bridging to NSNumber(1.0), passing the `> 0` check
        // and rendering as an expiry one millisecond after 1970 — an "expired 1970"
        // card for what is really a malformed credential.
        TestHarness.expect("a boolean expiry is malformed, not an expiry in 1970",
                           ClaudeCredential.decode(fixture("credential-boolean-expiry.json")),
                           .unreadable("credential expiry is not a number"))
    }

    private static func renewalMaterialIsNotRequired() {
        // Regression: disqualifying an account over a capability the app deliberately
        // never exercises. Read-only operation never uses a refresh token, so its
        // absence must not mark an otherwise valid credential unusable.
        let (accounts, _, _) = discoverAll()
        TestHarness.expect("a usable token with no renewal material is pending",
                           state(accounts, "work"), "pending")

        // Regression: collapsing authenticated-but-unfetched into active. Discovery
        // resolves to pre-fetch states ONLY — a snapshot is something only a successful
        // fetch can produce. Asserted once over the whole result, so the check count
        // does not inflate with the fixture world's size and the invariant is carried
        // by a real assertion rather than a literal `true` inside a loop.
        let postFetch = accounts.filter { account in
            switch account.state {
            case .pending, .signedOut, .expired, .failed: return false
            case .active, .stale: return true
            }
        }
        TestHarness.expect("discovery never yields a post-fetch state",
                           postFetch.map { $0.ref.label }, [])
    }

    private static func duplicateIdentityPrefersTheUsableCredential() {
        // Regression, reproduced from the reviewer's report: two directories carrying
        // the SAME account — an ordinary copied configuration — where only the
        // second-scanned one holds the live credential. Each directory has its own
        // credential entry, because the service name is derived from the path. Keeping
        // the first-scanned candidate means the app reports a working login as signed
        // out and never even consults the good entry.
        var fs = FakeFileSystem(homeDirectoryPath: home)
        fs.directories = [home, home + "/.claude", home + "/.claude-personal"]
        fs.files = [
            home + "/.claude.json": fixture("identity-default.json"),
            home + "/.claude-personal/.claude.json": fixture("identity-clone-of-default.json"),
        ]
        let credentials = FakeCredentialSource()
        // Deliberately NOTHING under the unsuffixed name: here the default directory is
        // the stale copy.
        credentials.blobs = [
            derivedService(home + "/.claude-personal"): fixture("credential-live.json"),
        ]
        let log = LogCollector()
        let accounts = ClaudeProfileDiscovery(fileSystem: fs, credentials: credentials,
                                              log: log.record).discover(now: now)

        TestHarness.expect("one account, not two", accounts.count, 1)
        TestHarness.expect("and it is the directory holding the usable credential",
                           accounts.first?.ref.label, "personal")
        TestHarness.expect("so it is pending, not signed out",
                           state(accounts, "personal"), "pending")
        TestHarness.check("the sibling's credential is actually consulted",
                          credentials.requestedServices
                              .contains(derivedService(home + "/.claude-personal")))
        TestHarness.check("and the collapse is explained rather than silent",
                          log.contains("hold the same account"))

        // Tie-break: when neither is healthier, the result must not depend on
        // dictionary ordering. Scan order decides, which keeps `~/.claude` winning
        // among equals.
        let bothUsable = FakeCredentialSource()
        bothUsable.blobs = [
            ClaudeProfileDiscovery.defaultServiceName: fixture("credential-live.json"),
            derivedService(home + "/.claude-personal"):
                fixture("credential-no-renewal-material.json"),
        ]
        let tied = ClaudeProfileDiscovery(fileSystem: fs, credentials: bothUsable,
                                          log: { _ in }).discover(now: now)
        TestHarness.expect("equally healthy candidates fall back to scan order",
                           tied.map { $0.ref.label }, ["default"])
    }

    private static func arbitraryRegisteredLocation() {
        // Regression: capping discovery at one naming convention. A profile rooted at an
        // arbitrary path is invisible to the conventional scan and — because the digest
        // cannot be inverted — equally invisible to store enumeration, so without the
        // registration escape hatch it is unreachable by any means.
        let (accounts, _, _) = discoverAll()
        TestHarness.expect("a registered path outside home and outside the convention is found",
                           state(accounts, "team-alpha"), "pending")
    }

    private static func environmentDesignatedDirectory() {
        // Regression: honouring only the conventional scan, so a user who runs Claude
        // Code with a designated configuration directory sees no account at all.
        var fs = FakeFileSystem(homeDirectoryPath: home)
        fs.directories = [home, "/srv/designated/claude"]
        fs.files = ["/srv/designated/claude/.claude.json": fixture("identity-registered.json")]
        fs.environment = [
            ClaudeProfileDiscovery.configDirectoryEnvironmentVariable: "/srv/designated/claude",
        ]
        let credentials = FakeCredentialSource()
        credentials.blobs = [
            derivedService("/srv/designated/claude"): fixture("credential-live.json"),
        ]

        let accounts = ClaudeProfileDiscovery(fileSystem: fs, credentials: credentials,
                                              log: { _ in }).discover(now: now)
        TestHarness.expect("the environment-designated directory is discovered",
                           accounts.count, 1)
        TestHarness.expect("the environment-designated account is pending",
                           state(accounts, "claude"), "pending")

        // Regression: accepting a RELATIVE designated directory. It would resolve as a
        // directory yet hash to a service name the CLI never wrote — a healthy account
        // rendering signedOut with no explanation.
        var relative = fs
        relative.directories.insert("claude-relative")
        relative.environment = [
            ClaudeProfileDiscovery.configDirectoryEnvironmentVariable: "claude-relative",
        ]
        let log = LogCollector()
        let rejected = ClaudeProfileDiscovery(fileSystem: relative, credentials: credentials,
                                              log: log.record).discover(now: now)
        TestHarness.expect("a relative designated directory is not discovered",
                           rejected.count, 0)
        TestHarness.check("and the reason names the environment variable",
                          log.contains(ClaudeProfileDiscovery.configDirectoryEnvironmentVariable))
    }

    private static func theHomeDirectoryIsNotAProfile() {
        // Regression: registering `$HOME` itself (or pointing the environment variable
        // at it). Home is the one directory whose `.claude.json` IS the default
        // profile's identity file, so it would appear as a second candidate carrying
        // the default account's identity — one account claimed by two directories,
        // resolved only by the dedup rule and by scan-order luck.
        var fs = FakeFileSystem(homeDirectoryPath: home)
        fs.directories = [home, home + "/.claude"]
        fs.files = [home + "/.claude.json": fixture("identity-default.json")]
        let log = LogCollector()
        let discovery = ClaudeProfileDiscovery(fileSystem: fs,
                                               credentials: FakeCredentialSource(),
                                               log: log.record)
        TestHarness.expect("home is not a candidate profile directory",
                           discovery.candidateDirectories(registeredLocations: [home, "~"]),
                           [home + "/.claude"])
        TestHarness.check("and registering it is explained rather than silently ignored",
                          log.contains("the home directory is not a profile"))
    }

    private static func credentialDigestAndUnrelatedSiblings() {
        // The stored blob is NOT only the Anthropic token: a real entry on the target
        // machine also carries `mcpOAuth` client secrets for unrelated third-party
        // servers. Two regressions follow, and this fixture pins both.
        let siblings = fixture("credential-with-unrelated-siblings.json")

        // (a) Sibling keys must not break parsing — the app must keep working as the
        // vendor adds sections it knows nothing about.
        guard case .usable(let credential) = ClaudeCredential.decode(siblings) else {
            TestHarness.check("a blob with unrelated sibling keys still parses", false)
            return
        }
        TestHarness.expect("the token comes from the claudeAiOauth subtree",
                           credential.accessToken, "sk-ant-oat01-FIXTURE-NOT-A-REAL-TOKEN-0005")

        // (b) Nothing from the siblings may reach the parsed model. The model has no
        // member that could hold it, and this asserts that stays true: rendering the
        // whole value and searching it must find no sibling material.
        let rendered = "\(credential)"
        TestHarness.check("no sibling client secret reaches the parsed model",
                          !rendered.contains("FIXTURE-CLIENT-SECRET-NOT-REAL-aaaa")
                              && !rendered.contains("FIXTURE-UNRELATED-SECRET-NOT-REAL-bbbb")
                              && !rendered.contains("mcpOAuth"))

        // §6 revives a stopped account by observing that its stored credential CHANGED.
        // The comparison value is the DIGEST — retaining the blob to diff it would
        // write third-party secrets into a file this app has no business creating.
        let live = fixture("credential-live.json")
        TestHarness.check("the digest changes when the OAuth material changes",
                          ClaudeCredential.credentialDigest(live)
                              != ClaudeCredential.credentialDigest(siblings))
        TestHarness.check("the digest carries none of the payload",
                          !ClaudeCredential.credentialDigest(siblings)
                              .contains("FIXTURE-CLIENT-SECRET-NOT-REAL-aaaa"))

        // Regression: the measured 1507-vs-1506 detail. A subprocess reader appends a
        // newline the direct API does not. JSONSerialization tolerates trailing
        // whitespace, so `decode` cannot pin this — but the digest can, and must: if it
        // did not, every poll would look like a credential change and would revive
        // stopped accounts forever (§6).
        TestHarness.check("the fixture really does carry the trailing newline",
                          live.last == 0x0A)
        TestHarness.expect("the digest is identical for both readers' bytes",
                           ClaudeCredential.credentialDigest(live),
                           ClaudeCredential.credentialDigest(live.dropLast()))
        // Leading whitespace exercises the rebasing: a Data slice keeps its parent's
        // indices, so an un-rebased canonical form traps when indexed from zero.
        TestHarness.expect("and is unaffected by leading whitespace",
                           ClaudeCredential.credentialDigest(Data(" \n".utf8) + live),
                           ClaudeCredential.credentialDigest(live))
        // A trailing NUL IS rejected by JSONSerialization, so this one is observable
        // through decode as well.
        TestHarness.check(
            "a trailing NUL byte does not defeat parsing",
            ClaudeCredential.decode(live.dropLast() + Data([0x00]))
                == ClaudeCredential.decode(live)
        )
        TestHarness.expect("an empty payload is a fault, not a signed-out profile",
                           ClaudeCredential.decode(Data()),
                           .unreadable("credential payload is empty"))
    }

    private static func oversizedIdentityFile() {
        // Regression: reading an unbounded config into memory on a discovery pass that
        // re-runs on every popover open. A corrupt or pathological file must be skipped
        // loudly, not swallowed.
        var fs = FakeFileSystem(homeDirectoryPath: home)
        fs.directories = [home, home + "/.claude-huge"]
        var padded = fixture("identity-work.json")
        padded.append(Data(repeating: 0x20,
                           count: ClaudeProfileDiscovery.maximumIdentityFileBytes + 1))
        fs.files = [home + "/.claude-huge/.claude.json": padded]
        let log = LogCollector()
        let accounts = ClaudeProfileDiscovery(fileSystem: fs,
                                              credentials: FakeCredentialSource(),
                                              log: log.record).discover(now: now)
        TestHarness.expect("an oversized config is not read", accounts.count, 0)
        TestHarness.check("and the cap is reported",
                          log.contains("exceeds the config size cap"))
    }

    private static func orphanCredentialEntries() {
        // Regression: driving discovery off the credential store. The store's keys are
        // one-way digests, so an entry cannot name the profile it belongs to; five
        // orphans on the target machine belong to directories that no longer exist and
        // must appear NOWHERE.
        let (accounts, credentials, _) = discoverAll()
        for orphan in ["717d1b88", "a8ed8011", "edf4bcd1", "ee4187de", "f51c74b8"] {
            let service = ClaudeProfileDiscovery.derivedServicePrefix + orphan
            TestHarness.check("orphan \(orphan) is never even looked up",
                              !credentials.requestedServices.contains(service))
        }
        // Stronger than "no orphan appeared": discovery must consult exactly one
        // service per discovered account and nothing else, so the store is never a
        // source of candidates.
        let expected = Set([
            ClaudeProfileDiscovery.defaultServiceName,
            derivedService(home + "/.claude-work"),
            derivedService(home + "/.claude-expired"),
            derivedService(home + "/.claude-lapsed"),
            derivedService(home + "/.claude-missing"),
            derivedService("/opt/fixture-profiles/team-alpha"),
        ])
        TestHarness.expect("one credential lookup per discovered account",
                           credentials.requestedServices.count, accounts.count)
        TestHarness.expect("and every lookup belongs to a discovered directory",
                           Set(credentials.requestedServices), expected)
    }

    private static func labelsAndSubtitles() {
        let (accounts, _, _) = discoverAll()
        TestHarness.expect("labels strip the .claude- prefix, default is named default",
                           accounts.map { $0.ref.label },
                           ["default", "expired", "lapsed", "missing", "work", "team-alpha"])
        TestHarness.expect("the subtitle is the account's email address",
                           accounts.first?.ref.subtitle, "primary@example.test")

        // Regression: keying identity on the location, so signing a different account
        // into a directory inherits the previous occupant's history. Identity comes
        // from the durable account identifier in the config, never from the path.
        TestHarness.expect("identity is the durable account identifier",
                           accounts.first?.ref.id,
                           AccountIdentity(provider: .anthropic,
                                           "00000000-0000-4000-8000-00000000a001"))
    }
}
