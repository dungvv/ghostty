import SwiftUI

/// The side panel palette and type scale.
///
/// Every colour here was sampled from a running Otty window rather than
/// guessed, so the panels sit next to the terminal the same way they do
/// there. They are fixed rather than semantic because the panels are always
/// dark: the point is to match one specific look, and `NSColor`'s adaptive
/// greys would drift away from it as soon as the system appearance changed.
enum OttyTheme {
    // MARK: Surfaces

    /// Background shared by both side panels.
    static let panel = Color(hex: 0x424550)

    /// The terminal's own background, slightly darker than the panels so the
    /// split between them reads without a hard border.
    static let terminal = Color(hex: 0x353845)

    /// The selected tab row.
    static let selection = Color(hex: 0x555761)

    /// A row under the pointer, which is a halfway step to the selection.
    static let hover = Color(hex: 0x4B4E59)

    /// Hairline between a panel and the terminal.
    static let divider = Color(hex: 0x4A4C57)

    // MARK: Text

    /// Values and anything else that should read first.
    static let primaryText = Color(hex: 0xEDEDEB)

    /// Section headings in the info panel.
    static let headingText = Color(hex: 0xB4B5B6)

    /// Tab titles.
    static let tabTitle = Color(hex: 0xA3A4A6)

    /// The dim second column: panel captions, process names, empty states.
    static let secondaryText = Color(hex: 0x8E8F92)

    // MARK: Accents

    /// Action links.
    static let accent = Color(hex: 0x88C2F4)

    /// A running process.
    static let running = Color(hex: 0x78B86E)

    /// A process that has exited.
    static let stopped = Color(hex: 0x8E8F92)

    // MARK: Type

    /// Panel captions such as "TABS", which are uppercased and tracked out.
    static let caption = Font.system(size: 10, weight: .semibold)

    /// Section headings in the info panel.
    static let heading = Font.system(size: 12, weight: .semibold)

    /// Tab titles and info values.
    static let body = Font.system(size: 12.5)

    /// The dim second column.
    static let detail = Font.system(size: 11)

    /// Numbers that should not jitter as they tick.
    static let number = Font.system(size: 11).monospacedDigit()

    // MARK: Metrics

    static let rowHeight: CGFloat = 30
    static let rowCornerRadius: CGFloat = 6
    static let panelPadding: CGFloat = 10
}

extension Color {
    /// Build a colour from a `0xRRGGBB` literal.
    ///
    /// sRGB explicitly: the sampled values came from a screenshot in that
    /// space, and letting SwiftUI pick a different one would shift them.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
