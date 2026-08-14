import AppKit
import SwiftUI

/// The floating panel: borderless, translucent, centered near the top of the active screen,
/// Spotlight-style. It replaced an NSPopover anchored to the status item; the popover's
/// anchoring was the source of a whole class of positioning bugs, and the centered panel is
/// the shape the user actually wanted once they saw it.
final class FloatingPanel: NSPanel {
    /// Borderless windows refuse key status by default, and a capture field that cannot
    /// become key never sees a keystroke.
    override var canBecomeKey: Bool { true }
}

@MainActor
enum PanelBuilder {

    /// Panel chrome: translucent material behind the whole interface, continuous corners,
    /// a hairline ring so the edge reads on any wallpaper.
    static func build(hosting: NSView) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Metric.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // Follows the user to whatever space or full-screen app they are in; a capture tool
        // that refuses to appear over a full-screen window is not a capture tool.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.Metric.panelRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        // The layer mask above clips the content but NOT the blur backdrop: that layer is
        // sampled behind the window and kept painting the square corners, which showed as
        // opaque white squares behind the rounded shape. maskImage is the supported way to
        // shape the material itself.
        effect.maskImage = roundedMask(radius: Theme.Metric.panelRadius)

        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        return panel
    }

    /// A stretchable rounded rectangle for the material mask, drawn with the SAME
    /// continuous-corner curve the layer clip and the hairline ring use. Mixing curve
    /// families left a crescent of naked blur outside the ring at every corner: the
    /// circular arc bulges up to 2.4 pt past the continuous curve at this radius.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        // A continuous corner's influence extends ~1.53x the radius along each edge, so
        // the stretchable center must start beyond that or the corners distort on resize.
        let inset = ceil(radius * 1.6)
        let edge = inset * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(Path(roundedRect: rect, cornerRadius: radius, style: .continuous).cgPath)
            ctx.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        return image
    }

    /// The screen the pointer is on: the shortcut is pressed from wherever the user is
    /// working, and the panel has to appear there, not on whichever display is "main".
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Top edge pinned at 18% down the screen, horizontally centered. The top stays fixed
    /// while the content grows and shrinks, so the field never jumps under the caret.
    static func place(_ panel: NSPanel, size: NSSize, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let top = visible.maxY - visible.height * 0.18
        panel.setFrame(NSRect(x: visible.midX - size.width / 2,
                              y: top - size.height,
                              width: size.width, height: size.height),
                       display: true)
    }

    /// Resize in place keeping the top edge anchored.
    static func resize(_ panel: NSPanel, to size: NSSize) {
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        panel.setFrame(frame, display: true)
    }
}
