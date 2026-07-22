import Foundation

// §5.1: the usage endpoint is reached with an agent `User-Agent`, and the version it
// advertises is resolved from the LOCALLY INSTALLED CLI rather than pinned at compile
// time. A pinned constant rots immediately — the value written into the spec was already
// ~150 releases behind the installed CLI on the day it was written.
//
// The policy lives here and is pure. Actually locating and running the executable is
// impure (it launches a subprocess and reads the real filesystem), so it arrives through
// `AgentVersionProbing` and its only real conformer is an APP-ONLY file. Two constraints
// on that conformer are stated here because they are the reason this seam exists at all:
//
//   1. Resolution MUST NOT depend on the inherited environment. A menu-bar app launched
//      by the window server or as a login item inherits no shell PATH, so a bare command
//      lookup succeeds in development and fails silently in the shipped bundle. The probe
//      therefore names absolute paths. (An early reading suggested the GUI path did carry
//      a populated environment; that measurement was taken from an app launched FROM a
//      shell, which forwards the caller's environment, and proves nothing about a Finder
//      or login-item launch.)
//   2. The version must come from the EXECUTABLE, not from a version-like field in the
//      CLI's own configuration — those are onboarding artefacts and were observed many
//      releases stale on the target machine.
//
// Failure is never fatal: an unresolved version falls back to the floor and the request
// still goes out.
protocol AgentVersionProbing {
    // Returns the raw `--version` output of the installed CLI, or nil if no installation
    // was found or it could not be run. "Not found" is a normal outcome, not an error.
    func probeVersionOutput() -> String?
}

enum AgentVersion {
    // The floor, and the ONLY hardcoded version in the app. It is a fallback, never a
    // default: if it is ever observed in a request while the CLI is installed, resolution
    // is broken.
    static let floor = "2.1.217"

    // §5.1: re-resolve at most daily. The probe launches a subprocess, so doing it per
    // fetch would spend ~0.4s of every 5-minute poll for a value that changes weekly at
    // most.
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    // Observed output: "2.1.217 (Claude Code)". Only the leading token is taken, and it
    // is validated rather than trusted: whatever comes back is interpolated into a
    // request header, so a multi-line or control-character-bearing value must not reach
    // it. A rejected parse falls back to the floor, which is always a working request.
    static func parse(_ output: String) -> String? {
        let firstLine = output.split(whereSeparator: { $0.isNewline }).first ?? ""
        var token = firstLine.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init) ?? ""
        if token.hasPrefix("v") { token = String(token.dropFirst()) }

        guard token.count <= 32, token.first?.isNumber == true else { return nil }
        // Digits, dots and the usual pre-release punctuation, in EITHER case: a
        // `2.1.0-RC1` build is a real version and would otherwise fall back to the floor.
        // Nothing here could break a header or smuggle a second one in.
        // Spelled out rather than using `.alphanumerics`, which admits non-ASCII letters
        // and digits that have no business in a header value.
        let allowed = CharacterSet(charactersIn:
            "0123456789.-+abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return token
    }

    static func userAgent(version: String) -> String { "claude-code/\(version)" }
}

// Holds the resolved version between polls. An actor because accounts poll concurrently
// (§6) and would otherwise each launch their own probe on the same tick.
//
// THREADING: `probeVersionOutput()` blocks for as long as its own timeout. That blocks
// this actor's executor, not the caller's — and callers are already off the main thread
// because every fetch is.
actor AgentVersionCache {
    private let probe: AgentVersionProbing
    private var resolved: String?
    private var resolvedAt: Date?

    init(probe: AgentVersionProbing) {
        self.probe = probe
    }

    func current(now: Date) -> String {
        if let resolved, let resolvedAt,
           now.timeIntervalSince(resolvedAt) < AgentVersion.refreshInterval,
           now >= resolvedAt {
            return resolved
        }
        // A failed probe is cached too, as the floor. Otherwise every poll on a machine
        // with no CLI installed re-runs a probe that is known to find nothing.
        let version = probe.probeVersionOutput().flatMap(AgentVersion.parse) ?? AgentVersion.floor
        resolved = version
        resolvedAt = now
        return version
    }
}
