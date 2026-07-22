import Foundation
import Combine

// The impure SHELL around `UsageEngine` (§6). It owns exactly the four things the engine
// must not: the clock, the timers, the defaults database, and the concrete providers
// that reach the network and the credential store. Every policy decision — when to
// fetch, whether the budget allows it, how far to back off, what a row displays, what
// the menu bar shows, when persisted state is reclaimed — lives in `Model/UsageEngine`
// and `Model/UsagePolicy`, which compile into the test target. Nothing below decides
// anything; it transports.
//
// The split exists because `Core/` is app-only: a policy engine written here would be
// compiled by no test target at all, and §6 is the section of this design with the most
// failure modes that only appear on a timeline hours long.
//
// SINGLE WRITER (§6): the store is confined to the main actor, so however many fetches
// are in flight, every registry mutation and every menu-bar recomputation happens one at
// a time. Fetches themselves are `nonisolated async` on the providers and run off the
// main actor; only their results come back here.
@MainActor
final class UsageStore: ObservableObject {
    // What §7 reads. Both are projections the engine computed under one consistent view
    // of the registry — never assembled piecemeal by the UI.
    @Published private(set) var accounts: [AccountPresentation] = []
    @Published private(set) var menuBar: [ProviderFigure] = []
    @Published private(set) var lastSuccessAt: Date?

    // How often the engine is ASKED whether anything is due. Not a polling interval:
    // the intervals are per account and live in the engine, and this only bounds how
    // late a due fetch can be.
    static let tickInterval: TimeInterval = 15
    // §6: discovery re-runs on a schedule, not only at launch, and doubles as the
    // credential observation that revives a stopped account. Local and cheap — it costs
    // no upstream request, which is what makes it safe under a rate-limit budget.
    static let surveyInterval: TimeInterval = 60
    // The floor between two surveys triggered by the user rather than by the timer. A
    // survey is local and costs no upstream request, but it performs one blocking
    // credential read per profile and it lands its results on the main actor — so an
    // unthrottled survey per popover open lets a user drive main-actor work as fast as
    // they can click, on a path task 9 is about to wire to a real UI. Five seconds is
    // below the interval at which a profile's discovery state can meaningfully change
    // and far above the rate a person can open a popover.
    static let userSurveyFloor: TimeInterval = 5

    static let persistencePrefix = "usage.v2.account."
    static let persistenceIndexKey = "usage.v2.accounts"
    static let registeredLocationsKey = "registered_config_directories"

