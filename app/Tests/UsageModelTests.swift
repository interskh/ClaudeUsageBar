import Foundation

// §10: each case names the regression it prevents.
enum UsageModelTests {
    private static func window(_ span: WindowSpan,
                               _ scope: WindowScope,
                               _ utilization: Utilization,
                               isActive: Bool = false,
                               resetsAt: Date? = nil) -> UsageWindow {
        UsageWindow(id: WindowID(span: span, scope: scope),
                    label: "ignored — labels are presentation only",
                    utilization: utilization,
                    resetsAt: resetsAt,
                    isActive: isActive)
    }

    private static func snapshot(_ windows: [UsageWindow]) -> Snapshot {
        Snapshot(account: AccountRef(id: AccountIdentity(provider: .anthropic, "acct-1"),
                                     label: "default"),
                 windows: windows,
                 fetchedAt: Date(timeIntervalSince1970: 0))
    }

    static func run() {
        utilization()
        windowIdentity()
        accountIdentity()
        money()
    }

    private static func utilization() {
        // Regression: coercing unknown to zero, manufacturing headroom the account may
        // not have. Unknown must not compare equal to any known reading, least of all 0.
        TestHarness.check("unknown utilization is not zero", Utilization.unknown != .known(0))

        // Regression: an unknown BINDING window falling through to the next-highest
        // known window, presenting a non-binding figure as though it were the
        // constraint (§7.1). 62% is genuinely not what constrains this account.
        TestHarness.expect(
            "unknown binding window makes the aggregate unknown",
            snapshot([
                window(.weekly, .account, .unknown, isActive: true),
                window(.session, .account, .known(62)),
            ]).bindingUtilization,
            .unknown
        )

        // Regression: "fixing" the above by letting a high known figure win. Unknown
        // beating a known 95 is the deliberate never-under-report trade.
        TestHarness.expect(
            "unknown beats a known 95 among binding windows",
            snapshot([
                window(.weekly, .account, .unknown, isActive: true),
                window(.session, .account, .known(95), isActive: true),
            ]).bindingUtilization,
            .unknown
        )

        // Regression: unknown counting as zero inside the aggregate. With no window
        // flagged binding, the unknown one must contribute nothing — not drag the
        // figure down, and not be selected as the worst.
        TestHarness.expect(
            "unknown is excluded from the fallback aggregate",
            snapshot([
                window(.session, .account, .unknown),
                window(.weekly, .account, .known(40)),
            ]).bindingUtilization,
            .known(40)
        )

        // Regression: reintroducing max-only heuristics. The provider marks the binding
        // limit precisely so the single-number UI needs none.
        TestHarness.expect(
            "worst-of prefers the binding window over a higher inactive one",
            snapshot([
                window(.weekly, .account, .known(31), isActive: true),
                window(.session, .account, .known(88)),
            ]).bindingUtilization,
            .known(31)
        )

        // Regression: showing 0% for an account that reported nothing. Absent, unknown
        // and zero are three distinct facts all the way to the menu bar.
        TestHarness.check("an account with no windows yields no figure",
                          snapshot([]).bindingUtilization == nil)
        TestHarness.expect("windows present but none quantified yields unknown",
                           snapshot([window(.session, .account, .unknown)]).bindingUtilization,
                           .unknown)

        // Regression: an out-of-range percent winning a max() and displacing the real
        // binding figure, or one provider truncating where the other rounds — the
        // choice straddles the 90% red / notification band.
        TestHarness.expect("percent clamps above 100", Utilization.percent(140), .known(100))
        TestHarness.expect("percent clamps below 0", Utilization.percent(-5), .known(0))
        TestHarness.expect("a fractional percent rounds, never truncates",
                           Utilization.percent(89.5), .known(90))
        TestHarness.expect("a non-finite percent is unknown, not 0%",
                           Utilization.percent(Double.nan), .unknown)
    }

    private static func windowIdentity() {
        // Regression: collapsing span and scope into one key, so a model-scoped short
        // window's alert suppresses the model-scoped long window's (§8).
        let shortScoped = WindowID(span: .session, scope: .model(id: "claude-sonnet-4-5"))
        let longScoped = WindowID(span: .weekly, scope: .model(id: "claude-sonnet-4-5"))
        TestHarness.check("same scope, different span => distinct window identity",
                          shortScoped != longScoped)
        var thresholds: [WindowID: Int] = [:]
        thresholds[shortScoped] = 75
        thresholds[longScoped] = 90
        TestHarness.expect("per-window threshold state does not collide",
                           thresholds[shortScoped], 75)

        // Regression: keying scope on display text, which merges two model histories on
        // a label collision and splits one on a rename.
        TestHarness.check("same span, different scope => distinct window identity",
                          WindowID(span: .weekly, scope: .account)
                              != WindowID(span: .weekly, scope: .model(id: "claude-opus-4-5")))

        // Regression: one provider spelling a span `.other(seconds: 18000)` while the
        // other spells the same span `.session`. Two spellings of one span means
        // unifying them later resets every stored threshold and re-fires the whole
        // [25, 50, 75, 90] ladder (§8).
        TestHarness.expect("18000s canonicalises to .session", WindowSpan(seconds: 18_000), .session)
        TestHarness.expect("604800s canonicalises to .weekly", WindowSpan(seconds: 604_800), .weekly)
        TestHarness.check("a genuinely non-standard duration stays .other",
                          WindowSpan(seconds: 3_600) == .other(seconds: 3_600))
        TestHarness.check(
            "a duration-classified window keys identically to a named one",
            WindowID(span: WindowSpan(seconds: 18_000), scope: .feature(id: "codex"))
                == WindowID(span: .session, scope: .feature(id: "codex"))
        )
    }

