import Foundation

// §10: each case names the regression it prevents. For every assertion the question was
// "what production change would make this fail?" — a test that cannot fail when the
// business logic changes is worse than no test, because it reports coverage it does not
// have. (Task 5 shipped three of those; one had been green for the whole life of the bug
// it was named after, because it asserted the fate of a NEIGHBOURING entry.)
//
// Everything here runs against sanitised recorded fixtures, an in-memory filesystem and a
// fake HTTP client. No network is reachable from this target at all — the concrete client
// is excluded from the test compile by name and `build.sh` greps these sources for
// networking symbols — so a test that appeared to pass by talking to the real endpoint
// cannot exist.
//
// NO TOKEN MATERIAL, real or fictional, is spelled out in this file. Expected request
// headers are rebuilt by decoding the credential fixture, so a fixture edit cannot leave
// an assertion passing against a value nothing sends any more.
enum CodexProviderTests {

    // MARK: - Fakes

    // A CLASS, not a struct: `credentialIsReReadOnEveryFetch` has to change the file
    // between two fetches on one provider, and that is the only way to prove the token is
    // re-read rather than captured once.
    private final class FakeFileSystem: ProfileFileSystem, @unchecked Sendable {
        var homeDirectoryPath: String
        var environment: [String: String] = [:]
        var directories: Set<String> = []
        var files: [String: Data] = [:]
        // Paths that EXIST and cannot be read — a locked volume, or the CLI's own rewrite
        // caught in flight. The default `readFile` cannot represent this, which is exactly
        // the gap that made a corrupt credential indistinguishable from a sign-out.
        var unreadablePaths: Set<String> = []

        init(homeDirectoryPath: String) {
            self.homeDirectoryPath = homeDirectoryPath
        }

        func readFile(atPath path: String) -> FileReadResult {
            if unreadablePaths.contains(path) { return .unreadable("could not be read") }
            guard let data = files[path] else { return .missing }
            return .contents(data)
        }

        func environmentVariable(_ name: String) -> String? {
            guard let value = environment[name], !value.isEmpty else { return nil }
            return value
        }
        func isDirectory(atPath path: String) -> Bool { directories.contains(path) }
        func directoryEntries(atPath path: String) -> [String] { [] }
        func fileContents(atPath path: String) -> Data? { files[path] }
    }

    private final class FakeHTTP: HTTPRequesting, @unchecked Sendable {
        // Keyed by absolute URL so the endpoint-fallback tests can answer the two paths
        // differently — the whole point of §5.2's 404 rule.
        var outcomes: [String: HTTPOutcome] = [:]
        var fallbackOutcome: HTTPOutcome = .failure(message: "not configured")
        private(set) var requests: [HTTPRequest] = []

        func get(_ request: HTTPRequest) async -> HTTPOutcome {
            requests.append(request)
            return outcomes[request.url.absoluteString] ?? fallbackOutcome
        }

        var requestedPaths: [String] { requests.map { $0.url.absoluteString } }
    }

    // MARK: - Fixture world

    private static let home = "/fake/home"
    private static let codexDirectory = home + "/.codex"
    private static let authPath = codexDirectory + "/auth.json"
    private static let now = Date(timeIntervalSince1970: 1_784_800_000)

