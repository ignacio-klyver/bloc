import Foundation

/// Turns what the user typed into a moment: `@mañana 9:30`, `@lun 15:30`, `@14/8 10:00`,
/// `@18:00`, `@en 2h`.
///
/// The grammar is deliberately small, and it either matches the whole tail or it matches
/// nothing. A half-understood time is worse than no time at all: the note would be filed with
/// words missing and a reminder nobody asked for. When the tail does not parse, the line is
/// returned exactly as it was written.
enum When {

    /// The hour a day gets when it is named without one. Nine in the morning is when a
    /// reminder for "el lunes" is actually useful.
    static let defaultHour = 9

    /// Slack refuses to hold a scheduled message longer than this.
    static let maxHorizon: TimeInterval = 120 * 86_400

    // MARK: - Capture

    /// A captured line, split into the note and the `@cuándo` trailing it.
    struct Capture: Equatable {
        /// The note text with the `@cuándo` taken out. Equal to the raw line when there
        /// was nothing to take out.
        var text: String
        /// The literal spec the user wrote, without the `@`, when one was recognised.
        var spec: String?
        /// The resolved moment. Nil when no spec was recognised.
        var date: Date?
        /// The spec resolved to a moment that has already gone by.
        var past = false
        /// Further out than Slack is willing to hold a message.
        var tooFar = false

        var scheduled: Bool { date != nil && !past && !tooFar }
    }

    /// Splits a captured line into the note and the `@cuándo` that trails it.
    ///
    /// The `@` only counts at the start of a word, so an address inside the note
    /// (`mandar mail a juan@cresium.com`) is never mistaken for a schedule, and the whole
    /// tail after it has to parse: anything left over means the user wrote a mention, not a
    /// time. The spec goes at the end of the line, which is also where it reads best.
    static func capture(_ raw: String, now: Date = Date(),
                        calendar: Calendar = .current) -> Capture {
        let chars = Array(raw)
        var candidates: [Int] = []
        for (index, character) in chars.enumerated() where character == "@" {
            if index == 0 || chars[index - 1].isWhitespace { candidates.append(index) }
        }

        for start in candidates.reversed() {
            let spec = String(chars[(start + 1)...])
            guard let date = date(from: spec, now: now, calendar: calendar) else { continue }
            let text = String(chars[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            // A line that is only a time has no note to send. Fall through and leave the
            // text alone rather than filing an empty note with a reminder attached.
            guard !text.isEmpty else { continue }
            return Capture(text: text,
                           spec: spec.trimmingCharacters(in: .whitespacesAndNewlines),
                           date: date,
                           past: date <= now,
                           tooFar: date.timeIntervalSince(now) > maxHorizon)
        }
        return Capture(text: raw, spec: nil, date: nil)
    }

    // MARK: - Parsing

    /// Resolves a spec written without the `@`. Returns nil unless every word is understood.
    static func date(from spec: String, now: Date = Date(),
                     calendar: Calendar = .current) -> Date? {
        var words = normalise(spec)
        guard !words.isEmpty else { return nil }

        if let date = relative(&words, now: now) {
            return words.isEmpty ? date : nil
        }

        // A day, a time, or both, always in that order.
        let slot = daySlot(&words, now: now, calendar: calendar)
        let time = clockTime(&words)
        guard words.isEmpty, slot != nil || time != nil else { return nil }

        return resolve(slot: slot, time: time, now: now, calendar: calendar)
    }

    /// Words that carry no meaning here, so `mañana a las 9` and `el lunes` both work.
    private static let filler: Set<String> = [
        "a", "al", "la", "las", "el", "los", "de", "del",
        "que", "viene", "proximo", "proxima", "este", "esta"
    ]

    /// Lowercased, unaccented and split, so `MAÑANA` and `manana` are the same word.
    private static func normalise(_ spec: String) -> [String] {
        spec.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !filler.contains($0) }
    }

    // MARK: Relative

    /// `en 2h`, `en 30 min`, `en 3 dias`, `en 2` (horas).
    private static func relative(_ words: inout [String], now: Date) -> Date? {
        guard words.first == "en", words.count >= 2 else { return nil }

        // The number and its unit may be glued or apart; joining settles both at once.
        let glued = words.dropFirst().joined()
        let digits = glued.prefix(while: \.isNumber)
        guard let amount = Int(digits), amount > 0 else { return nil }

        let seconds: Int
        switch String(glued.dropFirst(digits.count)) {
        case "m", "min", "mins", "minuto", "minutos": seconds = amount * 60
        case "", "h", "hs", "hora", "horas":          seconds = amount * 3_600
        case "d", "dia", "dias":                      seconds = amount * 86_400
        case "sem", "semana", "semanas":              seconds = amount * 604_800
        default: return nil
        }

        words.removeAll()
        return now.addingTimeInterval(TimeInterval(seconds))
    }

    // MARK: Day

    /// A calendar day plus how far to jump if the resolved moment turns out to be in the
    /// past. A weekday jumps a week, an implied day jumps to tomorrow, and a day the user
    /// named outright never jumps: `@hoy 8:00` at ten in the morning is a mistake worth
    /// reporting, not one worth silently rewriting.
    private struct Slot {
        var year: Int, month: Int, day: Int
        var roll: Int
    }

    private static func slot(_ date: Date, calendar: Calendar, roll: Int) -> Slot {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return Slot(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0, roll: roll)
    }

    private static let weekdays: [String: Int] = [
        "domingo": 1, "dom": 1,
        "lunes": 2, "lun": 2,
        "martes": 3, "mar": 3,
        "miercoles": 4, "mie": 4, "mier": 4,
        "jueves": 5, "jue": 5,
        "viernes": 6, "vie": 6,
        "sabado": 7, "sab": 7,
    ]

    private static func daySlot(_ words: inout [String], now: Date,
                                calendar: Calendar) -> Slot? {
        guard let first = words.first else { return nil }

        switch first {
        case "hoy":
            words.removeFirst()
            return slot(now, calendar: calendar, roll: 0)
        case "manana":
            words.removeFirst()
            let date = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return slot(date, calendar: calendar, roll: 0)
        case "pasado":
            // "pasado mañana", and "pasado" on its own means the same thing.
            words.removeFirst(words.count > 1 && words[1] == "manana" ? 2 : 1)
            let date = calendar.date(byAdding: .day, value: 2, to: now) ?? now
            return slot(date, calendar: calendar, roll: 0)
        default:
            break
        }

        if let target = weekdays[first] {
            words.removeFirst()
            let current = calendar.component(.weekday, from: now)
            let delta = (target - current + 7) % 7
            let date = calendar.date(byAdding: .day, value: delta, to: now) ?? now
            // Landing on today is allowed: `@lunes 18:00` on a Monday morning means today.
            // If the hour has already gone by, the roll moves it a full week.
            return slot(date, calendar: calendar, roll: 7)
        }

        if let numeric = numericDay(first, now: now, calendar: calendar) {
            words.removeFirst()
            return numeric
        }
        return nil
    }

    /// `14/8`, `14-8`, `14/8/2026`, `14/8/26`, `2026-08-14`.
    private static func numericDay(_ word: String, now: Date, calendar: Calendar) -> Slot? {
        let parts = word.split(whereSeparator: { $0 == "/" || $0 == "-" }).map(String.init)
        guard (2...3).contains(parts.count), parts.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        let numbers = parts.compactMap(Int.init)

        var year: Int, month: Int, day: Int
        switch numbers.count {
        case 3 where parts[0].count == 4:
            (year, month, day) = (numbers[0], numbers[1], numbers[2])
        case 3:
            (day, month) = (numbers[0], numbers[1])
            year = numbers[2] < 100 ? 2_000 + numbers[2] : numbers[2]
        default:
            (day, month) = (numbers[0], numbers[1])
            year = calendar.component(.year, from: now)
        }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }

        // A bare day and month always means the next time that date comes around, so
        // `@25/12` written on the 30th of December lands next year rather than in the past.
        if numbers.count == 2,
           let candidate = calendar.date(from: DateComponents(year: year, month: month, day: day)),
           candidate < calendar.startOfDay(for: now) {
            year += 1
        }
        return Slot(year: year, month: month, day: day, roll: 0)
    }

