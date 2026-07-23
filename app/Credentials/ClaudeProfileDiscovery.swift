import Foundation
import CryptoKit

// Anthropic multi-profile discovery (§4.1). PURE: no Keychain, no networking, no
// SwiftUI — this file compiles into the test target, so every dependency on the
// machine (home directory, environment, credential store) arrives through an injected
// protocol and can be faked. Path handling is lexical for the same reason: see
// `normalize`.
//
// Discovery is DIRECTORY-DRIVEN, never credential-store-driven. The store is keyed by
// a one-way digest of the configuration path, so an entry cannot name the profile it
// belongs to: enumerating the store yields opaque entries that cannot be resolved back
// to an identity, including orphans belonging to directories that no longer exist
// (five on the target machine). Nothing here ever enumerates the store.

// The filesystem facts discovery needs, and nothing more. Deliberately read-only:
// there is no write, create, or delete member, so no discovery code path can acquire
// one by accident (acceptance criterion 16).
protocol ProfileFileSystem {
    var homeDirectoryPath: String { get }
    func environmentVariable(_ name: String) -> String?
    func isDirectory(atPath path: String) -> Bool
    func directoryEntries(atPath path: String) -> [String]
    func fileContents(atPath path: String) -> Data?

    // Reading one file has THREE outcomes, not two: `fileContents` collapses "not there"
    // and "there and unreadable" into `nil`, and §4.1 requires those stay distinguishable
    // — a locked or corrupt credential rendered as a confident "you are signed out" sends
    // the user to re-authenticate a session that was never broken.
    //
    // A REQUIREMENT, not merely an extension member with a default. A method that exists
    // only in a protocol extension dispatches STATICALLY through an existential, so the
    // real filesystem's override would never be called and the distinction would be
    // inert — which is exactly what happened on the first attempt at this. The default
    // below keeps every existing conformer compiling unchanged.
    func readFile(atPath path: String) -> FileReadResult
}

// The outcome of ONE file read. Names the FAULT, never the payload.
enum FileReadResult {
    case contents(Data)
    case missing
    case unreadable(String)
}

extension ProfileFileSystem {
    // Conformers that cannot tell absence from unreadability keep the old behaviour: a
    // fake filesystem holding a dictionary of files genuinely has no third case.
    func readFile(atPath path: String) -> FileReadResult {
        guard let data = fileContents(atPath: path) else { return .missing }
        return .contents(data)
    }
}

// The outcome of ONE credential lookup. Three cases, not an optional: §4.1 now
// requires "the credential is not there" (`signedOut`, normal and user-actionable) to
// stay distinguishable from "the app could not find out" (`failed`, an operational
// fault). A locked login keychain, a denied ACL and a crashed subprocess all used to
// flatten into a confident "you are signed out", which sends the user to
// re-authenticate a session that was never broken.
enum CredentialLookup {
    case found(Data)
    case absent
    // Names the FAULT — never the payload. The blob is not only the Anthropic token:
    // one profile's real entry also carries an `mcpOAuth` section with live client
    // secrets for unrelated third-party servers, so quoting any of it in a diagnostic
    // would leak someone else's credential.
    case failed(String)
}

// The credential store, as a lookup by service name. Returns the RAW stored bytes:
// a subprocess reader appends a trailing newline the direct API does not, and
// canonicalising belongs with the parsing — which is pure and tested — rather than
// with the impure reader, which is not.
//
// §3/§6 make credential freshness an invariant of `fetch`: a token rotates roughly
// 8-hourly, so a copy captured at discovery is guaranteed to go stale while the stored
// credential stays healthy, and an implementation that cached one would permanently
// park a live account as expired. The protocol is therefore a pull-only lookup with no
// handle to hold, conforming types carry no storage, and — the part that actually
// enforces it — no token ever enters the model: `DiscoveredAccount` carries a state,
// never a credential, so a caller has nothing stale to hold on to.
//
// THREADING: a conforming type may block the calling thread for as long as its own
// bounded timeout. Callers run discovery OFF the main thread; §6's popover-open
// re-discovery would otherwise stall the menu bar for one lookup per account.
protocol ClaudeCredentialSource {
    func lookupCredential(service: String) -> CredentialLookup
}

