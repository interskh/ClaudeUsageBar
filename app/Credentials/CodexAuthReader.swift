import Foundation

// Codex credential discovery (§4.2). PURE: the filesystem arrives through the same
// injected `ProfileFileSystem` protocol `ClaudeProfileDiscovery` takes, so this whole
// file — path resolution, the auth-mode gate, the composite identity rule — compiles
// into the test target and runs against in-memory fixtures with no machine underneath
// it. There is no second filesystem abstraction: the concrete implementation is already
// app-only and already excluded from the test compile by name.
//
// READ-ONLY, and that is a design constraint rather than a habit (§1). Nothing here
// writes, refreshes or rotates `auth.json`; the CLI owns that file and a second writer
// would race it.
//
// The credential document may carry unrelated third-party material, so this file reads
// ONLY the subtrees it needs, retains only the four fields on `CodexCredential`, and
// never quotes any part of the document into a log, an error, a warning or a fixture
// (the rule task 4 learned the hard way — see the handoff log).

// What one read of `auth.json` resolved to. SIX cases, not an optional and not a boolean.
// §4.1 established that "there is no credential" (normal, user-actionable) and "the app
// could not find out" (an operational fault) must stay distinguishable. Codex adds two
// more shapes of its own: a credential that is perfectly valid but belongs to an API-key
// login rather than a ChatGPT subscription, and one that carries a working token but
// nothing durable to key persisted state on.
enum CodexAuthRead: Equatable {
    case usable(CodexCredential)

    // `auth.json` is not there. The user has not signed in, or has signed out.
    case fileMissing

    // Signed in, but not with a ChatGPT subscription (§4.2 requires
    // `auth_mode == "chatgpt"`). An API-key login has no subscription quota, so there is
    // nothing to poll — but the user is not "signed out" either, and telling them so
    // would send them to fix something that is not broken.
    case unsupportedAuthMode

    // The document parsed but carries no bearer token to send.
    case noAccessToken

    // A WORKING TOKEN THAT CANNOT BE KEYED. Deliberately not `usable`: §4.2 exists to
    // stop persisted state being misattributed between sign-ins, and an account with no
    // durable identifier at all would have to share one persistence namespace with every
    // other such account — so the next sign-in would inherit the previous occupant's
    // cached readings and notification history. Refusing to fetch is what makes that
    // namespace permanently EMPTY rather than merely warned about.
    case noDurableIdentity

    // Present, and could not be read: not JSON, not an object, unreadable bytes. Names
    // the FAULT only — never the payload, which is the secret.
    case unreadable(String)
}

// The four fields this app needs out of the credential, and nothing else. Deliberately
// not a decode of the whole document: retaining the rest would put unrelated secrets in
// memory and, sooner or later, in a diagnostic.
struct CodexCredential: Equatable {
    let accessToken: String
    // `tokens.account_id` — a UUID on the target machine.
    let accountIdentifier: String?
    // The id_token's `chatgpt_user_id` / `user_id` claim — a `user-…` string.
    let userIdentifier: String?
    let emailAddress: String?  // presentation only (`AccountRef.subtitle`)

    // §4.2: IDENTITY IS COMPOSITE, and it is composite because neither field is
    // trustworthy alone — the identifier sent with the request and the one returned in
    // the response have been OBSERVED to disagree, the response reusing its user
    // identifier as its account identifier. Keying on either single field misattributes
    // one signed-in account's notification history and cached readings to the next.
    //
    // FIXED ARITY, always two slots, with a resolved-but-missing component spelled as an
    // empty one. A variable-length composite would change the account's `storageKey` —
    // and so orphan its persisted state (§6, §8) — the day one of the two fields fails to
    // parse and comes back.
    //
    // Each component is namespaced by its field, so an account identifier that happens to
    // equal another account's user identifier cannot alias it: ["account:x", "user:"] and
    // ["account:", "user:x"] stay distinct (and `AccountIdentity` keeps components as a
    // list precisely so they cannot be run together).
    //
    // KNOWN RESIDUAL, warned about rather than hidden (`Warning.halfResolvedIdentity`):
    // when only one half resolves, the key carries only that half's information. Two
    // sign-ins sharing an account identifier — plausible if it names a workspace rather
    // than a person — and both lacking a readable user half would land on one key. The
    // alternative, refusing a credential over a field the request never sends, takes a
    // working account off the screen; the warning is the honest middle.
    var identityComponents: [String] {
        guard accountIdentifier != nil || userIdentifier != nil else {
            // Unreachable from `CodexAuthReader.read`, which resolves this to
            // `.noDurableIdentity` before a credential is ever built. Kept total because
            // the type is visible and a caller could construct one directly; the sentinel
            // cannot alias a real composite, which always has exactly two differently
            // prefixed components.
            return [CodexCredential.unresolvedIdentityComponent]
        }
        return ["account:" + (accountIdentifier ?? ""), "user:" + (userIdentifier ?? "")]
    }

