import Foundation

// Resolves the installed CLI's version by running it (§5.1). APP-ONLY: it launches a
// subprocess and reads the real filesystem, which §10 keeps out of the test target. The
// policy it feeds — caching, the daily refresh, parsing and validating the output, the
// floor — is pure and lives in `AgentVersion`.
//
// NO PATH LOOKUP, EVER. A menu-bar app launched by the window server or as a login item
// inherits no shell environment, so `claude --version` resolved through PATH works in
// development and finds nothing in the shipped bundle — silently, since a failed
// resolution is a normal outcome that falls back to the floor. Every candidate below is
// an absolute path, and the only environment consulted is the process's own home
// directory, which the window server does provide.
//
// The version comes from the EXECUTABLE. Version-like fields recorded in the CLI's own
// configuration are onboarding artefacts and were observed many releases stale on the
// target machine, so they are not consulted even as a fallback.
struct InstalledAgentVersionProbe: AgentVersionProbing {
    // Known install locations, most specific first. Adding one is cheap; getting one
    // wrong costs nothing, since a missing file is skipped without a subprocess.
    static func candidatePaths(home: String) -> [String] {
        [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            home + "/.bun/bin/claude",
            home + "/.npm-global/bin/claude",
            home + "/node_modules/.bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
    }

    // The probe runs at most once a day (`AgentVersionCache`), so a generous bound costs
    // nothing; a CLI that hangs must not hold an actor for longer than this.
    static let timeoutSeconds = 10

    // Version output is a single short line. The cap exists so that pointing this at the
    // wrong executable cannot stream unbounded output into memory.
    static let maximumOutputBytes = 8 * 1024

    // Deterministic, and the same whether the app was launched from a shell, from Finder,
    // or as a login item. The PATH here is only ever used to resolve a shebang
    // interpreter, so it names the system locations and the two package-manager prefixes
    // an interpreter is realistically installed under.
    static func minimalEnvironment(home: String) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": home,
        ]
    }

    let home: String

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home = home
    }

    func probeVersionOutput() -> String? {
        for path in InstalledAgentVersionProbe.candidatePaths(home: home) {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if let output = run(path) { return output }
        }
        return nil
    }

    private func run(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        // An explicit, minimal environment rather than the inherited one. Naming the
        // executable absolutely is not by itself enough: an npm-global install ships a JS
        // entrypoint whose `#!/usr/bin/env node` shebang makes the KERNEL resolve the
        // interpreter through the PATH this process hands down. Inheriting it would put
        // the same environment dependency back one level lower, where it is invisible.
        // (Not live on the target machine — the installed CLI is a Mach-O binary with no
        // shebang — but the failure mode it prevents is silent.)
        process.environment = InstalledAgentVersionProbe.minimalEnvironment(home: home)

        let output = Pipe()
        process.standardOutput = output
        // Discarded: a version probe has nothing to say on stderr that a caller could
        // act on, and not capturing it removes any path by which it could be surfaced.
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drained concurrently with the wait: a process blocked writing into a full pipe
        // while we block waiting for it to exit is a deadlock.
        let handle = output.fileHandleForReading
        let collected = Collected()
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count > InstalledAgentVersionProbe.maximumOutputBytes { break }
            }
            try? handle.close()
            collected.finish(buffer)
        }

        if exited.wait(timeout: .now() + .seconds(InstalledAgentVersionProbe.timeoutSeconds))
            == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + .seconds(1))
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        guard let data = collected.wait(seconds: 2),
              data.count <= InstalledAgentVersionProbe.maximumOutputBytes,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}

// Hands bytes from the draining queue back to the caller exactly once. A locked class
// rather than a captured `var`, because the two run on different threads by design.
private final class Collected {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var data: Data?

    func finish(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
        ready.signal()
    }

    func wait(seconds: Int) -> Data? {
        _ = ready.wait(timeout: .now() + .seconds(seconds))
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