// The subset of the credential blob the app actually consumes. There is deliberately
// no `refreshToken` member: read-only operation never renews, and a field that cannot
// be used is a field that invites being used.
//
// Nothing outside the `claudeAiOauth` subtree is carried here, and sibling keys are
// never enumerated. That is a security requirement, not tidiness: a real blob on the
// target machine carries an `mcpOAuth` section holding live client secrets for
// unrelated third-party servers. This type is the boundary at which all of that is
// dropped.
struct ClaudeCredential: Equatable {
    let accessToken: String
    let expiresAt: Date
    let subscriptionType: String?
    let rateLimitTier: String?
}

// Three outcomes, because §4.1 distinguishes them: a well-formed blob that simply
// carries no OAuth material means the profile is signed out, while a blob that cannot
// be read at all is a fault the app must own up to rather than dress as signed out.
enum ClaudeCredentialDecoding: Equatable {
    case usable(ClaudeCredential)
    case noOAuthMaterial
    case unreadable(String)  // fault description only — never any part of the payload
}

extension ClaudeCredential {
    // Decodes what §4.1's credential gate tests and NOTHING more: an access token and
    // its recorded expiry. It must not require renewal material — treating a missing
    // refresh token as disqualifying would mark an account unusable over a capability
    // the app deliberately declines to exercise.
    //
    // `noOAuthMaterial` is the disqualifying condition — NOT an absent item and NOT
    // zero-length data. The derived-name entry for the default profile on the target
    // machine is present and 506 bytes long yet carries no OAuth block, so a gate
    // written against existence or non-emptiness would admit it (§4.1).
    static func decode(_ data: Data) -> ClaudeCredentialDecoding {
        let canonical = canonicalBlob(data)
        guard !canonical.isEmpty else { return .unreadable("credential payload is empty") }
        guard let root = try? JSONSerialization.jsonObject(with: canonical) else {
            return .unreadable("credential payload is not valid JSON")
        }
        guard let object = root as? [String: Any] else {
            return .unreadable("credential payload is not a JSON object")
        }
        // The ONLY subtree read. Siblings are neither retained nor enumerated.
        guard let oauth = object["claudeAiOauth"] as? [String: Any] else {
            return .noOAuthMaterial
        }
        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            return .noOAuthMaterial
        }
        guard let rawExpiry = oauth["expiresAt"] else { return .noOAuthMaterial }
        guard let milliseconds = unixMilliseconds(rawExpiry) else {
            // Present but not a number — including a JSON boolean, which bridges to
            // NSNumber(1.0) and would otherwise read as an expiry one millisecond after
            // 1970. That is a malformed credential, not a lapsed one.
            return .unreadable("credential expiry is not a number")
        }
        // A non-positive expiry is not an expiry that lapsed in 1970; it is the absence
        // of a recorded one. `work-ethan` on the target machine carries exactly this —
        // expiresAt 0 — and must resolve signedOut, not expired and not failed.
        guard milliseconds > 0 else { return .noOAuthMaterial }

