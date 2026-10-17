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

    func read() -> MuseAuthRead {
        guard let authPath else {
            return .unreadable("the home directory is not an absolute path")
        }
        let data: Data
        switch fileSystem.readFile(atPath: authPath) {
        case .missing:
            return .fileMissing
        case .unreadable(let fault):
            return .unreadable(fault)
        case .contents(let contents):
            data = contents
        }
        guard data.count <= MuseAuthReader.maximumCredentialBytes else {
            return .unreadable("the credential file is implausibly large")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let meta = providers["meta"] as? [String: Any] else {
            return .unreadable("the credential file carries no Meta provider block")
        }
        guard MuseAuthReader.string(meta["mechanism"]) == MuseAuthReader.requiredMechanism else {
            return .unsupportedMechanism
        }

        let email = MuseAuthReader.string(meta["user_email"])
        let fullName = MuseAuthReader.string(meta["user_full_name"])

        // Inline token (non-Keychain storage), else the CLI's Keychain item.
        if let inline = MuseAuthReader.string(meta["access_token"]) {
            guard email != nil else { return .noDurableIdentity }
            return .usable(MuseCredential(accessToken: inline,
                                          emailAddress: email,
                                          fullName: fullName))
        }
        switch tokens.lookupCredential(service: MuseAuthReader.keychainService) {
        case .absent:
            return .noAccessToken
        case .failed(let fault):
            return .unreadable(fault)
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
