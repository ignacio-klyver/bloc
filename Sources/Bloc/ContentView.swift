import SwiftUI

enum Tab: Equatable, Hashable {
    case pending
    case day(DayKey)
}

/// What currently holds the keyboard. The field is the default; the list rows join the
/// tab order so tildar, expandir, editar y borrar all have a keyboard path.
enum FocusTarget: Hashable {
    case capture
    case note(UUID)
    /// The "cuándo" field of the scheduling row.
    case schedule
}

struct ContentView: View {
    @ObservedObject var store: Store
    var onClose: () -> Void
    /// Reports the fitted content size so the panel can follow with its top edge pinned.
    var onResize: (CGSize) -> Void

    /// Lets a state be opened directly. Used by the offscreen renderer so every screen,
    /// including the ones a user reaches rarely, can be inspected without driving the UI.
    struct Initial {
        var tab: Tab = .day(.today)
        var query = ""
        var showUndo = false
        var scheduling = false
        var whenDraft = ""
    }

    /// Set when the global shortcut could not be registered, so the panel says so instead of
    /// leaving the user pressing a combination that another app already owns.
    var shortcutWarning: String?

    init(store: Store, onClose: @escaping () -> Void,
         onResize: @escaping (CGSize) -> Void = { _ in },
         shortcutWarning: String? = nil, initial: Initial = Initial()) {
        self.store = store
        self.onClose = onClose
        self.onResize = onResize
        self.shortcutWarning = shortcutWarning
        _tab = State(initialValue: initial.tab)
        _draft = State(initialValue: initial.query)
        _showUndo = State(initialValue: initial.showUndo)
        _scheduling = State(initialValue: initial.scheduling)
        _whenDraft = State(initialValue: initial.whenDraft)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tab: Tab = .day(.today)
    @State private var draft = ""
    @State private var fieldHeight: CGFloat = CaptureField.minHeight
    @State private var crumpling: [Note] = []
    @State private var showUndo = false
    @State private var undoTimer: Task<Void, Never>?
    @State private var undoHovering = false
    @State private var hoveredDay: DayKey?
    @State private var contentHeight: CGFloat = 0
    @State private var pillHovering = false
    /// The row currently opened to its second level of detail.
    @State private var expandedID: UUID?
    /// The scheduling row, opened with ⌘⏎ for when the `@cuándo` syntax is not at hand.
    @State private var scheduling = false
    @State private var whenDraft = ""

    @FocusState private var focus: FocusTarget?

    private var selectedDay: DayKey {
        if case .day(let day) = tab { return day }
        return .today
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reading the draft

    /// The draft split into the note and the `@cuándo` trailing it. Parsed on every
    /// keystroke so the create row can show what Enter is about to do.
    private var capture: When.Capture { When.capture(draft) }

    /// The moment the note is actually going to be sent, or nil when there is nothing to
    /// send: no time written, Slack not connected, or an hour Slack will not take.
    ///
    /// With the scheduling row open that row is the answer, so both ways of committing —
    /// its button and a plain Enter — end up sending the same note at the same hour. Two
    /// controls on screen promising two different things is how a user gets surprised.
    private var reminder: Date? {
        if scheduling { return scheduleDate }
        guard store.slackConnected, capture.scheduled else { return nil }
        return capture.date
    }

    /// What gets filed. The `@cuándo` is only taken out of the text when it is really going
    /// to become a reminder; otherwise the user's line is saved exactly as they wrote it.
    private var noteText: String {
        (reminder != nil ? capture.text : trimmedDraft)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One field, two intents: while it holds text the panel is in results mode, showing the
    /// create row plus every note that matches. Empty again, it goes back to browsing days.
    private var searching: Bool { !trimmedDraft.isEmpty }

    private var visibleNotes: [Note] {
        if searching { return store.search(noteText) }
        switch tab {
        case .pending: return store.pending
        case .day(let day): return store.notes(on: day)
        }
    }

    /// Cross-day lists carry the day as a group header instead of a label under every note.
    private var grouped: [(day: DayKey, notes: [Note])] {
        guard groupsByDay else { return [(selectedDay, visibleNotes)] }
        var order: [DayKey] = []
        var buckets: [DayKey: [Note]] = [:]
        for note in visibleNotes {
            if buckets[note.day] == nil { order.append(note.day) }
            buckets[note.day, default: []].append(note)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var groupsByDay: Bool { tab == .pending || searching }

    private var orderedIDs: [UUID] { visibleNotes.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            fieldRow
            Rule()
            if scheduling {
                scheduleRow
                Rule()
            }
            main
            Rule()
            footer
        }
        .frame(width: Theme.Metric.panelWidth)
        // The material alone let whatever sits behind the window decide the text's fate:
        // light ink over a white page was unreadable. The wash keeps the translucency while
        // guaranteeing a ground of the right appearance under every label.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        // The material behind is the surface; the ring keeps the edge legible on any wallpaper.
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metric.panelRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { onResize(geo.size) }
                    .onChange(of: geo.size) { _, size in onResize(size) }
            }
        }
        .background { shortcuts }
        .onExitCommand(perform: closeOrCancel)
        .onAppear { focus = .capture }
        // Each panel opening reloads the store and bumps the token. Returning to today here
        // is what keeps the app from opening on yesterday after midnight.
        .onChange(of: store.sessionToken) { _, _ in resetSession() }
        .accessibilityLabel("Bloc")
    }

    // MARK: Field

    /// No icon. A magnifier said "this is a search box", but the primary job here is
    /// writing; the placeholder wording carries the search half. The field is chrome, so
    /// its text lives on the 20 pt chrome edge, Raycast-style, and the caret is the
    /// affordance.
    private var fieldRow: some View {
        CaptureField(
            text: $draft,
            height: $fieldHeight,
            placeholder: "Buscá o escribí una nota",
            onSubmit: save,
            onEscape: closeOrCancel,
            onMoveDown: focusFirstNote,
            onStepDay: stepDay
        )
        .frame(height: fieldHeight)
        .focused($focus, equals: .capture)
        .accessibilityLabel("Buscar o escribir una nota")
        .padding(.horizontal, Theme.Metric.inset)
    }

    // MARK: Schedule

    /// The long way round to a reminder, opened with ⌘⏎.
    ///
    /// The `@cuándo` syntax is faster and it is what the create row teaches, but a syntax
    /// you have to remember is a syntax that fails you at the exact moment you are in a
    /// hurry. This row asks the same parser the same question, shows the answer in full
    /// before committing to it, and offers the four times a reminder is usually wanted.
    private var scheduleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text(scheduleTitle.uppercased())
                    .font(.system(size: Theme.Size.label, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: 0)
                Button("Cancelar", action: closeScheduling)
                    .buttonStyle(TextActionStyle())
                    .padding(.trailing, -7)
            }

            HStack(spacing: 6) {
                ForEach(When.suggestions, id: \.self) { suggestion in
                    suggestionChip(suggestion)
                }
            }

            HStack(spacing: 10) {
                TextField("mañana 9:30", text: $whenDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.Size.note))
                    .foregroundStyle(Theme.ink)
                    .focused($focus, equals: .schedule)
                    .onSubmit(confirmSchedule)
                    // The field would otherwise swallow Escape before the panel's own
                    // handler could close the row.
                    .onExitCommand(perform: closeScheduling)
                    .frame(width: 150)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Metric.rowRadius,
                                         style: .continuous)
                            .fill(Theme.rowHover))
                    .accessibilityLabel("Cuándo enviarla a Slack")