        return .usable(ClaudeCredential(
            accessToken: accessToken,
            expiresAt: Date(timeIntervalSince1970: milliseconds / 1000),
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        ))
    }

    // §6 revives a stopped account by observing that its stored credential CHANGED.
    // The comparison value is this DIGEST, never the blob.
    //
    // THIS IS A SECURITY BOUNDARY, not an optimisation. The stored blob is not only the
    // Anthropic token: a real entry on the target machine also carries an `mcpOAuth`
    // section with live client IDs and secrets for unrelated third-party servers.
    // Retaining the blob to diff it would write those secrets into a file this app has
    // no business creating — a worse exposure than the one the read-only rule exists to
    // prevent. A digest compares exactly as well and carries nothing.
    static func credentialDigest(_ data: Data) -> String {
        SHA256.hash(data: canonicalBlob(data)).map { String(format: "%02x", $0) }.joined()
    }

    // The stored blob in a reader-independent form, so that "has this credential
    // changed?" cannot flip merely because the bytes came back through a subprocess
    // (which appends a newline the direct API does not). TRANSIENT and private: it is
    // the digest's input and the parser's input, and it is never handed to a caller
    // that could retain it.
    private static func canonicalBlob(_ data: Data) -> Data {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x00]
        var start = data.startIndex
        var end = data.endIndex
        while start < end, whitespace.contains(data[start]) { start = data.index(after: start) }
        while end > start, whitespace.contains(data[data.index(before: end)]) {
            end = data.index(before: end)
        }
        // Rebased: a Data slice keeps its parent's indices, so a caller indexing from 0
        // into a leading-whitespace-trimmed slice would trap.
        return Data(data[start..<end])
    }

    // `expiresAt` is Unix MILLISECONDS (§4.1) and arrives as an integer or a double
    // depending on the writer. Never parsed out of a string figure: a credential whose
    // expiry we cannot read is one whose usability we cannot judge.
    private static func unixMilliseconds(_ value: Any) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        // JSON booleans bridge to NSNumber as well, and `as? NSNumber` accepts them.
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite else { return nil }
        return milliseconds
    }
}

// The account identity carried alongside the credential. This — not the location — is
// what the account IS (§4.1): keying on the directory would mean a different account
// signing into it silently inherits the previous occupant's cached readings and
// notification history.
struct ClaudeAccountIdentityFile: Equatable {
    let accountUUID: String?
    let emailAddress: String?
    let organizationUUID: String?

    // The identity gate (§4.1): a candidate is an account IFF its configuration carries
    // an `oauthAccount` object. Nothing about credentials decides inclusion.
    static func decode(_ data: Data) -> ClaudeAccountIdentityFile? {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let oauth = object["oauthAccount"] as? [String: Any]
        else { return nil }

        return ClaudeAccountIdentityFile(
            accountUUID: nonEmpty(oauth["accountUuid"]),
            emailAddress: nonEmpty(oauth["emailAddress"]),
            organizationUUID: nonEmpty(oauth["organizationUuid"])
        )
    }

    // §3: a durable account identifier where one is published, otherwise a composite of
    // the identifier fields available. `accountUuid` alone is preferred precisely
    // BECAUSE it is durable — folding the email in would orphan an account's history
    // the day the user changes their address, which is the misattribution the identity
    // rules exist to prevent.
    //
    // CAVEAT for tasks 6-8: on the composite path, identity is stable only while the
    // SET of available fields is. If a config gains an `organizationUuid` it previously
    // lacked, ["a@example.test"] becomes ["a@example.test", "org"], the storage key
    // changes, and that account's persisted state is reclaimed as if it had left
    // discovery. Identity is therefore NOT immutable across polls and nothing may
    // assume it is; losing threshold history is the accepted cost (§6), silent
    // misattribution is not.
    var identityComponents: [String] {
        if let accountUUID { return [accountUUID] }
        return [emailAddress, organizationUUID].compactMap { $0 }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}

// The outcome of validating a user-typed registered location (§4.1/§7.3). Two cases,
// because the whole point is that a failure is REPORTED at add-time rather than the
// location being accepted and silently ignored by the next survey. `accepted` carries the
// normalized absolute path (so the store persists the canonical form the survey will key
// on, not the raw `~`-relative string) and the durable label to echo back to the user.
enum RegisteredLocationValidation: Equatable {
    case accepted(normalizedPath: String, label: String)
    case rejected(reason: String)
}

// A candidate directory that passed the identity gate, together with the service name
// its credential lives under and the state that credential resolves to. Task 5 needs
// the service name to re-read the credential on every fetch (§3), and task 7 needs it
// as the key for the per-CREDENTIAL request budget (§6) — neither is derivable from an
// `AccountRef`, which deliberately carries no location.
struct ResolvedClaudeProfile {
    let directory: String
    let service: String
    let account: DiscoveredAccount
}

struct ClaudeProfileDiscovery {
    // The authoritative namespace for the default profile. There is NO derived
    // fallback: see `serviceName(forDirectory:home:)`.
    static let defaultServiceName = "Claude Code-credentials"
    static let derivedServicePrefix = "Claude Code-credentials-"
    static let configDirectoryEnvironmentVariable = "CLAUDE_CONFIG_DIR"
    static let identityFileName = ".claude.json"
    static let defaultDirectoryName = ".claude"
    static let maximumIdentityFileBytes = 8 * 1024 * 1024

