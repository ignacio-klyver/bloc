import AppKit
import SwiftUI

/// The capture field: a plain text view with a placeholder and the keyboard contract for
/// writing a note. Nothing is drawn behind the text.
///
/// This replaced a ruled-paper surface. The rules and the red margin line came from a visual
/// reference, but in a 340 pt panel they were noise, and keeping the text from colliding with
/// them needed an optical offset that had to be re-tuned every time anything moved. A field
/// whose padding only has to answer to the text is a field whose padding can be right.
final class CaptureTextView: NSTextView {

    var placeholder: String = ""
    var placeholderColor: NSColor = NSColor(Theme.inkSecondary)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPlaceholderIfNeeded()
    }

    /// Drawn with the view's own typing attributes at the text container origin, so it lands on
    /// exactly the same baseline the first typed character would.
    private func drawPlaceholderIfNeeded() {
        guard string.isEmpty, !placeholder.isEmpty else { return }
        var attributes = typingAttributes
        attributes[.foregroundColor] = placeholderColor
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(at: NSPoint(x: origin.x + padding, y: origin.y))
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: rect, color: insertionPointColor, turnedOn: flag)
    }
}

// MARK: - SwiftUI wrapper

struct CaptureField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onMoveDown: () -> Void
    /// Left and right arrows step the day, but only while the field is empty, so the cursor
    /// always wins whenever there is text to move through.
    var onStepDay: (Int) -> Void

    /// One line plus symmetric padding. The field starts at the size of what it holds and
    /// grows as you type, the way a message input does, instead of reserving empty rows.
    static var minHeight: CGFloat { Theme.Metric.fieldLine + Theme.Metric.fieldPadY * 2 }
    static var maxHeight: CGFloat {
        Theme.Metric.fieldLine * 6 + Theme.Metric.fieldLead * 5 + Theme.Metric.fieldPadY * 2
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = CaptureTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.drawsBackground = false
        // No horizontal inset: the field sits naked in the panel header next to the
        // magnifier, and the row provides the margins.
        view.textContainerInset = NSSize(width: 0, height: Theme.Metric.fieldPadY)
        view.textContainer?.lineFragmentPadding = 0
        // The text view grows with its content inside the scroll view, so once the field
        // stops growing at six lines the caret can still scroll into view. Without this,
        // line seven was written outside the clip and edited blind.
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.font = Theme.fieldFont
        view.placeholder = placeholder

        // Natural line height plus the same leading the saved notes use, so what you type and
        // what you read back have identical rhythm.
        let style = NSMutableParagraphStyle()
        style.lineSpacing = Theme.Metric.fieldLead
        view.defaultParagraphStyle = style
        view.typingAttributes = [
            .font: Theme.fieldFont,
            .paragraphStyle: style,
            .foregroundColor: NSColor(Theme.ink)
        ]

        applyColors(to: view)

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CaptureTextView else { return }
        if view.string != text { view.string = text }
        view.placeholder = placeholder
        applyColors(to: view)
        view.needsDisplay = true

        let measured = measuredHeight(for: view)
        if abs(measured - height) > 0.5 {
            DispatchQueue.main.async { height = measured }
        }
    }

    private func applyColors(to view: CaptureTextView) {
        // Secondary, not tertiary: this line is the app's main invitation, and tertiary
        // was disappearing into the translucent material.
        view.placeholderColor = NSColor(Theme.inkSecondary)
        view.insertionPointColor = NSColor(Theme.accent)
        view.textColor = NSColor(Theme.ink)
    }

    private func measuredHeight(for view: CaptureTextView) -> CGFloat {
        guard let lm = view.layoutManager, let tc = view.textContainer else {
            return CaptureField.minHeight
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let content = max(used, lm.extraLineFragmentRect.maxY, Theme.Metric.fieldLine)
        return min(max(content + Theme.Metric.fieldPadY * 2, CaptureField.minHeight),
                   CaptureField.maxHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptureField
        init(_ parent: CaptureField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? CaptureTextView else { return }
            parent.text = view.string
            view.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true

            // Shift+Return and Option+Return both mean "stay in this note".
            case #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true

            case #selector(NSResponder.moveDown(_:)):
                // Only leave the field when there is nowhere further down inside it.
                let atEnd = textView.selectedRange().location >= (textView.string as NSString).length
                if atEnd {
                    parent.onMoveDown()
                    return true
                }
                return false

            // With an empty field the arrows have no cursor to move, so they navigate days.
            // With any text they belong to the caret and this never fires.
            case #selector(NSResponder.moveLeft(_:)):
                guard textView.string.isEmpty else { return false }
                parent.onStepDay(-1)
                return true

            case #selector(NSResponder.moveRight(_:)):
                guard textView.string.isEmpty else { return false }
                parent.onStepDay(1)
                return true

            default:
                return false
            }
        }
    }
}
