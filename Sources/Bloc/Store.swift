import Foundation
import SwiftUI

/// Owns every note and the markdown files behind them.
///
/// The files are the durable artifact: one `YYYY-MM-DD.md` per day in the notes folder.
/// A mutation updates memory first, then rewrites that day's file atomically. If the write
/// fails, `writeError` is published and the caller keeps whatever the user typed.
@MainActor
final class Store: ObservableObject {

    @Published private(set) var byDay: [DayKey: [Note]] = [:]
    @Published private(set) var days: [DayKey] = []
    @Published var writeError: String?

    /// What happened with Slack the last time a reminder was handed over. Nil while there is
    /// nothing to say. Kept apart from `writeError`, which is about the note itself: the note
    /// is always saved first, so a Slack failure is news, never data loss.
    @Published var slackNotice: String?

    /// Whether reminders can be handed over at all. Read once per session rather than per
    /// note, so a capture never waits on the filesystem.
    private(set) var slack: SlackConfig?

    var slackConnected: Bool { slack != nil }

    /// Bumped on every reload, which happens each time the popover opens. The view watches it
    /// to return to today: the controller is built once at launch and lives for weeks, so
    /// without this the popover still opened on yesterday after midnight.
    @Published private(set) var sessionToken = 0

    /// The most recent deletion, kept so ⌘Z can put it back where it was.
    private var lastDeleted: (note: Note, index: Int)?

    let folder: URL

    /// Where the workspace comes from. Only `.connected` ever touches the network.
    enum SlackAccess {
        /// The workspace configured on disk. What the app runs on.
        case connected
        /// No workspace at all: the self-test has no business talking to a real one.
        case off
        /// A workspace that exists only so an offscreen render can show the states that
        /// depend on one. Nothing is ever sent.
        case pretend(SlackConfig)
    }

    private let access: SlackAccess

    /// True only when a real workspace is behind it, so a render can look connected without
    /// a request ever leaving the machine.
    private var live: Bool {
        if case .connected = access { return true }
        return false
    }

    init(folder: URL? = nil, slack access: SlackAccess = .connected) {
        self.folder = folder ?? Store.defaultFolder()
        self.access = access
        switch access {
        case .connected: self.slack = SlackStore.load()
        case .off: self.slack = nil
        case .pretend(let config): self.slack = config
        }
        reload()
    }

    /// New installs write to ~/Documents/Bloc. Installs that predate that name keep using
    /// ~/Documents/notas: if that folder already exists it wins, so nothing is migrated and
    /// no notes are left behind in a folder the app stopped looking at.
    private static func defaultFolder() -> URL {
        let documents = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
        let legacy = documents.appendingPathComponent("notas", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return legacy
        }
        return documents.appendingPathComponent("Bloc", isDirectory: true)
    }

    // MARK: - Reading

    /// Cheapest possible check that the folder still matches what is in memory: the newest
    /// modification date and the file count, both from `stat`, with nothing read or parsed.
    private var lastFingerprint: (newest: Date, count: Int)?

    private func fingerprint() -> (newest: Date, count: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var newest = Date.distantPast
        var count = 0
        for url in files where url.pathExtension == "md" {
            count += 1
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, date > newest {
                newest = date
            }
        }
        return (newest, count)
    }

    /// Called every time the popover opens. Always advances the session so the view can return
    /// to today, but only re-reads the disk when something actually changed out there.
    /// Parsing every file on each open was work done before the caret appeared.
    func openSession() {
        // Cheap, and it is the only moment the app can notice that Slack was connected from
        // the command line while the panel was closed.
        if live { slack = SlackStore.load() }
        slackNotice = nil

        let current = fingerprint()
        if let last = lastFingerprint, last == current {
            sessionToken &+= 1
        } else {
            reload()
        }
        retryPending()
    }

    /// Picks up the reminders that never made it to Slack: the app was quit mid-request, the
    /// network was down, the workspace was connected only afterwards. Without this a note
    /// that failed once would sit there with its hour and never be sent, and the only sign
    /// would be a badge nobody reads twice.
    private func retryPending() {
        guard live, slack != nil else { return }
        let now = Date()
        for note in byDay.values.flatMap({ $0 })
        where note.slackID == nil && (note.remindAt.map { $0 > now } ?? false) {
            handOver(note)
        }
    }