    let fileSystem: ProfileFileSystem
    let credentials: ClaudeCredentialSource
    // Every silent exclusion goes through here. A directory vanishing with no
    // explanation is indistinguishable from a bug, and these are exactly the paths a
    // user would report as "my account disappeared". Injected so tests can assert the
    // explanation was produced, and so the pure target carries no dependency on NSLog.
    let log: (String) -> Void

    init(fileSystem: ProfileFileSystem,
         credentials: ClaudeCredentialSource,
         log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.fileSystem = fileSystem
        self.credentials = credentials
        self.log = log
    }

    // §6: cheap and local, so it re-runs periodically and on popover open rather than
    // only at launch. `now` is injected so the expiry boundary is testable without a
    // fixture that rots.
    func discover(registeredLocations: [String] = [], now: Date = Date()) -> [DiscoveredAccount] {
        resolveProfiles(registeredLocations: registeredLocations, now: now).map { $0.account }
    }

    func resolveProfiles(registeredLocations: [String] = [],
                         now: Date = Date()) -> [ResolvedClaudeProfile] {
        guard let home = ClaudeProfileDiscovery.lexicallyStandardized(fileSystem.homeDirectoryPath)
        else {
            log("🔎 Home directory is not an absolute path; no Claude profiles discovered")
            return []
        }

        var resolved: [ResolvedClaudeProfile] = []
        for directory in candidateDirectories(registeredLocations: registeredLocations) {
            guard let identity = identityFile(for: directory, home: home) else { continue }

            let components = identity.identityComponents
            // The `oauthAccount` object is present but names no account at all. It
            // cannot key persisted state, and §3 forbids falling back to the location —
            // that is exactly the cross-sign-in misattribution the identity rules exist
            // to prevent — so the candidate is dropped rather than mis-keyed.
            guard !components.isEmpty else {
                log("🔎 Excluding \(directory): oauthAccount carries no identifier field")
                continue
            }

            let service = ClaudeProfileDiscovery.serviceName(forDirectory: directory, home: home)
            let ref = AccountRef(
                id: AccountIdentity(provider: .anthropic, components: components),
                label: ClaudeProfileDiscovery.label(forDirectory: directory, home: home),
                subtitle: identity.emailAddress
            )
            resolved.append(ResolvedClaudeProfile(
                directory: directory,
                service: service,
                account: DiscoveredAccount(ref: ref, state: state(forService: service, now: now))
            ))
        }

        return deduplicatingByIdentity(resolved)
    }

