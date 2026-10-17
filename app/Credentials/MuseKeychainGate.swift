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
//   - otherwise the inner source is consulted ONLY under an activated arm, which the
//     shell issues for a user-initiated Refresh, and each arm buys exactly one real read;
//   - an unarmed, uncached lookup reports `notConnectedFault` instead of reading.
//
// The cached token is bound to the auth file's email it was read for. A lookup for a
// different (or no) email is a cache miss that drops the token, so a `muse logout &&
// muse login` as someone else can never pair the old token with the new identity.
//
// Two locks, so the main actor never waits on a prompt: `state` guards the flags and the
// cache and is only ever held briefly; `reads` serialises real reads, so concurrent
// background callers wait on the in-flight one and then see its cache instead of issuing
// a second read (a second prompt). `arm`, `endSurvey`, `invalidate` and `isArmed` touch
// `state` alone. An `invalidate` that lands mid-read wins: the read's result is not cached.
//
// An arm belongs to the user-initiated survey it was issued for. `arm()` only records a
// pending ticket; the owning survey activates it when it STARTS (`beginSurvey`), so a
// survey already running cannot spend it, and `endSurvey` withdraws it if the survey never
// reached the gate (Muse not installed, inline token). A newer arm (a click during an
// in-flight survey) carries a newer ticket and waits for the next survey.
//
// SECRET HANDLING: only the `access_token` is retained, in memory only — never
// persisted, logged, or quoted. The rest of the item's payload (a minted inference key)
// is dropped on the spot, and callers get a synthesized blob that carries the token
// alone. `invalidate()` drops it when upstream rejects the token.
protocol AccountBoundCredentialSource: ClaudeCredentialSource {
    func lookupCredential(service: String, boundTo email: String?) -> CredentialLookup
    func invalidate()
}

final class MuseKeychainGate: AccountBoundCredentialSource, @unchecked Sendable {
    static let notConnectedFault = MuseAuthReader.connectInstruction

    struct ArmTicket: Equatable {
        fileprivate let serial: Int
    }

    private let inner: ClaudeCredentialSource
    private let state = NSLock()
    private let reads = NSLock()
    private var cache: (token: String, email: String)?
    private var pendingSerial: Int?
    private var activeSerial: Int?
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
        guard cache == nil else { return nil }
        armSerial += 1
        pendingSerial = armSerial
        return ArmTicket(serial: armSerial)
    }

    // Called by the survey the ticket was handed to, as it starts. A stale ticket (a newer
    // click replaced it) activates nothing.
    func beginSurvey(_ ticket: ArmTicket?) {
        state.lock()
        defer { state.unlock() }
        guard let ticket, ticket.serial == pendingSerial else { return }
        pendingSerial = nil
        activeSerial = ticket.serial
    }

    func endSurvey(_ ticket: ArmTicket?) {
        state.lock()
        defer { state.unlock() }
        guard let ticket else { return }
        if ticket.serial == activeSerial { activeSerial = nil }
        if ticket.serial == pendingSerial { pendingSerial = nil }
    }

    var isArmed: Bool {
        state.lock()
        defer { state.unlock() }
        return activeSerial != nil
    }

    func invalidate() {
        state.lock()
        defer { state.unlock() }
        cache = nil
        generation += 1
    }

    // Conformance for plain `ClaudeCredentialSource` callers: no identity to bind to, so
    // never a cache hit.
    func lookupCredential(service: String) -> CredentialLookup {
        lookupCredential(service: service, boundTo: nil)
    }

    func lookupCredential(service: String, boundTo email: String?) -> CredentialLookup {
        if let cached = cachedLookup(for: email) { return cached }
        reads.lock()
        defer { reads.unlock() }
        if let cached = cachedLookup(for: email) { return cached }

        state.lock()
        guard activeSerial != nil else {
            state.unlock()
            return .failed(MuseKeychainGate.notConnectedFault)
        }
        activeSerial = nil
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
            if generation == startedAt, let email { cache = (read, email) }
            state.unlock()
            return synthesizedBlob(read)
        }
    }

    private func cachedLookup(for email: String?) -> CredentialLookup? {
        state.lock()
        defer { state.unlock() }
        guard let cached = cache else { return nil }
        guard let email, email == cached.email else {
            cache = nil
            generation += 1
            return nil
        }
        return synthesizedBlob(cached.token)
    }

    private func synthesizedBlob(_ token: String) -> CredentialLookup {
        guard let data = try? JSONSerialization.data(withJSONObject: ["access_token": token])
        else { return .failed("could not repackage the Muse token") }
        return .found(data)
    }
}
