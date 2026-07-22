import Foundation

// Strategy B (§2): read the Anthropic credential by shelling out to Apple's own
// `security` tool rather than calling `SecItemCopyMatching` in-process.
//
// This is not a stylistic choice, it was measured. Strategy A reads the item but
// PROMPTS ON EVERY LAUNCH — 9.8s of modal per item — and the grant does not survive a
// relaunch. The reason is structural and not fixable by keeping a signing identity
// stable: this build machine has no Developer ID certificate, so `build.sh` falls back
// to ad-hoc signing, and an ad-hoc signature's designated requirement is a cdhash pin
// over the exact binary. Every rebuild therefore invalidates every ACL grant. Strategy
// B is silent (~100ms) precisely because the process the ACL evaluates is Apple-signed,
// and its identity does not change when we rebuild.
//
// READ-ONLY, acceptance criterion 16. This type has exactly one verb, `read`, and the
// only tool invocation in it is a find. The app must never refresh or rotate a token:
// refresh tokens are single-use, so rotating one from a second process would spend
// Claude Code's token and break the user's login. There is deliberately no write path
// to disable, misconfigure, or reach by accident.
//
// SECRET HANDLING: the stored blob is NOT only the Anthropic token — a real entry on
// the target machine also carries third-party client secrets under `mcpOAuth`. No
// error, log line or diagnostic in this file interpolates any part of the payload;
// they carry the service name, the exit code and the fault only.
//
// This file is APP-ONLY: §10 keeps the Keychain out of the test target, and `build.sh`
// both excludes it from the test compile by name and greps the collected test sources
// for exactly this kind of dependency. Discovery reaches it only through the pure
// `ClaudeCredentialSource` protocol, which tests satisfy with a fake.
enum KeychainReadError: Error, Equatable {
    // Normal, not exceptional: an unsigned-in profile simply has no entry (§4.1
    // resolves it to `signedOut`). Every OTHER case here is a fault, and §4.1 requires
    // it to reach the UI as `failed` rather than being dressed up as signed out.
    case itemNotFound(service: String)
    case toolFailed(service: String, exitCode: Int32)
    case launchFailed(service: String, reason: String)
    case timedOut(service: String, seconds: Int)
    case oversizedPayload(service: String, limit: Int)

    // Names the service and the failure mode, NEVER the secret.
    var description: String {
        switch self {
        case .itemNotFound(let service):
            return "no keychain item for service \(service)"
        case .toolFailed(let service, let exitCode):
            return "keychain read exited \(exitCode) for service \(service)"
        case .launchFailed(let service, let reason):
            return "could not run the keychain reader for service \(service): \(reason)"
        case .timedOut(let service, let seconds):
            return "keychain read for service \(service) timed out after \(seconds)s"
        case .oversizedPayload(let service, let limit):
            return "keychain item for service \(service) exceeds \(limit) bytes"
        }
    }
}

struct KeychainStore: ClaudeCredentialSource {
    // The tool exits 44 on errSecItemNotFound.
    private static let itemNotFoundExitCode: Int32 = 44
    private static let toolPath = "/usr/bin/security"

    // A healthy read is ~100ms (measured). The watchdog exists for the unhealthy case:
    // a locked login keychain puts up a system prompt and the tool then waits on the
    // user indefinitely. Without a bound, §6's popover-open re-discovery would hang the
    // menu bar behind a dialog the user may never see.
    static let timeoutSeconds = 5

    // The credential blob is ~1.5 KB. The cap is three orders of magnitude above that
    // and exists so a wrong or corrupted item cannot be streamed into memory without
    // limit. Exceeding it is a fault, not a silent truncation — a truncated credential
    // would parse as malformed and read as a broken account.
    static let maximumPayloadBytes = 1024 * 1024

    let account: String

    init(account: String = NSUserName()) {
        self.account = account
    }

