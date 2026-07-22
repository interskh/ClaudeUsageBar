import Foundation

// The pure projection behind §7.1's menu bar. The view (Core/UI) only maps a band to a
// concrete NSColor and lays out an attributed string; every decision that could
// manufacture headroom — what an unknown figure reads as, which glyph names a provider,
// which colour band a figure falls in — lives here, in a file the test target compiles,
// so the manufactured-headroom invariant (§3) is tested rather than trusted to a
// two-line `switch` inside an untestable AppKit view.
//
// The worst-of aggregation itself is NOT here: `UsageEngine.menuBarFigures` already did
// it (unknown beats known across enabled accounts), and re-deriving it in the UI is the
// single-sourcing violation task 7 spent findings preventing. This only formats the
// figures the engine handed down.

enum UsageBand: Equatable {
    case low     // < 70  → green
    case medium  // < 90  → amber
    case high    // ≥ 90  → red
    case unknown // no readable figure — a band of its own, never folded into `low`

    // §3/§7.1: `.unknown` is a distinct outcome, never coerced to a number and therefore
    // never to a colour band that implies headroom the account may not have.
    static func classify(_ utilization: Utilization) -> UsageBand {
        switch utilization {
        case .unknown:
            return .unknown
        case .known(let percent):
            if percent < 70 { return .low }
            if percent < 90 { return .medium }
            return .high
        }
    }
}

// One rendered figure: the glyph that names the provider, the value to draw, its colour
// band, and the tooltip line naming the source account and window (§7.1 — the tooltip is
// the only place the single-number bar says where its figure came from).
struct MenuBarSegment: Equatable {
    let provider: ProviderKind  // which mark the view draws
    let glyph: String
    let value: String   // "78%" for a known figure, "?" for unknown — never "0%"
    let band: UsageBand
    let tooltip: String
}

enum MenuBarPresentation {
    static func glyph(for provider: ProviderKind) -> String {
        switch provider {
        case .anthropic: return "⚡"
        case .codex: return "◆"
        }
    }

    static func providerName(_ provider: ProviderKind) -> String {
        switch provider {
        case .anthropic: return "Claude"
        case .codex: return "Codex"
        }
    }

    // The value text. An unknown figure reads "?", never "0%" and never another window's
    // number — the engine already guaranteed this upstream; the job here is to not undo it
    // with a `?? 0`.
    static func valueText(_ utilization: Utilization) -> String {
        switch utilization {
        case .known(let percent): return "\(percent)%"
        case .unknown: return "?"
        }
    }

    // A provider absent from `figures` is absent from the result — no entry is
    // synthesised at 0%. An empty input therefore yields an empty output, which the view
    // renders as its neutral idle state rather than as two 0% figures.
    static func segments(_ figures: [ProviderFigure]) -> [MenuBarSegment] {
        figures.map { figure in
            MenuBarSegment(
                provider: figure.provider,
                glyph: glyph(for: figure.provider),
                value: valueText(figure.utilization),
                band: UsageBand.classify(figure.utilization),
                tooltip: "\(providerName(figure.provider)): \(figure.accountLabel)"
                    + " · \(figure.windowLabel) — \(valueText(figure.utilization))"
            )
        }
    }
}
