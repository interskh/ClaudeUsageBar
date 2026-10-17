import Foundation

// Gates every read of Muse's Keychain item. PURE: the real store arrives through the
// injected `ClaudeCredentialSource`, so this file compiles into the test target.
//
// Muse's item is partitioned to Meta's team ID, so macOS prompts on EVERY read through
// the `security` tool, and Muse resets any grant when it rewrites the token (roughly
// hourly). A poll reads the item several times, so left alone the background timer
// produces a prompt storm. The gate turns that into one prompt per user action:
//
//   - a token already read is served from memory and never touches the inner source;
//   - otherwise the inner source is consulted ONLY after `arm()`, which the shell calls
//     for a user-initiated Refresh, and each arm buys exactly one real read;
//   - an unarmed, uncached lookup reports `notConnectedFault` instead of reading.
//
// Two locks, so the main actor never waits on a prompt: `state` guards the flags and the
// cache and is only ever held briefly; `reads` serialises real reads, so concurrent
// background callers wait on the in-flight one and then see its cache instead of issuing
// a second read (a second prompt). `arm`, `endSurvey`, `invalidate` and `isArmed` touch
// `state` alone. An `invalidate` that lands mid-read wins: the read's result is not cached.
//
// An arm belongs to the user-initiated survey it was issued for. `arm()` returns a ticket,
// and `endSurvey` withdraws that arm if the survey never reached the gate (Muse not
// installed, inline token), so a later background survey cannot spend it. A newer arm
// (a click during an in-flight survey) carries a newer ticket and survives for the next.
//
// SECRET HANDLING: only the `access_token` is retained, in memory only — never
// persisted, logged, or quoted. The rest of the item's payload (a minted inference key)
// is dropped on the spot, and callers get a synthesized blob that carries the token
// alone. `invalidate()` drops it when upstream rejects the token.
final class MuseKeychainGate: ClaudeCredentialSource, @unchecked Sendable {
    static let notConnectedFault = MuseAuthReader.connectInstruction

    struct ArmTicket: Equatable {
        fileprivate let serial: Int
    }

    private let inner: ClaudeCredentialSource
    private let state = NSLock()
    private let reads = NSLock()
    private var token: String?
    private var armed = false
    private var armSerial = 0
    private var generation = 0

    init(inner: ClaudeCredentialSource) {
        self.inner = inner
    }

    // Nil when nothing is allowed: while a token is cached the cache path never reads, so
    // an arm would only linger and let a later background poll prompt after invalidation.
    @discardableResult
    func arm() -> ArmTicket? {
        state.lock()
        defer { state.unlock() }
        guard token == nil else { return nil }
        armed = true
        armSerial += 1
        return ArmTicket(serial: armSerial)
    }

    func endSurvey(_ ticket: ArmTicket?) {
        state.lock()
        defer { state.unlock() }
        if let ticket, ticket.serial == armSerial { armed = false }
    }

    var isArmed: Bool {
        state.lock()
        defer { state.unlock() }
        return armed
    }

    func invalidate() {
        state.lock()
        defer { state.unlock() }
        token = nil
        generation += 1
    }

    func lookupCredential(service: String) -> CredentialLookup {
        if let cached = cachedLookup() { return cached }
        reads.lock()
        defer { reads.unlock() }
        if let cached = cachedLookup() { return cached }

        state.lock()
        guard armed else {
            state.unlock()
            return .failed(MuseKeychainGate.notConnectedFault)
        }
        armed = false
        let startedAt = generation
        state.unlock()

        switch inner.lookupCredential(service: service) {
        case .absent:
            return .absent
        case .failed(let fault):
            return .failed(fault)
        case .found(let blob):
            guard let read = MuseAuthReader.token(inKeychainBlob: blob) else { return .absent }
            state.lock()
            if generation == startedAt { token = read }
            state.unlock()
            return synthesizedBlob(read)
        }
    }

    private func cachedLookup() -> CredentialLookup? {
        state.lock()
        defer { state.unlock() }
        return token.map(synthesizedBlob)
    }

    private func synthesizedBlob(_ token: String) -> CredentialLookup {
        guard let data = try? JSONSerialization.data(withJSONObject: ["access_token": token])
        else { return .failed("could not repackage the Muse token") }
        return .found(data)
    }
}
