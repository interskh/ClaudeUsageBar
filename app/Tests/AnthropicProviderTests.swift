import Foundation

// §10: each case names the regression it prevents.
//
// Everything here runs against sanitised recorded fixtures, an in-memory filesystem, an
// in-memory credential store and a fake HTTP client. No network is reachable from this
// target at all — the concrete client is excluded from the test compile by name and
// `build.sh` greps these sources for networking symbols — so a test that appeared to
// pass by talking to the real endpoint cannot exist.
enum AnthropicProviderTests {

    // MARK: - Fakes

    private struct FakeFileSystem: ProfileFileSystem {
        let homeDirectoryPath: String
        var directories: Set<String> = []
        var files: [String: Data] = [:]

        func environmentVariable(_ name: String) -> String? { nil }
        func isDirectory(atPath path: String) -> Bool { directories.contains(path) }
        func directoryEntries(atPath path: String) -> [String] {
            directories.compactMap { directory in
                guard directory.hasPrefix(path + "/") else { return nil }
                let remainder = directory.dropFirst(path.count + 1)
                return remainder.contains("/") ? nil : String(remainder)
            }
        }
        func fileContents(atPath path: String) -> Data? { files[path] }
    }

    // ROTATES THE STORED TOKEN on every lookup, because that is the only way to prove the
    // "re-read on every fetch" invariant (§3). Counting lookups CANNOT prove it: `fetch`
    // calls `resolveProfiles`, which already performs one lookup per profile to resolve
    // state, so the counter advances identically whether or not the token itself was
    // re-read. Verified — a real cross-fetch token cache added to the provider left a
    // counting test green. Rotating the value makes the assertion the token that was
    // actually SENT, which a cache cannot fake.
    private final class FakeCredentialSource: ClaudeCredentialSource {
        var blobs: [String: Data] = [:]
        var faults: [String: String] = [:]
        var absent: Set<String> = []
        // When set, each lookup of this service yields a credential with a fresh token.
        var rotatingService: String?
        private(set) var lookups = 0
        private(set) var issuedTokens: [String] = []

        func lookupCredential(service: String) -> CredentialLookup {
            lookups += 1
            if absent.contains(service) { return .absent }
            if let fault = faults[service] { return .failed(fault) }
            if service == rotatingService, let template = blobs[service] {
                let token = "fixture-rotated-\(issuedTokens.count + 1)"
                issuedTokens.append(token)
                return .found(FakeCredentialSource.blob(template, accessToken: token))
            }
            if let blob = blobs[service] { return .found(blob) }
            return .absent
        }

        // Rewrites only `claudeAiOauth.accessToken`, so the rest of the credential stays
        // exactly as recorded.
        private static func blob(_ template: Data, accessToken: String) -> Data {
            guard var root = (try? JSONSerialization.jsonObject(with: template)) as? [String: Any],
                  var oauth = root["claudeAiOauth"] as? [String: Any]
            else { return template }
            oauth["accessToken"] = accessToken
            root["claudeAiOauth"] = oauth
            return (try? JSONSerialization.data(withJSONObject: root)) ?? template
        }
    }

    private final class FakeHTTP: HTTPRequesting, @unchecked Sendable {
        var outcome: HTTPOutcome = .failure(message: "not configured")
        private(set) var requests: [HTTPRequest] = []

        func get(_ request: HTTPRequest) async -> HTTPOutcome {
            requests.append(request)
            return outcome
        }
    }

    private struct FakeVersionProbe: AgentVersionProbing {
        let output: String?
        func probeVersionOutput() -> String? { output }
    }

    // MARK: - Fixture world

    private static let home = "/fake/home"
    private static let now = Date(timeIntervalSince1970: 1_784_800_000)
    private static let accountUUID = "00000000-0000-4000-8000-00000000a001"