    // MARK: Time

    /// `9`, `9:30`, `9.30`, `9hs`, `18:00`, `9am`, `9:30 pm`.
    private static func clockTime(_ words: inout [String]) -> (hour: Int, minute: Int)? {
        guard let first = words.first else { return nil }

        var body = first
        var meridiem: String?
        for tag in ["am", "pm"] where body.hasSuffix(tag) {
            meridiem = tag
            body = String(body.dropLast(tag.count))
        }
        for tag in ["hs", "h"] where body.hasSuffix(tag)
            && !body.dropLast(tag.count).isEmpty
            && body.dropLast(tag.count).allSatisfy(\.isNumber) {
            body = String(body.dropLast(tag.count))
        }

        let parts = body.split(whereSeparator: { $0 == ":" || $0 == "." }).map(String.init)
        guard (1...2).contains(parts.count),
              (1...2).contains(parts[0].count),
              let value = Int(parts[0]) else { return nil }

        var hour = value
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let m = Int(parts[1]), (0..<60).contains(m) else {
                return nil
            }
            minute = m
        }

        // A meridiem written as its own word: `9 pm`.
        var consumed = 1
        if meridiem == nil, words.count > 1, words[1] == "am" || words[1] == "pm" {
            meridiem = words[1]
            consumed = 2
        }

        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
        }
        guard (0...23).contains(hour) else { return nil }

        words.removeFirst(consumed)
        return (hour, minute)
    }

    private static func resolve(slot: Slot?, time: (hour: Int, minute: Int)?,
                                now: Date, calendar: Calendar) -> Date? {
        // No day named means today, and a time that already went by means tomorrow.
        let base = slot ?? self.slot(now, calendar: calendar, roll: 1)
        let components = DateComponents(year: base.year, month: base.month, day: base.day,
                                        hour: time?.hour ?? defaultHour,
                                        minute: time?.minute ?? 0)
        guard var date = calendar.date(from: components) else { return nil }
        if date <= now, base.roll > 0,
           let rolled = calendar.date(byAdding: .day, value: base.roll, to: date) {
            date = rolled
        }
        return date
    }

    // MARK: - Display

    /// `hoy 09:30` · `mañana 09:30` · `viernes 09:30` · `15 ago 09:30`
    static func label(_ date: Date, now: Date = Date(),
                      calendar: Calendar = .current) -> String {
        let day = DayKey(date, calendar: calendar)
        let time = clock(date, calendar: calendar)

        if day == DayKey(now, calendar: calendar) { return "hoy \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           day == DayKey(tomorrow, calendar: calendar) { return "mañana \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           day == DayKey(yesterday, calendar: calendar) { return "ayer \(time)" }

        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        if (2...6).contains(days) { return "\(DayFormat.weekday(day)) \(time)" }
        return "\(DayFormat.short(day)) \(time)"
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// The suggestions offered above the field, in the order a reminder is usually wanted.
    static let suggestions = ["en 1 h", "hoy 18:00", "mañana 9:00", "lunes 9:00"]
}