    private static func accountIdentity() {
        // Regression: misattributing one account's history to another after a sign-in
        // switch. Two credentials that agree on one identifier but differ on the other
        // must not collide — including once flattened into a storage namespace, where a
        // naive join of ("a:b", "c") and ("a", "b:c") would produce one key.
        let composite = AccountIdentity(provider: .codex, components: ["a:b", "c"])
        let rival = AccountIdentity(provider: .codex, components: ["a", "b:c"])
        TestHarness.check("composite identity distinguishes a shared identifier",
                          composite != rival)
        TestHarness.check("composite storage namespaces do not collide",
                          composite.storageKey != rival.storageKey)
        TestHarness.check("the same composite is the same account",
                          composite == AccountIdentity(provider: .codex, components: ["a:b", "c"]))
        // Regression: two providers' identifier spaces overlapping into one key.
        TestHarness.check("identity is scoped by provider",
                          AccountIdentity(provider: .codex, "x")
                              != AccountIdentity(provider: .anthropic, "x"))

        // Regression: the two plausible ways to weaken the escaper, neither of which
        // the ("a:b","c") pair above can see. Escaping the separator but not the escape
        // character ("why are we escaping backslashes?"), and escaping in the wrong
        // order, which doubles the escape character just inserted. Both collapse to the
        // same collision — [":"] and ["\\", ""] both render as `\\:`.
        TestHarness.check(
            "a colon-only or wrong-order escaper is not sufficient",
            AccountIdentity(provider: .codex, components: [":"]).storageKey
                != AccountIdentity(provider: .codex, components: ["\\", ""]).storageKey
        )
        // Regression: empty components vanishing into the separator run.
        TestHarness.check(
            "empty components are still positions",
            AccountIdentity(provider: .codex, components: [""]).storageKey
                != AccountIdentity(provider: .codex, components: ["", ""]).storageKey
        )

        // Fuzz over the adversarial alphabet: the storage namespace must be as
        // discriminating as identity itself, not merely on hand-picked pairs. Any
        // shortcut in the escaper shows up here as two accounts sharing one namespace.
        let alphabet = ["", ":", "\\", "a", ":\\", "\\:", "\\\\", "::"]
        var identities: Set<AccountIdentity> = []
        var keys: Set<String> = []
        for first in alphabet {
            for second in alphabet {
                for components in [[first], [first, second]] {
                    let identity = AccountIdentity(provider: .codex, components: components)
                    identities.insert(identity)
                    keys.insert(identity.storageKey)
                }
            }
        }
        TestHarness.expect("no two distinct identities share a storage namespace",
                           keys.count, identities.count)

        // Regression: relabelling or moving a profile orphaning its history (§6, §8).
        // Synthesized Hashable over label/subtitle would pass an `.id == .id` check but
        // fail this one, which is the shape every later task actually uses.
        let identity = AccountIdentity(provider: .anthropic, "acct-1")
        let beforeRename = AccountRef(id: identity, label: "work-fiona")
        let afterRename = AccountRef(id: identity, label: "fiona", subtitle: "fiona@example.com")
        var history: [AccountRef: Int] = [beforeRename: 75]
        TestHarness.expect("threshold history survives a rename and a discovered email",
                           history[afterRename], 75)
        history[afterRename] = 90
        TestHarness.expect("a renamed account updates its own entry, not a second one",
                           history.count, 1)

        // Regression: a different account signing into the same location inheriting the
        // previous occupant's readings (§6). An identity change IS an account change.
        TestHarness.check(
            "a different identity at the same label is a different account",
            history[AccountRef(id: AccountIdentity(provider: .anthropic, "acct-2"),
                               label: "work-fiona")] == nil
        )

        // Regression: a stored provider drifting out of step with the identity's, which
        // would file an account under one glyph while its state landed in the other
        // provider's namespace.
        TestHarness.expect("a ref reports its identity's provider",
                           AccountRef(id: AccountIdentity(provider: .codex, "x"), label: "pro").provider,
                           .codex)
    }

    private static func money() {
        // Regression: floating-point currency, and fabricating a currency/scale the
        // provider never stated. $0.05 qualified is not the bare string "5".
        TestHarness.check("qualified money is not equal to the same bare figure",
                          MonetaryAmount.qualified(minor: 5, currency: "USD", exponent: 2)
                              != .unqualified(raw: "5"))
        // Regression: dropping the exponent, which turns $0.05 into $5.00.
        TestHarness.check("scale is part of a qualified amount",
                          MonetaryAmount.qualified(minor: 5, currency: "USD", exponent: 2)
                              != .qualified(minor: 5, currency: "USD", exponent: 0))
    }
}