    func reload() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var loaded: [DayKey: [Note]] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files where file.hasSuffix(".md") {
            let stem = String(file.dropLast(3))
            guard let day = DayKey(fileName: stem) else { continue }
            let url = folder.appendingPathComponent(file)
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            loaded[day] = NoteMarkdown.parse(body, day: day)
        }

        // Today always exists as a tab, even before anything is written to it.
        if loaded[.today] == nil { loaded[.today] = [] }

        byDay = loaded
        days = loaded.keys.sorted()
        lastFingerprint = fingerprint()
        sessionToken &+= 1
    }

    /// Starred notes lead their day; everything else keeps its written order. The promotion
    /// is display-only: the markdown file stays in capture order, so the journal on disk
    /// remains chronological and the star can be taken back without reshuffling the file.
    private func promoted(_ notes: [Note]) -> [Note] {
        notes.filter(\.starred) + notes.filter { !$0.starred }
    }

    /// Display order within a day: what still needs attention first, what is already
    /// processed sunk to the bottom, and inside each block the starred ones lead.
    /// [pending starred] [pending] [done starred] [done].
    private func displayOrder(_ notes: [Note]) -> [Note] {
        promoted(notes.filter { !$0.done }) + promoted(notes.filter(\.done))
    }

    func notes(on day: DayKey) -> [Note] { displayOrder(byDay[day] ?? []) }

    /// Every unprocessed note, newest day first, starred leading within each day. Sorting
    /// starred above the day order looked important but scrambled the day grouping: an old
    /// starred note dragged its whole day above today.
    var pending: [Note] {
        days.sorted(by: >).flatMap { day in
            promoted((byDay[day] ?? []).filter { !$0.done })
        }
    }

    var pendingCount: Int { pending.count }

    /// Note count per day, used for the tick heights.
    func count(on day: DayKey) -> Int { byDay[day]?.count ?? 0 }

    /// Whether a day still holds unprocessed notes, used to tint its tick.
    func hasPending(on day: DayKey) -> Bool {
        (byDay[day] ?? []).contains { !$0.done }
    }

    func search(_ query: String) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return days.sorted(by: >).flatMap { day in
            displayOrder((byDay[day] ?? []).filter { $0.text.lowercased().contains(q) })
        }
    }

    // MARK: - Writing

    /// Files a note, and when a time came with it, hands that note to Slack to deliver.
    ///
    /// The file is written first and the network comes after: capture is the promise this
    /// app makes, and it is never made to wait on a request that might take a second or
    /// fail outright. A reminder that could not be handed over leaves the note on disk with
    /// its hour and no Slack id, which is what the row then says out loud.
    @discardableResult
    func add(_ text: String, remindAt: Date? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let day = DayKey.today
        var notes = byDay[day] ?? []
        let note = Note(text: trimmed, day: day, remindAt: remindAt)
        notes.append(note)
        guard commit(notes, to: day) else { return false }
        if remindAt != nil { handOver(note) }
        return true
    }

    @discardableResult
    func toggleDone(_ note: Note) -> Bool {
        mutate(note) { $0.done.toggle() }
    }

    @discardableResult
    func toggleStar(_ note: Note) -> Bool {
        mutate(note) { $0.starred.toggle() }
    }

    /// Empty text is refused rather than treated as a delete. A note vanishing from the editor
    /// with no crumple, no banner and no announcement reads as data loss, so deleting stays
    /// an explicit action.
    ///
    /// Editing a note that is still waiting to be sent rewrites the Slack message too: the
    /// old one is called off and the new text takes its place at the same hour. Leaving the
    /// original queued would deliver a version of the note the user already corrected.
    @discardableResult
    func update(_ note: Note, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note.text else { return false }
        guard mutate(note, { $0.text = trimmed }) else { return false }

        if note.isUpcoming(), let updated = find(note.id) {
            callOff(note)
            handOver(updated)
        }
        return true
    }

    @discardableResult
    func delete(_ note: Note) -> Bool {
        guard var notes = byDay[note.day],
              let index = notes.firstIndex(where: { $0.id == note.id }) else { return false }
        let snapshot = (note: notes[index], index: index)
        notes.remove(at: index)
        // Arm the undo only once the write succeeded. Arming it first left the note both in
        // memory and marked as deleted, so the next undo inserted a duplicate.
        guard commit(notes, to: note.day) else { return false }
        lastDeleted = snapshot
        // The note is gone, so the message it was going to send has to go with it. The undo
        // hands it back to Slack.
        callOff(snapshot.note)
        return true
    }

    /// Puts the last deleted note back at its original position.
    @discardableResult
    func undoDelete() -> Bool {
        guard let (note, index) = lastDeleted else { return false }
        var notes = byDay[note.day] ?? []
        var restored = note
        // The old Slack id died with the cancellation, so the reminder is queued again from
        // scratch rather than restored with a handle that no longer resolves.
        restored.slackID = nil
        notes.insert(restored, at: min(index, notes.count))
        lastDeleted = nil
        guard commit(notes, to: note.day) else { return false }
        if restored.isUpcoming() { handOver(restored) }
        return true
    }

    /// Calls off a reminder without touching the note. The explicit way out for a note that
    /// is still going to be written, but no longer needs to be announced.
    @discardableResult
    func cancelReminder(_ note: Note) -> Bool {
        guard note.remindAt != nil else { return false }
        callOff(note)
        return mutate(note) { $0.remindAt = nil; $0.slackID = nil }
    }

    /// Attaches a reminder to a note that was captured without one.
    @discardableResult
    func schedule(_ note: Note, at date: Date) -> Bool {
        callOff(note)
        guard mutate(note, { $0.remindAt = date; $0.slackID = nil }),
              let updated = find(note.id) else { return false }
        handOver(updated)
        return true
    }

    // MARK: - Slack

    private func find(_ id: UUID) -> Note? {
        byDay.values.flatMap { $0 }.first { $0.id == id }
    }

    /// Hands a note's reminder to Slack and writes the id it gives back into the file.
    ///
    /// Slack holds the schedule from here on: the message is delivered at its hour whether
    /// or not this Mac is awake. That is the whole reason the reminder is not a local timer.
    private func handOver(_ note: Note) {
        guard live, let remindAt = note.remindAt else { return }
        guard let config = slack else {
            slackNotice = "Guardada con la hora, pero Slack no está conectado. "
                + "Corré Bloc --slack-connect."
            return
        }
        guard remindAt > Date() else {
            slackNotice = "Guardada, pero esa hora ya pasó: no la agendé."
            return
        }

        let text = note.text
        let id = note.id
        Task { @MainActor in
            do {
                let scheduled = try await SlackAPI.schedule(text: text, at: remindAt,
                                                            config: config)
                // The note may have been deleted or edited while the request was in flight.
                guard let current = find(id), current.remindAt == remindAt else { return }
                _ = mutate(current) { $0.slackID = scheduled }
                slackNotice = nil
            } catch {
                slackNotice = "No se pudo agendar en Slack: \(error.localizedDescription)"
            }
        }
    }

    /// Best effort: the note has already stopped existing locally, so a failure here is
    /// worth reporting but never worth blocking or undoing anything for.
    private func callOff(_ note: Note) {
        guard live, let config = slack, let scheduled = note.slackID,
              note.isUpcoming() else { return }
        Task { @MainActor in
            do {
                try await SlackAPI.cancel(id: scheduled, config: config)
            } catch SlackError.api("invalid_scheduled_message_id") {
                // Already delivered or already gone. Nothing to report.
            } catch {
                slackNotice = "No pude cancelar el mensaje en Slack: "
                    + error.localizedDescription
            }
        }
    }

    /// Disarms the undo. Called when the offer expires or the user moves on, so a reflex ⌘Z
    /// days later cannot resurrect a note into an old day's file.
    func clearUndo() {
        lastDeleted = nil
    }

    var canUndo: Bool { lastDeleted != nil }

    // MARK: - Plumbing

    private func mutate(_ note: Note, _ change: (inout Note) -> Void) -> Bool {
        guard var notes = byDay[note.day],
              let index = notes.firstIndex(where: { $0.id == note.id }) else { return false }
        change(&notes[index])
        return commit(notes, to: note.day)
    }

    /// Updates memory, then writes the day's file. On failure the in-memory change is rolled
    /// back so what is on screen always matches what is on disk.
    private func commit(_ notes: [Note], to day: DayKey) -> Bool {
        let previous = byDay[day]
        byDay[day] = notes
        if !days.contains(day) { days = byDay.keys.sorted() }

        do {
            let url = folder.appendingPathComponent("\(day.fileName).md")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try NoteMarkdown.render(notes).write(to: url, atomically: true, encoding: .utf8)
            writeError = nil
            return true
        } catch {
            byDay[day] = previous
            writeError = "No se pudo guardar. La nota sigue acá, probá de nuevo."
            return false
        }
    }
}
