import Foundation

/// Exercises the store against a throwaway folder and checks what actually lands on disk.
/// Run with `Bloc --selftest`. Exits non-zero if anything fails.
@MainActor
enum SelfTest {

    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("  ok    \(label)")
        } else {
            print("  FALLA \(label)")
            failures.append(label)
        }
    }

    static func run() -> Int32 {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bloc-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = Store(folder: folder, slack: .off)
        let today = DayKey.today
        let file = folder.appendingPathComponent("\(today.fileName).md")

        func body() -> String {
            (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }

        print("escritura")
        check(store.add("preguntar a Max lo del CUIT"), "add devuelve true")
        check(store.notes(on: today).count == 1, "la nota queda en memoria")
        check(body() == "- [ ] preguntar a Max lo del CUIT\n", "el archivo tiene la línea de tarea")

        print("multilínea")
        store.add("primera\nsegunda")
        check(body().contains("- [ ] primera\n      segunda\n"), "la continuación va indentada")

        print("ida y vuelta")
        let reparsed = NoteMarkdown.parse(body(), day: today)
        check(reparsed.count == 2, "vuelven a parsear 2 notas")
        check(reparsed[1].text == "primera\nsegunda", "la multilínea sobrevive el round trip")

        print("estado")
        let first = store.notes(on: today)[0]
        store.toggleDone(first)
        check(body().hasPrefix("- [x] "), "tildar escribe [x]")
        check(store.pendingCount == 1, "el contador de pendientes baja")

        // By content, not by display index: sinking the just-ticked note reordered the
        // list and position 1 stopped meaning "the multiline note".
        if let multi = store.notes(on: today).first(where: { $0.text.hasPrefix("primera") }) {
            store.toggleStar(multi)
        }
        check(body().contains("- [ ] !primera"), "destacar escribe el signo")
        check(store.notes(on: today).first?.starred == true, "la destacada sube al tope de su día")
        check(store.notes(on: today).last?.done == true, "la tildada se hunde al fondo de su día")
        check(body().hasPrefix("- [x] "), "el archivo conserva el orden de escritura")

        print("orden de pendientes")
        store.add("sin destacar")
        let pending = store.pending
        check(pending.first?.starred == true, "las destacadas van primero")

        print("borrado y deshacer")
        let target = store.notes(on: today)[0]
        let before = store.notes(on: today).count
        store.delete(target)
        check(store.notes(on: today).count == before - 1, "borrar saca la nota")
        check(store.canUndo, "queda algo para deshacer")
        store.undoDelete()
        check(store.notes(on: today).count == before, "deshacer la devuelve")
        check(store.notes(on: today)[0].text == target.text, "vuelve a su posición original")

        print("vacíos")
        check(!store.add("   \n  "), "no guarda una nota en blanco")

        // --- casos que encontró el review ---

        print("markdown: el signo de admiración es texto, no marcador")
        let bang = Store(folder: folder.appendingPathComponent("bang"), slack: .off)
        bang.add("!urgente: llamar a Marina")
        let bangBack = bang.notes(on: today)
        check(bangBack.first?.text == "!urgente: llamar a Marina",
              "el «!» inicial sobrevive el round trip")
        check(bangBack.first?.starred == false,
              "una nota que empieza con «!» no aparece destacada sola")
        let bangFresh = Store(folder: folder.appendingPathComponent("bang"), slack: .off)
        check(bangFresh.notes(on: today).first?.text == "!urgente: llamar a Marina",
              "y también sobrevive releyendo el disco")

        print("markdown: barra invertida inicial")
        let slash = Store(folder: folder.appendingPathComponent("slash"), slack: .off)
        slash.add("\\ruta\\del\\archivo")
        check(Store(folder: folder.appendingPathComponent("slash"), slack: .off)
                .notes(on: today).first?.text == "\\ruta\\del\\archivo",
              "una nota que empieza con «\\» vuelve igual")

        print("markdown: línea en blanco en el medio")
        let blank = Store(folder: folder.appendingPathComponent("blank"), slack: .off)
        blank.add("reunión con Max\n\nllamar a Marina")
        check(Store(folder: folder.appendingPathComponent("blank"), slack: .off)
                .notes(on: today).first?.text == "reunión con Max\n\nllamar a Marina",
              "la línea vacía del medio no se pierde")

        print("markdown: una nota destacada sigue funcionando")
        let star = Store(folder: folder.appendingPathComponent("star"), slack: .off)
        star.add("coordinar la prueba")
        star.toggleStar(star.notes(on: today)[0])
        let starFresh = Store(folder: folder.appendingPathComponent("star"), slack: .off)
        check(starFresh.notes(on: today).first?.starred == true, "la estrella sobrevive")
        check(starFresh.notes(on: today).first?.text == "coordinar la prueba",
              "y no se come una letra del texto")

        print("editar a vacío no borra")
        let edit = Store(folder: folder.appendingPathComponent("edit"), slack: .off)
        edit.add("no me borres")
        let victim = edit.notes(on: today)[0]
        check(!edit.update(victim, text: "   "), "vaciar el texto devuelve false")
        check(edit.notes(on: today).count == 1, "y la nota sigue estando")
        check(!edit.canUndo, "sin armar un deshacer fantasma")

        print("deshacer se puede desarmar")
        let dis = Store(folder: folder.appendingPathComponent("dis"), slack: .off)
        dis.add("efímera")
        dis.delete(dis.notes(on: today)[0])
        check(dis.canUndo, "después de borrar hay deshacer")
        dis.clearUndo()
        check(!dis.canUndo, "clearUndo lo desarma")
        check(!dis.undoDelete(), "y un deshacer posterior no resucita nada")

        print("búsqueda")
        check(store.search("cuit").count == 1, "encuentra sin importar mayúsculas")
        check(store.search("").isEmpty, "una búsqueda vacía no devuelve todo")

        print("recarga desde disco")
        let fresh = Store(folder: folder, slack: .off)
        check(fresh.notes(on: today).count == store.notes(on: today).count,
              "releer el disco da la misma cantidad")

        runWhen()
        runReminderMarkdown(in: folder)

        print("")
        if failures.isEmpty {
            print("todo verde (\(folder.lastPathComponent))")
            return 0
        }
        print("\(failures.count) fallas: \(failures.joined(separator: ", "))")
        return 1
    }

    // MARK: - El «@cuándo»

    /// Every case runs against a frozen clock: a parser tested against the real one passes
    /// in the morning and fails after six in the evening.
    private static func runWhen() {
        let calendar = Calendar.current
        // Viernes 14 de agosto de 2026, diez de la mañana.
        guard let now = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 14, hour: 10, minute: 0)) else {
            check(false, "no se pudo construir la fecha de referencia")
            return
        }

        func parse(_ raw: String) -> When.Capture {
            When.capture(raw, now: now, calendar: calendar)
        }
        /// `2026-08-15 09:30`
        func stamp(_ date: Date?) -> String {
            guard let date else { return "—" }
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return String(format: "%04d-%02d-%02d %02d:%02d",
                          c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        }

        print("cuándo: lo que se entiende")
        let tomorrow = parse("avisarle a Marina @mañana 9:30")
        check(tomorrow.text == "avisarle a Marina", "el @cuándo sale del texto")
        check(tomorrow.spec == "mañana 9:30", "y queda guardado como se escribió")
        check(stamp(tomorrow.date) == "2026-08-15 09:30", "mañana 9:30 resuelve bien")
        check(tomorrow.scheduled, "y queda lista para agendar")

        check(stamp(parse("x @hoy 18:00").date) == "2026-08-14 18:00", "hoy con hora")
        check(stamp(parse("x @18:00").date) == "2026-08-14 18:00", "una hora sola es hoy")
        check(stamp(parse("x @8:00").date) == "2026-08-15 08:00",
              "una hora que ya pasó cae mañana")
        check(stamp(parse("x @lunes").date) == "2026-08-17 09:00",
              "un día sin hora usa las nueve")
        check(stamp(parse("x @vie 15:30").date) == "2026-08-14 15:30",
              "el día de hoy nombrado por su nombre sigue siendo hoy")
        check(stamp(parse("x @vie 8:00").date) == "2026-08-21 08:00",
              "salvo que la hora ya haya pasado, y ahí es la semana que viene")
        check(stamp(parse("x @pasado mañana 11").date) == "2026-08-16 11:00", "pasado mañana")
        check(stamp(parse("x @25/12 10:00").date) == "2026-12-25 10:00", "fecha con barras")
        check(stamp(parse("x @1/1 10:00").date) == "2027-01-01 10:00",
              "una fecha que ya pasó este año cae en el que viene")
        check(stamp(parse("x @2026-09-01 7:15").date) == "2026-09-01 07:15", "fecha ISO")
        check(stamp(parse("x @en 2h").date) == "2026-08-14 12:00", "en 2h")
        check(stamp(parse("x @en 30 min").date) == "2026-08-14 10:30", "en 30 min")
        check(stamp(parse("x @en 3 dias").date) == "2026-08-17 10:00", "en 3 días")
        check(stamp(parse("x @mañana a las 9").date) == "2026-08-15 09:00", "«a las» se ignora")
        check(stamp(parse("x @el lunes a las 3pm").date) == "2026-08-17 15:00", "pm")
        check(stamp(parse("x @MAÑANA 9").date) == "2026-08-15 09:00", "mayúsculas y acentos")
        check(stamp(parse("x @manana 9").date) == "2026-08-15 09:00", "y sin acento también")
        check(stamp(parse("x @hoy 19hs").date) == "2026-08-14 19:00", "«hs» pegado a la hora")
        check(stamp(parse("x @mañana 9.30").date) == "2026-08-15 09:30", "la hora con punto")

        print("cuándo: lo que no se toca")
        check(parse("mandarle el contrato a juan@cresium.com").date == nil,
              "un mail no es un horario")
        check(parse("hablar con @juan").date == nil, "una mención tampoco")
        check(parse("hablar con @juan del tema").spec == nil, "ni aunque siga la oración")
        check(parse("revisar el @deploy 9:30").date == nil,
              "una palabra que no es un día no arrastra a la hora")
        check(parse("@mañana 9:30").date == nil, "una línea que es solo hora no es una nota")
        check(parse("@mañana 9:30").text == "@mañana 9:30", "y vuelve intacta")
        check(parse("comprar pan").text == "comprar pan", "una nota común no se toca")
        check(parse("x @hoy 8:00").past, "una hora de hoy que ya pasó queda marcada")
        check(!parse("x @hoy 8:00").scheduled, "y no se agenda")
        check(parse("x @en 200 dias").tooFar, "más allá de 120 días queda marcado")

        print("cuándo: cómo se dice")
        check(When.label(parse("x @mañana 9:30").date ?? now, now: now, calendar: calendar)
                == "mañana 09:30", "mañana")
        check(When.label(parse("x @lunes").date ?? now, now: now, calendar: calendar)
                == "lunes 09:00", "un día de esta semana se dice por su nombre")
        check(When.label(parse("x @25/12 10:00").date ?? now, now: now, calendar: calendar)
                == "25 dic 10:00", "y uno lejano por su fecha")
    }

    // MARK: - El recordatorio en el archivo

    private static func runReminderMarkdown(in folder: URL) {
        let day = DayKey.today
        print("markdown: el recordatorio va al archivo")

        let calendar = Calendar.current
        guard let at = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 15, hour: 9, minute: 30)) else {
            check(false, "no se pudo construir la fecha del recordatorio")
            return
        }

        let note = Note(text: "avisarle a Marina", day: day, remindAt: at, slackID: "Q123ABC")
        let body = NoteMarkdown.render([note])
        check(body == "- [ ] avisarle a Marina\n      ↳ slack 2026-08-15 09:30 · Q123ABC\n",
              "se escribe indentado bajo su nota")

        let back = NoteMarkdown.parse(body, day: day)
        check(back.count == 1, "sigue siendo una sola nota")
        check(back.first?.text == "avisarle a Marina",
              "la línea del recordatorio no se cuela en el texto")
        check(back.first?.remindAt == at, "la hora vuelve igual")
        check(back.first?.slackID == "Q123ABC", "y el id de Slack también")

        let queued = Note(text: "sin id todavía", day: day, remindAt: at)
        let queuedBack = NoteMarkdown.parse(NoteMarkdown.render([queued]), day: day)
        check(queuedBack.first?.remindAt == at, "una nota sin id conserva la hora")
        check(queuedBack.first?.slackID == nil, "y sigue sin id")

        // The store rewrites the whole day on every change, so a reminder written by one
        // session has to survive being read and written back by the next.
        let disk = Store(folder: folder.appendingPathComponent("slack"), slack: .off)
        disk.add("recordar el pago", remindAt: at)
        let reread = Store(folder: folder.appendingPathComponent("slack"), slack: .off)
        check(reread.notes(on: day).first?.remindAt == at,
              "la hora sobrevive ir y volver del disco")
        if let saved = reread.notes(on: day).first {
            reread.toggleStar(saved)
        }
        let afterStar = Store(folder: folder.appendingPathComponent("slack"),
                              slack: .off)
        check(afterStar.notes(on: day).first?.remindAt == at,
              "y sobrevive a que reescriban el día por otra cosa")

        print("markdown: una línea que se parece al marcador")
        let sneaky = Note(text: "pasos\n↳ slack 2026-08-15 09:30", day: day)
        let sneakyBack = NoteMarkdown.parse(NoteMarkdown.render([sneaky]), day: day)
        check(sneakyBack.first?.text == "pasos\n↳ slack 2026-08-15 09:30",
              "una línea del usuario que empieza como el marcador vuelve como texto")
        check(sneakyBack.first?.remindAt == nil, "y no inventa un recordatorio")
    }
}