    // Two directories can carry the same account — a copied or migrated configuration,
    // which is ordinary. They are ONE account, but WHICH directory represents it is not
    // arbitrary: each has its own credential entry, because the service name is derived
    // from the path. Keeping the first-scanned one lets a stale copy shadow the
    // directory that actually holds the live credential, so the app reports a working
    // login as signed out and never even consults the good entry — the same failure
    // class the default-profile special case exists to prevent, arriving through a
    // different door.
    //
    // The winner is therefore chosen by CREDENTIAL HEALTH, not scan order: usable beats
    // lapsed beats unreadable beats absent. Scan order is only the tie-break, which
    // keeps the result deterministic and keeps `~/.claude` winning among equals, since
    // it is appended first.
    private func deduplicatingByIdentity(
        _ profiles: [ResolvedClaudeProfile]
    ) -> [ResolvedClaudeProfile] {
        var winnerIndexByIdentity: [AccountIdentity: Int] = [:]
        for (index, profile) in profiles.enumerated() {
            let identity = profile.account.ref.id
            guard let incumbent = winnerIndexByIdentity[identity] else {
                winnerIndexByIdentity[identity] = index
                continue
            }
            let challengerRank = ClaudeProfileDiscovery.credentialRank(profile.account.state)
            let incumbentRank = ClaudeProfileDiscovery
                .credentialRank(profiles[incumbent].account.state)
            let kept = challengerRank < incumbentRank ? index : incumbent
            let dropped = kept == index ? incumbent : index
            winnerIndexByIdentity[identity] = kept
            log("🔎 \(profiles[dropped].directory) and \(profiles[kept].directory) hold the "
                + "same account; using \(profiles[kept].directory)")
        }
        return winnerIndexByIdentity.values.sorted().map { profiles[$0] }
    }

    // Lower is better. `active`/`stale` are unreachable from discovery (§3) and rank
    // last so a future caller reusing this cannot accidentally prefer a state discovery
    // never produces.
    private static func credentialRank(_ state: AccountState) -> Int {
        switch state {
        case .pending: return 0
        case .expired: return 1
        // A fault outranks absence: "could not read this one" is worth surfacing over
        // "this one is definitely empty", because it is the case that may still resolve.
        case .failed: return 2
        case .signedOut: return 3
        case .active, .stale: return 4
        }
    }

    // The candidate set is the UNION of three sources (§4.1), so that convention is a
    // convenience rather than the limit of what can be tracked: a profile rooted at an
    // arbitrary path is invisible to the conventional scan and — because the digest
    // cannot be inverted — equally invisible to store enumeration.
    func candidateDirectories(registeredLocations: [String]) -> [String] {
        guard let home = ClaudeProfileDiscovery.lexicallyStandardized(fileSystem.homeDirectoryPath)
        else { return [] }
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ path: String, source: String) {
            guard let normalized = ClaudeProfileDiscovery.normalize(path, home: home) else {
                log("🔎 Ignoring \(source) '\(path)': not an absolute path")
                return
            }
            // The home directory itself is never a profile. Registering it (or pointing
            // the environment variable at it) would otherwise create a SECOND candidate
            // carrying the default account's identity — through the home-level identity
            // file that only `~/.claude` is allowed to read — and the two would collide
            // on one identity.
            guard normalized != home else {
                log("🔎 Ignoring \(source) '\(path)': the home directory is not a profile")
                return
            }
            guard seen.insert(normalized).inserted else { return }
            guard fileSystem.isDirectory(atPath: normalized) else { return }
            ordered.append(normalized)
        }

        // Conventional home-directory locations, default first so it leads the popover
        // and wins the dedup tie-break among equally healthy candidates.
        append(home + "/" + ClaudeProfileDiscovery.defaultDirectoryName, source: "profile")
        for entry in fileSystem.directoryEntries(atPath: home).sorted()
        where entry.hasPrefix(ClaudeProfileDiscovery.defaultDirectoryName + "-") {
            append(home + "/" + entry, source: "profile")
        }

        // The configuration directory designated by the environment, when one is set.
        if let designated = fileSystem.environmentVariable(
            ClaudeProfileDiscovery.configDirectoryEnvironmentVariable
        ) {
            append(designated, source: ClaudeProfileDiscovery.configDirectoryEnvironmentVariable)
        }

        // Directories the user has explicitly registered (§7.3). Arbitrary absolute
        // paths: neither necessarily under home nor matching the naming convention.
        for location in registeredLocations {
            append(location, source: "registered location")
        }

        return ordered
    }

