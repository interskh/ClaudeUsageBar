import Foundation

// Muse credential discovery. PURE: the filesystem and the token store both arrive
// through injected protocols, so this file compiles into the test target.
//
// Muse keeps account metadata in `auth.json` and, on macOS, the OAuth device token
// itself in a Keychain item (`storage: "keychain"`). On other platforms the token is
// inline in `auth.json`. This reader resolves either shape and retains only the token
// plus the identity fields. It never writes, refreshes, or rotates anything: the Muse
// CLI owns both stores.
//
// The Keychain payload carries unrelated secret material beside the token (a minted
// inference key). Only `access_token` is read out of it; the rest is neither retained
// nor quoted anywhere.

enum MuseAuthRead: Equatable {
    case usable(MuseCredential)
    case fileMissing
    // Signed in with an API key rather than the Meta account login. An API key has no
    // subscription quota to read, so this is not usable — and not "signed out" either.
    case unsupportedMechanism
    case noAccessToken
    // A working token with no durable identifier to key persisted state on. Refusing
    // to fetch is what keeps two different sign-ins from sharing one state namespace.
    case noDurableIdentity
    // The Keychain item has not been read yet because no user action has asked for it.
    // Not signed out and not a fault: the card says how to connect.
    case notConnected
    case unreadable(String)
}

struct MuseCredential: Equatable {
    let accessToken: String
    let emailAddress: String?
    let fullName: String?

    var identityComponents: [String] {
        guard let emailAddress else { return [MuseCredential.unresolvedIdentityComponent] }
        return ["email:" + emailAddress]
    }

    static let unresolvedIdentityComponent = "unresolved"
}

extension MuseCredential: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "MuseCredential(token: <redacted>, email: \(emailAddress != nil), name: \(fullName != nil))"
    }
    var debugDescription: String { description }
}

// Reads `$MUSE_AUTH_PATH`, else `$XDG_CONFIG_HOME/muse/auth.json`, else
// `~/.config/muse/auth.json`. The device token comes from the file when it is inline,
// otherwise from the CLI's Keychain item through the injected credential source.
struct MuseAuthReader {
    static let authPathEnvironmentVariable = "MUSE_AUTH_PATH"
    static let xdgConfigHomeVariable = "XDG_CONFIG_HOME"
    static let configDirectoryName = "muse"
    static let credentialFileName = "auth.json"
    static let keychainService = "ai.meta.dev.credentials"
    static let requiredMechanism = "oauth"
    static let maximumCredentialBytes = 4 * 1024 * 1024
    // The CLI's item is partitioned to Meta's team ID, so the Apple tool `KeychainStore`
    // shells out to prompts on every read, and the CLI resets any grant when it rewrites
    // its token. Reads are therefore user-initiated only (see `MuseKeychainGate`), and
    // this is what the card says instead of prompting from the background.
    //
    // This deliberately relaxes the "re-read the credential on every fetch" rule
    // (KeychainStore, §3/§6): the gate holds the token in memory only — never persisted —
    // and drops it when upstream rejects it, returning the card to this state.
    static let connectInstruction = "Click Refresh to connect Muse — macOS will ask for Keychain access"

    let fileSystem: ProfileFileSystem
    let tokens: ClaudeCredentialSource
    private let log: (String) -> Void

    init(fileSystem: ProfileFileSystem,
         tokens: ClaudeCredentialSource,
         log: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.fileSystem = fileSystem
        self.tokens = tokens
        self.log = log
    }

    var authPath: String? {
        guard let home = ClaudeProfileDiscovery.lexicallyStandardized(fileSystem.homeDirectoryPath)
        else { return nil }
        if let configured = fileSystem.environmentVariable(MuseAuthReader.authPathEnvironmentVariable) {
            guard let normalized = ClaudeProfileDiscovery.normalize(configured, home: home) else {
                log("🔎 Ignoring \(MuseAuthReader.authPathEnvironmentVariable) "
                    + "'\(configured)': not an absolute path")
                return nil
            }
            return normalized
        }
        if let xdg = fileSystem.environmentVariable(MuseAuthReader.xdgConfigHomeVariable),
           let normalized = ClaudeProfileDiscovery.normalize(xdg, home: home) {
            return normalized + "/" + MuseAuthReader.configDirectoryName
                + "/" + MuseAuthReader.credentialFileName
        }
        return home + "/.config/" + MuseAuthReader.configDirectoryName
            + "/" + MuseAuthReader.credentialFileName
    }

    var configDirectoryPath: String? {
        authPath.map { ($0 as NSString).deletingLastPathComponent }
    }

    // The inclusion gate is the configuration directory, as with Codex: no Muse
    // configuration at all means no Muse account is shown; a configuration without a
    // usable credential shows a present, signed-out account.
    var isInstalled: Bool {
        guard let configDirectoryPath else { return false }
        return fileSystem.isDirectory(atPath: configDirectoryPath)
    }