    private static func fixture(_ name: String) -> Data {
        let url = TestHarness.fixturesDirectory
            .appendingPathComponent("anthropic")
            .appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            fatalError("missing fixture: \(url.path)")
        }
        return data
    }

    private static func parse(_ name: String) -> AnthropicUsageParser.Parsed {
        guard case .parsed(let parsed) = AnthropicUsageParser.parse(fixture(name)) else {
            fatalError("fixture \(name) failed to parse")
        }
        return parsed
    }

    private static func window(_ parsed: AnthropicUsageParser.Parsed,
                               _ scope: WindowScope,
                               _ span: WindowSpan) -> UsageWindow? {
        parsed.windows.first { $0.id == WindowID(span: span, scope: scope) }
    }

    // MARK: - The flat-key regression

    // THE reason this provider was rewritten. The vendor kept the flat per-model keys and
    // now returns `null` in them while the matching `limits[]` entry is live and non-zero.
    // A parser bound to the flat keys therefore returns 200 OK, parses cleanly, and
    // reports a model-scoped limit as absent — silently, and in the direction that
    // invents headroom. The fixture is the real payload's shape: the flat key is null and
    // the array entry reports 37%.
    private static func scopedUsageComesFromTheArrayNotTheFlatKey() {
        let parsed = parse("usage-live.json")
        let scoped = window(parsed, .model(id: "Aurora"), .weekly)
        TestHarness.expect("live scoped limit is read from limits[] while its flat key is null",
                           scoped?.utilization, .known(37))
        TestHarness.expect("the whole array is projected, not just the two known kinds",
                           parsed.windows.count, 3)
        TestHarness.expect("account-wide weekly comes from the array too",
                           window(parsed, .account, .weekly)?.utilization, .known(61))
        TestHarness.expect("session comes from the array too",
                           window(parsed, .account, .session)?.utilization, .known(12))
        TestHarness.expect("the provider's own binding flag is carried through",
                           window(parsed, .account, .weekly)?.isActive, true)
    }

    // §5.1 forbids a client-side label map, and acceptance criterion 6 is verified by
    // grepping the source for model display names. This pins the behaviour that makes
    // that grep meaningful: the label and the scope discriminator both come from the
    // payload, so a model this build has never heard of appears with a usable name.
    private static func modelScopedWindowUsesPayloadSuppliedLabels() {
        let parsed = parse("usage-live.json")
        let scoped = window(parsed, .model(id: "Aurora"), .weekly)
        TestHarness.expect("scoped label is the payload's display name", scoped?.label, "Aurora")
        TestHarness.expect("account-wide labels are derived from the payload's own grouping",
                           window(parsed, .account, .weekly)?.label, "Weekly")
        TestHarness.expect("session label likewise",
                           window(parsed, .account, .session)?.label, "Session")
        // An empty string is not a label. Passing it through renders a bar with a blank
        // name, which reads as a rendering bug rather than as the vendor sending nothing.
        TestHarness.expect("an empty group falls back to the entry's own class",
                           parse("usage-empty-group.json").windows.first?.label, "Weekly all")
    }

    // §3 requires scope identity from a stable discriminator, never display text. §5.1
    // records the shortfall: the identifier has been observed null while the display name
    // was populated, so the display name is the fallback and ONLY the fallback. Keying on
    // display text whenever it is present would split a window's history on a rename that
    // the identifier would have absorbed.
    private static func scopeIdentityPrefersTheIdentifierOverTheDisplayName() {
        let parsed = parse("usage-scoped-identified.json")
        TestHarness.check(
            "an identified scope keys on the identifier, not the display name",
            window(parsed, .model(id: "mdl_a1b2c3"), .weekly) != nil
        )
        TestHarness.expect("the display name still supplies the label",
                           window(parsed, .model(id: "mdl_a1b2c3"), .weekly)?.label, "Meridian")
        TestHarness.check(
            "display text is never used as identity when an identifier exists",
            window(parsed, .model(id: "Meridian"), .weekly) == nil
        )
        // A scope that identifies nothing is KEPT, with a degraded but distinct identity.
        // It is not folded onto `.account` (which would merge a scoped quota into the
        // account-wide window of the same span) and above all it is not discarded: see
        // `anUnidentifiableScopeKeepsItsUsage`.
        TestHarness.expect("an unidentifiable scope still produces a window",
                           parsed.windows.count, 2)
        TestHarness.check("and the degradation is surfaced rather than silent",
                          parsed.warnings.contains(AnthropicUsageParser.Warning.unidentifiedScope))
    }

    // THE SAME UNDER-REPORT AS THE FLAT KEYS, ONE LAYER LOWER. Ingesting every array entry
    // and then DISCARDING one because its scope names nothing is indistinguishable, from
    // the user's side, from never having read it: measured at an 85-point under-report,
    // with the discarded 95% reading surviving only inside a warning string. §5.1 mandates
    // a discriminator fallback chain; it nowhere sanctions deleting the window.
    private static func anUnidentifiableScopeKeepsItsUsage() {
        let parsed = parse("usage-scope-unusable.json")
        TestHarness.expect("both readings survive", parsed.windows.count, 2)
        TestHarness.expect("the binding figure is the high one, not the one that parsed",
                           Snapshot.bindingUtilization(of: parsed.windows), .known(95))
        // Its identity is its own class, so it neither merges into the account-wide window
        // nor collides with it.
        TestHarness.expect("an unidentifiable scope keys on its own class",
                           window(parsed, .feature(id: "kind:weekly_scoped"), .weekly)?.utilization,
                           .known(95))
        TestHarness.expect("and the account-wide window is untouched",
                           window(parsed, .account, .weekly)?.utilization, .known(10))

        // A `scope` that is present but NOT AN OBJECT used to be read as "no scope at all"
        // and projected account-wide, silently merging a scoped quota into the account's.
        let nonObject = parse("usage-scope-not-an-object.json")
        TestHarness.expect("a non-object scope does not become the account-wide window",
                           window(nonObject, .account, .weekly)?.utilization, .known(10))
        TestHarness.expect("it keeps its own identity and its figure",
                           window(nonObject, .feature(id: "kind:weekly_scoped"), .weekly)?
                               .utilization,
                           .known(95))
        TestHarness.check("and it is surfaced",
                          nonObject.warnings.contains(AnthropicUsageParser.Warning.unidentifiedScope))
    }

    // §8 keys threshold state on the whole `WindowID`, and every downstream
    // `[WindowID: …]` keeps exactly one entry per key. Two account-wide classes sharing a
    // span therefore silently lose one window and cross-arm the other's [25, 50, 75, 90]
    // ladder. Measured: `weekly_all` at 61% and a sibling weekly class at 95% produced two
    // windows with byte-identical IDs and no warning.
    private static func twoClassesSharingASpanKeepDistinctIdentities() {
        let parsed = parse("usage-two-weekly-classes.json")
        TestHarness.expect("both classes are projected", parsed.windows.count, 2)
        TestHarness.expect("their identities are distinct",
                           Set(parsed.windows.map(\.id)).count, 2)
        TestHarness.expect("the genuinely account-wide class keeps the account scope",
                           window(parsed, .account, .weekly)?.utilization, .known(61))
        TestHarness.expect("the narrower class keys on itself",
                           window(parsed, .feature(id: "kind:weekly_other_all"), .weekly)?
                               .utilization,
                           .known(95))
        TestHarness.check("and nothing had to be reported as a collision",
                          !parsed.warnings.contains(AnthropicUsageParser.Warning.collidingIdentities))
    }

    // §5.1/§5.2: ingestion is exhaustive over quota-bearing groups, not a fixed list of
    // the ones that existed when this was written. A filter on known kinds omits a live
    // limit silently — the same blindness the flat keys caused.
    private static func quotaClassesOutsideTheKnownOnesAreStillIngested() {
        let parsed = parse("usage-novel-groups.json")
        TestHarness.expect("every entry is ingested regardless of kind", parsed.windows.count, 4)
        TestHarness.expect("an unseen quota class still reports its usage",
                           parsed.windows.first { $0.label == "Monthly" }?.utilization, .known(44))
        TestHarness.expect("a non-model scope dimension becomes a feature scope",
                           window(parsed, .feature(id: "surface:batch-jobs"),
                                  WindowSpan(seconds: AnthropicUsageParser.dailyWindowSeconds))?
                               .label,
                           "Batch jobs")
        // Two classes whose duration the payload never states must not collapse onto one
        // WindowID — §8 keys threshold state on it, so one would suppress the other's
        // alerts. Neither is given an invented duration; each keys on the class itself.
        let unstated = WindowSpan(seconds: AnthropicUsageParser.unstatedWindowSeconds)
        TestHarness.check(
            "a class with no stated duration keeps its own identity",
            window(parsed, .feature(id: "kind:monthly_all"), unstated) != nil
                && window(parsed, .feature(id: "kind:quarterly_burst"), unstated) != nil
        )
        TestHarness.expect("and it is labelled from the payload's own words, with no map",
                           window(parsed, .feature(id: "kind:quarterly_burst"), unstated)?.label,
                           "Quarterly burst")
    }

    // §8's warning made concrete: a `WindowID` that moves because the PAYLOAD grew a field
    // reclaims that window's threshold state and re-fires the entire [25, 50, 75, 90]
    // ladder. Ranking unknown scope dimensions alphabetically does exactly that — measured,
    // adding an `agent` dimension moved a window keyed on `surface` onto `agent`.
    private static func scopeIdentitySurvivesTheVendorAddingADimension() {
        let before = parse("usage-scope-one-dimension.json")
        let after = parse("usage-scope-added-dimension.json")
        TestHarness.expect("a known dimension is used when it is the only one",
                           before.windows.first?.id.scope, .feature(id: "surface:s1"))
        TestHarness.expect("and it still is once an unknown dimension appears beside it",
                           after.windows.first?.id.scope, before.windows.first?.id.scope)
        // Two dimensions naming the same value are two different quotas, so the dimension
        // key is part of the identity.
        let aliasing = parse("usage-scope-aliasing.json")
        TestHarness.expect("identical values under different dimensions do not alias",
                           Set(aliasing.windows.map(\.id.scope)).count, 2)
    }

    // §5.2's rule, which applies to any self-describing bucket list: classify by DURATION,
    // never by position. On the sibling provider the first slot was observed holding the
    // weekly window, so "first is the session" is measurably wrong.
    private static func windowsAreClassifiedByDurationNotArrayPosition() {
        let parsed = parse("usage-weekly-first.json")
        TestHarness.expect("the weekly window is weekly even when it comes first",
                           window(parsed, .account, .weekly)?.utilization, .known(61))
        TestHarness.expect("the session window is session even when it comes second",
                           window(parsed, .account, .session)?.utilization, .known(12))
    }

    // §3: absent, unknown and zero are three different facts. A bar reading zero because
    // the provider declined to say, rendered identically to one reading zero because
    // nothing was used, is the only failure here that actively misleads.
    private static func nullUtilizationIsUnknownAndNeverZero() {
        let parsed = parse("usage-unknown-utilization.json")
        TestHarness.expect("an explicit null percent is unknown, not 0",
                           window(parsed, .account, .session)?.utilization, .unknown)
        TestHarness.expect("an absent percent is unknown, not 0",
                           window(parsed, .account, .weekly)?.utilization, .unknown)
        // And it must not be swept into an aggregate as though it were a low reading.
        TestHarness.expect("unknown windows contribute nothing to the worst-of",
                           Snapshot.bindingUtilization(of: parsed.windows), .known(43))
        TestHarness.expect("an unknown window is still present rather than dropped",
                           parsed.windows.count, 3)
    }

    // §5.1: render a scoped bar on presence of a RESET TIME, not on a non-zero figure. An
    // unused model reports zero and a freshly-reset but genuinely active window also
    // reports zero; only the reset time separates them. Gating on utilization hides a
    // window that is actually live.
    private static func zeroWithAResetTimeIsRealAndZeroWithoutOneIsNot() {
        let parsed = parse("usage-zero-windows.json")
        TestHarness.expect("a freshly-reset window at 0% is a real window",
                           window(parsed, .model(id: "Aurora"), .weekly)?.utilization, .known(0))
        TestHarness.check("a window that has never started is not rendered",
                          window(parsed, .model(id: "Meridian"), .weekly) == nil)
    }

    // §3: money is minor units plus an exponent, never a Double. And a figure that
    // arrives without a currency stays unqualified — inferring "USD" presents a guess as
    // a fact.
    private static func moneyIsMinorUnitsAndNeverFabricatesACurrency() {
        let qualified = parse("usage-live.json").spend
        TestHarness.expect("used is qualified from minor units + currency + exponent",
                           qualified?.used, .qualified(minor: 1234, currency: "USD", exponent: 2))
        TestHarness.expect("an absent limit stays absent rather than becoming zero",
                           qualified?.limit, nil)

        // THE SCALE IS NOT THE CURRENCY. Withholding the currency is honest; withholding
        // the SCALE while emitting the raw minor-unit integer over-reports by 10^exponent
        // — `{amount_minor: 1500, exponent: 2}` is 15.00, and rendering it as "1500" is a
        // 100x error stated as fact. An earlier revision of this suite asserted "1500" was
        // correct, which is why the bug survived its own test.
        let bare = parse("usage-spend-unqualified.json").spend
        TestHarness.expect("a stated scale is kept even when the currency is not",
                           bare?.used, .unqualified(raw: "15.00"))
        TestHarness.expect("an amount with neither currency nor scale is the bare figure",
                           bare?.balance, .unqualified(raw: "1500"))
        TestHarness.expect("scaling is exact string arithmetic, never floating point",
                           AnthropicUsageParser.decimalString(minor: 5, exponent: 4), "0.0005")
        TestHarness.expect("and it handles a credit",
                           AnthropicUsageParser.decimalString(minor: -1500, exponent: 2), "-15.00")
    }

    // A figure that cannot be represented is reported as no figure. `NSNumber.intValue`
    // WRAPS on overflow and TRUNCATES a fraction, so the naive conversion turns an
    // unreadable amount into a confident wrong one — measured, `99999999999999999999`
    // became `7766279631452241919` and was presented as qualified money with no warning.
    private static func unrepresentableMoneyIsWithheldNotFabricated() {
        let parsed = parse("usage-money-out-of-range.json")
        TestHarness.expect("an amount beyond Int is not wrapped into a plausible one",
                           parsed.spend?.used, nil)
        TestHarness.expect("a fractional minor-unit figure is not truncated",
                           parsed.spend?.limit, nil)
        // A scale of 1000 decimal places is not a scale; the figure is still shown, but
        // without a fabricated qualification.
        TestHarness.expect("an out-of-range exponent does not qualify the amount",
                           parsed.spend?.balance, .unqualified(raw: "100"))
        TestHarness.check("and every withheld figure is surfaced",
                          parsed.warnings.contains(AnthropicUsageParser.Warning.unreadableSpend))

        // A blank currency is not a currency: qualifying against it would render an
        // amount as though the provider had named one.
        TestHarness.expect("whitespace is not a currency code",
                           AnthropicUsageParser.amount(
                               ["amount_minor": 100, "currency": "   ", "exponent": 2]),
                           .unqualified(raw: "1.00"))
    }

    // The balance field has been observed as a String on one provider and a Number on the
    // other, for the same concept. A parser that binds only one shape fails on the real
    // payload, and it fails by reporting no credits rather than by throwing.
    private static func balanceParsesAsBothStringAndNumber() {
        TestHarness.expect("balance as a JSON string parses",
                           parse("usage-balance-string.json").spend?.balance,
                           .unqualified(raw: "0"))
        TestHarness.expect("balance as a JSON number parses",
                           parse("usage-balance-number.json").spend?.balance,
                           .unqualified(raw: "0"))
        TestHarness.expect("a fully qualified limit alongside it is unaffected",
                           parse("usage-balance-string.json").spend?.limit,
                           .qualified(minor: 2000, currency: "USD", exponent: 2))
    }

    // §5: decode permissively and per-key. Both vendors add and retire top-level fields
    // without notice, so one unreadable companion entry must never discard the payload —
    // but the drop has to be surfaced, or the under-report is silent again.
    private static func oneUnreadableEntryDoesNotDiscardThePayload() {
        let parsed = parse("usage-partly-unreadable.json")
        TestHarness.expect("the readable entry survives its unreadable neighbours",
                           window(parsed, .account, .weekly)?.utilization, .known(61))
        // Asserting only that a DIFFERENT entry survived is what let the `kind` deletion
        // live here undetected: this fixture always carried a `kind`-less 50% entry, and
        // nothing asked what became of it. A test that passes while the bug it sits on top
        // of is present is not coverage.
        TestHarness.expect("the entry with no readable kind keeps its figure too",
                           window(parsed, .feature(id: "group:weekly"),
                                  WindowSpan(seconds: AnthropicUsageParser.unstatedWindowSeconds))?
                               .utilization,
                           .known(50))
        TestHarness.expect("so nothing is lost from the aggregate",
                           Snapshot.bindingUtilization(of: parsed.windows), .known(61))
        TestHarness.check("the element that carried no fields at all is reported as dropped",
                          parsed.warnings.contains(AnthropicUsageParser.Warning.unreadableEntry))
        TestHarness.check("and the kept-but-unidentified one is reported as kept",
                          parsed.warnings.contains(AnthropicUsageParser.Warning.unidentifiedLimit))
    }

    // THE SAME UNDER-REPORT AS THE SCOPE PATH, THROUGH THE ADJACENT FIELD. An entry whose
    // `kind` cannot be read is exactly as real as one whose `scope` cannot be read. The
    // first revision of this provider degraded the second and DELETED the first, a few
    // lines apart — measured at a binding utilization of 10% while a 95% limit sat in the
    // payload unread. All three unreadable shapes are pinned, because `guard let x = y as?
    // String` collapses them and a later refactor may not.
    private static func anUnreadableKindKeepsItsUsage() {
        for fixture in ["usage-kind-absent.json",
                        "usage-kind-empty.json",
                        "usage-kind-not-a-string.json"] {
            let parsed = parse(fixture)
            TestHarness.expect("\(fixture): both readings survive", parsed.windows.count, 2)
            TestHarness.expect("\(fixture): the binding figure is the one that lost its kind",
                               Snapshot.bindingUtilization(of: parsed.windows), .known(95))
            TestHarness.expect("\(fixture): the account-wide window is untouched",
                               window(parsed, .account, .weekly)?.utilization, .known(10))
            TestHarness.check("\(fixture): and the degradation is surfaced as KEPT, not dropped",
                              parsed.warnings.contains(AnthropicUsageParser.Warning.unidentifiedLimit)
                                  && !parsed.warnings
                                      .contains(AnthropicUsageParser.Warning.unreadableEntry))
        }

        // Two entries that both lost their `kind` must not then collide with each other —
        // the degraded identity has to be distinct, not merely present.
        let pair = parse("usage-kind-absent-pair.json")
        TestHarness.expect("two kind-less entries both survive", pair.windows.count, 2)
        TestHarness.expect("with distinct identities", Set(pair.windows.map(\.id)).count, 2)
        TestHarness.check("no collision has to be reported",
                          !pair.warnings.contains(AnthropicUsageParser.Warning.collidingIdentities))
        // Even with nothing at all to key on, position is used rather than dropping one.
        let anonymous = parse("usage-kind-and-group-absent.json")
        TestHarness.expect("entries with neither kind nor group still both appear",
                           anonymous.windows.count, 2)
        TestHarness.expect("and are still distinct", Set(anonymous.windows.map(\.id)).count, 2)
        TestHarness.expect("with a label naming the absence rather than a blank bar",
                           anonymous.windows.first?.label, AnthropicUsageParser.Label.unidentified)

        // The dormant rule is a statement about the WINDOW, not a read failure, so it
        // still applies to an entry that lost its kind.
        let dormant = parse("usage-kind-absent-dormant.json")
        TestHarness.expect("a kind-less entry at 0% with no reset time is still dormant",
                           dormant.windows.count, 0)
        // And it does not then claim to be on screen. A warning that describes a window
        // nobody can see teaches the user to ignore the ones that matter.
        TestHarness.check("a dormant entry raises no kept-but-unidentified warning",
                          !dormant.warnings.contains(AnthropicUsageParser.Warning.unidentifiedLimit))
    }

    // `spend` present but not an object read as "this plan has no spending", which is a
    // different fact. Nothing is degradable here — no field inside it is readable — so it
    // yields nothing, but it must not do so silently.
    private static func anUnreadableSpendSectionIsNotAnAbsentOne() {
        let unreadable = parse("usage-spend-not-an-object.json")
        TestHarness.expect("no spend is produced", unreadable.spend, nil)
        TestHarness.check("but the failure to read it is surfaced",
                          unreadable.warnings.contains(AnthropicUsageParser.Warning.unreadableSpend))
        // A genuinely absent spend section stays silent.
        let absent = parse("usage-weekly-first.json")
        TestHarness.check("a payload with no spend section says nothing about spending",
                          !absent.warnings.contains(AnthropicUsageParser.Warning.unreadableSpend))
    }

    // These three key names are recorded as GUESSES rather than observations, which makes
    // covering them more important, not less: an uncovered speculative branch is one
    // nobody notices is wrong. Duration stated outright must outrank the name, because the
    // name is the weaker signal — that is the whole ordering §5.2 exists to establish.
    private static func anExplicitDurationOutranksTheKindToken() {
        let parsed = parse("usage-explicit-duration.json")
        TestHarness.expect("a stated duration wins over a contradicting kind token",
                           parsed.windows.first { $0.label == "Stated weekly" }?.id.span, .weekly)
        let statedWeekly = ["Stated weekly", "Stated weekly two", "Stated weekly three"]
        TestHarness.expect("each of the three accepted key names is honoured",
                           parsed.windows.filter { statedWeekly.contains($0.label) }
                               .filter { $0.id.span == .weekly }.count,
                           3)
        TestHarness.expect("with no stated duration the kind token still classifies",
                           parsed.windows.first { $0.label == "Session" }?.id.span, .session)
        // A zero or unusable figure is not a duration; it must not displace the name.
        TestHarness.expect("an unusable stated duration falls back to the kind token",
                           parsed.windows.first { $0.label == "Zero duration" }?.id.span, .session)
        // And it is the route by which an entry with no readable kind can still be
        // classified by duration rather than landing on the unstated span.
        TestHarness.expect("a stated duration classifies an entry that has no kind at all",
                           parsed.windows.first { $0.label == "Kindless" }?.id.span, .weekly)
    }

    // The absence of the array itself is not a payload with no limits — it is the schema
    // drift §5's retention exists to catch. Degrading to an empty snapshot would render a
    // reassuring, entirely fictional "no limits" state.
    private static func aMissingLimitsArrayIsMalformedNotEmpty() {
        if case .malformed(let fault) = AnthropicUsageParser.parse(fixture("usage-no-limits-array.json")) {
            TestHarness.check("the fault names the missing array", fault.contains("limits"))
        } else {
            TestHarness.check("a payload with no limits array is malformed", false)
        }
        if case .malformed = AnthropicUsageParser.parse(Data("not json".utf8)) {
            TestHarness.check("a non-JSON body is malformed", true)
        } else {
            TestHarness.check("a non-JSON body is malformed", false)
        }
    }

    // Measured: `ISO8601DateFormatter` parses fractional seconds or plain seconds
    // depending on its options, never both. The observed payload uses fractional; the
    // documented shape does not. A single-formatter implementation silently loses every
    // reset time the day the vendor drops the microseconds — and a window with no reset
    // time is then treated as never-started and hidden.
    private static func resetTimesParseWithAndWithoutFractionalSeconds() {
        TestHarness.check("fractional-second timestamps parse",
                          AnthropicUsageParser.timestamp("2026-07-22T21:00:00.073484+00:00").date != nil)
        TestHarness.check("whole-second timestamps parse",
                          AnthropicUsageParser.timestamp("2026-07-22T21:00:00Z").date != nil)
        TestHarness.expect("both spellings of one instant agree",
                           AnthropicUsageParser.timestamp("2026-07-22T21:00:00.000000+00:00"),
                           AnthropicUsageParser.timestamp("2026-07-22T21:00:00Z"))
        TestHarness.expect("a null reset time is absent, not the epoch",
                           AnthropicUsageParser.timestamp(NSNull()), .absent)
        TestHarness.expect("an absent key is absent", AnthropicUsageParser.timestamp(nil), .absent)
        // A timestamp with no zone designator satisfies neither option set. It is a real
        // shape to get wrong — it looks correct to a reader — and it must land on
        // `unreadable` so the window is kept rather than mistaken for never-started.
        TestHarness.expect("a timestamp with no zone designator is unreadable, not absent",
                           AnthropicUsageParser.timestamp("2026-07-23T07:00:00"), .unreadable)
    }

    // "The provider gave no reset time" and "the provider gave one we could not read" are
    // OPPOSITE facts: the first says the window never started (§3), the second says it
    // started and the format defeated us. Collapsing both into nil made one unrecognised
    // timestamp spelling silently delete a live window — measured with a space instead of
    // `T`, at 0%, gone with no warning. A single vendor formatting change could blank an
    // account's whole card that way.
    private static func anUnreadableResetTimeNeverPassesForNeverStarted() {
        let parsed = parse("usage-unreadable-reset.json")
        TestHarness.expect("a window whose reset time could not be read is still shown",
                           window(parsed, .model(id: "m1"), .weekly)?.utilization, .known(0))
        TestHarness.expect("a reset time of the wrong type does not make it dormant either",
                           window(parsed, .account, .session)?.utilization, .known(0))
        TestHarness.expect("nor does one missing only its zone designator",
                           window(parsed, .feature(id: "kind:daily_scoped"),
                                  WindowSpan(seconds: AnthropicUsageParser.dailyWindowSeconds))?
                               .utilization,
                           .known(0))
        TestHarness.check("and the unreadable timestamp is surfaced",
                          parsed.warnings.contains(AnthropicUsageParser.Warning.unreadableResetTime))
        // The dormant rule itself still holds for a genuinely absent reset time.
        let dormant = parse("usage-zero-windows.json")
        TestHarness.check("a genuinely absent reset time at 0% is still dormant",
                          window(dormant, .model(id: "Meridian"), .weekly) == nil)
        TestHarness.check("and that case raises no unreadable-timestamp warning",
                          !dormant.warnings.contains(AnthropicUsageParser.Warning.unreadableResetTime))
    }

    // `Utilization.percent(Double)` guards `isFinite` and then calls `Int(_: Double)`,
    // which TRAPS outside `Int`'s range — so an absurd figure did not under-report, it
    // killed the process mid-poll (measured: exit 133). A menu-bar app that dies when the
    // vendor emits a bad number is worse than one that misreads it.
    private static func anAbsurdPercentIsClampedRatherThanCrashing() {
        let parsed = parse("usage-percent-extremes.json")
        TestHarness.expect("an enormous percent is clamped, not converted",
                           window(parsed, .account, .session)?.utilization, .known(100))
        TestHarness.expect("a negative percent is clamped to zero",
                           window(parsed, .account, .weekly)?.utilization, .known(0))
        TestHarness.expect("a non-finite percent is no figure at all, not zero",
                           AnthropicUsageParser.utilization(Double.nan), .unknown)
        TestHarness.expect("and neither is infinity",
                           AnthropicUsageParser.utilization(Double.infinity), .unknown)
    }

    // §5.1: the figure arrives as Int OR Double, and the rounding rule straddles the 90%
    // red band and §8's notification threshold — 89.5 must read 90, or a red account
    // renders amber and never alerts.
    private static func doublePercentsRoundHalfAwayFromZero() {
        let parsed = parse("usage-double-percent.json")
        TestHarness.expect("89.5 rounds up, into the red band",
                           window(parsed, .account, .session)?.utilization, .known(90))
        TestHarness.expect("89.4 rounds down, staying out of it",
                           window(parsed, .account, .weekly)?.utilization, .known(89))
    }

    // JSON booleans bridge to `NSNumber` and `as? NSNumber` accepts them, so a `true`
    // would read as 1% used — a fabricated figure that looks entirely plausible. Deleting
    // the `CFBooleanGetTypeID` guard left the whole suite green before this case existed.
    private static func aBooleanIsNotAFigure() {
        let parsed = parse("usage-boolean-figures.json")
        TestHarness.expect("a boolean percent is unknown, not 1%",
                           window(parsed, .account, .session)?.utilization, .unknown)
        TestHarness.expect("a boolean minor-unit amount is no amount",
                           parsed.spend?.used, nil)
    }

    // §7 drops an account with no windows out of the popover and the menu-bar worst-of, so
    // a token whose scope was reduced looks exactly like a healthy account with nothing to
    // report. Say which one it is rather than vanishing.
    private static func anEmptyLimitsArrayIsExplained() {
        let parsed = parse("usage-balance-string.json")
        TestHarness.expect("no windows", parsed.windows.count, 0)
        TestHarness.check("but the account does not vanish unexplained",
                          parsed.warnings.contains(AnthropicUsageParser.Warning.noLimits))
    }

    // §7 renders warnings to the USER. Developer phrasing ("skipped limit 1: scope carries
    // no discriminator") is not an explanation, and one line per bad entry turns a payload
    // with twenty of them into twenty identical lines in a popover.
    private static func warningsAreUserFacingAndDeduplicated() {
        let parsed = parse("usage-many-bad-entries.json")
        TestHarness.expect("twenty malformed entries produce one line", parsed.warnings.count, 1)
        TestHarness.expect("and it is the user-facing phrasing",
                           parsed.warnings.first, AnthropicUsageParser.Warning.unreadableEntry)
        TestHarness.check("no warning quotes the payload or names an array index",
                          parsed.warnings.allSatisfy { !$0.contains("limit 1") && !$0.contains("kind") })
    }

    // MARK: - Transport contract

    // §6 honours `Retry-After`, and the header carries EITHER seconds OR an HTTP-date. A
    // parser that handles only the numeric form treats a dated one as "no advice" and
    // retries immediately, which earns a longer ban. The 60s floor is deliberately NOT
    // applied here — it is the store's, and a floor applied twice is a floor that
    // disagrees with itself.
    private static func retryAfterNormalisesSecondsAndHTTPDates() {
        TestHarness.expect("delta-seconds", RetryAfter.seconds(from: "120", now: now), 120)
        let inTwoMinutes = now.addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        TestHarness.expect("an HTTP-date becomes the same wait",
                           RetryAfter.seconds(from: formatter.string(from: inTwoMinutes), now: now),
                           120)
        TestHarness.expect("a date already past means retry now, not a negative wait",
                           RetryAfter.seconds(from: formatter.string(from: now.addingTimeInterval(-60)),
                                              now: now),
                           0)
        TestHarness.expect("no header is no advice", RetryAfter.seconds(from: nil, now: now), nil)
        TestHarness.expect("an unparseable header is no advice",
                           RetryAfter.seconds(from: "soon", now: now), nil)
        TestHarness.expect("header names are matched case-insensitively",
                           HTTPHeaders.value("Retry-After", in: ["retry-after": "30"]), "30")
    }

    // §5.1: the advertised agent version is resolved from the installed CLI, because a
    // pinned constant was already ~150 releases stale on the day it was written. The
    // value is interpolated into a request header, so anything that is not a plain
    // version token falls back to the floor rather than reaching the wire.
    private static func agentVersionIsResolvedNotPinned() {
        TestHarness.expect("the installed CLI's own output supplies the version",
                           AgentVersion.parse("2.1.217 (Claude Code)\n"), "2.1.217")
        TestHarness.expect("a leading v is tolerated", AgentVersion.parse("v3.0.1"), "3.0.1")
        TestHarness.expect("a header-breaking value is rejected",
                           AgentVersion.parse("2.1.0\r\nX-Injected: 1"), "2.1.0")
        TestHarness.expect("non-version output is rejected outright",
                           AgentVersion.parse("command not found"), nil)
        // An uppercase pre-release is a real published version; rejecting it would quietly
        // advertise the floor while a newer CLI is installed.
        TestHarness.expect("a pre-release tag is kept whatever its case",
                           AgentVersion.parse("2.1.0-RC1 (Claude Code)"), "2.1.0-RC1")

        let resolved = awaitResult {
            await AgentVersionCache(probe: FakeVersionProbe(output: "9.9.9 (Claude Code)"))
                .current(now: now)
        }
        TestHarness.expect("a successful probe wins over the floor", resolved, "9.9.9")

        let fallback = awaitResult {
            await AgentVersionCache(probe: FakeVersionProbe(output: nil)).current(now: now)
        }
        TestHarness.expect("no installation found falls back to the floor and never fails",
                           fallback, AgentVersion.floor)

        // Re-resolved at most daily (§5.1): the probe launches a subprocess, so a cache
        // that expired per poll would spend it on every account, every five minutes.
        let cache = AgentVersionCache(probe: CountingProbe())
        _ = awaitResult { await cache.current(now: now) }
        _ = awaitResult { await cache.current(now: now.addingTimeInterval(3600)) }
        let third = awaitResult { await cache.current(now: now.addingTimeInterval(90_000)) }
        TestHarness.expect("the probe re-runs only once the day has elapsed", third, "2.0.0")
    }

    private final class CountingProbe: AgentVersionProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func probeVersionOutput() -> String? {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return "\(count).0.0"
        }
    }

    // MARK: - Provider

    private static func world() -> (FakeFileSystem, FakeCredentialSource) {
        var fs = FakeFileSystem(homeDirectoryPath: home)
        fs.directories = [home, home + "/.claude"]
        fs.files = [
            home + "/.claude.json": fixture("identity-default.json"),
        ]
        let credentials = FakeCredentialSource()
        credentials.blobs[ClaudeProfileDiscovery.defaultServiceName] = fixture("credential-live.json")
        return (fs, credentials)
    }

    private static func provider(_ fs: FakeFileSystem,
                                 _ credentials: FakeCredentialSource,
                                 _ http: FakeHTTP,
                                 version: String? = "9.9.9 (Claude Code)") -> AnthropicProvider {
        AnthropicProvider(
            discovery: ClaudeProfileDiscovery(fileSystem: fs, credentials: credentials, log: { _ in }),
            http: http,
            agentVersion: AgentVersionCache(probe: FakeVersionProbe(output: version)),
            clock: { now }
        )
    }

    private static func ref() -> AccountRef {
        AccountRef(id: AccountIdentity(provider: .anthropic, accountUUID), label: "default")
    }

    // §5.1: the beta header and a plausible agent User-Agent are load-bearing — without
    // them the endpoint rejects the request — and the version in that User-Agent comes
    // from the installed CLI rather than a constant.
    private static func requestCarriesTheRequiredAuthAndAgentHeaders() {
        let (fs, credentials) = world()
        let http = FakeHTTP()
        http.outcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        _ = awaitResult { await provider(fs, credentials, http).fetch(ref()) }

        let headers = http.requests.first?.headers ?? [:]
        // Read back out of the fixture rather than written out here: no token material,
        // real or otherwise, is spelled into this source.
        guard case .usable(let credential) =
            ClaudeCredential.decode(fixture("credential-live.json"))
        else {
            TestHarness.check("the credential fixture is usable", false)
            return
        }
        TestHarness.expect("the OAuth access token is sent as a bearer token",
                           headers["Authorization"], "Bearer " + credential.accessToken)
        TestHarness.expect("the beta header is sent", headers["anthropic-beta"], "oauth-2025-04-20")
        TestHarness.expect("the User-Agent advertises the resolved CLI version",
                           headers["User-Agent"], "claude-code/9.9.9")
        TestHarness.expect("the endpoint is the OAuth usage endpoint",
                           http.requests.first?.url.absoluteString,
                           "https://api.anthropic.com/api/oauth/usage")
    }

    // §3: the access token rotates roughly 8-hourly, so a copy captured at discovery is
    // guaranteed to go stale while the stored credential stays healthy. Caching one would
    // permanently park a live account as expired, and every parsing test would still pass.
    private static func credentialIsReReadOnEveryFetch() {
        let (fs, credentials) = world()
        credentials.rotatingService = ClaudeProfileDiscovery.defaultServiceName
        let http = FakeHTTP()
        http.outcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))
        let subject = provider(fs, credentials, http)
        _ = awaitResult { await subject.fetch(ref()) }
        _ = awaitResult { await subject.fetch(ref()) }

        let sent = http.requests.compactMap { $0.headers["Authorization"] }
        TestHarness.expect("both fetches issued a request", sent.count, 2)
        // The assertion is on the token that went out, not on how many times the store was
        // asked: a provider holding a cached token would still trigger the store lookups
        // discovery performs, but it could not send the newer value.
        TestHarness.check(
            "the second fetch sends the rotated token, not the one from the first fetch",
            sent.count == 2 && sent[0] != sent[1]
        )
        let issued = credentials.issuedTokens.map { "Bearer " + $0 }
        TestHarness.check(
            "every token sent is one the store issued, in the order the store issued them",
            sent.allSatisfy(issued.contains)
                && sent.count == 2
                && (issued.firstIndex(of: sent[0]) ?? 0) < (issued.firstIndex(of: sent[1]) ?? 0)
        )
    }

    // The whole projection, end to end: a recorded payload becomes a snapshot whose plan
    // comes from the credential (the payload publishes none) and whose raw body is
    // returned for §5's retention, since §6 forbids the provider writing it itself.
    private static func successfulFetchProjectsASnapshotAndReturnsTheRawBody() {
        let (fs, credentials) = world()
        let http = FakeHTTP()
        let body = fixture("usage-live.json")
        http.outcome = .response(status: 200, headers: [:], body: body)

        guard case .success(let fetched) =
            awaitResult({ await provider(fs, credentials, http).fetch(ref()) })
        else {
            TestHarness.check("a 200 with a valid payload succeeds", false)
            return
        }
        TestHarness.expect("windows are projected", fetched.snapshot.windows.count, 3)
        TestHarness.expect("the plan label comes from the credential, not the payload",
                           fetched.snapshot.planLabel, "max")
        TestHarness.expect("the raw body is returned for §5's retention", fetched.rawBody, body)
        TestHarness.expect("the snapshot is stamped with the fetch time",
                           fetched.snapshot.fetchedAt, now)
    }

    // §6: the provider does not decide expiry-vs-revoked, because it does not hold the
    // re-read expiry at the moment of rejection. It reports the rejection; the store
    // re-reads once and retries before parking an account.
    private static func statusCodesMapOntoTheErrorContract() {
        let (fs, credentials) = world()
        let http = FakeHTTP()

        http.outcome = .response(status: 401, headers: [:], body: Data())
        TestHarness.expect("401 is an authentication rejection, not an expiry verdict",
                           failure(fs, credentials, http), .authenticationRejected)

        http.outcome = .response(status: 429, headers: ["Retry-After": "90"], body: Data())
        TestHarness.expect("429 carries the normalised Retry-After",
                           failure(fs, credentials, http), .rateLimited(retryAfter: 90))

        http.outcome = .response(status: 503, headers: [:], body: Data())
        TestHarness.expect("an unexpected status names the code and nothing else",
                           failure(fs, credentials, http), .unexpectedStatus(code: 503))

        http.outcome = .failure(message: "the network connection was lost")
        TestHarness.expect("no response at all is a transport failure",
                           failure(fs, credentials, http),
                           .transport(message: "the network connection was lost"))
    }

    // §5: `malformedResponse` carries the body for the same reason the success path does.
    // This IS the silent schema drift the retention exists to diagnose, so discarding the
    // payload here throws the evidence away in the one case that most needs it.
    private static func malformedResponseCarriesTheBodyForDiagnosis() {
        let (fs, credentials) = world()
        let http = FakeHTTP()
        let body = fixture("usage-no-limits-array.json")
        http.outcome = .response(status: 200, headers: [:], body: body)

        guard case .failure(.malformedResponse(_, let rawBody)) = result(fs, credentials, http) else {
            TestHarness.check("a payload with no limits array fails as malformed", false)
            return
        }
        TestHarness.expect("the body travels with the failure", rawBody, body)
    }

    // §5.2 and the protocol's own note: an identity disagreement is the OBSERVED NORMAL
    // STATE on the target machine for the sibling provider. Modelling it as a FetchError
    // would render a live account as a hard failure, so it is a warning — and the warning
    // never quotes the identifiers, which are account identifiers.
    private static func identityDisagreementWarnsRatherThanFails() {
        let (fs, credentials) = world()
        let http = FakeHTTP()
        http.outcome = .response(status: 200, headers: [:],
                                 body: fixture("usage-identity-mismatch.json"))

        guard case .success(let fetched) = result(fs, credentials, http) else {
            TestHarness.check("an identity disagreement still yields a snapshot", false)
            return
        }
        TestHarness.expect("the disagreement is surfaced as a warning",
                           fetched.snapshot.warnings.count, 1)
        TestHarness.check("the warning names the condition, never the identifiers",
                          fetched.snapshot.warnings.allSatisfy { !$0.contains(accountUUID) })
        TestHarness.expect("and the usage is still reported", fetched.snapshot.windows.count, 1)
    }

    // §4.1 keeps "the credential is gone" and "the app could not find out" distinct all
    // the way through. A locked keychain reported as an authentication rejection would
    // start the store down the expiry path for an account that is perfectly healthy.
    private static func unusableCredentialsAreDistinguishedFromReadFaults() {
        let (fs, credentials) = world()
        let http = FakeHTTP()
        http.outcome = .response(status: 200, headers: [:], body: fixture("usage-live.json"))

        credentials.absent = [ClaudeProfileDiscovery.defaultServiceName]
        TestHarness.expect("a vanished credential is an authentication rejection",
                           failure(fs, credentials, http), .authenticationRejected)

        credentials.absent = []
        credentials.faults[ClaudeProfileDiscovery.defaultServiceName] = "the keychain is locked"
        TestHarness.expect("a store that could not be read is not dressed up as a rejection",
                           failure(fs, credentials, http),
                           .transport(message: "the keychain is locked"))
        TestHarness.check("no request is made without a credential", http.requests.isEmpty)
    }

    // §6 backs off and RETRIES a transport failure. An account that has genuinely left
    // discovery — its directory removed while a poll was in flight — would therefore be
    // retried forever on a timer nothing ever stops. It needs a terminal answer.
    private static func anAccountThatLeftDiscoveryIsTerminalNotRetryable() {
        var fs = FakeFileSystem(homeDirectoryPath: home)
        fs.directories = [home]
        let credentials = FakeCredentialSource()
        let http = FakeHTTP()
        TestHarness.expect("a vanished account is not reported as a retryable transport fault",
                           failure(fs, credentials, http), .accountUnknown)
        TestHarness.check("and no request is attempted for it", http.requests.isEmpty)
    }

    // MARK: - Plumbing

    private static func result(_ fs: FakeFileSystem,
                               _ credentials: FakeCredentialSource,
                               _ http: FakeHTTP) -> Result<FetchedSnapshot, FetchError> {
        awaitResult { await provider(fs, credentials, http).fetch(ref()) }
    }

    // `FetchedSnapshot` is not Equatable (it carries a whole snapshot), so error-path
    // assertions compare the error alone.
    private static func failure(_ fs: FakeFileSystem,
                                _ credentials: FakeCredentialSource,
                                _ http: FakeHTTP) -> FetchError? {
        guard case .failure(let error) = result(fs, credentials, http) else { return nil }
        return error
    }

    // The harness is synchronous and `fetch` is async (§3). Bridging here keeps every
    // test a plain function rather than making the whole suite async.
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
        scopedUsageComesFromTheArrayNotTheFlatKey()
        modelScopedWindowUsesPayloadSuppliedLabels()
        scopeIdentityPrefersTheIdentifierOverTheDisplayName()
        anUnidentifiableScopeKeepsItsUsage()
        twoClassesSharingASpanKeepDistinctIdentities()
        quotaClassesOutsideTheKnownOnesAreStillIngested()
        scopeIdentitySurvivesTheVendorAddingADimension()
        windowsAreClassifiedByDurationNotArrayPosition()
        nullUtilizationIsUnknownAndNeverZero()
        zeroWithAResetTimeIsRealAndZeroWithoutOneIsNot()
        moneyIsMinorUnitsAndNeverFabricatesACurrency()
        unrepresentableMoneyIsWithheldNotFabricated()
        balanceParsesAsBothStringAndNumber()
        oneUnreadableEntryDoesNotDiscardThePayload()
        anUnreadableKindKeepsItsUsage()
        anUnreadableSpendSectionIsNotAnAbsentOne()
        anExplicitDurationOutranksTheKindToken()
        aMissingLimitsArrayIsMalformedNotEmpty()
        resetTimesParseWithAndWithoutFractionalSeconds()
        anUnreadableResetTimeNeverPassesForNeverStarted()
        anAbsurdPercentIsClampedRatherThanCrashing()
        doublePercentsRoundHalfAwayFromZero()
        aBooleanIsNotAFigure()
        anEmptyLimitsArrayIsExplained()
        warningsAreUserFacingAndDeduplicated()
        retryAfterNormalisesSecondsAndHTTPDates()
        agentVersionIsResolvedNotPinned()
        requestCarriesTheRequiredAuthAndAgentHeaders()
        credentialIsReReadOnEveryFetch()
        successfulFetchProjectsASnapshotAndReturnsTheRawBody()
        statusCodesMapOntoTheErrorContract()
        malformedResponseCarriesTheBodyForDiagnosis()
        identityDisagreementWarnsRatherThanFails()
        unusableCredentialsAreDistinguishedFromReadFaults()
        anAccountThatLeftDiscoveryIsTerminalNotRetryable()
    }
}
