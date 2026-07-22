import SwiftUI
import AppKit

extension AppDelegate {
    // §7.1's menu bar: one figure per provider, each INDEPENDENTLY coloured. The engine
    // (`store.menuBar`) already computed the worst-of across enabled accounts and the
    // unknown-beats-known rule; this view only paints what it was handed. The pure
    // projection (glyph, value text, band, tooltip) lives in `MenuBarPresentation` where
    // the test target can pin the manufactured-headroom invariant — here we only map a
    // band to a concrete colour and lay out an attributed title.

    // Band colours match the app's existing green/amber/red. `.unknown` gets a neutral
    // grey of its own: an unreadable figure must never borrow a band that implies
    // headroom the account may not have.
    private func color(for band: UsageBand) -> NSColor {
        switch band {
        case .low:     return NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0)
        case .medium:  return NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)
        case .high:    return NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
        case .unknown: return NSColor.secondaryLabelColor
        }
    }

    // Drive the menu bar from the store's published figures. One figure per provider,
    // each coloured on its own; a provider absent from the array renders nothing; an
    // empty array is the neutral idle state, never "0%".
    func renderMenuBar(_ figures: [ProviderFigure]) {
        guard let button = statusItem.button else { return }
        let segments = MenuBarPresentation.segments(figures)

        guard !segments.isEmpty else {
            // Idle: the app is running but has nothing to show yet. A dim spark — not 0%.
            button.image = createSparkIcon(color: .secondaryLabelColor)
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "ClaudeUsageBar — waiting for usage data"
            return
        }

        // Everything is drawn in the attributed TITLE (image slot cleared) so that two
        // providers can carry two independent colours — a single `button.image` cannot.
        button.image = nil
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small), weight: .semibold)
        let title = NSMutableAttributedString()

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "  "))
            }
            let bandColor = color(for: segment.band)

            // The provider glyph as a colour-controlled image attachment, so the tint is
            // the band's — an emoji glyph would ignore the colour and show one provider in
            // the wrong band. The spark is the app's existing Claude mark; Codex gets a
            // diamond drawn the same way.
            let attachment = NSTextAttachment()
            attachment.image = providerIcon(for: segment.provider, color: bandColor)
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            title.append(NSAttributedString(attachment: attachment))

            title.append(NSAttributedString(string: " \(segment.value)", attributes: [
                .foregroundColor: bandColor,
                .font: font,
            ]))
        }

        button.attributedTitle = title
        // The tooltip is the only place the single-number bar names its source account and
        // window (§7.1). One line per provider.
        button.toolTip = segments.map { $0.tooltip }.joined(separator: "\n")
    }

    // Inert shims for the cookie-era `LegacyUsageManager`, which is instantiated (the
    // popover/settings still reference its type until task 11) but NEVER polls, so these
    // are never called at runtime. They are no-ops rather than renderers so that even if
    // the legacy manager were somehow driven, it could not fight the store for the button.
    // Task 11 deletes these with their last call site.
    // `nonisolated` so the (non-`@MainActor`) legacy manager's call sites still compile
    // now that `AppDelegate` is `@MainActor`. Safe because the bodies touch nothing.
    nonisolated func updateStatusIcon(percentage: Int) {}
    nonisolated func updateStatusIcon(sessionPercentage: Int, weeklyPercentage: Int) {}

    private func providerIcon(for provider: ProviderKind, color: NSColor) -> NSImage {
        switch provider {
        case .anthropic: return createSparkIcon(color: color)
        case .codex:     return createDiamondIcon(color: color)
        }
    }

    func createSparkIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        // SVG path: M8 1L9 6L13 3L10 7L15 8L10 9L13 13L9 10L8 15L7 10L3 13L6 9L1 8L6 7L3 3L7 6L8 1Z
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8, y: 1))
        path.line(to: NSPoint(x: 9, y: 6))
        path.line(to: NSPoint(x: 13, y: 3))
        path.line(to: NSPoint(x: 10, y: 7))
        path.line(to: NSPoint(x: 15, y: 8))
        path.line(to: NSPoint(x: 10, y: 9))
        path.line(to: NSPoint(x: 13, y: 13))
        path.line(to: NSPoint(x: 9, y: 10))
        path.line(to: NSPoint(x: 8, y: 15))
        path.line(to: NSPoint(x: 7, y: 10))
        path.line(to: NSPoint(x: 3, y: 13))
        path.line(to: NSPoint(x: 6, y: 9))
        path.line(to: NSPoint(x: 1, y: 8))
        path.line(to: NSPoint(x: 6, y: 7))
        path.line(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 7, y: 6))
        path.close()

        color.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }

    // Codex's mark: a filled diamond (§7.1's `◆`), drawn as a bezier so it takes the
    // band colour exactly as the spark does rather than rendering as a fixed-colour glyph.
    func createDiamondIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8, y: 2))
        path.line(to: NSPoint(x: 14, y: 8))
        path.line(to: NSPoint(x: 8, y: 14))
        path.line(to: NSPoint(x: 2, y: 8))
        path.close()

        color.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }
}

// NSColor extension for hex conversion
extension NSColor {
    var hexString: String {
        guard let rgbColor = self.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