    // A source that binds its cached token to an identity gets the auth file's email, so
    // a token read for one login is never served for another.
    private func lookupToken(boundTo email: String?) -> CredentialLookup {
        if let bound = tokens as? AccountBoundCredentialSource {
            return bound.lookupCredential(service: MuseAuthReader.keychainService, boundTo: email)
        }
        return tokens.lookupCredential(service: MuseAuthReader.keychainService)
    }

    private func forgetToken() {
        (tokens as? AccountBoundCredentialSource)?.invalidate()
    }

    // Whether a card is waiting for the user to connect: the bare instruction, or a
    // denied/timed-out read that ends with it. Both mean a Refresh click should arm.
    static func isWaitingToConnect(_ state: AccountState) -> Bool {
        if case .failed(let message) = state { return message.hasSuffix(connectInstruction) }
        return false
    }

    // One parse of the auth file shared by `read`, `credentialMaterial` and
    // `authIdentityEmail`, so what each of them is willing to do cannot drift: the
    // token source is consulted only for an oauth login with no inline token.
    private enum AuthFile {
        case rejected(MuseAuthRead, file: Data?)
        case oauth(email: String?, fullName: String?, inlineToken: String?, file: Data)
    }

    private func parseAuthFile() -> AuthFile {
        guard let authPath else {
            return .rejected(.unreadable("the home directory is not an absolute path"), file: nil)
        }
        let data: Data
        switch fileSystem.readFile(atPath: authPath) {
        case .missing:
            return .rejected(.fileMissing, file: nil)
        case .unreadable(let fault):
            return .rejected(.unreadable(fault), file: nil)
        case .contents(let contents):
            data = contents
        }
        guard data.count <= MuseAuthReader.maximumCredentialBytes else {
            return .rejected(.unreadable("the credential file is implausibly large"), file: data)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let meta = providers["meta"] as? [String: Any] else {
            return .rejected(.unreadable("the credential file carries no Meta provider block"),
                             file: data)
        }
        guard MuseAuthReader.string(meta["mechanism"]) == MuseAuthReader.requiredMechanism else {
            return .rejected(.unsupportedMechanism, file: data)
        }
        return .oauth(email: MuseAuthReader.string(meta["user_email"]),
                      fullName: MuseAuthReader.string(meta["user_full_name"]),
                      inlineToken: MuseAuthReader.string(meta["access_token"]),
                      file: data)
    }

    func read() -> MuseAuthRead {
        let email: String?
        let fullName: String?
        switch parseAuthFile() {
        case .rejected(let read, _):
            // Signed out or on another mechanism: whatever was cached belongs to a login
            // that no longer exists.
            if read == .fileMissing || read == .unsupportedMechanism { forgetToken() }
            return read
        case .oauth(let parsedEmail, let parsedName, let inline, _):
            email = parsedEmail
            fullName = parsedName
            // Inline token (non-Keychain storage), else the CLI's Keychain item.
            if let inline {
                forgetToken()
                guard email != nil else { return .noDurableIdentity }
                return .usable(MuseCredential(accessToken: inline,
                                              emailAddress: email,
                                              fullName: fullName))
            }
        }
        switch lookupToken(boundTo: email) {
        case .absent:
            return .noAccessToken
        case .failed(let fault):
            if fault == MuseKeychainGate.notConnectedFault { return .notConnected }
            return .unreadable(fault + "; " + MuseAuthReader.connectInstruction)
        case .found(let blob):
            guard let token = MuseAuthReader.token(inKeychainBlob: blob) else {
                return .noAccessToken
            }
            guard email != nil else { return .noDurableIdentity }
            return .usable(MuseCredential(accessToken: token,
                                          emailAddress: email,
                                          fullName: fullName))
        }
    }

    // The account's email as the auth file states it, for an oauth login whose token is
    // not available yet. Readable without the token, so a not-yet-connected account keeps
    // the same identity — and so its persisted state — as the connected one.
    func authIdentityEmail() -> String? {
        if case .oauth(let email, _, _, _) = parseAuthFile() { return email }
        return nil
    }

    // What the credential digest is taken over. An inline token means the Keychain is
    // never consulted — not even to digest it — so the file is the whole credential;
    // otherwise the (gated) token source, with the file as the fallback. A file that
    // `read` would reject never reaches the token source.
    func credentialMaterial() -> Data? {
        switch parseAuthFile() {
        case .rejected(_, let file):
            return file
        case .oauth(let email, _, let inline, let file):
            if inline != nil { return file }
            if case .found(let blob) = lookupToken(boundTo: email) {
                return blob
            }
            return file
        }
    }

    // The Keychain payload is a JSON object; only its `access_token` is read. Sibling
    // secrets in the same item are never retained.
    static func token(inKeychainBlob blob: Data) -> String? {
        var data = blob
        // The `security` tool appends a trailing newline; JSONSerialization tolerates
        // trailing whitespace, so no canonicalisation is needed beyond a size sanity.
        guard data.count <= maximumCredentialBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        data = Data()
        return string(root["access_token"])
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
