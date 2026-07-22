import Foundation

// §7.1's projection is pure and therefore tested here rather than resting on the
// screenshot alone. The load-bearing assertion is the manufactured-headroom invariant:
// an unknown figure renders as "?", never as "0%" and never by borrowing another
// provider's number, and an absent provider produces no segment at all.
enum MenuBarPresentationTests {
    private static func figure(_ provider: ProviderKind,
                               _ utilization: Utilization,
                               account: String = "acct",
                               window: String = "session") -> ProviderFigure {
        ProviderFigure(provider: provider,
                       utilization: utilization,
                       accountLabel: account,
                       windowLabel: window)
    }

    static func run() {
        // Band boundaries: green < 70, amber < 90, red ≥ 90. The 70 and 90 edges are the
        // ones that straddle a colour change, so they are the ones asserted.
        TestHarness.expect("band 0 is low", UsageBand.classify(.known(0)), .low)
        TestHarness.expect("band 69 is low", UsageBand.classify(.known(69)), .low)
        TestHarness.expect("band 70 is medium", UsageBand.classify(.known(70)), .medium)
        TestHarness.expect("band 89 is medium", UsageBand.classify(.known(89)), .medium)
        TestHarness.expect("band 90 is high", UsageBand.classify(.known(90)), .high)
        TestHarness.expect("band 100 is high", UsageBand.classify(.known(100)), .high)

        // Unknown is its own band — NOT low. Folding it into low is the manufactured
        // headroom this whole design exists to prevent, one layer down in the view.
        TestHarness.expect("unknown is its own band", UsageBand.classify(.unknown), .unknown)

        // An unknown figure reads "?", never "0%".
        TestHarness.expect("unknown value text", MenuBarPresentation.valueText(.unknown), "?")
        TestHarness.expect("known value text", MenuBarPresentation.valueText(.known(78)), "78%")
        TestHarness.expect("zero is a real 0%", MenuBarPresentation.valueText(.known(0)), "0%")

        // Glyphs name the provider and do not alias each other.
        TestHarness.expect("claude glyph", MenuBarPresentation.glyph(for: .anthropic), "⚡")
        TestHarness.expect("codex glyph", MenuBarPresentation.glyph(for: .codex), "◆")

        // Two providers in different bands at once produce two independently-banded
        // segments in the engine's order — the view colours each on its own.
        let segments = MenuBarPresentation.segments([
            figure(.anthropic, .known(78), account: "fiona", window: "5h session"),
            figure(.codex, .known(31), account: "work", window: "weekly"),
        ])
        TestHarness.expect("two segments", segments.count, 2)
        TestHarness.expect("claude segment band", segments[0].band, .medium)
        TestHarness.expect("codex segment band", segments[1].band, .low)
        TestHarness.expect("claude value", segments[0].value, "78%")
        TestHarness.expect("claude tooltip",
                           segments[0].tooltip,
                           "Claude: fiona · 5h session — 78%")
        TestHarness.expect("codex tooltip",
                           segments[1].tooltip,
                           "Codex: work · weekly — 31%")

        // An unknown provider figure renders as unknown, keeping its own segment — it is
        // present-but-unreadable, distinct from absent.
        let mixed = MenuBarPresentation.segments([
            figure(.anthropic, .unknown),
            figure(.codex, .known(12)),
        ])
        TestHarness.expect("unknown keeps a segment", mixed.count, 2)
        TestHarness.expect("unknown segment value", mixed[0].value, "?")
        TestHarness.expect("unknown segment band", mixed[0].band, .unknown)

        // A provider absent from the engine's figures is absent from the segments — never
        // synthesised at 0%. An empty input yields an empty output (the idle state).
        let claudeOnly = MenuBarPresentation.segments([figure(.anthropic, .known(50))])
        TestHarness.expect("absent provider omitted", claudeOnly.count, 1)
        TestHarness.expect("absent provider is claude only", claudeOnly[0].glyph, "⚡")
        TestHarness.expect("empty input is empty output",
                           MenuBarPresentation.segments([]).isEmpty, true)
    }
}