    // §4.1, and the single most dangerous rule in this file.
    //
    // DEFAULT DIRECTORY: the unsuffixed entry is authoritative and the derived name is
    // NOT CONSULTED AT ALL. On the target machine the derived name for `~/.claude` —
    // `6a445fbb` — exists and holds 506 bytes of data carrying no OAuth block, so a
    // hash-first implementation binds it and reports the user's PRIMARY account as
    // signed out. No fallback can distinguish that anomaly from a legitimate
    // credential, so there is no fallback: when the authoritative entry is absent the
    // account resolves to signedOut.
    static func serviceName(forDirectory directory: String, home: String) -> String {
        guard !isDefaultDirectory(directory, home: home) else { return defaultServiceName }
        return derivedServicePrefix + sha256Prefix(normalize(directory, home: home) ?? directory)
    }

    // First 8 hex characters of the hex digest of the absolute path, WITH NO TRAILING
    // SLASH. Verified against the store on the target machine: `~/.claude-work-fiona`
    // → 6c3a8789, `~/.claude-work-ethan` → de838ebc.
    static func sha256Prefix(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    static func isDefaultDirectory(_ directory: String, home: String) -> Bool {
        normalize(directory, home: home) == home + "/" + defaultDirectoryName
    }

    // Label = directory basename with a leading `.claude-` stripped, or "default" for
    // `~/.claude`. Presentation only: §3 keys everything durable on the identity, so
    // renaming a profile directory must not orphan its history.
    static func label(forDirectory directory: String, home: String) -> String {
        if isDefaultDirectory(directory, home: home) { return "default" }
        let path = normalize(directory, home: home) ?? directory
        let name = String(path.split(separator: "/").last ?? "")
        let prefix = defaultDirectoryName + "-"
        if name.hasPrefix(prefix), name.count > prefix.count {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    // Absolute, lexical, and — critically — resolved against the INJECTED home.
    // Returns nil for anything that is not absolute after `~` expansion.
    //
    // Foundation's `standardizingPath` cannot be used here, measured twice over: it
    // expands `~` against the PROCESS's real home (so an injected home is silently
    // bypassed and a test reads the developer's own machine), and it consults the real
    // filesystem (`/private/tmp/x` → `/tmp/x`). The second is not cosmetic: the service
    // name is the digest of this string, so rewriting the path yields a name the CLI
    // never wrote and a healthy account renders signedOut. Task 11 feeds user-typed
    // paths straight in here.
    //
    // A relative path is REJECTED rather than resolved: there is no defensible base to
    // resolve it against — the app's working directory is wherever the window server
    // launched it — and resolving it wrongly produces exactly the silent-signedOut
    // failure above.
    static func normalize(_ path: String, home: String) -> String? {
        lexicallyStandardized(expandingTilde(path, home: home))
    }

    static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    // Purely textual: no symlink resolution, no filesystem access, no environment.
    static func lexicallyStandardized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    // The identity gate. Reads the `oauthAccount` object from the profile's
    // configuration; a directory without one is not an account and never appears in any
    // state (this is what excludes `~/.claude-backups` and `~/.claude-koop-llm-stub`).
    //
    // The default profile is a deliberate special case, verified on the target machine:
    // `~/.claude/.claude.json` EXISTS but carries no `oauthAccount`, while the
    // home-level `~/.claude.json` carries it. Consulting only the in-directory file
    // would exclude the user's primary account outright. The home-level fallback is
    // restricted to the default directory: allowing any profile to inherit it would let
    // a signed-out sibling profile borrow the default account's identity.
    //
    // PRECEDENCE, pinned by test: in-directory FIRST, home-level second. The
    // in-directory file is the profile's own configuration and the more specific
    // statement about that profile; the home-level file is the shared one the default
    // profile happens to sit alongside. If a future CLI starts writing `oauthAccount`
    // into `~/.claude/.claude.json`, that file becomes authoritative — the intended
    // outcome, since it is then the one the CLI maintains.
    func identityFile(for directory: String, home: String) -> ClaudeAccountIdentityFile? {
        var paths = [directory + "/" + ClaudeProfileDiscovery.identityFileName]
        if ClaudeProfileDiscovery.isDefaultDirectory(directory, home: home) {
            paths.append(home + "/" + ClaudeProfileDiscovery.identityFileName)
        }
        for path in paths {
            guard let data = fileSystem.fileContents(atPath: path) else { continue }
            // Bounded: discovery re-runs on every popover open, and a corrupt or
            // pathological config must not be pulled into memory wholesale.
            guard data.count <= ClaudeProfileDiscovery.maximumIdentityFileBytes else {
                log("🔎 Ignoring \(path): \(data.count) bytes exceeds the config size cap")
                continue
            }
            guard let identity = ClaudeAccountIdentityFile.decode(data) else { continue }
            return identity
        }
        return nil
    }

    // §4.1's registered-location escape hatch, validated AT REGISTRATION. A location that
    // fails the identity gate must be reported as such the moment the user adds it — not
    // accepted and then silently dropped by the next survey, which is indistinguishable
    // from a bug ("I added my config and nothing showed up"). This runs the SAME gate the
    // survey does (`normalize` → not-home → is-a-directory → `identityFile` carries an
    // `oauthAccount` with at least one identifier), so a location this accepts is exactly a
    // location the survey will resolve to an account. Credential HEALTH is deliberately not
    // checked here: §4.1 makes the identity file decide inclusion and the credential decide
    // STATE, so a validly-configured but signed-out profile is a legitimate account to
    // track — it will simply render "Sign in via …". PURE: reuses the injected filesystem,
    // so a passing and a failing candidate are both testable without touching the machine.
    func validateCandidate(_ location: String) -> RegisteredLocationValidation {
        guard let home = ClaudeProfileDiscovery.lexicallyStandardized(fileSystem.homeDirectoryPath) else {
            return .rejected(reason: "Home directory could not be resolved.")
        }
        guard let normalized = ClaudeProfileDiscovery.normalize(location, home: home) else {
            // Matches task 4's contract: a registered location is an absolute path; a
            // relative one has no defensible base for a window-server-launched app.
            return .rejected(reason: "Enter an absolute path (starting with / or ~).")
        }
        guard normalized != home else {
            return .rejected(reason: "The home directory itself is not a profile.")
        }
        guard fileSystem.isDirectory(atPath: normalized) else {
            return .rejected(reason: "No directory exists at this path.")
        }
        guard let identity = identityFile(for: normalized, home: home),
              !identity.identityComponents.isEmpty else {
            return .rejected(reason: "No Claude account is configured here "
                             + "(\(ClaudeProfileDiscovery.identityFileName) has no oauthAccount).")
        }
        return .accepted(
            normalizedPath: normalized,
            label: ClaudeProfileDiscovery.label(forDirectory: normalized, home: home)
        )
    }

    // The credential gate. It decides STATE, never inclusion (§4.1) — an account whose
    // credential is absent, unusable or unreadable is still present, in `signedOut` or
    // `failed`. Filtering it out here would make those states unrepresentable in the UI.
    //
    // Resolves to `pending`, `signedOut`, `expired` or `failed` ONLY. `active` and
    // `stale` are produced by a successful fetch (§3): an account is authenticated well
    // before it has a reading, and collapsing the two would force discovery to fabricate
    // a snapshot or misreport a healthy account.
    func state(forService service: String, now: Date) -> AccountState {
        switch credentials.lookupCredential(service: service) {
        case .absent:
            // The one case that genuinely means "sign in": the entry is not there.
            return .signedOut
        case .failed(let fault):
            // The app could not find out. Saying "signed out" here would be confident
            // and wrong, and would send the user to re-authenticate a live session.
            return .failed(fault)
        case .found(let blob):
            switch ClaudeCredential.decode(blob) {
            case .usable(let credential):
                return credential.expiresAt <= now ? .expired(credential.expiresAt) : .pending
            case .noOAuthMaterial:
                // Well-formed, and it says this profile holds no OAuth credential.
                return .signedOut
            case .unreadable(let fault):
                return .failed(fault)
            }
        }
    }
}
