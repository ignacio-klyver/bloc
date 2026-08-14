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

    /// Bumped on every reload, which happens each time the popover opens. The view watches it
    /// to return to today: the controller is built once at launch and lives for weeks, so
    /// without this the popover still opened on yesterday after midnight.
    @Published private(set) var sessionToken = 0

    /// The most recent deletion, kept so ⌘Z can put it back where it was.
    private var lastDeleted: (note: Note, index: Int)?

    let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? Store.defaultFolder()
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
        let current = fingerprint()
        if let last = lastFingerprint, last == current {
            sessionToken &+= 1
            return
        }
        reload()
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

    @discardableResult
    func add(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let day = DayKey.today
        var notes = byDay[day] ?? []
        notes.append(Note(text: trimmed, day: day))
        return commit(notes, to: day)
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
    @discardableResult
    func update(_ note: Note, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return mutate(note) { $0.text = trimmed }
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
        return true
    }

    /// Puts the last deleted note back at its original position.
    @discardableResult
    func undoDelete() -> Bool {
        guard let (note, index) = lastDeleted else { return false }
        var notes = byDay[note.day] ?? []
        notes.insert(note, at: min(index, notes.count))
        lastDeleted = nil
        return commit(notes, to: note.day)
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