    static let unresolvedIdentityComponent = "unresolved"

    // Conditions §4.2 requires be SURFACED rather than silently resolved to one field.
    // They travel on `Snapshot.warnings` (§3 gives discovery no warnings channel, and an
    // ambiguous identity is emphatically not a fetch failure).
    var identityWarnings: [String] {
        guard let accountIdentifier, let userIdentifier else {
            return [CodexCredential.Warning.halfResolvedIdentity]
        }
        // The two halves of the composite COLLIDE: the credential names one value twice,
        // so the composite carries no more information than a single field and a re-login
        // that changed only the other half would be invisible.
        return accountIdentifier == userIdentifier
            ? [CodexCredential.Warning.collidingIdentifiers]
            : []
    }

    enum Warning {
        static let collidingIdentifiers =
            "This Codex sign-in uses one identifier for both the account and the user."
        static let halfResolvedIdentity =
            "Only part of this Codex account's identity could be read; "
            + "its usage history may not survive signing out and back in."
    }
}

// A bearer token must not be printable by ANY diagnostic path, including a test harness
// that stringifies a value to describe a failed comparison. The synthesized reflection
// would print `accessToken` in full, so both description hooks are overridden — and
// `CodexAuthRead`'s own reflection routes through these for its associated value.
extension CodexCredential: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "CodexCredential(token: <redacted>, account: \(accountIdentifier != nil), "
            + "user: \(userIdentifier != nil), email: \(emailAddress != nil))"
    }

    var debugDescription: String { description }
}

// Reads `$CODEX_HOME/auth.json`, else `~/.codex/auth.json` (§4.2).
struct CodexAuthReader {
    static let homeEnvironmentVariable = "CODEX_HOME"
    static let defaultDirectoryName = ".codex"
    static let credentialFileName = "auth.json"
    // §4.2: the ONE accepted mode. An API-key login is a valid credential for a different
    // product and has no subscription quota.
    static let requiredAuthMode = "chatgpt"

    // A credential document is a few KB (about 4 KB on the target machine). The cap
    // exists so a corrupt or pathological file cannot be pulled into memory wholesale on
    // a discovery pass that runs on every popover open; exceeding it is a read FAULT, not
    // an absence, so it cannot masquerade as "signed out".
    static let maximumCredentialBytes = 4 * 1024 * 1024

    let fileSystem: ProfileFileSystem
    private let log: (String) -> Void

    init(fileSystem: ProfileFileSystem, log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.fileSystem = fileSystem
        self.log = log
    }

    // The configuration directory, resolved but not required to exist.
    //
    // The environment variable wins when it is set, exactly as the CLI resolves it. It is
    // normalised lexically — never against the real filesystem — so the path this app
    // reads is the path the string names.
    var directoryPath: String? {
        guard let home = ClaudeProfileDiscovery.lexicallyStandardized(fileSystem.homeDirectoryPath)
        else { return nil }
        if let configured = fileSystem.environmentVariable(CodexAuthReader.homeEnvironmentVariable) {
            guard let normalized = ClaudeProfileDiscovery.normalize(configured, home: home) else {
                log("🔎 Ignoring \(CodexAuthReader.homeEnvironmentVariable) "
                    + "'\(configured)': not an absolute path")
                return nil
            }
            return normalized
        }
        return home + "/" + CodexAuthReader.defaultDirectoryName
    }

    var credentialPath: String? {
        directoryPath.map { $0 + "/" + CodexAuthReader.credentialFileName }
    }

    // THE INCLUSION GATE, and it is deliberately the DIRECTORY rather than the credential
    // — the same split §4.1 draws for the sibling. A machine with no Codex configuration
    // at all has no Codex account and shows nothing; a machine that has one but is signed
    // out shows a signed-out account rather than pretending Codex does not exist.
    var isInstalled: Bool {
        guard let directoryPath else { return false }
        return fileSystem.isDirectory(atPath: directoryPath)
    }

