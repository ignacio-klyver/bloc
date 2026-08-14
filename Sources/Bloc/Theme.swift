import AppKit
import SwiftUI

/// Design tokens.
///
/// The panel floats on a translucent material, so text runs on the system label colors,
/// which macOS keeps legible over any blur the wallpaper produces (and which turn opaque
/// automatically under Reduce Transparency). The palette work that survives from the opaque
/// era is the accent, still OKLCH-derived and still a marker only, and the paper tone the
/// crumple ball is made of. See `palette_check.py` for the original derivation.
enum Theme {

    // MARK: - Color

    private static func dynamic(light: (Double, Double, Double),
                                dark: (Double, Double, Double),
                                _ name: String) -> Color {
        let ns = NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
        return Color(nsColor: ns)
    }

    /// Note text.
    static let ink = Color(nsColor: .labelColor)

    /// Day label, meta.
    static let inkSecondary = Color(nsColor: .secondaryLabelColor)

    /// Placeholder, hints, metadata.
    static let inkTertiary = Color(nsColor: .tertiaryLabelColor)

    /// Hovered / focused / expanded note row: a neutral wash over the material.
    static let rowHover = Color.primary.opacity(0.06)

    /// The crumple ball's paper.        light oklch(0.968 0.008 85) · dark oklch(0.262 0.008 85)
    static let paper = dynamic(light: (0.9686, 0.9569, 0.9333),
                               dark:  (0.1490, 0.1412, 0.1255), "paper")

    /// Marker only: star, dot, ticks with pending notes. Never used as a text color.
    ///                                light oklch(0.620 0.150 55) · dark oklch(0.780 0.130 55)
    static let accent = dynamic(light: (0.7882, 0.4118, 0.0471),
                                dark:  (0.9686, 0.6275, 0.3843), "accent")

    /// Pending pill background.       light oklch(0.935 0.038 55) · dark oklch(0.345 0.060 55)
    static let accentFill = dynamic(light: (1.0000, 0.8941, 0.8235),
                                    dark:  (0.3176, 0.1882, 0.0980), "accentFill")

    /// The one hairline weight: the rule under the field, the rule above the footer, and the
    /// ring around the panel.
    static let hairline: Color = {
        let ns = NSColor(name: NSColor.Name("hairline")) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.10)
                : NSColor(white: 0, alpha: 0.08)
        }
        return Color(nsColor: ns)
    }()

    // MARK: - Type
    //
    // One family (the system face), four roles. Sizes in points.

    enum Size {
        /// The capture field, the biggest voice in the panel.
        static let field: CGFloat = 17
        static let note: CGFloat = 15
        /// Section headers (set in caps) and control labels.
        static let label: CGFloat = 12
        static let foot: CGFloat = 11
    }

    static let noteFont = NSFont.systemFont(ofSize: Size.note, weight: .regular)
    static let fieldFont = NSFont.systemFont(ofSize: Size.field, weight: .regular)

    // MARK: - Motion
    //
    // Two clocks and one signature, nothing else. Hover is deliberately INSTANT, like
    // native macOS menus: a hover fade was the clock that kept colliding with everything
    // (tick a note and the fill faded at one speed while the row sank at another).

    enum Motion {
        /// Press feedback on buttons. Isolated to the pressed control, never concurrent.
        static let press = Animation.easeOut(duration: 0.12)
        /// THE clock: every state change that moves, swaps or reveals content runs on
        /// this one spring. Tick, sink, star, expand, count roll, banners, day switch.
        static let state = Animation.spring(duration: 0.25, bounce: 0)
        // The crumple delete keeps its own physics; it is the app's signature.
    }

    // MARK: - Metrics

    /// The layout has exactly two leading edges and one indent step between them.
    ///
    ///   `inset` (20)            chrome: field, section headers, footer
    ///   `inset + gutter` (70)   note text
    ///
    /// The 50 pt gutter is the checkbox and star column: 20 + 10 + 10 + 10. Anything that
    /// introduces a third edge is a bug, not a refinement.
    enum Metric {
        /// Single leading edge every element aligns to.
        static let inset: CGFloat = 20
        /// Checkbox and star column. Note text starts at `inset + gutter`.
        static let gutter: CGFloat = 50
        /// One step of subordination inside a row.
        static let gap: CGFloat = 10
        /// How far the list outdents so a hover row can breathe past the content edge.
        /// Full bleed: the hover surface spans the panel edge to edge, Barrie-style, and
        /// the panel's own inset becomes the air around the ink. The content never moves
        /// off the 20/70 edges; only the surface grows.
        static let rowBleed: CGFloat = 20
        /// Capture field: no box of its own, the panel header is the field.
        static let fieldPadY: CGFloat = 16
        /// The font's own line height, so one empty line is exactly one line tall.
        static var fieldLine: CGFloat { NSLayoutManager().defaultLineHeight(for: fieldFont) }
        /// Leading between wrapped lines, shared between the field and the note rows.
        static let fieldLead: CGFloat = 6
        static let panelRadius: CGFloat = 26
        static let rowRadius: CGFloat = 8
        static let panelWidth: CGFloat = 560
        static let listMaxHeight: CGFloat = 400
        /// List row spacing. The visible gap between notes also includes each row's own
        /// vertical padding; day breaks are set where the group header is laid out.
        static let gapInner: CGFloat = 2
    }
}
