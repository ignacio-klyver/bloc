import SwiftUI

/// A note at two levels of detail. Collapsed: up to two lines of text. Expanded: the full
/// text, a metadata line, and the actions held visible. One click opens the second level;
/// a click on the text inside it starts editing.
struct NoteRow: View {
    let note: Note
    var showDay: Bool = false
    var isFocused: Bool
    var isExpanded: Bool
    /// Whether a reminder can be offered at all. With no workspace connected the menu says
    /// so instead of offering an action that would quietly do nothing.
    var slackConnected: Bool = false
    var onToggle: () -> Void
    var onStar: () -> Void
    var onDelete: () -> Void
    var onEdit: (String) -> Void
    var onExpand: () -> Void
    /// Called when inline editing ends (commit or cancel), so the owner can put keyboard
    /// focus back on the row. Without it, leaving the editor dropped focus on the floor.
    var onEndEdit: () -> Void = {}
    var onSchedule: (Date) -> Void = { _ in }
    var onCancelReminder: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    private var highlighted: Bool { hovering || isFocused || isExpanded }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metric.gap) {
            checkbox

            // The star keeps its slot whether or not it is lit, so every note's text starts
            // on the same leading edge. Without this, starred and plain rows sit on two
            // different edges and the column reads as ragged.
            Group {
                if note.starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accent)
                        // Scales in inside the same transaction that slides the row, so the
                        // star and the move read as one event. Without this it popped in at
                        // the destination before the row started travelling.
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Color.clear
                }
            }
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }

            VStack(alignment: .leading, spacing: 4) {
                if editing { editor } else { label }
                // The reminder shows at both levels of detail: it is a promise the app made
                // on the user's behalf, and a promise you have to expand a row to find is a
                // promise you will be surprised by.
                if note.remindAt != nil && !editing { reminderBadge }
                if isExpanded && !editing { meta }
            }

            Spacer(minLength: 0)

            // The actions keep their place in the layout at all times and only fade in.
            // Inserting them on hover shrank the text column, rewrapped the note to a
            // second line and moved the very button the pointer was heading for.
            actions
                .opacity(highlighted && !editing ? 1 : 0)
                .allowsHitTesting(highlighted && !editing)
                // Without an explicit guide the icons take whatever baseline SwiftUI infers
                // for a non-text view, which measured visibly low against the first line.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 7 }
        }
        // The list container is outdented by `rowBleed` and every row pads it back, so the
        // content lands on the same 20 pt edge as the field while the hover surface still
        // has room to breathe around it.
        .padding(.leading, Theme.Metric.rowBleed)
        // Optically balanced, not equal: the action icons carry ~7 pt of air inside their
        // own boxes, so the box needs less padding than the checkbox side for the visible
        // right gap to match the visible left one.
        .padding(.trailing, Theme.Metric.rowBleed - 4)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metric.rowRadius, style: .continuous)
                .fill(isFocused && !editing
                      ? Color.primary.opacity(0.10)
                      : (highlighted ? Theme.rowHover : Color.clear))
        }
        // Keyboard focus is distinct from hover: a deeper fill plus an accent bar on the
        // leading edge. The bar is marker duty; the full 2 pt frame this replaced was the
        // loudest orange in the app and read as chrome, not as a marker.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 3)
                .padding(.vertical, 6)
                .opacity(isFocused && !editing ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .focusable(!editing)
        // The row paints its own focused state (the same fill as hover), so the system ring
        // is redundant on top of it, and inside the outdented scroll view it drew clipped at
        // both edges, which read as a broken border.
        .focusEffectDisabled()
        .onKeyPress(.space) { onToggle(); return .handled }
        .onKeyPress(.return) {
            // First Enter opens the detail; the second starts editing inside it.
            if isExpanded { beginEdit() } else { onExpand() }
            return .handled
        }
        .onKeyPress(.delete) { onDelete(); return .handled }
        .onKeyPress(.deleteForward) { onDelete(); return .handled }
        .onKeyPress(KeyEquivalent("d"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            onStar()
            return .handled
        }
        // Everything the row can do, reachable from one right click, Barrie-style. This is
        // also the only affordance that works without hovering the exact icon targets.
        .contextMenu {
            Button(note.done ? "Marcar como pendiente" : "Marcar como procesada",
                   action: onToggle)
            Button("Editar", action: beginEdit)
            Button(note.starred ? "Sacar el destacado" : "Destacar", action: onStar)
            Divider()
            slackMenu
            Divider()
            Button("Borrar", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(note.done ? "Procesada" : "Pendiente")
        .accessibilityAddTraits(note.done ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Espacio para tildar, Enter para abrir, Suprimir para borrar")
    }

    /// Scheduling an old note from the menu, and calling one off. The submenu offers the
    /// same four times the capture row does, so there is one vocabulary in the app and not
    /// a second one hiding in a right click.
    @ViewBuilder
    private var slackMenu: some View {
        if !slackConnected {
            Button("Enviar a Slack…") {}
                .disabled(true)
        } else {
            Menu(note.remindAt == nil ? "Enviar a Slack" : "Reprogramar en Slack") {
                ForEach(When.suggestions, id: \.self) { suggestion in
                    if let date = When.date(from: suggestion) {
                        Button(suggestion) { onSchedule(date) }
                    }
                }
            }
        }
        if note.isUpcoming() {
            Button("Cancelar el recordatorio", action: onCancelReminder)
        }
    }

    /// The day is spoken as part of the note rather than shown on its own row, so the
    /// cross-day list keeps its context without paying a row per note for it.
    private var accessibilityText: String {
        var text = showDay ? "\(note.text). \(DayFormat.long(note.day))" : note.text
        if let remindAt = note.remindAt {
            text += note.isUpcoming()
                ? ". Se envía a Slack \(When.label(remindAt))"
                : ". Enviada a Slack \(When.label(remindAt))"
        }
        return text
    }

    /// Collapsed, the row is a summary; the click promises the rest and expanding keeps it.
    private var label: some View {
        Text(note.text)
            .font(.system(size: Theme.Size.note))
            // A done note still has to be readable: tertiary measured 1.9:1 on the light
            // ground. The strikethrough and the filled checkbox carry the "done", the
            // color only needs to recede one step.
            .foregroundStyle(note.done ? Theme.inkSecondary : Theme.ink)
            .strikethrough(note.done, color: Theme.inkTertiary)
            .lineSpacing(Theme.Metric.fieldLead)
            .lineLimit(isExpanded ? nil : 2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded ? beginEdit() : onExpand() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "Tocá para editar" : "Tocá para abrir")
    }

    /// What Slack is going to do with this note, in three states that read differently
    /// on purpose: waiting on Slack, already delivered, and never handed over at all.
    @ViewBuilder
    private var reminderBadge: some View {
        if let remindAt = note.remindAt {
            let upcoming = remindAt > Date()
            let queued = note.slackID != nil

            HStack(spacing: 5) {
                Image(systemName: upcoming
                      ? (queued ? "paperplane.fill" : "exclamationmark.triangle")
                      : "checkmark.circle")
                    .font(.system(size: 9, weight: .medium))
                Text(reminderText(remindAt, upcoming: upcoming, queued: queued))
                    .font(.system(size: Theme.Size.foot))
            }
            // Accent is a marker, and a reminder waiting to fire is exactly that. Once it
            // has gone out, or if it never got queued, it stops being a live signal.
            .foregroundStyle(upcoming && queued ? Theme.accent : Theme.inkSecondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func reminderText(_ date: Date, upcoming: Bool, queued: Bool) -> String {
        if !upcoming { return "enviada · \(When.label(date))" }
        if !queued { return "sin agendar · \(When.label(date))" }
        return "Slack · \(When.label(date))"
    }

    /// The second level of detail: where the note lives and what state it is in.
    private var meta: some View {
        Text(metaText)
            .font(.system(size: Theme.Size.foot))
            .foregroundStyle(Theme.inkSecondary)
            .accessibilityHidden(true)
    }

    private var metaText: String {
        var parts = [DayFormat.long(note.day)]
        if note.starred { parts.append("destacada") }
        if note.done { parts.append("procesada") }
        return parts.joined(separator: " · ")
    }

    private var editor: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: Theme.Size.note))
            .foregroundStyle(Theme.ink)
            .lineSpacing(Theme.Metric.fieldLead)
            .focused($editorFocused)
            .onSubmit(commitEdit)
            // Leaving the field commits too, so clicking away never silently drops an edit.
            .onChange(of: editorFocused) { _, focused in
                if !focused && editing { commitEdit() }
            }
            .onExitCommand {
                editing = false
                onEndEdit()
            }
    }

    // MARK: Checkbox

    /// Reminders-shaped: an open circle that fills when the note is processed. Both glyphs
    /// stay in the view and cross-fade, so the state change animates in and out.
    private var checkbox: some View {
        Button(action: onToggle) {
            ZStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.inkTertiary)
                    .opacity(note.done ? 1 : 0)
                    .scaleEffect(reduceMotion ? 1 : (note.done ? 1 : 0.25))
                    .blur(radius: reduceMotion ? 0 : (note.done ? 0 : 4))
                Image(systemName: "circle")
                    .foregroundStyle(Theme.inkTertiary)
                    .opacity(note.done ? 0 : 1)
                    .scaleEffect(reduceMotion ? 1 : (note.done ? 0.25 : 1))
                    // Mirror of the glyph above: blurred while leaving, sharp while present.
                    .blur(radius: reduceMotion ? 0 : (note.done ? 4 : 0))
            }
            .font(.system(size: 16, weight: .regular))
            .frame(width: 20, height: 20)
            // The glyph stays 20 pt and the target becomes 32. Tildar is the action repeated
            // most and it was the smallest thing to hit in the app. Extending the hit shape
            // rather than padding the frame keeps the text column on its 70 pt edge.
            .contentShape(Rectangle().size(width: 32, height: 32).offset(x: -6, y: -6))
        }
        .buttonStyle(.plain)
        // Reduced motion keeps the state change legible with a plain fade instead of
        // collapsing it to an instant swap. Tildar is the most repeated action in the app,
        // so the swap runs at micro-interaction speed, not modal speed.
        .animation(reduceMotion ? .easeOut(duration: 0.12) : Theme.Motion.state,
                   value: note.done)
        .accessibilityLabel(note.done ? "Marcar como pendiente" : "Marcar como procesada")
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3.5 }
    }

    // MARK: Trailing actions

    private var actions: some View {
        HStack(spacing: 2) {
            iconButton(note.starred ? "star.slash" : "star",
                       label: note.starred ? "Sacar el destacado" : "Destacar",
                       action: onStar)
            iconButton("trash", label: "Borrar nota", action: onDelete)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 26, height: 26)
                // 1 pt sideways is all the 2 pt gap to the neighbour allows without the two
                // hit areas overlapping; vertically there is room to reach 30.
                .contentShape(Rectangle().size(width: 28, height: 30).offset(x: -1, y: -2))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: Editing

    private func beginEdit() {
        draft = note.text
        editing = true
        DispatchQueue.main.async { editorFocused = true }
    }

    private func commitEdit() {
        editing = false
        onEdit(draft)
        onEndEdit()
    }
}

/// The fixed press feedback: scale 0.96, never lower.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}