    func read() -> CodexAuthRead {
        guard let credentialPath else {
            return .unreadable("the home directory is not an absolute path")
        }
        let data: Data
        switch fileSystem.readFile(atPath: credentialPath) {
        case .missing:
            return .fileMissing
        // Existing-but-unreadable is a FAULT. The CLI rewrites this file on every token
        // rotation, so a read landing mid-write is routine — and reporting that as
        // "signed out" is advice that is both wrong and actionable in the wrong direction.
        case .unreadable(let fault):
            return .unreadable(fault)
        case .contents(let contents):
            data = contents
        }
        guard data.count <= CodexAuthReader.maximumCredentialBytes else {
            return .unreadable("the credential file is implausibly large")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unreadable("the credential file is not a JSON object")
        }

        // §4.2's gate. An absent mode is NOT assumed to be the required one: assuming it
        // would send an API key's bearer token to the subscription endpoint.
        guard let mode = CodexAuthReader.string(root["auth_mode"]),
              mode == CodexAuthReader.requiredAuthMode
        else { return .unsupportedAuthMode }

        // THE ONLY SUBTREE READ. Siblings are neither retained nor enumerated — and the
        // API key that sits at this same top level is never named anywhere in this file's
        // read path: §4.2 puts it outside subscription quota entirely, and the rule holds
        // when it is populated as much as when it is null.
        guard let tokens = root["tokens"] as? [String: Any] else { return .noAccessToken }
        guard let accessToken = CodexAuthReader.string(tokens["access_token"]) else {
            return .noAccessToken
        }

        let claims = CodexAuthReader.identityClaims(
            inIDToken: CodexAuthReader.string(tokens["id_token"])
        )
        // The stored `account_id` and the JWT's own account claim have been observed
        // identical; the stored one wins because it is also the value sent in the
        // `X-Account-Id` header, so the identity keys on the field the request uses.
        let accountIdentifier = CodexAuthReader.string(tokens["account_id"]) ?? claims.account
        guard accountIdentifier != nil || claims.user != nil else {
            // See `CodexAuthRead.noDurableIdentity`: a token we cannot key is a token we
            // cannot safely cache or notify for.
            return .noDurableIdentity
        }

        return .usable(CodexCredential(
            accessToken: accessToken,
            accountIdentifier: accountIdentifier,
            userIdentifier: claims.user,
            emailAddress: claims.email
        ))
    }

    // MARK: - id_token claims

    // The `id_token` is a JWT whose payload segment carries the identity claims. It is
    // read for IDENTITY ONLY.
    //
    // §4.2 FORBIDS reading the plan from here: the subscription claims are a cache
    // stamped at `chatgpt_subscription_last_checked` and were observed a month stale on
    // an active account, so the plan comes from the live usage response instead. Nothing
    // below touches those claims, and adding them would reintroduce a value that is wrong
    // in the direction of showing a lapsed subscription as current.
    //
    // The signature is NOT verified, and does not need to be: this is our own locally
    // stored token, read to decide which folder of persisted state to use. Nothing is
    // authorised on the strength of these claims — the upstream endpoint validates the
    // token it is sent.
    static let claimNamespace = "https://api.openai.com/auth"

    struct IdentityClaims: Equatable {
        let account: String?
        let user: String?
        let email: String?
    }

    static func identityClaims(inIDToken token: String?) -> IdentityClaims {
        let none = IdentityClaims(account: nil, user: nil, email: nil)
        guard let token else { return none }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        // header.payload.signature. A token with a different shape is not one we can read;
        // identity then rests on the stored `account_id` alone, which is surfaced through
        // `halfResolvedIdentity` rather than silently reducing the composite.
        guard segments.count == 3,
              let payload = base64URLDecoded(String(segments[1])),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        else { return none }

        let scoped = claims[claimNamespace] as? [String: Any] ?? [:]
        return IdentityClaims(
            account: string(scoped["chatgpt_account_id"]),
            // Both spellings are present and identical in the observed token. Reading both
            // costs one `??` and covers the vendor retiring either.
            //
            // The JWT's `sub` is deliberately NOT a third fallback: it resolves a
            // DIFFERENT value for the same account, so the day the preferred claims came
            // back the account's `storageKey` would move and §6 would reclaim its history.
            // A fallback that changes identity is worse than an absent half, which at
            // least holds its place.
            user: string(scoped["chatgpt_user_id"]) ?? string(scoped["user_id"]),
            email: string(claims["email"])
        )
    }

    // JWT segments are base64url WITHOUT padding, which `Data(base64Encoded:)` rejects
    // outright — so the obvious one-liner returns nil on every real token and the whole
    // identity composite silently degrades to its stored half.
    static func base64URLDecoded(_ segment: String) -> Data? {
        var encoded = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
