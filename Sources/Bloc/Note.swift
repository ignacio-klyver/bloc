import Foundation

/// A calendar day, used as both the file name and the tab identity.
struct DayKey: Hashable, Comparable, Identifiable, Sendable {
    let year: Int, month: Int, day: Int

    var id: String { fileName }
    /// `2026-08-10`
    var fileName: String { String(format: "%04d-%02d-%02d", year, month, day) }

    init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    init?(fileName: String) {
        let parts = fileName.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    static var today: DayKey { DayKey(Date()) }

    var date: Date? {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func < (a: DayKey, b: DayKey) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// One captured note. The `id` lives only in memory; the markdown file is the source of truth
/// for text, state, star and reminder, and is rewritten in full whenever the day changes.
struct Note: Identifiable, Hashable, Sendable {
    let id = UUID()
    var text: String
    var done: Bool = false
    var starred: Bool = false
    var day: DayKey
    /// When this note is due to arrive as a Slack message. Nil for a plain note.
    var remindAt: Date?
    /// Slack's id for the scheduled message. Absent while the note is waiting to be handed
    /// over, and absent for good if the hand-off failed, which is exactly the difference
    /// between "va a llegar" and "no se agendó".
    var slackID: String?

    /// Still ahead, so it can still be called off.
    func isUpcoming(_ now: Date = Date()) -> Bool {
        guard let remindAt else { return false }
        return remindAt > now
    }

    static func == (a: Note, b: Note) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Markdown

enum NoteMarkdown {

    /// The indent that marks a continuation line. Fixed width so an empty line inside a note
    /// still has something to be recognised by.
    private static let indent = "      "

    /// Opens the line that carries the Slack reminder. Indented like a continuation so a
    /// reader's eye groups it with its note, and marked so the parser never mistakes it for
    /// one of the user's own lines.
    private static let reminderMarker = "↳ slack "

    /// The reminder timestamp, written in local time. These files are read by a person, in
    /// the timezone they were written in; an ISO instant with an offset would be correct and
    /// unreadable.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// Renders a day's notes as the file body.
    ///
    ///     - [ ] !destacada y pendiente
    ///     - [ ] pendiente
    ///           segunda línea de la misma nota
    ///     - [ ] avisarle a Marina
    ///           ↳ slack 2026-08-15 09:30 · Q1298393284
    ///     - [x] procesada
    ///
    /// A note whose own text starts with `!` or `\` gets that character escaped with a
    /// backslash, so the star marker can never be confused with the user's words, and the
    /// same protection covers a continuation line that happens to begin with the reminder
    /// marker.
    static func render(_ notes: [Note]) -> String {
        var out = ""
        for note in notes {
            let box = note.done ? "x" : " "
            let star = note.starred ? "!" : ""
            let lines = note.text.components(separatedBy: "\n")
            out += "- [\(box)] \(star)\(escape(lines.first ?? ""))\n"
            for continuation in lines.dropFirst() {
                out += indent + escapeMarker(continuation) + "\n"
            }
            if let remindAt = note.remindAt {
                let id = note.slackID.map { " · \($0)" } ?? ""
                out += indent + reminderMarker + stamp.string(from: remindAt) + id + "\n"
            }
        }
        return out
    }

    /// Protects a user line that would otherwise read as the reminder marker.
    private static func escapeMarker(_ line: String) -> String {
        let body = line.drop(while: { $0 == " " })
        return body.hasPrefix(reminderMarker) || body.hasPrefix("\\" + reminderMarker)
            ? "\\" + line
            : line
    }

    /// Protects a leading `!` or `\` so it survives the round trip as literal text.
    private static func escape(_ text: String) -> String {
        (text.hasPrefix("!") || text.hasPrefix("\\")) ? "\\" + text : text
    }

    private static func unescape(_ text: String) -> String {
        text.hasPrefix("\\") ? String(text.dropFirst()) : text
    }

    /// Parses a day file back into notes. Anything that is not a task line and not a
    /// continuation of one is ignored, so hand-editing the file never destroys notes.
    static func parse(_ body: String, day: DayKey) -> [Note] {
        var notes: [Note] = []
        for rawLine in body.components(separatedBy: "\n") {
            if let note = taskLine(rawLine, day: day) {
                notes.append(note)
                continue
            }
            guard !notes.isEmpty else { continue }

            // The reminder line belongs to the note above it and is not part of its text.
            // Checked before the continuation rules, which would otherwise swallow it.
            if rawLine.hasPrefix(" "),
               let reminder = reminderLine(rawLine.drop(while: { $0 == " " })) {
                notes[notes.count - 1].remindAt = reminder.date
                notes[notes.count - 1].slackID = reminder.id
                continue
            }

            // Our own indent marks a continuation, including a deliberately empty line.
            if rawLine.hasPrefix(indent) {
                notes[notes.count - 1].text +=
                    "\n" + unescapeMarker(String(rawLine.dropFirst(indent.count)))
                continue
            }
            // Looser rule for files edited by hand: any indented, non-empty line continues
            // the note above it.
            if rawLine.hasPrefix(" "), !rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                notes[notes.count - 1].text +=
                    "\n" + unescapeMarker(String(rawLine.drop(while: { $0 == " " })))
            }
        }
        return notes
    }

    /// `↳ slack 2026-08-15 09:30 · Q1298393284`, with the id still absent while the note is
    /// on its way to Slack. A line that starts with the marker but carries an unreadable
    /// date is dropped rather than guessed at: a wrong hour is worse than no reminder.
    private static func reminderLine(_ body: some StringProtocol) -> (date: Date, id: String?)? {
        guard body.hasPrefix(reminderMarker) else { return nil }
        let rest = body.dropFirst(reminderMarker.count)
            .trimmingCharacters(in: .whitespaces)

        let parts = rest.components(separatedBy: " · ")
        guard let date = stamp.date(from: parts[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let id = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : nil
        return (date, id?.isEmpty == false ? id : nil)
    }

    /// Undoes `escapeMarker`. Only a backslash guarding the marker is removed, so a
    /// continuation that legitimately starts with `\` is left as the user wrote it.
    private static func unescapeMarker(_ line: String) -> String {
        guard line.hasPrefix("\\") else { return line }
        let rest = line.dropFirst()
        return rest.drop(while: { $0 == " " }).hasPrefix(reminderMarker) ? String(rest) : line
    }

    private static func taskLine(_ line: String, day: DayKey) -> Note? {
        let markers: [(String, Bool)] = [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)]
        for (prefix, done) in markers where line.hasPrefix(prefix) {
            var text = String(line.dropFirst(prefix.count))
            var starred = false
            // Only an unescaped `!` is the star marker.
            if text.hasPrefix("!") {
                starred = true
                text.removeFirst()
            }
            return Note(text: unescape(text), done: done, starred: starred, day: day)
        }
        return nil
    }
}