                Text(scheduleEcho)
                    .font(.system(size: Theme.Size.label))
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button("Agendar", action: confirmSchedule)
                    .buttonStyle(TextActionStyle())
                    .disabled(scheduleDate == nil || trimmedDraft.isEmpty)
                    .opacity(scheduleDate == nil || trimmedDraft.isEmpty ? 0.4 : 1)
                    .padding(.trailing, -7)
            }
        }
        .padding(.horizontal, Theme.Metric.inset)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private var scheduleTitle: String {
        store.slackConnected ? "Enviar a Slack" : "Slack no está conectado"
    }

    private var scheduleDate: Date? {
        guard store.slackConnected else { return nil }
        guard let date = When.date(from: whenDraft), date > Date(),
              date.timeIntervalSinceNow <= When.maxHorizon else { return nil }
        return date
    }

    /// Says only what is going wrong. When the words do resolve, the create row underneath
    /// is already showing the hour in full, and saying it twice made the panel argue with
    /// itself about which one was the real answer.
    private var scheduleEcho: String {
        guard store.slackConnected else { return "corré Bloc --slack-connect" }
        let trimmed = whenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "hoy 18:00, mañana 9, lunes, en 2h…" }
        guard let date = When.date(from: trimmed) else { return "no entendí «\(trimmed)»" }
        if date <= Date() { return "\(When.label(date)) ya pasó" }
        if date.timeIntervalSinceNow > When.maxHorizon { return "más de 120 días" }
        return ""
    }

    private func suggestionChip(_ suggestion: String) -> some View {
        Button {
            whenDraft = suggestion
            focus = .schedule
        } label: {
            Text(suggestion)
                .font(.system(size: Theme.Size.label))
                .foregroundStyle(whenDraft == suggestion ? Theme.ink : Theme.inkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(whenDraft == suggestion
                                           ? Theme.accentFill : Theme.rowHover))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Enviar \(suggestion)")
    }

    // MARK: Main

    /// Vertical rhythm, tightest to loosest: inside a note, between notes, between days.
    /// Day breaks stay at least twice the gap between notes so the grouping reads.
    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            if searching {
                createRow.padding(.top, 12)
                results.padding(.top, 8)
            } else {
                // The header belongs to the list it labels, so the larger gap goes above
                // it, against the field chrome, and the small one binds it to its rows.
                header.padding(.top, 22)
                list.padding(.top, 4)
            }
        }
        .padding(.horizontal, Theme.Metric.inset)
        .padding(.bottom, 14)
    }

    /// Always the first row of results mode: Enter files the text as a note no matter what
    /// matches below, so capture speed never depends on what already exists.
    ///
    /// When the line ends in a `@cuándo`, the row is also the receipt for it: it shows the
    /// note without the spec and, underneath, the hour it is going to arrive in Slack. The
    /// reading and the promise are the same object, so there is no way to press Enter and be
    /// surprised by what got scheduled.
    private var createRow: some View {
        Button(action: save) {
            // Baseline, not centre: with a second line under the note the centred glyphs
            // drifted down and stopped reading as belonging to the note's first line.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.accent)
                    // Same column as the checkboxes below, so the create row and the result
                    // rows share their two edges.
                    .frame(width: Theme.Metric.gutter, alignment: .leading)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }

                VStack(alignment: .leading, spacing: 3) {
                    // Regular, not medium: at medium the 15 pt echo weighed the same as the
                    // 17 pt field above it and the panel had two focal points. The orange
                    // plus and the return glyph carry the default-action affordance.
                    Text(noteText.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: Theme.Size.note, weight: .regular))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let note = captureNote {
                        Text(note.text)
                            .font(.system(size: Theme.Size.foot))
                            .foregroundStyle(note.warning ? Theme.ink : Theme.inkSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Theme.Metric.gap)
                Image(systemName: reminder != nil ? "paperplane.fill" : "return")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(reminder != nil ? Theme.accent : Theme.inkTertiary)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            }
            .padding(.horizontal, Theme.Metric.rowBleed)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metric.rowRadius,
                                           style: .continuous))
        }
        .buttonStyle(CreateRowStyle())
        .padding(.horizontal, -Theme.Metric.rowBleed)
        .accessibilityLabel(createRowLabel)
    }

    /// The second line of the create row: what is going to happen with the time the user
    /// wrote. `warning` is for the cases where the note is still saved but nothing is sent,
    /// which is the one thing the row must never leave implied.
    private var captureNote: (text: String, warning: Bool)? {
        // Whatever is actually going to happen wins, whether it came from the `@cuándo` or
        // from the row below.
        if let date = reminder { return ("Slack · \(When.label(date))", false) }
        guard let date = capture.date else { return nil }
        if !store.slackConnected {
            return ("Slack no está conectado · se guarda como texto", true)
        }
        if capture.past {
            return ("\(When.label(date)) ya pasó · se guarda como texto", true)
        }
        if capture.tooFar {
            return ("Slack no agenda más allá de 120 días · se guarda como texto", true)
        }
        return nil
    }

    private var createRowLabel: String {
        guard let date = reminder else { return "Crear la nota. \(noteText)" }
        return "Crear la nota y enviarla a Slack \(When.label(date)). \(noteText)"
    }

    @ViewBuilder
    private var results: some View {
        if visibleNotes.isEmpty {
            Text("Ninguna nota guardada coincide.")
                .font(.system(size: Theme.Size.label))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.top, 6)
                .padding(.bottom, 10)
        } else {
            list
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(headerLabel.uppercased())
                .font(.system(size: Theme.Size.label, weight: .semibold))
                .tracking(0.8)
                // The count updates live while the pointer scrubs the tick strip.
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            pendingPill
        }
    }

    private var headerLabel: String {
        if let hovered = hoveredDay, hovered != selectedDay {
            let count = store.count(on: hovered)
            let noun = count == 1 ? "1 nota" : "\(count) notas"
            return "\(DayFormat.long(hovered)) · \(count == 0 ? "sin notas" : noun)"
        }
        switch tab {
        case .pending: return "Pendientes"
        case .day(let day): return DayFormat.long(day)
        }
    }

    private var pendingPill: some View {
        Button {
            tab = tab == .pending ? .day(.today) : .pending
            dismissUndo()
        } label: {
            HStack(spacing: 6) {
                // The dot means "there is something waiting". With nothing waiting it would
                // be a lit signal for a state that does not exist.
                if store.pendingCount > 0 {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }
                Text(pendingLabel)
                    .font(.system(size: Theme.Size.label, weight: .semibold))
                    .monospacedDigit()
                    // The count rolls to its new value when a note is ticked, so the pill
                    // answers the action instead of silently being different.
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : Theme.Motion.state,
                               value: store.pendingCount)
                    // Chrome voice, not content voice. At full ink on the panel's only
                    // color mass, the pill out-shouted the field and the notes in every
                    // squint test the critique ran.
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // The capsule fill is a selected-state signal, not a costume: unselected, the
            // dot and the count carry the message alone, and the fill appears on hover as
            // the button affordance.
            .background(Capsule().fill(
                tab == .pending ? Theme.accentFill
                    : (pillHovering ? Theme.rowHover : Color.clear)))
            // The pill is the most-pressed navigation control. The hit area grows past the
            // capsule into the free space around it; nothing moves.
            .contentShape(Capsule().inset(by: -5))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { pillHovering = $0 }
        .accessibilityLabel(pendingPillLabel)
    }

    /// Full strings, never a number glued to a word, so zero and one read correctly.
    private var pendingLabel: String {
        switch store.pendingCount {
        case 0: return "Sin pendientes"
        case 1: return "1 pendiente"
        case let n: return "\(n) pendientes"
        }
    }

    /// The pill toggles, so the name has to say where the press goes, not where you are.
    private var pendingPillLabel: String {
        tab == .pending
            ? "\(pendingLabel). Volver al día de hoy"
            : "\(pendingLabel). Abrir la bandeja de pendientes"
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if visibleNotes.isEmpty && crumpling.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Metric.gapInner) {
                    ForEach(grouped, id: \.day) { group in
                        if groupsByDay {
                            // One real step below the section title: medium against its
                            // semibold, looser top. Semibold at 1 pt less was the same
                            // voice twice, and three critique lenses tripped on it
                            // independently.
                            Text(DayFormat.long(group.day).uppercased())
                                .font(.system(size: Theme.Size.foot, weight: .medium))
                                .tracking(0.6)
                                // Content-bearing text: tertiary failed contrast over the
                                // translucent material. Tertiary stays for hints only.
                                .foregroundStyle(Theme.inkSecondary)
                                .padding(.leading, Theme.Metric.rowBleed)
                                // The day break stays at least twice the measured ink gap
                                // between notes, or the grouping reads as noise.
                                .padding(.top, group.day == grouped.first?.day ? 12 : 40)
                                .padding(.bottom, 4)
                        }
                        ForEach(group.notes) { note in
                            row(for: note)
                        }
                    }
                }
                .padding(.bottom, 2)
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, new in contentHeight = new }
                    }
                }
            }
            // Shrink-wrap the list so a short day does not leave dead space above the footer,
            // and cap it so a long one scrolls instead of growing the panel without limit.
            .frame(height: min(max(contentHeight, 32), Theme.Metric.listMaxHeight))
            // Outdent the scroll view so a hover row can extend past the content edge without
            // being clipped. Rows and group headers pad it back to the 20 pt edge.
            .padding(.horizontal, -Theme.Metric.rowBleed)
            // Indicators exist only when there is genuinely something to scroll. With
            // .automatic, every list-height change (switching tabs, filtering) flashed a
            // scroller for content that fit entirely on screen.
            .scrollIndicators(contentHeight > Theme.Metric.listMaxHeight ? .automatic : .hidden)
            .mask {
                if contentHeight > Theme.Metric.listMaxHeight {
                    // The overlay scroller draws in the trailing strip; keeping that strip
                    // fully opaque exempts it from the fade, which was cutting the thumb
                    // short and read as a broken scrollbar.
                    ZStack(alignment: .trailing) {
                        LinearGradient(
                            stops: [.init(color: .black, location: 0),
                                    .init(color: .black, location: 0.95),
                                    .init(color: .black.opacity(0.15), location: 1)],
                            startPoint: .top, endPoint: .bottom)
                        Color.black.frame(width: 14)
                    }
                } else {
                    Color.black
                }
            }
            // Changing day rides the same clock as every other content change.
            .animation(reduceMotion ? nil : Theme.Motion.state, value: tab)
            // Starring reorders the list; the row slides to its place so the eye can follow
            // where the note went instead of finding it teleported. Never while searching:
            // there the order changes on every keystroke, and rows sliding around under
            // the typing turned filtering into a light show.
            .animation(reduceMotion || searching ? nil : Theme.Motion.state, value: orderedIDs)
            .animation(reduceMotion ? nil : Theme.Motion.state, value: expandedID)
        }
    }

    @ViewBuilder
    private func row(for note: Note) -> some View {
        if crumpling.contains(where: { $0.id == note.id }) {
            CrumplingRow(note: note) { finishDelete(note) }
        } else {
            NoteRow(
                note: note,
                showDay: groupsByDay,
                isFocused: focus == .note(note.id),
                isExpanded: expandedID == note.id,
                slackConnected: store.slackConnected,
                onToggle: { toggle(note) },
                onStar: { star(note) },
                onDelete: { beginDelete(note) },
                onEdit: { store.update(note, text: $0) },
                onExpand: { expandedID = expandedID == note.id ? nil : note.id },
                onEndEdit: { focus = .note(note.id) },
                onSchedule: { date in
                    store.schedule(note, at: date)
                    announce("Se envía a Slack \(When.label(date))")
                },
                onCancelReminder: {
                    store.cancelReminder(note)
                    announce("Recordatorio cancelado")
                }
            )
            .focused($focus, equals: .note(note.id))
            .onKeyPress(.upArrow) { moveFocus(-1, from: note.id) }
            .onKeyPress(.downArrow) { moveFocus(1, from: note.id) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emptyTitle)
                .font(.system(size: Theme.Size.note, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text(emptyBody)
                .font(.system(size: Theme.Size.label))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
        .accessibilityElement(children: .combine)
    }

    private var emptyTitle: String {
        switch tab {
        case .pending: return "No quedó nada pendiente"
        case .day(let day):
            return day == .today ? "Todavía no anotaste nada hoy" : "Sin notas ese día"
        }
    }

    private var emptyBody: String {
        switch tab {
        case .pending: return "Procesaste todo lo que anotaste."
        case .day(let day):
            return day == .today
                ? "Lo que escribas arriba queda guardado en el día de hoy."
                : "Ese día no quedó nada escrito."
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if let warning = shortcutWarning {
                banner(text: warning, action: nil, actionLabel: nil, isError: true)
            } else if let error = store.writeError {
                banner(text: error, action: nil, actionLabel: nil, isError: true)
            } else if let notice = store.slackNotice {
                // The note is already on disk by the time this appears, so it is news about
                // the reminder, never about the note. It gets a dismiss and no action.
                banner(text: notice, action: nil, actionLabel: nil, isError: true,
                       onDismiss: { store.slackNotice = nil })
            } else if showUndo {
                banner(text: "Nota borrada", action: undo, actionLabel: "Deshacer",
                       isError: false, onDismiss: dismissUndo)
            }

            HStack(spacing: 10) {
                TickStrip(store: store,
                          selection: Binding(
                            get: { selectedDay },
                            set: { tab = .day($0); draft = "" }),
                          onHover: { hoveredDay = $0 })

                Spacer(minLength: 4)

                Text(DayFormat.monthYear(selectedDay))
                    .font(.system(size: Theme.Size.foot))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // The chevron glyph is centred in its target, so the button box has to start
            // left of the margin for the glyph itself to land on the 20 pt edge. Optical
            // alignment, not geometric.
            .padding(.leading, Theme.Metric.inset - 9)
            .padding(.trailing, Theme.Metric.inset)
            .padding(.top, 9)
            .padding(.bottom, 11)
        }
        // The banner appears and leaves rarely, so a short fade is affordable and keeps it
        // from popping the footer down without warning.
        .animation(reduceMotion ? nil : Theme.Motion.state, value: showUndo)
        .animation(reduceMotion ? nil : Theme.Motion.state, value: store.writeError)
        .animation(reduceMotion ? nil : Theme.Motion.state, value: store.slackNotice)
    }

    private func banner(text: String, action: (() -> Void)?, actionLabel: String?,
                        isError: Bool, onDismiss: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: Theme.Size.label))
                .foregroundStyle(isError ? Theme.ink : Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action, let actionLabel {
                Button(actionLabel, action: action).buttonStyle(TextActionStyle())
            }
            // The countdown is a best effort, not a guarantee: if the hover-end event never
            // arrives, the timer holds forever, so the offer always has a way out by hand.
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle().inset(by: -3))
                }
                .buttonStyle(PressScaleStyle())
                // The glyph carries ~6 pt of air inside its box; outdent it so its visible
                // edge lands on the 20 pt margin like everything else on that edge.
                .padding(.trailing, -6)
                .accessibilityLabel("Descartar el aviso")
                .help("Descartar")
            }
        }
        .padding(.horizontal, Theme.Metric.inset)
        .padding(.vertical, 8)
        .background(isError ? Theme.accentFill : Theme.rowHover)
        // Hovering pauses the countdown, so an offer with an action is never yanked away
        // while the user is reaching for it.
        .onHover { hovering in
            undoHovering = hovering
            if hovering { undoTimer?.cancel() } else if showUndo { armUndoTimer() }
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Keyboard

    /// Command shortcuts live on zero-size buttons so the panel keeps a real key map without
    /// a menu bar menu. No unmodified keys here: a bare arrow or a bare ⌘Z is resolved in
    /// performKeyEquivalent before the text field ever sees it, which stole the cursor and the
    /// text undo from the capture field.
    private var shortcuts: some View {
        VStack(spacing: 0) {
            Button("Hoy") { tab = .day(.today); draft = "" }
                .keyboardShortcut("0", modifiers: .command)
            Button("Pendientes") { tab = .pending; draft = "" }
                .keyboardShortcut("p", modifiers: .command)
            Button("Buscar") { focus = .capture }
                .keyboardShortcut("f", modifiers: .command)
            Button("Deshacer borrado") { undo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            // ⌘⏎ has to travel this way: a plain Return belongs to the capture field, and
            // the field's own command handler never sees the command-modified one.
            Button("Enviar a Slack") { scheduling ? closeScheduling() : openScheduling() }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    /// Enter: whatever the line itself says, including a `@cuándo` if it holds one.
    private func save() { file(at: nil) }

    /// `date` is the scheduling row's answer, which overrides anything the line implied.
    private func file(at date: Date?) {
        let remindAt = date ?? reminder
        // With an explicit time the `@cuándo` is stripped either way; without one the line
        // is filed exactly as it was typed.
        let text = date != nil && capture.date != nil ? capture.text : noteText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if store.add(text, remindAt: remindAt) {
            draft = ""
            closeScheduling()
            if tab != .pending { tab = .day(.today) }
            expandedID = nil
            dismissUndo()
            if let remindAt {
                announce("Nota guardada y agendada en Slack para \(When.label(remindAt)).")
            } else {
                announce("Nota guardada. \(pendingLabel).")
            }
        } else if let error = store.writeError {
            // The banner alone is silent for a screen reader, and this is the one moment where
            // the user needs to know their text is still in the field.
            announce(error)
        }
        // On a failed write the draft is deliberately left in the field.
    }

    /// ⌘⏎ opens the scheduling row, prefilled with whatever the line already implies, so the
    /// two ways of setting a time are the same time and not two competing answers.
    private func openScheduling() {
        guard !trimmedDraft.isEmpty else { return }
        if whenDraft.isEmpty {
            whenDraft = capture.spec ?? When.suggestions[2]
        }
        scheduling = true
        focus = .schedule
    }

    private func closeScheduling() {
        scheduling = false
        whenDraft = ""
        if focus == .schedule { focus = .capture }
    }

    private func confirmSchedule() {
        guard let date = scheduleDate else { return }
        file(at: date)
    }

    private func toggle(_ note: Note) {
        // In the pending tab, ticking removes the row: move the keyboard somewhere real
        // before it disappears, or focus dies with it and arrow keys go silent.
        if tab == .pending && !note.done { refocusAfterRemoval(of: note.id) }
        // Ticking sinks the note to the bottom of its day; same transaction rule as the
        // star, so the state change and the slide read as one event.
        withAnimation(reduceMotion || searching ? nil : Theme.Motion.state) {
            _ = store.toggleDone(note)
        }
        announce(note.done ? "Marcada como pendiente" : "Procesada. \(pendingLabel).")
    }

    /// Hands focus to the removed row's successor, else its predecessor, else the field.
    private func refocusAfterRemoval(of id: UUID) {
        guard focus == .note(id) else { return }
        let ids = orderedIDs
        guard let index = ids.firstIndex(of: id) else {
            focus = .capture
            return
        }
        if index + 1 < ids.count {
            focus = .note(ids[index + 1])
        } else if index > 0 {
            focus = .note(ids[index - 1])
        } else {
            focus = .capture
        }
    }

    /// Starring reorders the list, so the state change and the movement have to travel in
    /// one transaction. Mutating the store outside `withAnimation` made the star pop in at
    /// its destination a beat before the row moved, which read as two unrelated events.
    private func star(_ note: Note) {
        withAnimation(reduceMotion || searching ? nil : Theme.Motion.state) {
            _ = store.toggleStar(note)
        }
    }

    private func beginDelete(_ note: Note) {
        if expandedID == note.id { expandedID = nil }
        // The crumpling row is not focusable, so a keyboard delete would strand focus.
        refocusAfterRemoval(of: note.id)
        crumpling.append(note)
    }

    private func finishDelete(_ note: Note) {
        crumpling.removeAll { $0.id == note.id }
        guard store.delete(note) else { return }
        showUndo = true
        armUndoTimer()
        announce("Nota borrada")
    }

    private func undo() {
        guard store.canUndo else { return }
        store.undoDelete()
        undoTimer?.cancel()
        showUndo = false
        announce("Nota restaurada")
    }

    /// The offer expires instead of living forever. The hosting view is built once at launch,
    /// so a banner set during one opening used to reappear on every later one with a live
    /// undo pointing at a note deleted days earlier.
    private func armUndoTimer() {
        undoTimer?.cancel()
        undoTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            // While the pointer rests on the banner, keep checking instead of returning:
            // dying here on a stale hover flag left the banner up forever, because the
            // re-arm only ran from a hover-end event that sometimes never arrives.
            while !Task.isCancelled && undoHovering {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            showUndo = false
            store.clearUndo()
        }
    }

    private func dismissUndo() {
        undoTimer?.cancel()
        showUndo = false
        store.clearUndo()
    }

    private func focusFirstNote() {
        if let first = orderedIDs.first { focus = .note(first) }
    }

    private func moveFocus(_ delta: Int, from id: UUID) -> KeyPress.Result {
        let ids = orderedIDs
        guard let index = ids.firstIndex(of: id) else { return .ignored }
        let next = index + delta
        if next < 0 {
            focus = .capture
            return .handled
        }
        guard ids.indices.contains(next) else { return .ignored }
        focus = .note(ids[next])
        return .handled
    }

    /// Day stepping is bound to the arrows only while the field is empty, so it can never
    /// take the cursor away from text the user is editing.
    private func stepDay(_ delta: Int) {
        guard let date = selectedDay.date,
              let moved = Calendar.current.date(byAdding: .day, value: delta, to: date)
        else { return }
        let next = DayKey(moved)
        if next <= .today {
            tab = .day(next)
        }
    }

    private func resetSession() {
        tab = .day(.today)
        draft = ""
        crumpling.removeAll()
        dismissUndo()
        hoveredDay = nil
        expandedID = nil
        scheduling = false
        whenDraft = ""
        focus = .capture
    }

    /// One step back per press: the scheduling row closes first, then the detail, then the
    /// search text, then the panel.
    private func closeOrCancel() {
        if scheduling {
            closeScheduling()
            return
        }
        if expandedID != nil {
            expandedID = nil
            return
        }
        if !draft.isEmpty {
            draft = ""
            focus = .capture
            return
        }
        dismissUndo()
        onClose()
    }

    /// Routes state changes to VoiceOver, so what the animation says is also spoken.
    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

// MARK: - Small pieces

/// A text action that belongs to the palette. `.link` painted these the system blue, which is
/// the one colour in the app that was never measured and never chosen.
struct TextActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.Size.label, weight: .medium))
            .foregroundStyle(Theme.ink)
            .underline(hovering)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(hovering ? Theme.rowHover : Color.clear))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// The create row lights up on hover like a note row, so it reads as the default action
/// it already is.
struct CreateRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: Theme.Metric.rowRadius, style: .continuous)
                    .fill(hovering ? Theme.rowHover : Color.clear)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// The one separator weight in the app: under the field and above the footer.
struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
