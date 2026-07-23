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
        providerRecoveryHint()
    }

    // §7.2: the signed-out/expired card's "Sign in via …" hint is derived from the
    // account's own provider, so a lapsed Codex account is directed to the Codex CLI and
    // an Anthropic one to Claude Code. Regression: hardcoding one provider's CLI for every
    // card — the money-line's structural twin of the task 8 hardcoded-title defect.
    private static func providerRecoveryHint() {
        TestHarness.expect("an Anthropic account's recovery CLI is Claude Code",
                           ProviderKind.anthropic.cliName, "Claude Code")
        TestHarness.expect("a Codex account's recovery CLI is Codex, not Claude Code",
                           ProviderKind.codex.cliName, "Codex")
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
        // provider never stated. Asserted on the RENDERED text, not enum equality — enum
        // `!=` survives a scale-loss regression in `display`, the rendered strings do not.
        // $0.05 qualified renders differently from the bare figure "5".
        TestHarness.check("qualified money renders differently from the same bare figure",
                          MonetaryAmount.qualified(minor: 5, currency: "USD", exponent: 2).display
                              != MonetaryAmount.unqualified(raw: "5").display)
        // Regression: dropping the exponent, which turns $0.05 into $5. Rendered, so a
        // `display` that silently ignored the exponent would fail here.
        TestHarness.check("scale changes the rendered amount",
                          MonetaryAmount.qualified(minor: 5, currency: "USD", exponent: 2).display
                              != MonetaryAmount.qualified(minor: 5, currency: "USD", exponent: 0).display)

        moneyDisplay()
        extraLine()
    }

    // §7.2's Extra dollar line renders MonetaryAmount → text. Integer-only formatting so
    // the 100× over-report (task 5) cannot re-enter through a Double.
    private static func moneyDisplay() {
        // Regression: emitting the minor-unit integer bare — 1500 rendered as $1500
        // instead of $15.00, a 100× over-report a shipped test once asserted as correct.
        TestHarness.expect("USD scales minor units by the exponent",
                           MonetaryAmount.qualified(minor: 1500, currency: "USD", exponent: 2).display,
                           "$15.00")
        // Regression: $0.00 vs an empty string — a genuine zero spend must read as $0.00.
        TestHarness.expect("zero spend is $0.00",
                           MonetaryAmount.qualified(minor: 0, currency: "USD", exponent: 2).display,
                           "$0.00")
        // Regression: a sub-unit figure losing its leading zero (5 → $.05).
        TestHarness.expect("sub-unit pads a leading integer zero",
                           MonetaryAmount.qualified(minor: 5, currency: "USD", exponent: 2).display,
                           "$0.05")
        // Regression: exponent 0 fabricating a decimal point.
        TestHarness.expect("exponent 0 has no fractional part",
                           MonetaryAmount.qualified(minor: 15, currency: "USD", exponent: 0).display,
                           "$15")
        // A negative amount (a refund/credit — task 5 keeps these) signs the figure, not
        // the currency symbol drift.
        TestHarness.expect("negative USD signs the amount",
                           MonetaryAmount.qualified(minor: -250, currency: "USD", exponent: 2).display,
                           "-$2.50")
        // A non-USD currency is qualified with its code, never a $ implying dollars.
        TestHarness.expect("non-USD currency uses its code, not $",
                           MonetaryAmount.qualified(minor: 1500, currency: "EUR", exponent: 2).display,
                           "EUR 15.00")
        // Regression: an unqualified balance having a currency/scale INFERRED (§5.2/§3).
        // "15" free credits with no currency is shown exactly as stated — not "$15.00".
        TestHarness.expect("unqualified amount is shown verbatim",
                           MonetaryAmount.unqualified(raw: "15").display,
                           "15")

        // Regression: the formatter TRAPPING on a drifted/hostile provider-or-persisted
        // value instead of degrading. `abs(Int.min)` traps (task 5's `Int(1e30)` class);
        // `exponent + 1` overflows at Int.max; a huge finite exponent forces a pathological
        // `String(repeating:)`. Each must produce a BOUNDED string, never crash.
        TestHarness.expect("Int.min minor does not trap and renders its full magnitude",
                           MonetaryAmount.qualified(minor: Int.min, currency: "USD", exponent: 2).display,
                           "-$92233720368547758.08")
        TestHarness.expect("Int.max exponent does not overflow, degrading to the bare figure",
                           MonetaryAmount.qualified(minor: 1500, currency: "USD", exponent: Int.max).display,
                           "$1500")
        TestHarness.expect("a huge finite exponent degrades to the bare figure, not a giant allocation",
                           MonetaryAmount.qualified(minor: 1500, currency: "USD", exponent: 1_000_000).display,
                           "$1500")
    }

    private static func extraLine() {
        // §7.2: spend used joined with the free balance. The balance is UNQUALIFIED — it
        // carries NO currency (§5.2) — so it must render EXACTLY as the provider stated.
        // The fixture is deliberately symbol-free ("15", not "$15"): a "$15" fixture could
        // not tell "renders verbatim" apart from "fabricates a $", the money-side twin of
        // manufactured headroom.
        TestHarness.expect("extra line joins used spend and an unqualified balance verbatim",
                           Spend(used: .qualified(minor: 0, currency: "USD", exponent: 2),
                                 balance: .unqualified(raw: "15")).extraLine,
                           "$0.00 · 15 free")
        // Balance alone (no spend yet) still shows the free credits — with no fabricated $.
        TestHarness.expect("an unqualified balance is never given a fabricated currency symbol",
                           Spend(balance: .unqualified(raw: "15")).extraLine,
                           "15 free")
        // Regression: fabricating "$0.00" for an account the provider said nothing about.
        // Neither figure present → no line, so the card omits Extra entirely.
        TestHarness.check("empty spend produces no extra line",
                          Spend().extraLine == nil)
    }
}
