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

        let store = Store(folder: folder)
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
        let bang = Store(folder: folder.appendingPathComponent("bang"))
        bang.add("!urgente: llamar a Marina")
        let bangBack = bang.notes(on: today)
        check(bangBack.first?.text == "!urgente: llamar a Marina",
              "el «!» inicial sobrevive el round trip")
        check(bangBack.first?.starred == false,
              "una nota que empieza con «!» no aparece destacada sola")
        let bangFresh = Store(folder: folder.appendingPathComponent("bang"))
        check(bangFresh.notes(on: today).first?.text == "!urgente: llamar a Marina",
              "y también sobrevive releyendo el disco")

        print("markdown: barra invertida inicial")
        let slash = Store(folder: folder.appendingPathComponent("slash"))
        slash.add("\\ruta\\del\\archivo")
        check(Store(folder: folder.appendingPathComponent("slash"))
                .notes(on: today).first?.text == "\\ruta\\del\\archivo",
              "una nota que empieza con «\\» vuelve igual")

        print("markdown: línea en blanco en el medio")
        let blank = Store(folder: folder.appendingPathComponent("blank"))
        blank.add("reunión con Max\n\nllamar a Marina")
        check(Store(folder: folder.appendingPathComponent("blank"))
                .notes(on: today).first?.text == "reunión con Max\n\nllamar a Marina",
              "la línea vacía del medio no se pierde")

        print("markdown: una nota destacada sigue funcionando")
        let star = Store(folder: folder.appendingPathComponent("star"))
        star.add("coordinar la prueba")
        star.toggleStar(star.notes(on: today)[0])
        let starFresh = Store(folder: folder.appendingPathComponent("star"))
        check(starFresh.notes(on: today).first?.starred == true, "la estrella sobrevive")
        check(starFresh.notes(on: today).first?.text == "coordinar la prueba",
              "y no se come una letra del texto")

        print("editar a vacío no borra")
        let edit = Store(folder: folder.appendingPathComponent("edit"))
        edit.add("no me borres")
        let victim = edit.notes(on: today)[0]
        check(!edit.update(victim, text: "   "), "vaciar el texto devuelve false")
        check(edit.notes(on: today).count == 1, "y la nota sigue estando")
        check(!edit.canUndo, "sin armar un deshacer fantasma")

        print("deshacer se puede desarmar")
        let dis = Store(folder: folder.appendingPathComponent("dis"))
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
        let fresh = Store(folder: folder)
        check(fresh.notes(on: today).count == store.notes(on: today).count,
              "releer el disco da la misma cantidad")

        print("")
        if failures.isEmpty {
            print("todo verde (\(folder.lastPathComponent))")
            return 0
        }
        print("\(failures.count) fallas: \(failures.joined(separator: ", "))")
        return 1
    }
}