    private static func fixture(_ name: String) -> Data {
        let url = TestHarness.fixturesDirectory
            .appendingPathComponent("codex")
            .appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            fatalError("missing fixture: \(url.path)")
        }
        return data
    }

    private static func json(_ name: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: fixture(name))) as? [String: Any] ?? [:]
    }

    // Reads a value out of the credential fixture rather than restating it here.
    private static func token(_ name: String, _ key: String) -> String? {
        (json(name)["tokens"] as? [String: Any])?[key] as? String
    }

    private static func reader(_ fs: FakeFileSystem) -> CodexAuthReader {
        CodexAuthReader(fileSystem: fs, log: { _ in })
    }

    private static func world(auth: String? = "auth-live.json",
                              installed: Bool = true) -> FakeFileSystem {
        let fs = FakeFileSystem(homeDirectoryPath: home)
        if installed { fs.directories = [home, codexDirectory] }
        if let auth { fs.files[authPath] = fixture(auth) }
        return fs
    }

    private static func credential(_ name: String) -> CodexCredential? {
        guard case .usable(let credential) = reader(world(auth: name)).read() else { return nil }
        return credential
    }

    private static func parse(_ name: String) -> CodexUsageParser.Parsed {
        guard case .parsed(let parsed) = CodexUsageParser.parse(fixture(name), now: now) else {
            fatalError("fixture \(name) failed to parse")
        }
        return parsed
    }

    private static func window(_ parsed: CodexUsageParser.Parsed,
                               _ scope: WindowScope,
                               _ span: WindowSpan) -> UsageWindow? {
        parsed.windows.first { $0.id == WindowID(span: span, scope: scope) }
    }

    // MARK: - The one-bucket-many-windows regression

    // THE reason this parser is a flattening (§5.2). Each bucket holds its OWN set of
    // temporal windows, so a parser that maps one bucket to one window reads the right key
    // and silently keeps the first thing in it — 200 OK, clean parse, missing limits.
    //
    // What would break this: replacing the `map` over `flat.windows` in `project` with a
    // `first`, or reintroducing "primary is the session window". Both were measured to
    // halve the window count here while every other assertion in this file stayed green.
    private static func oneBucketContributesMoreThanOneWindow() {
        let parsed = parse("usage-multi-window.json")
        TestHarness.expect("two buckets each holding two windows yield four windows",
                           parsed.windows.count, 4)
        TestHarness.expect("the account bucket's short window survives",
                           window(parsed, .account, .session)?.utilization, .known(12))
        TestHarness.expect("the account bucket's long window survives",
                           window(parsed, .account, .weekly)?.utilization, .known(47))
        TestHarness.expect("the feature bucket's long window survives",
                           window(parsed, .feature(id: "feature:codex_alpha"), .weekly)?.utilization,
                           .known(88))
        TestHarness.expect("the feature bucket's short window survives",
                           window(parsed, .feature(id: "feature:codex_alpha"), .session)?.utilization,
                           .known(3))
        // The binding figure is the one the menu bar shows. If any window above were
        // dropped this would read 47 rather than 88 — the same silent under-report the
        // flat-key trap causes on the sibling.
        TestHarness.expect("the worst window across every bucket is the reported figure",
                           Snapshot.bindingUtilization(of: parsed.windows), .known(88))
    }

    // The same trap one level further in. A bucket's windows sit directly inside it on the
    // account-level group and one level down inside a feature-list entry, so the search
    // has to cover both — and an "if none at the first depth, try the second" shortcut is
    // an EARLY EXIT that deletes the nested windows of any bucket carrying both. That
    // shortcut is the natural way to write this function, which is why it is pinned.
    //
    // Added after a mutation SURVIVED: reintroducing that shortcut passed the whole suite,
    // because no fixture had a bucket with windows at both depths.
    private static func windowsAreFoundAtEitherNestingDepth() {
        let parsed = parse("usage-mixed-depth.json")
        let scope = WindowScope.feature(id: "feature:codex_alpha")
        TestHarness.expect("the window sitting directly in the bucket survives",
                           window(parsed, scope, .session)?.utilization, .known(66))
        TestHarness.expect("the window nested one level deeper survives too",
                           window(parsed, scope, .weekly)?.utilization, .known(55))
        TestHarness.expect("neither depth shadowed the other", parsed.windows.count, 3)
    }

    // THE INGESTION SWEEP, and the bug it was written for is the worst one in this file's
    // history. The invariant — nothing below ingestion may delete a window it managed to
    // read — was enforced by type: `window(from:)` cannot return nothing. THE BUG MOVED
    // UPSTREAM OF THE ENFORCEMENT. `flatten` tested `isTemporalWindow` on a bucket's
    // children and grandchildren but never on the bucket itself, so a group published as
    // a bare window was deleted AT ingestion and the invariant never ran.
    //
    // Measured before the fix, on production code:
    //   {"rate_limit":{"limit_window_seconds":18000,"used_percent":91}}
    //     → 0 windows, warnings = ["This Codex account reported no usage limits."]
    //   feature entry that is itself a window → 0 windows
    //   {"rate_limit":{…5%…},"video_rate_limit":[{…99%…}]}
    //     → 1 window (5%), warnings = []   ← a 99% limit, and NOTHING said so
    //
    // The question this test encodes is not "is my projection lossless" but "is there any
    // shape carrying a real figure that never becomes a window at all".
    private static func aBucketThatIsItselfAWindowIsIngested() {
        let account = parse("usage-bare-account-window.json")
        TestHarness.expect("an account bucket published as a bare window is ingested",
                           window(account, .account, .session)?.utilization, .known(91))

        let feature = parse("usage-bare-feature-window.json")
        TestHarness.expect("a feature entry published as a bare window is ingested",
                           window(feature, .feature(id: "feature:codex_alpha"), .session)?
                               .utilization,
                           .known(77))

        // The silent one. A healthy account bucket beside an unmodelled group holding a
        // bare window: the menu bar read 5% while a 99% limit existed, with no warning.
        let group = parse("usage-bare-group-window.json")
        TestHarness.expect("a bare window inside an unmodelled group is ingested",
                           group.windows.count, 2)
        TestHarness.expect("and it is the figure the account reports",
                           Snapshot.bindingUtilization(of: group.windows), .known(99))
    }

    // The other half of the same class: a shape we cannot read must never be silent.
    // Detection is by FIELD, so a vendor rename of both detection fields makes a window
    // invisible — that is unavoidable — but it must be SAID. The check was present one
    // nesting level down and absent one level up, so the same rename warned or did not
    // depending on how deeply it sat.
    private static func anUnrecognisableWindowShapeIsNeverSilent() {
        let renamed = parse("usage-renamed-window-fields.json")
        TestHarness.expect("a renamed window yields no window — detection is by field",
                           renamed.windows.count, 0)
        TestHarness.check("but it is surfaced rather than silently dropped",
                          renamed.warnings.contains(CodexUsageParser.Warning.unreadableWindow))

        // The search is bounded at two levels deep, deliberately — an unbounded walk would
        // start ingesting arbitrary nested objects. A window below that bound is missed,
        // and that too must be said rather than assumed away.
        let deep = parse("usage-deep-windows-key.json")
        TestHarness.expect("a window below the searched depth yields nothing",
                           deep.windows.count, 0)
        TestHarness.check("and says so", deep.warnings
            .contains(CodexUsageParser.Warning.unreadableWindow))
    }

    // §5's whole argument for the exhaustive scan is that it survives drift — and the two
    // enumerated keys were excluded from it unconditionally, which made them the only two
    // keys in the payload drift could silently delete. They are rescued through the
    // generic path instead: degraded identity, surfaced, figures kept.
    private static func anEnumeratedKeyWhoseShapeDriftedIsRescuedNotDropped() {
        let account = parse("usage-drifted-account-bucket.json")
        TestHarness.expect("an account bucket that arrived as a list keeps both windows",
                           account.windows.count, 2)
        TestHarness.expect("and the worse figure still reports",
                           Snapshot.bindingUtilization(of: account.windows), .known(91))
        TestHarness.check("under a degraded but surfaced identity",
                          account.warnings.contains(CodexUsageParser.Warning.unrecognisedGroup))

        let features = parse("usage-drifted-feature-list.json")
        TestHarness.expect("a feature list that arrived as an object keeps its window",
                           Snapshot.bindingUtilization(of: features.windows), .known(97))

        // THE OTHER HALF OF THE RESCUE, and it was unpinned: both fixtures above are fully
        // RECOVERABLE, so the "nothing recoverable inside it" branch never ran. An
        // enumerated key present in a shape holding no window at all must still be
        // surfaced — otherwise the one key whose absence fails loud can be present,
        // useless, and silent, which is strictly worse than absent.
        let unrescuable = parse("usage-unrescuable-keys.json")
        TestHarness.expect("an enumerated key with nothing recoverable yields no windows",
                           unrescuable.windows.count, 0)
        TestHarness.check("but says so rather than reporting an idle account",
                          unrescuable.warnings
                              .contains(CodexUsageParser.Warning.unreadableBucket))
    }

    // C5. A warning is NOT enough: §8 keys threshold state on the whole `WindowID` and
    // every `[WindowID: …]` downstream keeps exactly one of a colliding pair, so a
    // collision that is merely announced still merges two accounts' worth of history and
    // still lets one window vanish from any deduped view. The invariant requires a
    // degraded identity that is DISTINCT.
    private static func collidingIdentitiesAreMadeDistinctNotJustAnnounced() {
        let cases: [(String, Utilization)] = [
            ("usage-duplicate-features.json", .known(90)),  // same discriminator twice
            ("usage-group-subbuckets.json", .known(90)),    // one group, two sub-buckets
            ("usage-unstated-duration.json", .known(70)),   // one bucket, two unstated spans
        ]
        for (name, worst) in cases {
            let parsed = parse(name)
            TestHarness.expect("\(name): both windows survive", parsed.windows.count, 2)
            TestHarness.expect("\(name): and their identities are distinct",
                               Set(parsed.windows.map(\.id)).count, 2)
            TestHarness.check("\(name): the degradation is surfaced",
                              parsed.warnings
                                  .contains(CodexUsageParser.Warning.collidingIdentities))
            // The figure that matters is still reported — a deduped view would have kept
            // one of the two, and it might have been the wrong one.
            TestHarness.expect("\(name): the worse figure is still the reported one",
                               Snapshot.bindingUtilization(of: parsed.windows), worst)
        }
        // Every degraded identity carries the `dup:` prefix, which no natural scope id can
        // take — that is what stops one from aliasing a real feature.
        let ids = parse("usage-duplicate-features.json").windows.map(\.id.scope)
        TestHarness.check("degraded identities are namespaced out of the natural space",
                          ids.allSatisfy {
                              if case .feature(let id) = $0 { return id.hasPrefix("dup:") }
                              return false
                          })
    }

    // §10's row, and it is pinned against the LIVE recording rather than a hand-built
    // fixture: on the observed Pro account `primary_window` holds the WEEKLY window and
    // `secondary_window` is null. Classifying by position reports this account's weekly
    // usage as its session usage — a figure that is wrong and a reset time that is wrong
    // with it.
    private static func windowsAreClassifiedByDurationNotPosition() {
        let parsed = parse("usage-live.json")
        TestHarness.expect("the primary window is classified weekly because it lasts a week",
                           window(parsed, .account, .weekly)?.utilization, .known(4))
        TestHarness.check("nothing was classified as a session window",
                          window(parsed, .account, .session) == nil)
        // A null window means NO DATA, not 0% used: the window has not begun, because a
        // window does not begin until a real generation request is made. Rendering it as
        // an empty bar claims a measurement nobody took.
        TestHarness.expect("the null secondary window is omitted rather than zeroed",
                           parsed.windows.count, 2)
        TestHarness.check(
            "no window was invented at zero",
            parsed.windows.allSatisfy { $0.utilization != .known(0) || $0.id.scope != .account }
        )
        // The live payload is unremarkable, and the suite says so: a warning that fires on
        // a healthy account is one users learn to ignore.
        TestHarness.expect("a healthy live payload produces no parser warnings",
                           parsed.warnings, [])
    }

    // §5.2: ingestion is exhaustive over quota-bearing GROUPS, not over a fixed list of
    // two. The observed payload carries `code_review_rate_limit` beside the two enumerated
    // groups; a client that models only those two omits a live limit silently.
    //
    // What would break this: deleting the "every other top-level value" loop in `parse`,
    // or replacing it with a named allow-list.
    private static func quotaGroupsOutsideTheEnumeratedOnesAreIngested() {
        let parsed = parse("usage-extra-groups.json")
        TestHarness.expect("a bare quota bucket under an unmodelled name is ingested",
                           window(parsed, .feature(id: "group:code_review_rate_limit"), .weekly)?
                               .utilization,
                           .known(61))
        // The same group could equally arrive as a LIST of wrappers — the shape the known
        // feature list already uses. Handling only the object form omits it.
        TestHarness.expect("a list-shaped quota group under an unmodelled name is ingested",
                           window(parsed,
                                  .feature(id: "group:experimental_rate_limits:feature:codex_beta"),
                                  .session)?.utilization,
                           .known(25))
        TestHarness.expect("the account bucket is still ingested alongside them",
                           window(parsed, .account, .session)?.utilization, .known(10))
        TestHarness.expect("three groups yield three windows", parsed.windows.count, 3)
        // Ingested AND surfaced: a limit this build has never seen is worth saying out
        // loud, because its label and grouping are guesses.
        TestHarness.check("an unrecognised quota group is surfaced, not silently absorbed",
                          parsed.warnings.contains(CodexUsageParser.Warning.unrecognisedGroup))
        // Not every top-level object is a quota group. `credits` and `spend_control` carry
        // no window and must not become empty bars.
        TestHarness.check("non-quota top-level objects are not ingested as groups",
                          parsed.windows.allSatisfy { $0.id.scope != .feature(id: "group:credits") })
    }

    // MARK: - Degradation without deletion

    // The invariant that governs this whole file: NOTHING BELOW INGESTION MAY DELETE A
    // WINDOW IT MANAGED TO READ. Two windows in one bucket with no stated duration both
    // land on the same degraded span, and the answer is to keep both and say so — not to
    // pick one. Dropping either is an under-report; on the sibling the identical shape
    // produced an 85-point one that existed nowhere but a warning string.
    private static func windowsWithNoStatedDurationAreKeptNotDropped() {
        let parsed = parse("usage-unstated-duration.json")
        TestHarness.expect("both windows survive an unstated duration", parsed.windows.count, 2)
        TestHarness.check(
            "the worse of the two is still reported",
            Snapshot.bindingUtilization(of: parsed.windows) == .known(70)
        )
        // NOT folded onto a canonical span: the length of the window is not ours to invent,
        // and guessing would merge its threshold history with a window it has nothing to
        // do with.
        TestHarness.check("neither is folded onto a canonical span",
                          parsed.windows.allSatisfy { $0.id.span != .session && $0.id.span != .weekly })
        TestHarness.check("the unstated duration is surfaced",
                          parsed.warnings.contains(CodexUsageParser.Warning.unstatedDuration))
        // They would collide on span, and are made DISTINCT rather than merely announced —
        // see `collidingIdentitiesAreMadeDistinctNotJustAnnounced` for why a warning alone
        // still loses one of them downstream.
        TestHarness.expect("their identities are split rather than shared",
                           Set(parsed.windows.map(\.id)).count, 2)
        // The label says nothing about a period BECAUSE THE PAYLOAD SAID NOTHING. The twin
        // branch — a stated but non-canonical duration — names its own period, and pinning
        // only that one left this side free to render "0s limit", a duration presented as
        // a fact when the vendor never stated one. (Both sides of the ternary now bite.)
        TestHarness.expect("and neither claims a period the payload never stated",
                           parsed.windows.map(\.label), ["Limit", "Limit"])
    }

    // A duration that cannot be read EXACTLY is an unstated duration, not an approximate
    // one. `NSNumber.intValue` wraps silently on overflow and truncates a fraction, so the
    // obvious conversion turns an unreadable figure into a confident wrong span — and a
    // span is an identity here, so the window would be filed under a period the vendor
    // never stated and keep another window's threshold history (§8).
    //
    // Added after a mutation SURVIVED: swapping `exactInteger` for `intValue` passed the
    // whole suite, because no fixture carried a duration that could expose the difference.
    private static func aDurationThatCannotBeReadExactlyIsNotGuessedAt() {
        let parsed = parse("usage-nonsense-duration.json")
        TestHarness.expect("both windows survive an unreadable duration", parsed.windows.count, 2)
        // Under a wrapping conversion the first becomes a ~246-year window and the second
        // becomes a canonical weekly one. Both are fabrications.
        TestHarness.check("neither is filed under a period the payload never stated",
                          parsed.windows.allSatisfy { $0.id.span == WindowSpan(seconds: 0) })
        TestHarness.check("and the figures themselves are kept",
                          Snapshot.bindingUtilization(of: parsed.windows) == .known(44))
        TestHarness.check("the unstated duration is surfaced",
                          parsed.warnings.contains(CodexUsageParser.Warning.unstatedDuration))

        // A duration can be a PERFECTLY EXACT integer and still not be a window: ~285,000
        // years. The exactness check cannot see that, so the magnitude is bounded
        // separately — otherwise the span becomes an identity built from a nonsense, and
        // §7 renders "9000000000000s limit". Added after a mutation SURVIVED: removing the
        // bound passed the whole suite, because every absurd duration in the fixtures was
        // being rejected by the exactness check instead.
        let absurd = parse("usage-absurd-duration.json")
        TestHarness.expect("an absurd but exact duration is unstated, not believed",
                           window(absurd, .account, WindowSpan(seconds: 0))?.utilization,
                           .known(7))
        TestHarness.check("and is surfaced",
                          absurd.warnings
                              .contains(CodexUsageParser.Warning.unstatedDuration))
    }

    // §3/§5.2: scope identity comes from the STABLE feature discriminator, and when there
    // is none the chain degrades — but never to nothing. Each rung is namespaced so it
    // cannot alias another, and every window keeps its figure.
    private static func theDiscriminatorChainDegradesWithoutLosingAWindow() {
        let parsed = parse("usage-degraded-discriminators.json")
        TestHarness.expect("every entry yields a window whatever it published",
                           parsed.windows.count, 4)  // three features plus the account bucket
        TestHarness.expect("a stable discriminator keys the scope",
                           window(parsed, .feature(id: "feature:codex_alpha"), .session)?.utilization,
                           .known(11))
        // Display text as identity is a KNOWN weakness (a rename splits this window's
        // history), taken deliberately over deleting a live reading.
        TestHarness.expect("a display name keys the scope when no discriminator exists",
                           window(parsed, .feature(id: "name:Codename Beta"), .session)?.utilization,
                           .known(22))
        // Position is the last resort and is intentionally volatile under vendor
        // reordering. Under-reporting is the failure this provider exists to prevent; a
        // re-fired notification ladder is not.
        TestHarness.expect("position keys the scope when nothing else was published",
                           window(parsed, .feature(id: "index:2"), .session)?.utilization,
                           .known(33))
        TestHarness.expect("nothing collided", parsed.warnings.filter {
            $0 == CodexUsageParser.Warning.collidingIdentities
        }, [])
    }

    // A window that is PRESENT and unreadable is not an absent one, and an entry that is
    // not an object at all is the ONE thing with nothing to degrade to. Both must be
    // surfaced; neither may take the rest of the payload down with it (§5: decode
    // permissively, per key).
    private static func unreadableWindowsAreSurfacedAndTheRestSurvives() {
        let parsed = parse("usage-unreadable-windows.json")
        TestHarness.expect("the readable account window survives",
                           window(parsed, .account, .session)?.utilization, .known(10))
        TestHarness.expect("the readable feature window survives",
                           window(parsed, .feature(id: "feature:codex_alpha"), .session)?.utilization,
                           .known(10))
        TestHarness.check("a present-but-unreadable window is surfaced",
                          parsed.warnings.contains(CodexUsageParser.Warning.unreadableWindow))
        TestHarness.check("an entry that is not an object at all is surfaced",
                          parsed.warnings.contains(CodexUsageParser.Warning.unreadableBucket))

        // THE DEPTH-2 TWIN, and it was unpinned. A feature-list entry is a WRAPPER, so its
        // windows sit one level further down — which means the same unrecognisable value
        // reaches a different branch depending only on how deeply the vendor nested it.
        // Covering one side and not the other is the exact asymmetry C1 was an instance of.
        //
        // The account bucket in this fixture is healthy, so the depth-2 branch is the only
        // thing in the payload that can raise this warning.
        let nested = parse("usage-nested-unreadable-window.json")
        TestHarness.check("an unreadable window nested inside a wrapper is surfaced too",
                          nested.warnings.contains(CodexUsageParser.Warning.unreadableWindow))
        TestHarness.expect("and the readable account window is untouched",
                           window(nested, .account, .session)?.utilization, .known(10))

        // The same twin one level out: `genericGroup` raises this warning from an object
        // branch and a list branch, and neither was exercised. Two SEPARATE fixtures,
        // because one payload carrying both would let either branch alone satisfy the
        // assertion — which is how a twinned branch stays unpinned in the first place.
        for name in ["usage-group-object-unreadable-window.json",
                     "usage-group-list-unreadable-window.json"] {
            let group = parse(name)
            TestHarness.check("\(name): an unmodelled group we cannot read is surfaced",
                              group.warnings.contains(CodexUsageParser.Warning.unreadableWindow))
            TestHarness.expect("\(name): and the rest of the payload survives",
                               window(group, .account, .session)?.utilization, .known(10))
        }
    }

    // MARK: - Figures

    // §3: absent, unknown and zero are three different facts. Coercing unknown to zero
    // manufactures headroom the account may not have, and it is the one error that
    // actively misleads.
    //
    // The clamp is not tidiness. `Utilization.percent(Double)` guards `isFinite` and then
    // does `Int(value.rounded())`, which TRAPS outside Int's range — on the sibling a
    // payload carrying 1e30 killed the process mid-poll (exit 133). If the clamp is
    // removed this test does not fail, it takes the runner down with it, which is itself
    // the signal.
    private static func absurdFiguresAreClampedAndUnknownIsNeverZero() {
        let parsed = parse("usage-absurd-figures.json")
        TestHarness.expect("an unrepresentable percentage is clamped, not trusted",
                           window(parsed, .account, .session)?.utilization, .known(100))
        TestHarness.expect("a null percentage is unknown, never zero",
                           window(parsed, .account, .weekly)?.utilization, .unknown)
        // JSON booleans bridge to NSNumber, so `as? NSNumber` accepts `true` and it would
        // otherwise read as 1% used.
        TestHarness.expect("a boolean is not a figure",
                           window(parsed, .feature(id: "feature:codex_alpha"), .session)?.utilization,
                           .unknown)
    }

    // §5.2: `credits.balance` is a String ("0") in observed payloads and a Number in
    // others. Both bind — and BOTH STAY UNQUALIFIED, because this provider states no
    // currency and no scale, so neither may be inferred.
    //
    // The mirror-image mistake is the sibling's: there a scale WAS stated and the first
    // draft threw it away, rendering a 100× over-report that a test asserted was correct.
    // Here there is genuinely no scale to keep, and manufacturing one is the same error
    // pointing the other way.
    private static func balanceParsesAsStringAndNumberAndStaysUnqualified() {
        TestHarness.expect("a String balance is carried as the provider stated it",
                           parse("usage-live.json").spend?.balance, .unqualified(raw: "0"))
        TestHarness.expect("a Number balance is carried as the provider stated it",
                           parse("usage-balance-number.json").spend?.balance,
                           .unqualified(raw: "12.5"))
        for name in ["usage-live.json", "usage-balance-number.json"] {
            let balance = parse(name).spend?.balance
            var qualified = false
            if case .qualified = balance { qualified = true }
            TestHarness.check("\(name): no currency or exponent is fabricated", !qualified)
        }
        // Nothing else in this payload states a unit or a scale, so nothing else is
        // projected as money.
        TestHarness.check("no spend figure is invented for fields that state no unit",
                          parse("usage-live.json").spend?.used == nil
                              && parse("usage-live.json").spend?.limit == nil)
    }

    // §5.2 prefers the RELATIVE countdown: it needs no agreement between this machine's
    // clock and the vendor's. The absolute epoch is the fallback, and a present-but-
    // unreadable value is neither of those — collapsing it into "no reset time" would let
    // a live window pass for one that has never started.
    private static func resetTimesPreferTheCountdownAndDistinguishUnreadable() {
        let live = parse("usage-live.json")
        TestHarness.expect("the countdown is applied to our own clock",
                           window(live, .account, .weekly)?.resetsAt,
                           now.addingTimeInterval(514_656))

        let shapes = parse("usage-reset-shapes.json")
        TestHarness.expect("an absolute epoch is read when no countdown is given",
                           window(shapes, .account, .session)?.resetsAt,
                           Date(timeIntervalSince1970: 1_785_258_640))
        TestHarness.check("an unreadable reset time yields no date",
                          window(shapes, .account, .weekly)?.resetsAt == nil)
        // …and the window is STILL SHOWN. The reset time is a property of the window, not
        // a licence to delete it.
        TestHarness.expect("the window with the unreadable reset time is still reported",
                           window(shapes, .account, .weekly)?.utilization, .known(6))
        TestHarness.check("the unreadable reset time is surfaced",
                          shapes.warnings.contains(CodexUsageParser.Warning.unreadableResetTime))

        // J1: ONE UNREADABLE FIELD MUST NOT VETO THE OTHER. The code returned early from
        // the countdown branch without ever consulting the epoch, so a window carrying an
        // unreadable countdown AND a perfectly good absolute time reported no reset time
        // at all — the comment above the function said both were read, and they were not.
        // No fixture put both on one window, which is why the drift survived.
        let both = parse("usage-reset-both.json")
        TestHarness.expect("a good absolute time is used when the countdown is unreadable",
                           window(both, .account, .session)?.resetsAt,
                           Date(timeIntervalSince1970: 1_785_000_000))

        // MINOR 9: magnitudes are bounded for the same reason percentages are. `1e300` is
        // not a reset time, and handing §7's date formatting a date 1e300 seconds out
        // presents a nonsense as a fact.
        let absurd = parse("usage-absurd-reset.json")
        TestHarness.check("an unrepresentable countdown yields no date",
                          window(absurd, .account, .session)?.resetsAt == nil)
        TestHarness.check("and is surfaced rather than rendered",
                          absurd.warnings
                              .contains(CodexUsageParser.Warning.unreadableResetTime))
        TestHarness.expect("while the window itself is still reported",
                           window(absurd, .account, .session)?.utilization, .known(5))

        // THE EPOCH'S OWN UNREADABLE BRANCH, the twin of the countdown's. Every fixture
        // above reaches `unreadable` through `reset_after_seconds`; a payload that states
        // only `reset_at`, unreadably, takes a different branch — and the window must
        // still be shown, because an unreadable reset time says the window HAS started.
        let epoch = parse("usage-reset-at-unreadable.json")
        TestHarness.check("an unreadable absolute time yields no date",
                          window(epoch, .account, .session)?.resetsAt == nil)
        TestHarness.check("and is surfaced",
                          epoch.warnings
                              .contains(CodexUsageParser.Warning.unreadableResetTime))
        TestHarness.expect("while the window is still reported rather than treated as dormant",
                           window(epoch, .account, .session)?.utilization, .known(8))
    }

    // MINOR 8. The clamp is asymmetric ON PURPOSE, and it was symmetric by accident.
    // Clamping an over-large figure down to 100 over-reports, which is the safe direction
    // for a tool that exists to prevent under-reporting. Clamping a NEGATIVE figure up to
    // zero turns something nobody can interpret into a confident "0% used" — manufacturing
    // headroom, the one error §3 calls actively misleading. `true` already yielded
    // `.unknown`; `-5` yielded `.known(0)`.
    private static func aNegativePercentageIsUnknownNotZero() {
        TestHarness.expect("a negative percentage is no percentage at all",
                           window(parse("usage-negative-percent.json"), .account, .session)?
                               .utilization,
                           .unknown)
        // The other end of the clamp is unchanged, and must stay that way.
        TestHarness.expect("an over-large one is still clamped rather than discarded",
                           window(parse("usage-absurd-figures.json"), .account, .session)?
                               .utilization,
                           .known(100))
    }

    // A credit balance that is PRESENT and unreadable is not an absent one — the same
    // present-but-unreadable-so-vanished shape the window rules exist to prevent, on the
    // money side. Nothing asserted this warning, so the guard was free to be deleted.
    private static func anUnreadableCreditBalanceIsSurfaced() {
        let parsed = parse("usage-unreadable-credits.json")
        TestHarness.check("no spend figure is invented", parsed.spend == nil)
        TestHarness.check("and the failure to read one is surfaced",
                          parsed.warnings.contains(CodexUsageParser.Warning.unreadableCredits))

        // THE FIRST OF THE TWO SPEND GUARDS, and it was unpinned. The fixture above
        // exercises only the second (object present, balance unreadable); a `credits` that
        // is present and NOT AN OBJECT takes the other branch entirely, and vanished
        // silently — present-but-unreadable rendered identically to "this plan has no
        // credits", which is the same shape the window rules exist to prevent.
        let notAnObject = parse("usage-credits-not-an-object.json")
        TestHarness.check("credits present but not an object is a read failure, not an absence",
                          notAnObject.warnings
                              .contains(CodexUsageParser.Warning.unreadableCredits))
        TestHarness.check("and no spend is invented from it", notAnObject.spend == nil)
        TestHarness.expect("while the rest of the payload still projects",
                           window(notAnObject, .account, .session)?.utilization, .known(10))
        // A genuinely absent `credits` object says nothing, because there is nothing to
        // say: silence and a false alarm are not interchangeable.
        TestHarness.check("an absent credits object is not reported as unreadable",
                          !parse("usage-empty.json").warnings
                              .contains(CodexUsageParser.Warning.unreadableCredits))
    }

    // §7 renders these warnings as a list on one card. Without deduplication a payload
    // with twenty unreadable entries produces twenty identical lines, and a card nobody
    // reads is a card that cannot warn about anything. Order is preserved because the
    // card reads in sequence, which a `Set` alone would not give.
    private static func warningsAreDeduplicatedAndOrdered() {
        let parsed = parse("usage-repeated-warnings.json")
        TestHarness.expect("two entries with the same fault produce one line",
                           parsed.warnings.filter {
                               $0 == CodexUsageParser.Warning.unreadableBucket
                           }.count,
                           1)
        TestHarness.expect("and the lines are unique overall",
                           Set(parsed.warnings).count, parsed.warnings.count)

        // The SAME input through the unmodelled-group branch. Step 2 and step 3 are
        // twinned branches over the same shape, and the last round found them disagreeing
        // once already; this is the assertion that keeps them honest. Added after a
        // mutation SURVIVED: the enumerated branch was covered and the generic one was not.
        let generic = parse("usage-generic-list-mixed.json")
        TestHarness.expect("the real entry beside it is still ingested",
                           Snapshot.bindingUtilization(of: generic.windows), .known(42))
        TestHarness.check("and the unreadable element is surfaced the same way",
                          generic.warnings
                              .contains(CodexUsageParser.Warning.unreadableBucket))
    }

    // The unmodelled-group scan walks the payload's keys in SORTED order, so the window
    // list does not depend on dictionary ordering — §7 renders them in sequence, and an
    // order that moved between polls would make the popover jitter. Nothing pinned it, so
    // the sort was free to be deleted.
    private static func unmodelledGroupsAreProjectedInADeterministicOrder() {
        let parsed = parse("usage-ordered-groups.json")
        TestHarness.expect("groups are projected in sorted key order, not hash order",
                           parsed.windows.map(\.id.scope),
                           [.feature(id: "group:a_rate_limit"),
                            .feature(id: "group:z_rate_limit")])
    }

    // A top-level list that is not a quota group at all must stay silent. Warning
    // "some usage limits could not be read" about an ordinary array of strings is a false
    // alarm, and false alarms are how a card earns being ignored.
    private static func anOrdinaryListIsNotMistakenForAQuotaGroup() {
        let parsed = parse("usage-nonquota-list.json")
        TestHarness.expect("a plain list contributes no windows", parsed.windows.count, 1)
        TestHarness.check("and no warning about it",
                          !parsed.warnings.contains(CodexUsageParser.Warning.unreadableBucket)
                              && !parsed.warnings
                                  .contains(CodexUsageParser.Warning.unrecognisedGroup))
    }

    // MARK: - Payload-level facts

    // §4.2: the plan comes from the LIVE RESPONSE, never from `tokens.id_token` — the
    // JWT's subscription claims are a cache stamped at `chatgpt_subscription_last_checked`
    // and were observed a month stale on an active account. The fixture's JWT deliberately
    // claims a different plan, so a parser that read it would report that value here.
    private static func planComesFromTheResponseNotTheCachedTokenClaim() {
        TestHarness.expect("the plan is the one the live response states",
                           parse("usage-live.json").planLabel, "pro")
        // Asserted rather than assumed: if the fixture ever stopped disagreeing, the test
        // above would pass for the wrong reason and prove nothing.
        guard let segment = token("auth-live.json", "id_token")?
                .split(separator: ".", omittingEmptySubsequences: false).dropFirst().first,
              let payload = CodexAuthReader.base64URLDecoded(String(segment)),
              let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let scoped = claims[CodexAuthReader.claimNamespace] as? [String: Any]
        else {
            TestHarness.check("the credential fixture carries a readable id_token", false)
            return
        }
        TestHarness.check(
            "the fixture's cached plan claim disagrees, so the assertion above has teeth",
            (scoped["chatgpt_plan_type"] as? String) != "pro"
        )
    }

    // The account bucket IS the payload; its total absence is the schema drift §5 exists
    // to catch, and degrading to an empty snapshot would report a healthy account as
    // having no limits. But a NULL bucket is a live shape meaning "no account-level data"
    // and must not fail the fetch.
    private static func aMissingAccountBucketIsMalformedButANullOneIsNot() {
        var malformed = false
        if case .malformed = CodexUsageParser.parse(fixture("usage-no-rate-limit.json"), now: now) {
            malformed = true
        }
        TestHarness.check("a payload with no account bucket at all fails loud", malformed)

        let parsed = parse("usage-null-rate-limit.json")
        TestHarness.expect("a null account bucket still yields the feature limits",
                           parsed.windows.count, 1)
        TestHarness.check("and is not treated as an account-wide zero",
                          window(parsed, .account, .session) == nil)
        // NULL IS NO DATA, NOT A READ FAILURE. Telling the user a limit "could not be
        // read" every time a dormant bucket is null is the sort of small wrongness that
        // teaches people to ignore the warnings that matter. Added after a mutation
        // survived: collapsing the null check into a nil check passed the whole suite.
        TestHarness.check("a null bucket is not reported as an unreadable one",
                          !parsed.warnings.contains(CodexUsageParser.Warning.unreadableBucket))
    }

    // §7 drops an account with no windows out of the popover and the menu-bar worst-of
    // entirely, so a scope-reduced token looks exactly like a healthy account with nothing
    // to report. Say which one it is.
    private static func anAccountWithNoWindowsIsExplained() {
        let parsed = parse("usage-empty.json")
        TestHarness.expect("no windows are invented", parsed.windows.count, 0)
        TestHarness.check("and the emptiness is explained",
                          parsed.warnings.contains(CodexUsageParser.Warning.noLimits))
        TestHarness.check("no spend is invented either", parsed.spend == nil)
    }

    // §5.2: `allowed` / `limit_reached` are direct throttle state and are worth surfacing.
    // `limit_reached` also says WHICH bucket is currently binding, which is what
    // `isActive` means — without it the single figure §7.2 shows falls back to a
    // heuristic.
    private static func throttleStateIsSurfacedAndMarksTheBindingWindow() {
        let parsed = parse("usage-throttled.json")
        TestHarness.check("a reached limit is surfaced",
                          parsed.warnings.contains(CodexUsageParser.Warning.limitReached))
        TestHarness.check("a refusal to serve is surfaced",
                          parsed.warnings.contains(CodexUsageParser.Warning.notAllowed))
        TestHarness.expect("the binding bucket's window is marked active",
                           window(parsed, .account, .session)?.isActive, true)
        TestHarness.expect("and it is the figure the account reports",
                           Snapshot.bindingUtilization(of: parsed.windows), .known(100))
        // An unthrottled account flags nothing, so the aggregate falls back to the worst
        // known window rather than to an arbitrary one.
        TestHarness.check("an unthrottled account marks nothing active",
                          parse("usage-live.json").windows.allSatisfy { !$0.isActive })
    }

    // J2, and the failure is perverse: the RATE-LIMITED account is the one whose figure
    // disappears. `limit_reached` is a bucket flag, so it marked every window in the
    // bucket active — including one whose `used_percent` is null — and
    // `bindingUtilization` returns `.unknown` if ANY active window is unknown. Measured
    // on production code: a throttled bucket with a null session window and a 95% weekly
    // window reported `.unknown`; removing `limit_reached` from the same payload made it
    // correctly report 95%. Marking the constraint should never blank the constraint.
    private static func aThrottledBucketDoesNotBlankItsOwnFigure() {
        let parsed = parse("usage-throttled-unknown.json")
        TestHarness.expect("the throttled account still reports its worst known figure",
                           Snapshot.bindingUtilization(of: parsed.windows), .known(95))
        TestHarness.expect("a window with no figure is not presented as the constraint",
                           window(parsed, .account, .session)?.isActive, false)
        TestHarness.expect("while the one that has a figure is",
                           window(parsed, .account, .weekly)?.isActive, true)
        TestHarness.check("and the null figure is still not zero",
                          window(parsed, .account, .session)?.utilization == .unknown)
    }

    // J5. A per-feature quota exhausted while the account quota is healthy is the ordinary
    // real case, and `limit_reached` for a feature sits TWO levels down
    // (`additional_rate_limits[i].rate_limit.limit_reached` — see the live recording), so
    // the depth-2 throttle read is the only path that can mark a feature window binding.
    // Every other fixture has the flag false, so deleting that read changed nothing.
    private static func aFeatureCanBeTheBindingLimitWhileTheAccountIsHealthy() {
        let parsed = parse("usage-feature-throttled.json")
        let feature = window(parsed, .feature(id: "feature:codex_alpha"), .weekly)
        TestHarness.expect("the exhausted feature is marked as the constraint",
                           feature?.isActive, true)
        TestHarness.expect("the healthy account window is not",
                           window(parsed, .account, .session)?.isActive, false)
        // Without the depth-2 read nothing is active, and the aggregate falls back to the
        // worst known window — which happens to be the same number here, so the assertion
        // that bites is the flag itself, above.
        TestHarness.expect("and the account reports the feature's figure",
                           Snapshot.bindingUtilization(of: parsed.windows), .known(88))
        TestHarness.check("the reached limit is surfaced",
                          parsed.warnings.contains(CodexUsageParser.Warning.limitReached))
    }

    // Labels are presentation and come from the payload's own words — §5.1 forbids a
    // client-side label map, so a new feature arrives with a usable name and no build.
    // The span appears in the label ONLY when one bucket contributed several windows;
    // without that, the popover shows one bucket's two windows under one identical name,
    // which renders the one-bucket-many-windows bug as though it were still present.
    private static func labelsComeFromThePayloadAndDisambiguateSharedBuckets() {
        TestHarness.expect("a single-window feature bucket uses its display name",
                           window(parse("usage-live.json"),
                                  .feature(id: "feature:codex_alpha"), .weekly)?.label,
                           "Codename Alpha")
        let multi = parse("usage-multi-window.json")
        TestHarness.expect("a feature bucket's two windows are distinguishable",
                           multi.windows
                               .filter { $0.id.scope == .feature(id: "feature:codex_alpha") }
                               .map(\.label).sorted(),
                           ["Session · Codename Alpha", "Weekly · Codename Alpha"])
        TestHarness.expect("the account bucket's windows are named by period",
                           multi.windows.filter { $0.id.scope == .account }.map(\.label).sorted(),
                           ["Session", "Weekly"])

        // THE NON-CANONICAL SPAN, the twin of the unstated one. `WindowSpan.other` covers
        // "spans the providers have not standardised", and the label branch for a stated
        // one was unpinned while the branch for an unstated one (`"Limit"`) was covered —
        // every fixture used 18000 or 604800 or nothing at all.
        //
        // Two of them in one bucket, so the labels have to tell them apart: without the
        // period in the name the popover shows one bucket's two windows under one
        // identical "Limit", which is the one-bucket-many-windows bug rendered as though
        // it were still present.
        let other = parse("usage-noncanonical-span.json")
        TestHarness.expect("a stated but non-canonical duration names its own period",
                           other.windows.map(\.label).sorted(), ["3600s limit", "86400s limit"])
        // And it is NOT folded onto a canonical span: the length of an hour is not the
        // vendor's to have left unstated, and merging it onto `.session` would join its
        // threshold history (§8) to a window it has nothing to do with.
        TestHarness.check("and is not folded onto a canonical span",
                          other.windows.allSatisfy {
                              $0.id.span != .session && $0.id.span != .weekly
                          })
        TestHarness.expect("both figures survive",
                           Snapshot.bindingUtilization(of: other.windows), .known(44))
    }

    // MARK: - Credential reading (§4.2)

    // §4.2 requires `auth_mode == "chatgpt"`. An API-key login is a perfectly valid
    // credential for a different product with no subscription quota, and an ABSENT mode is
    // not assumed to be the required one — assuming it would send an API key's bearer
    // token to the subscription endpoint.
    private static func onlyAChatGPTLoginIsAcceptedAndAbsenceIsNotAssent() {
        TestHarness.check("an API-key login is not a subscription credential",
                          reader(world(auth: "auth-api-key-mode.json")).read() == .unsupportedAuthMode)
        TestHarness.check("an absent auth mode is not assumed to be the required one",
                          reader(world(auth: "auth-no-auth-mode.json")).read() == .unsupportedAuthMode)
    }

    // Task 4's finding, applied here: a locked file, a corrupt payload and a genuine
    // sign-out used to flatten into a confident "you are signed out" — advice that is
    // wrong and sends the user to re-authenticate a working session. Four inputs, four
    // outcomes.
    private static func credentialFailuresAreFourDistinctStatesNotOneBlanketSignedOut() {
        let states: [(String, CodexAuthRead)] = [
            ("no auth.json at all", reader(world(auth: nil)).read()),
            ("auth.json is not JSON", reader(world(auth: "auth-not-json.txt")).read()),
            ("no access token", reader(world(auth: "auth-no-access-token.json")).read()),
            ("an empty access token", reader(world(auth: "auth-empty-access-token.json")).read()),
        ]
        TestHarness.check("a missing file is a missing file", states[0].1 == .fileMissing)
        var unreadable = false
        if case .unreadable = states[1].1 { unreadable = true }
        TestHarness.check("an unparseable file is a FAULT, not a sign-out", unreadable)
        TestHarness.check("an absent access token is its own state", states[2].1 == .noAccessToken)
        TestHarness.check("an empty access token is not a token", states[3].1 == .noAccessToken)
        // The states must map onto DIFFERENT things the user is told, or the distinction
        // above is decorative.
        var displayed: [String] = []
        for (_, state) in states {
            switch CodexProvider.state(for: state) {
            case .signedOut: displayed.append("signedOut")
            case .failed: displayed.append("failed")
            default: displayed.append("other")
            }
        }
        TestHarness.expect("an unreadable credential does not render as signed out",
                           displayed, ["signedOut", "failed", "signedOut", "signedOut"])
    }

    // §4.2: IDENTITY IS COMPOSITE, because neither field is trustworthy alone — the
    // identifier sent with the request and the one returned in the response have been
    // OBSERVED to disagree. Getting this wrong misattributes one account's notification
    // history and cached readings to the next.
    private static func identityIsACompositeOfBothIdentifiers() {
        guard let live = credential("auth-live.json"),
              let other = credential("auth-other-account.json")
        else {
            TestHarness.check("the credential fixtures are usable", false)
            return
        }
        // Read out of the fixture rather than restated here.
        let storedAccount = token("auth-live.json", "account_id")
        TestHarness.expect("the stored account identifier is kept",
                           live.accountIdentifier, storedAccount)
        TestHarness.check("the user identifier is resolved from the token's identity claims",
                          live.userIdentifier?.hasPrefix("user-") == true)
        TestHarness.expect("both halves are namespaced and both are present",
                           live.identityComponents,
                           ["account:" + (storedAccount ?? ""), "user:" + (live.userIdentifier ?? "")])
        // The point of the composite: two sign-ins that agree on ONE half are still two
        // accounts. Keying on either field alone merges them.
        TestHarness.check("a different sign-in is a different identity",
                          live.identityComponents != other.identityComponents)
        TestHarness.check(
            "and the difference survives into the persisted-state namespace",
            AccountIdentity(provider: .codex, components: live.identityComponents).storageKey
                != AccountIdentity(provider: .codex, components: other.identityComponents).storageKey
        )
    }

    // FIXED ARITY. A composite that shrinks when one field fails to parse changes the
    // account's `storageKey`, and §6 drops persisted state by namespace — so a transient
    // id_token problem would silently orphan the account's history and re-fire its whole
    // notification ladder.
    private static func aHalfResolvedIdentityKeepsItsShape() {
        guard let missing = credential("auth-no-id-token.json"),
              let broken = credential("auth-broken-id-token.json")
        else {
            TestHarness.check("the degraded credential fixtures are usable", false)
            return
        }
        TestHarness.expect("an absent id_token leaves the slot empty rather than removing it",
                           missing.identityComponents.count, 2)
        TestHarness.expect("an unreadable id_token degrades the same way, and does not throw",
                           broken.identityComponents.count, 2)
        TestHarness.check("the stored half still keys the account",
                          missing.identityComponents.first == "account:"
                              + (token("auth-no-id-token.json", "account_id") ?? ""))

        // THE PERSISTED KEY ITSELF IS PINNED, not just its shape. §6 drops persisted state
        // by namespace and §8 arms thresholds under it, so any movement in this string
        // silently reclaims an account's history — and a length assertion cannot see that.
        // Pinning it makes a future change a decision rather than an accident.
        guard let live = credential("auth-live.json"),
              let account = token("auth-live.json", "account_id"),
              let user = live.userIdentifier
        else {
            TestHarness.check("the live credential fixture is usable", false)
            return
        }
        TestHarness.expect("the resolved key is exactly this",
                           AccountIdentity(provider: .codex,
                                           components: live.identityComponents).storageKey,
                           "codex:account\\:\(account):user\\:\(user)")
        TestHarness.expect("and the half-resolved one is exactly this",
                           AccountIdentity(provider: .codex,
                                           components: missing.identityComponents).storageKey,
                           "codex:account\\:\(account):user\\:")
        // The two are DIFFERENT keys, which is the accepted cost of a composite whose
        // halves can fail independently: losing the id_token re-keys the account once and
        // §6 reclaims its history. It is warned about (`halfResolvedIdentity`) rather than
        // hidden, and it no longer also drops the account — see `fetch`'s classification.
        TestHarness.check("losing a half moves the key, which is why it is warned about",
                          live.identityComponents != missing.identityComponents)
    }

    // §4.2 requires the collision and disagreement cases to be handled EXPLICITLY and
    // surfaced, rather than silently resolved to one field.
    private static func ambiguousCredentialIdentityIsSurfaced() {
        guard let colliding = credential("auth-colliding-identity.json"),
              let half = credential("auth-no-id-token.json"),
              let live = credential("auth-live.json")
        else {
            TestHarness.check("the identity fixtures are usable", false)
            return
        }
        TestHarness.check("one value used for both halves is surfaced",
                          colliding.identityWarnings
                              .contains(CodexCredential.Warning.collidingIdentifiers))
        // The half-resolved case had NO warning at all, and it is the one that can
        // collapse two sign-ins onto one key — two accounts sharing an account identifier
        // (plausible if it names a workspace) and both lacking a readable user half.
        TestHarness.check("a composite that only half resolved is surfaced",
                          half.identityWarnings
                              .contains(CodexCredential.Warning.halfResolvedIdentity))
        TestHarness.expect("a healthy credential is not warned about",
                           live.identityWarnings, [])
    }

    // C3: a credential with a WORKING token but nothing durable to key on is not
    // `usable`. Every such account would otherwise share one persistence namespace, so
    // the next sign-in would inherit the previous occupant's cached readings and
    // notification history — the misattribution §4.2 exists to prevent, which a warning
    // cannot fix because the app still reads the wrong account's numbers.
    //
    // The guarantee is structural rather than conventional: nothing can be PERSISTED
    // under the sentinel because no fetch can ever succeed for it.
    private static func anUnkeyableCredentialIsNeverFetchedOrPersisted() {
        TestHarness.check("a token with no durable identity is not a usable credential",
                          reader(world(auth: "auth-no-identity.json")).read() == .noDurableIdentity)
        var failed = false
        if case .failed = CodexProvider.state(for: .noDurableIdentity) { failed = true }
        TestHarness.check("it is shown as failed — the token works, the app declines to key it",
                          failed)

        // The account IS present (the user must be able to see why nothing is shown), and
        // it takes the sentinel identity…
        let fs = world(auth: "auth-no-identity.json")
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        let sentinel = AccountIdentity(provider: .codex,
                                       CodexCredential.unresolvedIdentityComponent)
        TestHarness.expect("it is discovered rather than hidden",
                           subject(fs, http).discoverAccounts().first?.ref.id, sentinel)
        // …but no snapshot can ever be filed under it.
        TestHarness.expect("and fetching it is terminal, so nothing is ever cached there",
                           failure(fs, http, ref: AccountRef(id: sentinel, label: "Codex")),
                           .accountUnknown)
        TestHarness.check("no request was even attempted", http.requests.isEmpty)
        TestHarness.check("a real composite cannot alias the sentinel",
                          credential("auth-live.json")?.identityComponents
                              != [CodexCredential.unresolvedIdentityComponent])
    }

    // §4.2: `OPENAI_API_KEY` is unrelated to subscription quota and is IGNORED even when
    // populated. And the credential document may carry unrelated third-party material,
    // which is parsed around rather than through — task 4 found live secrets for other
    // services sitting in the sibling's blob.
    private static func unrelatedCredentialMaterialIsNeverRead() {
        guard let withKey = credential("auth-with-api-key.json"),
              let withSiblings = credential("auth-with-unrelated-siblings.json"),
              let live = credential("auth-live.json")
        else {
            TestHarness.check("the credential fixtures are usable", false)
            return
        }
        TestHarness.expect("the bearer token is the subscription token, not the API key",
                           withKey.accessToken, live.accessToken)
        TestHarness.expect("an unrelated third-party section changes nothing",
                           withSiblings, live)
        // The API key is present in that fixture, so the assertion above has teeth.
        TestHarness.check("the fixture really does carry an API key",
                          json("auth-with-api-key.json")["OPENAI_API_KEY"] is String)
    }

    // §4.2: `$CODEX_HOME` wins when set. A menu-bar app inherits no shell environment, so
    // the DEFAULT path is the one that matters in the shipped bundle — but a developer or
    // a login item that does set it must not be read from the wrong place.
    private static func theConfiguredHomeOverridesTheDefaultLocation() {
        let fs = world(auth: nil)
        fs.environment["CODEX_HOME"] = "/fake/elsewhere/codex"
        fs.directories.insert("/fake/elsewhere/codex")
        fs.files["/fake/elsewhere/codex/auth.json"] = fixture("auth-live.json")
        TestHarness.expect("the configured directory is read",
                           reader(fs).credentialPath, "/fake/elsewhere/codex/auth.json")
        var usable = false
        if case .usable = reader(fs).read() { usable = true }
        TestHarness.check("and the credential there is found", usable)

        // A relative path has no defensible base in a window-server-launched app.
        let relative = world(auth: "auth-live.json")
        relative.environment["CODEX_HOME"] = "codex"
        TestHarness.check("a relative configured path is rejected, not resolved",
                          reader(relative).credentialPath == nil)
    }

    // MARK: - Discovery

    // §4.1's inclusion/state split, applied to a single-account provider: the DIRECTORY
    // decides whether there is an account to show, the CREDENTIAL decides what state it is
    // in. Conflating them makes signed-out unrepresentable — an account with no credential
    // would simply vanish, which looks identical to Codex not being installed.
    private static func discoveryPresentsTheAccountTogetherWithItsState() {
        func state(_ auth: String?, installed: Bool = true) -> AccountState? {
            CodexProvider(reader: reader(world(auth: auth, installed: installed)),
                          http: FakeHTTP(), clock: { now })
                .discoverAccounts().first?.state
        }
        var pending = false
        if case .pending = state("auth-live.json") { pending = true }
        TestHarness.check("a usable credential is pending, not active — it has no reading yet",
                          pending)
        var signedOut = false
        if case .signedOut = state(nil) { signedOut = true }
        TestHarness.check("a configured machine with no credential shows a signed-out account",
                          signedOut)
        var failed = false
        if case .failed = state("auth-not-json.txt") { failed = true }
        TestHarness.check("an unreadable credential shows as failed, not signed out", failed)
        TestHarness.check("a machine with no Codex configuration shows no Codex account",
                          state("auth-live.json", installed: false) == nil)
        // Presentation only, and read out of the credential rather than restated: §3 keeps
        // it off the identity entirely, so discovering it later must not orphan history.
        TestHarness.expect("the account's email is carried as its subtitle",
                           CodexProvider(reader: reader(world()), http: FakeHTTP(), clock: { now })
                               .discoverAccounts().first?.ref.subtitle,
                           credential("auth-live.json")?.emailAddress)
        TestHarness.check("and the fixture really publishes one, so that assertion has teeth",
                          credential("auth-live.json")?.emailAddress?.contains("@") == true)
    }

    // MARK: - Fetch

    // §5.2's request. Every header is load-bearing: without the bearer token the endpoint
    // rejects the request, and the account header is what the observed disagreement is
    // ABOUT — it is the identifier the request sends.
    private static func theRequestCarriesTheBearerTokenAndTheAccountHeader() {
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        _ = awaitResult { await subject(world(), http).fetch(reference()) }

        let headers = http.requests.first?.headers ?? [:]
        // Rebuilt from the fixture: no token material, real or fictional, is spelled into
        // this source.
        TestHarness.expect("the access token is sent as a bearer token",
                           headers["Authorization"],
                           token("auth-live.json", "access_token").map { "Bearer " + $0 })
        TestHarness.expect("the account identifier is sent as its own header",
                           headers["X-Account-Id"], token("auth-live.json", "account_id"))
        TestHarness.expect("JSON is requested", headers["Accept"], "application/json")
        TestHarness.expect("the documented endpoint is used", http.requestedPaths.first,
                           "https://chatgpt.com/backend-api/wham/usage")
        TestHarness.expect("and only one request was needed", http.requests.count, 1)
    }

    // §5.2: on 404, retry the alternate path and CACHE WHICHEVER ANSWERED — the path has
    // moved before. Without the cache every poll for the rest of the process's life pays
    // two round trips; caching the 404 instead would pin the app to a dead path.
    private static func aMovedPathIsRetriedOnceAndThenRemembered() {
        let http = FakeHTTP()
        http.outcomes["https://chatgpt.com/backend-api/wham/usage"] =
            .response(status: 404, headers: [:], body: Data())
        http.outcomes["https://chatgpt.com/api/codex/usage"] =
            .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        let provider = subject(world(), http)

        let first = awaitResult { await provider.fetch(reference()) }
        var succeeded = false
        if case .success = first { succeeded = true }
        TestHarness.check("the alternate path is tried when the first answers 404", succeeded)
        TestHarness.expect("both paths were tried, in order", http.requestedPaths,
                           ["https://chatgpt.com/backend-api/wham/usage",
                            "https://chatgpt.com/api/codex/usage"])

        _ = awaitResult { await provider.fetch(reference()) }
        TestHarness.expect("the working path is remembered for the next poll",
                           http.requestedPaths.count, 3)
        TestHarness.expect("and the dead one is not tried again",
                           http.requestedPaths.last, "https://chatgpt.com/api/codex/usage")
    }

    // Both paths gone is a STATUS, not a transport failure. §6 retries a transport failure
    // on a timer that nothing stops; an endpoint that has been withdrawn is not going to
    // come back within one poll interval.
    private static func bothPathsMissingIsAStatusNotATransportFailure() {
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 404, headers: [:], body: Data())
        TestHarness.expect("two 404s report the status", failure(world(), http),
                           .unexpectedStatus(code: 404))
    }

    // A network failure is not a moved path. Trying the alternate here would double every
    // timeout on a flaky connection and teach the cache nothing.
    private static func aTransportFailureDoesNotProbeTheAlternatePath() {
        let http = FakeHTTP()
        http.fallbackOutcome = .failure(message: "the network is down")
        TestHarness.expect("a transport failure is reported as one", failure(world(), http),
                           .transport(message: "the network is down"))
        TestHarness.expect("and only one path was tried", http.requests.count, 1)
    }

    // §6's error contract. Each status means a different thing to the store: one re-reads
    // the credential and retries, one waits for a stated interval, one is a bug report.
    // Collapsing them makes the store's backoff meaningless.
    private static func statusCodesMapOntoTheErrorContract() {
        func outcome(_ status: Int, headers: [String: String] = [:]) -> FetchError? {
            let http = FakeHTTP()
            http.fallbackOutcome = .response(status: status, headers: headers, body: Data())
            return failure(world(), http)
        }
        TestHarness.expect("401 is an authentication rejection", outcome(401),
                           .authenticationRejected)
        TestHarness.expect("403 is an authentication rejection", outcome(403),
                           .authenticationRejected)
        // Case-insensitively, because the two vendors do not agree on capitalisation and a
        // dictionary subscript does not forgive that.
        TestHarness.expect("429 carries the stated retry interval",
                           outcome(429, headers: ["retry-after": "120"]),
                           .rateLimited(retryAfter: 120))
        // The 60-second floor is the STORE's (§6). A floor applied in two places is a
        // floor that disagrees with itself.
        TestHarness.expect("and does not apply the store's floor here",
                           outcome(429, headers: ["Retry-After": "5"]),
                           .rateLimited(retryAfter: 5))
        TestHarness.expect("anything else names its status", outcome(500),
                           .unexpectedStatus(code: 500))
    }

    // §5's retention exists to diagnose silent schema drift, so the body travels WITH the
    // failure — discarding it here would throw the evidence away in the one case that most
    // needs it.
    private static func aMalformedResponseCarriesTheBodyForDiagnosis() {
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 200, headers: [:],
                                         body: fixture("usage-no-rate-limit.json"))
        guard case .malformedResponse(_, let body) = failure(world(), http) else {
            TestHarness.check("a body that cannot be projected is malformed", false)
            return
        }
        TestHarness.expect("the raw body is returned for diagnosis",
                           body, fixture("usage-no-rate-limit.json"))
    }

    // §3 and §5.2, and this is the case the whole warnings channel was added for: on the
    // target machine the response's `account_id` EQUALS its own `user_id` while the request
    // sends a UUID. It is the OBSERVED NORMAL STATE, so modelling it as a `FetchError`
    // would render the only real Codex account as a hard failure.
    private static func anIdentityDisagreementWarnsRatherThanFailing() {
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        guard case .success(let fetched) = result(world(), http) else {
            TestHarness.check("the live payload still yields a snapshot", false)
            return
        }
        TestHarness.check("the ambiguity is surfaced",
                          fetched.snapshot.warnings
                              .contains(CodexProvider.Warning.ambiguousIdentifiers))
        // Overlapping identifiers are NOT a mismatch: the composite exists precisely
        // because the two sides spell the pair differently.
        TestHarness.check("but an overlapping identity is not called a mismatch",
                          !fetched.snapshot.warnings
                              .contains(CodexProvider.Warning.identityDisagreement))
        TestHarness.expect("and the account is still fully usable",
                           fetched.snapshot.windows.count, 2)

        // A response with NOTHING in common with the credential is the dangerous case —
        // those readings may belong to another account entirely.
        let foreign = FakeHTTP()
        foreign.fallbackOutcome = .response(status: 200, headers: [:],
                                            body: fixture("usage-foreign-account.json"))
        guard case .success(let other) = result(world(), foreign) else {
            TestHarness.check("a foreign response still yields a snapshot", false)
            return
        }
        TestHarness.check("a wholly different account is called out",
                          other.snapshot.warnings
                              .contains(CodexProvider.Warning.identityDisagreement))

        // J3 — THE PARTIAL OVERLAP, and it warned about NOTHING. The rule required TOTAL
        // disjointness, so a response naming our user on one field and a DIFFERENT user on
        // the other passed in silence. That is the shape a genuine misattribution takes;
        // only the wholesale mix-up above was covered.
        let partial = FakeHTTP()
        partial.fallbackOutcome = .response(status: 200, headers: [:],
                                            body: fixture("usage-partial-identity.json"))
        guard case .success(let mixed) = result(world(), partial) else {
            TestHarness.check("a partially matching response still yields a snapshot", false)
            return
        }
        TestHarness.check("a response naming a stranger on one field is called out",
                          mixed.snapshot.warnings
                              .contains(CodexProvider.Warning.identityDisagreement))
    }

    // §3: credential freshness is an invariant of `fetch`. The CLI rotates `auth.json`
    // (the observed file carries its own `last_refresh`), so a token captured once is
    // guaranteed to go stale while the stored credential stays healthy — and a provider
    // that cached it would park a live account as rejected forever while every parsing
    // test stayed green.
    private static func theCredentialIsReReadOnEveryFetch() {
        let fs = world()
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        let provider = subject(fs, http)

        _ = awaitResult { await provider.fetch(reference()) }
        // The CLI rotates the token on disk between polls. Same account, new bearer.
        fs.files[authPath] = rotated(fixture("auth-live.json"))
        _ = awaitResult { await provider.fetch(reference()) }

        let sent = http.requests.compactMap { $0.headers["Authorization"] }
        TestHarness.expect("both fetches issued a request", sent.count, 2)
        TestHarness.check("the second fetch sends the rotated token, not the first one",
                          sent.count == 2 && sent[0] != sent[1])
    }

    // Rewrites ONLY the access token, so the rest of the credential — and therefore the
    // account's identity — stays exactly as recorded.
    private static func rotated(_ template: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: template)) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any]
        else { return template }
        tokens["access_token"] = (tokens["access_token"] as? String).map { $0 + "-rotated" }
        root["tokens"] = tokens
        return (try? JSONSerialization.data(withJSONObject: root)) ?? template
    }

    // §6 gained `.accountUnknown` in task 5 precisely because mapping this onto
    // `.transport` meant retrying an account that has genuinely left, forever, on a timer
    // nothing stops. Signing a different account in must not inherit the previous
    // occupant's identity either (§10's last row).
    private static func anAccountThatIsNoLongerSignedInIsTerminalNotRetryable() {
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        // A different account is signed in now.
        TestHarness.expect("a fetch for an account that is no longer signed in is terminal",
                           failure(world(auth: "auth-other-account.json"), http),
                           .accountUnknown)
        TestHarness.check("and no request is attempted for it", http.requests.isEmpty)

        TestHarness.expect("nor is one attempted when Codex is not installed at all",
                           failure(world(installed: false), http), .accountUnknown)
        TestHarness.check("still no request", http.requests.isEmpty)
    }

    // C2, and it was DEAD CODE. `fetch` derived the account reference from the credential
    // read result, so every non-usable read resolved to the shared `unresolved` sentinel
    // and could never equal a live account's id — the identity guard swallowed all four
    // credential classifications before the switch that distinguishes them ever ran.
    // (Proven by the reviewer: replacing both branch bodies with a trap left the suite
    // green at 392.)
    //
    // The cost is not cosmetic. Every one of these returned `.accountUnknown`, which §6
    // treats as TERMINAL and drops — and the CLI rewrites `auth.json` on every token
    // rotation, so a read landing mid-write is routine. One unlucky poll permanently
    // removed a healthy account, and §6's "re-read the credential and retry before
    // concluding anything" contract was unreachable from the credential side.
    private static func aCredentialFaultIsClassifiedRatherThanTreatedAsADepartedAccount() {
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))

        // A rewrite caught in flight: transient, so §6 must back off and retry.
        let truncated = world(auth: "auth-not-json.txt")
        guard case .transport = failure(truncated, http) ?? .accountUnknown else {
            TestHarness.check("an unreadable credential is retryable, not terminal", false)
            return
        }
        TestHarness.check("an unreadable credential is retryable, not terminal", true)

        // The credential is gone or unusable: §6 re-reads and decides expiry-vs-revoked;
        // this file does not get to conclude the account has LEFT.
        for name in [nil, "auth-no-access-token.json", "auth-api-key-mode.json"] {
            TestHarness.expect("\(name ?? "no auth.json"): the credential is rejected, "
                               + "not the account discarded",
                               failure(world(auth: name), http), .authenticationRejected)
        }

        // The one shape that genuinely justifies terminal treatment from the credential
        // side: somebody else is signed in now, and no retry brings the old account back.
        TestHarness.expect("a different account signed in is terminal",
                           failure(world(auth: "auth-other-account.json"), http),
                           .accountUnknown)
        TestHarness.check("and none of these attempted a request", http.requests.isEmpty)
    }

    // K2. `fileContents` returns nil for "not there" AND for "there and unreadable", so a
    // locked volume or a rewrite in flight rendered as a confident "you are signed out" —
    // advice that is wrong and sends the user to re-authenticate a working session. Task 4
    // split `failed` from `signedOut` for exactly this reason; nothing simulated it here.
    private static func anExistingButUnreadableCredentialIsAFaultNotASignOut() {
        let fs = world(auth: "auth-live.json")
        fs.unreadablePaths = [authPath]
        var unreadable = false
        if case .unreadable = reader(fs).read() { unreadable = true }
        TestHarness.check("a file that exists but cannot be read is a fault", unreadable)
        var failed = false
        if case .failed = subject(fs, FakeHTTP()).discoverAccounts().first?.state { failed = true }
        TestHarness.check("and it renders as failed, not as signed out", failed)
        // The genuinely missing file still resolves the other way — the distinction is the
        // whole point.
        TestHarness.check("while an absent file is still a sign-out",
                          reader(world(auth: nil)).read() == .fileMissing)
    }

    // K3. Any diagnostic path that stringifies a credential — including this harness
    // describing a failed comparison — must not be able to print a bearer token.
    private static func aBearerTokenCannotBePrintedByADiagnostic() {
        guard let live = credential("auth-live.json"),
              let token = token("auth-live.json", "access_token")
        else {
            TestHarness.check("the credential fixture is usable", false)
            return
        }
        for rendered in [String(describing: live),
                         String(reflecting: live),
                         String(describing: CodexAuthRead.usable(live))] {
            TestHarness.check("no rendering of a credential contains its token",
                              !rendered.contains(token))
        }
        TestHarness.check("and the redacted form still says what it is",
                          String(describing: live).contains("redacted"))
    }

    // J4, and it is the exact task-5 pattern: the existing test asserted on the
    // `CodexCredential` value while nothing pinned the only place §7 renders these — so
    // deleting `+ credential.identityWarnings` from the snapshot left the suite green.
    private static func credentialIdentityWarningsReachTheSnapshot() {
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        let fs = world(auth: "auth-colliding-identity.json")
        guard case .success(let fetched) = result(fs, http,
                                                  ref: CodexProvider.reference(for: reader(fs).read()))
        else {
            TestHarness.check("the colliding-identity credential still fetches", false)
            return
        }
        TestHarness.check("a credential-side identity warning reaches the user-visible list",
                          fetched.snapshot.warnings
                              .contains(CodexCredential.Warning.collidingIdentifiers))

        let half = world(auth: "auth-no-id-token.json")
        guard case .success(let other) = result(half, http,
                                                ref: CodexProvider.reference(for: reader(half).read()))
        else {
            TestHarness.check("the half-resolved credential still fetches", false)
            return
        }
        TestHarness.check("and so does the half-resolved one",
                          other.snapshot.warnings
                              .contains(CodexCredential.Warning.halfResolvedIdentity))
    }

    // The success path end to end: the projected snapshot plus the body it was projected
    // from (§5 retains the latest raw response per account, and §6 forbids the provider
    // writing it, so it has to be returned).
    private static func aSuccessfulFetchProjectsASnapshotAndReturnsTheRawBody() {
        let http = FakeHTTP()
        http.fallbackOutcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        guard case .success(let fetched) = result(world(), http) else {
            TestHarness.check("the live payload yields a snapshot", false)
            return
        }
        TestHarness.expect("the plan comes from the response", fetched.snapshot.planLabel, "pro")
        TestHarness.expect("the credit balance is carried through unqualified",
                           fetched.snapshot.spend?.balance, .unqualified(raw: "0"))
        TestHarness.expect("the snapshot is stamped with the fetch time",
                           fetched.snapshot.fetchedAt, now)
        TestHarness.expect("the raw body is returned verbatim",
                           fetched.rawBody, fixture("usage-live.json"))
        TestHarness.expect("and it is filed against the account that was asked for",
                           fetched.snapshot.account.id, reference().id)
    }

    // MARK: - Plumbing

    private static func subject(_ fs: FakeFileSystem, _ http: FakeHTTP) -> CodexProvider {
        CodexProvider(reader: reader(fs), http: http, clock: { now })
    }

    // The reference the app would hold for the live credential, resolved the same way
    // discovery resolves it.
    private static func reference() -> AccountRef {
        CodexProvider.reference(for: reader(world()).read())
    }

    // `ref` defaults to the live credential's reference — the account the app would be
    // holding — so a test that changes what is on disk is asking the same question the
    // store asks: "fetch the account I know about."
    private static func result(_ fs: FakeFileSystem,
                               _ http: FakeHTTP,
                               ref: AccountRef? = nil) -> Result<FetchedSnapshot, FetchError> {
        let account = ref ?? reference()
        return awaitResult { await subject(fs, http).fetch(account) }
    }

    private static func failure(_ fs: FakeFileSystem,
                                _ http: FakeHTTP,
                                ref: AccountRef? = nil) -> FetchError? {
        guard case .failure(let error) = result(fs, http, ref: ref) else { return nil }
        return error
    }

    // The harness is synchronous and `fetch` is async (§3). Bridging here keeps every test
    // a plain function rather than making the whole suite async.
    private static func awaitResult<T>(_ operation: @escaping () async -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await operation()
            done.signal()
        }
        done.wait()
        guard let value = box.value else { fatalError("async operation produced no value") }
        return value
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    static func run() {
        oneBucketContributesMoreThanOneWindow()
        windowsAreFoundAtEitherNestingDepth()
        aBucketThatIsItselfAWindowIsIngested()
        anUnrecognisableWindowShapeIsNeverSilent()
        anEnumeratedKeyWhoseShapeDriftedIsRescuedNotDropped()
        collidingIdentitiesAreMadeDistinctNotJustAnnounced()
        windowsAreClassifiedByDurationNotPosition()
        quotaGroupsOutsideTheEnumeratedOnesAreIngested()
        windowsWithNoStatedDurationAreKeptNotDropped()
        aDurationThatCannotBeReadExactlyIsNotGuessedAt()
        theDiscriminatorChainDegradesWithoutLosingAWindow()
        unreadableWindowsAreSurfacedAndTheRestSurvives()
        absurdFiguresAreClampedAndUnknownIsNeverZero()
        balanceParsesAsStringAndNumberAndStaysUnqualified()
        resetTimesPreferTheCountdownAndDistinguishUnreadable()
        planComesFromTheResponseNotTheCachedTokenClaim()
        aMissingAccountBucketIsMalformedButANullOneIsNot()
        anAccountWithNoWindowsIsExplained()
        throttleStateIsSurfacedAndMarksTheBindingWindow()
        aThrottledBucketDoesNotBlankItsOwnFigure()
        aFeatureCanBeTheBindingLimitWhileTheAccountIsHealthy()
        aNegativePercentageIsUnknownNotZero()
        anUnreadableCreditBalanceIsSurfaced()
        warningsAreDeduplicatedAndOrdered()
        unmodelledGroupsAreProjectedInADeterministicOrder()
        anOrdinaryListIsNotMistakenForAQuotaGroup()
        labelsComeFromThePayloadAndDisambiguateSharedBuckets()
        onlyAChatGPTLoginIsAcceptedAndAbsenceIsNotAssent()
        credentialFailuresAreFourDistinctStatesNotOneBlanketSignedOut()
        anExistingButUnreadableCredentialIsAFaultNotASignOut()
        aBearerTokenCannotBePrintedByADiagnostic()
        identityIsACompositeOfBothIdentifiers()
        aHalfResolvedIdentityKeepsItsShape()
        ambiguousCredentialIdentityIsSurfaced()
        anUnkeyableCredentialIsNeverFetchedOrPersisted()
        unrelatedCredentialMaterialIsNeverRead()
        theConfiguredHomeOverridesTheDefaultLocation()
        discoveryPresentsTheAccountTogetherWithItsState()
        theRequestCarriesTheBearerTokenAndTheAccountHeader()
        aMovedPathIsRetriedOnceAndThenRemembered()
        bothPathsMissingIsAStatusNotATransportFailure()
        aTransportFailureDoesNotProbeTheAlternatePath()
        statusCodesMapOntoTheErrorContract()
        aMalformedResponseCarriesTheBodyForDiagnosis()
        anIdentityDisagreementWarnsRatherThanFailing()
        credentialIdentityWarningsReachTheSnapshot()
        aCredentialFaultIsClassifiedRatherThanTreatedAsADepartedAccount()
        theCredentialIsReReadOnEveryFetch()
        anAccountThatIsNoLongerSignedInIsTerminalNotRetryable()
        aSuccessfulFetchProjectsASnapshotAndReturnsTheRawBody()
    }
}