    // No caching, by construction: this type has no storage beyond the account name, so
    // there is nowhere for a token to be retained between calls. §3/§6 require the
    // credential to be re-read on EVERY fetch — Claude Code rotates the access token
    // roughly every 8 hours, and a cached copy would park a live account as expired.
    //
    // THREADING: blocks the calling thread for up to `timeoutSeconds`. MUST NOT be
    // called on the main thread — with N accounts this is N sequential invocations.
    func lookupCredential(service: String) -> CredentialLookup {
        switch read(service: service) {
        case .success(let data):
            return .found(data)
        case .failure(.itemNotFound):
            return .absent
        case .failure(let error):
            // Logged AND returned: the log is for the developer, the returned fault is
            // what §4.1 requires the card to show instead of a false "signed out".
            NSLog("%@", "🔑 Keychain read failed: \(error.description)")
            return .failed(error.description)
        }
    }

    // Returns the RAW bytes as the tool printed them, including the trailing newline it
    // appends. Canonicalising lives with the parsing in `ClaudeCredential`, which is
    // pure and covered by tests; doing it here would put it in the one file the test
    // target cannot reach.
    func read(service: String) -> Result<Data, KeychainReadError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: KeychainStore.toolPath)
        // Absolute path, never a bare command name: a menu-bar app launched by the
        // window server or as a login item does not inherit a shell PATH (§5.1).
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]

        let output = Pipe()
        process.standardOutput = output
        // Discarded rather than captured: stderr adds nothing a caller can act on, and
        // not holding it removes any chance of a diagnostic path echoing it.
        process.standardError = FileHandle.nullDevice

        let collector = OutputCollector(limit: KeychainStore.maximumPayloadBytes)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(service: service, reason: "\(error)"))
        }

        // Drained CONCURRENTLY with the wait, not after it: a process blocked writing
        // into a full pipe while we block waiting for it to exit is a deadlock, and the
        // payload size is the vendor's to change.
        let handle = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { collector.drain(handle) }

        if exited.wait(timeout: .now() + .seconds(KeychainStore.timeoutSeconds)) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + .seconds(1))
            _ = collector.finish(timeout: 1)
            return .failure(.timedOut(service: service, seconds: KeychainStore.timeoutSeconds))
        }
        let drained = collector.finish(timeout: 2)

        guard process.terminationStatus == 0 else {
            if process.terminationStatus == KeychainStore.itemNotFoundExitCode {
                return .failure(.itemNotFound(service: service))
            }
            return .failure(.toolFailed(service: service, exitCode: process.terminationStatus))
        }
        switch drained {
        case .overLimit:
            return .failure(.oversizedPayload(service: service,
                                              limit: KeychainStore.maximumPayloadBytes))
        case .data(let data):
            // An empty payload is not a credential. `ClaudeCredential.decode` would
            // reject it anyway; this keeps the distinction visible at the read boundary,
            // where "nothing there" is still `absent` rather than a fault.
            guard !data.isEmpty else { return .failure(.itemNotFound(service: service)) }
            return .success(data)
        }
    }
}

// Reads a pipe on a background queue, bounded in size, and hands the bytes back exactly
// once. A class with a lock rather than a captured `var`, because the drain and the
// caller run on different threads by design — that is the whole point of the watchdog.
private final class OutputCollector {
    enum Outcome {
        case data(Data)
        case overLimit
    }

    private let limit: Int
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var overLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            lock.lock()
            if buffer.count + chunk.count > limit {
                overLimit = true
                // Dropped rather than truncated: a partial credential is worse than
                // none, and holding a megabyte of it serves nothing.
                buffer = Data()
                lock.unlock()
                break
            }
            buffer.append(chunk)
            lock.unlock()
        }
        try? handle.close()
        finished.signal()
    }

    // Waits briefly for the drain to finish, then reports what it has. A drain that has
    // not finished cannot be waited on indefinitely without reintroducing the hang the
    // watchdog exists to prevent.
    func finish(timeout seconds: Int) -> Outcome {
        _ = finished.wait(timeout: .now() + .seconds(seconds))
        lock.lock()
        defer { lock.unlock() }
        return overLimit ? .overLimit : .data(buffer)
    }
}