    private let defaults: UserDefaults
    private let engine: UsageEngine
    private let anthropic: AnthropicProvider
    private let codex: CodexProvider
    private var tickTimer: Timer?
    private var surveyTimer: Timer?
    private var isSurveying = false
    private var lastSurveyStartedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let now = Date()
        // The whole persisted keyspace, partitioned by a PURE function so that the load
        // path — including what is unreadable and must therefore be reclaimed — is
        // covered by the test target rather than living only here, where nothing
        // compiles it.
        let contents = PersistedStore.load(
            index: defaults.stringArray(forKey: UsageStore.persistenceIndexKey) ?? []
        ) { defaults.data(forKey: UsageStore.persistencePrefix + $0) }
        // The probe captures NOTHING but a defaults read: it is called from inside the
        // engine on a second authentication rejection, and it must re-read the credential
        // AT THAT MOMENT (§6) rather than reuse the last survey's copy, which is exactly
        // the stale reading the re-read exists to rule out.
        self.engine = UsageEngine(
            providerOrder: [.anthropic, .codex],
            restoring: contents.accounts,
            restoringLedgers: contents.ledgers,
            now: now,
            credentialProbe: { ref in
                UsageStore.credentialFact(
                    for: ref,
                    registeredLocations: UsageStore.registeredLocations(in: defaults)
                )
            }
        )
        let http = FoundationHTTPClient()
        self.anthropic = AnthropicProvider(
            discovery: UsageStore.makeDiscovery(),
            http: http,
            agentVersion: AgentVersionCache(probe: InstalledAgentVersionProbe()),
            registeredLocations: { UsageStore.registeredLocations(in: defaults) }
        )
        self.codex = CodexProvider(reader: UsageStore.makeCodexReader(), http: http)
        // A key the index names but this build cannot read — corrupt bytes, or a payload
        // written by a version with a different shape — never becomes an account payload,
        // so it never enters the engine's unclaimed map and the engine's orphan sweep
        // structurally cannot reach it. Left alone, the index keeps naming it and its blob
        // keeps sitting there forever. It is reclaimed HERE, at the one layer that can see
        // it, and the state it held is lost deliberately: it was already unreadable.
        reclaim(contents.unreadable)
    }

    private func reclaim(_ storageKeys: [String]) {
        guard !storageKeys.isEmpty else { return }
        var index = Set(defaults.stringArray(forKey: UsageStore.persistenceIndexKey) ?? [])
        for key in storageKeys {
            defaults.removeObject(forKey: UsageStore.persistencePrefix + key)
            index.remove(key)
            NSLog("🧹 Discarded unreadable persisted state for %@", key)
        }
        defaults.set(index.sorted(), forKey: UsageStore.persistenceIndexKey)
    }

    deinit {
        tickTimer?.invalidate()
        surveyTimer?.invalidate()
    }

    // MARK: - Lifecycle

    func start() {
        guard tickTimer == nil else { return }
        survey()
        tickTimer = Timer.scheduledTimer(withTimeInterval: UsageStore.tickInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pump() }
        }
        surveyTimer = Timer.scheduledTimer(withTimeInterval: UsageStore.surveyInterval,
                                           repeats: true) { [weak self] _ in
            Task { @MainActor in self?.survey() }
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        surveyTimer?.invalidate()
        surveyTimer = nil
    }

    // §6: discovery re-runs on popover open as well as on its timer — profiles are
    // created and signed out while the app is running. Throttled, because this one is
    // driven by the user: see `userSurveyFloor`.
    func popoverWillOpen() {
        survey(notBefore: UsageStore.userSurveyFloor)
        pump()
    }

    // §6's manual Refresh. It bypasses the interval and NOTHING else: the same admission
    // gate applies, so the 60s floor and the credential budget still bind.
    func refresh() {
        let now = Date()
        engine.requestManualRefresh(now: now)
        pump(now: now)
    }

    func refresh(_ identity: AccountIdentity) {
        let now = Date()
        engine.requestManualRefresh(identity, now: now)
        pump(now: now)
    }

    func setEnabled(_ enabled: Bool, for identity: AccountIdentity) {
        engine.setEnabled(enabled, for: identity)
        flush()
        publish(now: Date())
    }

    func isEnabled(_ identity: AccountIdentity) -> Bool { engine.isEnabled(identity) }

    // §5: diagnostic-only, latest per account, and deliberately not on
    // `AccountPresentation` so no display path can reach it.
    func retainedRawBody(for identity: AccountIdentity) -> Data? {
        engine.retainedRawBody(for: identity)
    }

    // MARK: - Registered locations (§4.1's escape hatch; task 11 owns the UI)

    var registeredLocations: [String] {
        get { UsageStore.registeredLocations(in: defaults) }
        set {
            defaults.set(newValue, forKey: UsageStore.registeredLocationsKey)
            survey()
        }
    }

    private static func registeredLocations(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: registeredLocationsKey) ?? []
    }

    // MARK: - Driving the engine

    private func pump(now: Date = Date()) {
        for task in engine.claimDueFetches(now: now) {
            run(task)
        }
        flush()
        publish(now: now)
    }

    private func run(_ task: PollTask) {
        let provider: any UsageProvider = task.ref.provider == .anthropic ? anthropic : codex
        Task { [weak self] in
            // `fetch` is nonisolated and async: it runs off the main actor, so a blocking
            // credential read inside it never stalls the menu bar. Only the result comes
            // back here, where the single writer applies it.
            let result = await provider.fetch(task.ref)
            guard let self else { return }
            let now = Date()
            self.engine.finish(task, result, now: now)
            self.flush()
            self.publish(now: now)
            // An authentication rejection queues an immediate re-read and retry (§6);
            // waiting for the next tick would delay it by up to `tickInterval` for no
            // reason. The retry still has to clear the 60s floor and the budget.
            self.pump(now: now)
        }
    }

    // §6's periodic re-discovery AND its credential observation, as one local pass. Runs
    // off the main actor because a credential lookup blocks for as long as its own
    // timeout, and this pass performs one per profile.
    private func survey(notBefore floor: TimeInterval = 0) {
        guard !isSurveying else { return }
        let now = Date()
        if floor > 0, let last = lastSurveyStartedAt, now.timeIntervalSince(last) < floor {
            return
        }
        lastSurveyStartedAt = now
        isSurveying = true
        let locations = registeredLocations
        Task { [weak self] in
            let observations = await Task.detached(priority: .utility) {
                UsageStore.collectObservations(registeredLocations: locations, now: Date())
            }.value
            guard let self else { return }
            self.isSurveying = false
            let now = Date()
            // Both providers ran, so both may reclaim: a Codex configuration that has
            // been removed yields no observation and its state is reclaimed (§6).
            self.engine.ingest(observations, covering: [.anthropic, .codex], now: now)
            self.flush()
            self.publish(now: now)
            self.pump(now: now)
        }
    }

    private func publish(now: Date) {
        accounts = engine.presentations(now: now)
        menuBar = engine.menuBarFigures(now: now)
        lastSuccessAt = accounts.compactMap { $0.lastSuccessAt }.max()
    }

    // MARK: - Persistence

    // §6's namespacing, made real: one defaults key per account, plus an index so that a
    // namespace whose account never comes back can be found and removed. Without the
    // index the keyspace is unenumerable and orphans accumulate silently — which is how
    // this machine came to hold five credential entries for directories that no longer
    // exist.
    private func flush() {
        var index = Set(defaults.stringArray(forKey: UsageStore.persistenceIndexKey) ?? [])
        for op in engine.drainPersistence() {
            switch op {
            case .write(let storageKey, let payload):
                defaults.set(payload, forKey: UsageStore.persistencePrefix + storageKey)
                index.insert(storageKey)
            case .delete(let storageKey):
                defaults.removeObject(forKey: UsageStore.persistencePrefix + storageKey)
                index.remove(storageKey)
            }
        }
        defaults.set(index.sorted(), forKey: UsageStore.persistenceIndexKey)
    }

    // MARK: - The local survey (nonisolated: no shared state, safe off the main actor)

    private nonisolated static func makeDiscovery() -> ClaudeProfileDiscovery {
        ClaudeProfileDiscovery(fileSystem: SystemProfileFileSystem(), credentials: KeychainStore())
    }

    private nonisolated static func makeCodexReader() -> CodexAuthReader {
        CodexAuthReader(fileSystem: SystemProfileFileSystem())
    }

    nonisolated static func collectObservations(registeredLocations: [String],
                                                now: Date) -> [AccountObservation] {
        var observations: [AccountObservation] = []

        // Anthropic. The service name is how the credential is ADDRESSED, and it is only
        // the fallback budget key: it digests a configuration PATH, and §6 scopes the
        // budget to the access token. `AccountObservation.budgetKey` prefers the
        // credential digest for exactly that reason.
        let discovery = makeDiscovery()
        for profile in discovery.resolveProfiles(registeredLocations: registeredLocations,
                                                 now: now) {
            observations.append(AccountObservation(
                account: profile.account,
                credentialLocation: profile.service,
                credential: anthropicCredentialFact(service: profile.service,
                                                    credentials: discovery.credentials)
            ))
        }

        // Codex. Single account (§4.2), so the credential file's path is its location.
        let reader = makeCodexReader()
        let codexLocation = reader.credentialPath ?? "codex"
        for account in CodexProvider(reader: reader, http: FoundationHTTPClient())
            .discoverAccounts() {
            observations.append(AccountObservation(
                account: account,
                credentialLocation: codexLocation,
                credential: codexCredentialFact(reader: reader)
            ))
        }

        return observations
    }

    // The wake-up contract of §6: what is compared across polls is a DIGEST. The blob is
    // read, hashed, and dropped in the same expression — it carries live `mcpOAuth`
    // client secrets for unrelated third-party servers, and persisting it to diff it
    // would be a worse exposure than the one the read-only rule prevents.
    private nonisolated static func anthropicCredentialFact(
        service: String,
        credentials: ClaudeCredentialSource
    ) -> CredentialFact {
        switch credentials.lookupCredential(service: service) {
        case .absent, .failed:
            return CredentialFact()
        case .found(let blob):
            var expiry: Date?
            if case .usable(let credential) = ClaudeCredential.decode(blob) {
                expiry = credential.expiresAt
            }
            return CredentialFact(digest: ClaudeCredential.credentialDigest(blob),
                                  expiresAt: expiry)
        }
    }

    // Same rule for Codex, through the same canonicalising digest so that "changed" means
    // the same thing on both providers. `auth.json` publishes no expiry this app can read,
    // so `expiresAt` stays nil — which means a Codex account is NEVER stopped as expired
    // (§6 stops a timer only on a second rejection with a genuinely lapsed stored expiry).
    // It backs off and keeps retrying instead, which is the correct treatment for a
    // rejection whose cause cannot be established locally.
    private nonisolated static func codexCredentialFact(reader: CodexAuthReader) -> CredentialFact {
        guard let path = reader.credentialPath,
              case .contents(let data) = reader.fileSystem.readFile(atPath: path)
        else { return CredentialFact() }
        return CredentialFact(digest: ClaudeCredential.credentialDigest(data))
    }

    // Re-reads ONE account's credential, now. Used only by the engine's second-rejection
    // test, which is why it re-runs discovery rather than consulting a cache: the whole
    // question being asked is whether the copy we last saw is out of date.
    nonisolated static func credentialFact(for ref: AccountRef,
                                           registeredLocations: [String]) -> CredentialFact {
        switch ref.provider {
        case .anthropic:
            let discovery = makeDiscovery()
            guard let profile = discovery
                .resolveProfiles(registeredLocations: registeredLocations, now: Date())
                .first(where: { $0.account.ref.id == ref.id })
            else { return CredentialFact() }
            return anthropicCredentialFact(service: profile.service,
                                           credentials: discovery.credentials)
        case .codex:
            return codexCredentialFact(reader: makeCodexReader())
        }
    }
}
