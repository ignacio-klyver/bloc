import AppKit
import SwiftUI

/// Offscreen renders of the real interface, so every state can be inspected without driving
/// the UI and without asking for accessibility permission.
@MainActor
enum Proof {


    /// Renders the whole popover with sample data, in both appearances, side by side.
    static func renderUI(to path: String) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bloc-proof-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        seed(folder)

        let store = Store(folder: folder)
        let scale: CGFloat = 2
        let gap: CGFloat = 24

        var shots: [(String, NSBitmapImageRep, NSSize)] = []
        for (label, appearance) in [("claro", NSAppearance(named: .aqua)!),
                                    ("oscuro", NSAppearance(named: .darkAqua)!)] {
            let host = NSHostingView(rootView: ContentView(store: store, onClose: {})
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = appearance
            // Size to the content the way NSPopover does, instead of imposing a height that
            // would clip the list and make a harness artifact look like a layout bug.
            host.frame = NSRect(x: 0, y: 0, width: Theme.Metric.panelWidth, height: 1)
            host.layoutSubtreeIfNeeded()

            // Let SwiftUI settle the async height measurement of the capture field.
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            let fitted = host.fittingSize
            host.frame = NSRect(x: 0, y: 0,
                                width: Theme.Metric.panelWidth,
                                height: max(fitted.height, 240))
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            print("  \(label): fittingSize \(fitted)")

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            shots.append((label, rep, host.bounds.size))
        }

        guard !shots.isEmpty else { return }
        let totalWidth = shots.reduce(gap) { $0 + $1.2.width + gap }
        let maxHeight = shots.map(\.2.height).max() ?? 0
        let canvas = NSRect(x: 0, y: 0, width: totalWidth, height: maxHeight + gap * 2 + 16)

        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        out.size = canvas.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor(srgbRed: 0.90, green: 0.89, blue: 0.87, alpha: 1).setFill()
        canvas.fill()

        var x = gap
        for (label, rep, size) in shots {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: 0.42, green: 0.41, blue: 0.40, alpha: 1)
            ]
            NSAttributedString(string: label.uppercased(), attributes: attributes)
                .draw(at: NSPoint(x: x, y: canvas.height - gap - 4))
            rep.draw(in: NSRect(x: x, y: canvas.height - gap - 16 - size.height,
                                width: size.width, height: size.height))
            x += size.width + gap
        }
        NSGraphicsContext.restoreGraphicsState()

        if let data = out.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("ui proof escrito en \(path)")
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Renders every state a reviewer needs to see, including the ones a user reaches rarely.
    static func renderStates(to path: String) {
        let full = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bloc-states-full-\(UUID().uuidString)")
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bloc-states-empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        seed(full)
        seedLong(full)

        let busyStore = Store(folder: full)
        let emptyStore = Store(folder: empty)

        var cases: [(String, Store, ContentView.Initial, NSAppearance)] = []
        let aqua = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!

        cases.append(("hoy vacío", emptyStore, .init(), aqua))
        cases.append(("pendientes (todo)", busyStore, .init(tab: .pending), aqua))
        cases.append(("pendientes vacío", emptyStore, .init(tab: .pending), aqua))
        cases.append(("resultados + crear", busyStore,
                      .init(query: "zzz"), aqua))
        cases.append(("lista larga (overflow)", busyStore, .init(tab: .pending), dark))
        cases.append(("deshacer visible", busyStore, .init(showUndo: true), aqua))

        var shots: [(String, NSBitmapImageRep, NSSize)] = []
        for (label, store, initial, appearance) in cases {
            let host = NSHostingView(
                rootView: ContentView(store: store, onClose: {}, initial: initial)
                    .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = appearance
            host.frame = NSRect(x: 0, y: 0, width: Theme.Metric.panelWidth, height: 1)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let fitted = host.fittingSize
            host.frame = NSRect(x: 0, y: 0,
                                width: Theme.Metric.panelWidth,
                                height: max(fitted.height, 200))
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            print("  \(label): \(host.frame.size)")
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            shots.append((label, rep, host.bounds.size))
        }

        writeSheet(shots, columns: 3, to: path)
        try? FileManager.default.removeItem(at: full)
        try? FileManager.default.removeItem(at: empty)
    }

    /// Lays shots out in a grid and writes the PNG.
    private static func writeSheet(_ shots: [(String, NSBitmapImageRep, NSSize)],
                                   columns: Int, to path: String) {
        guard !shots.isEmpty else { return }
        let gap: CGFloat = 24
        let labelH: CGFloat = 18
        let cellW = (shots.map(\.2.width).max() ?? 340) + gap
        let rows = Int(ceil(Double(shots.count) / Double(columns)))

        var rowHeights: [CGFloat] = []
        for row in 0..<rows {
            let slice = shots[(row * columns)..<min((row + 1) * columns, shots.count)]
            rowHeights.append((slice.map(\.2.height).max() ?? 0) + labelH + gap)
        }

        let canvas = NSRect(x: 0, y: 0,
                            width: CGFloat(columns) * cellW + gap,
                            height: rowHeights.reduce(gap, +))
        let scale: CGFloat = 2
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        out.size = canvas.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor(srgbRed: 0.90, green: 0.89, blue: 0.87, alpha: 1).setFill()
        canvas.fill()

        var y = gap
        for row in 0..<rows {
            var x = gap
            for column in 0..<columns {
                let index = row * columns + column
                guard index < shots.count else { break }
                let (label, rep, size) = shots[index]
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor(srgbRed: 0.42, green: 0.41, blue: 0.40, alpha: 1)
                ]
                NSAttributedString(string: label.uppercased(), attributes: attributes)
                    .draw(at: NSPoint(x: x, y: canvas.height - y - 12))
                rep.draw(in: NSRect(x: x, y: canvas.height - y - labelH - size.height,
                                    width: size.width, height: size.height))
                x += cellW
            }
            y += rowHeights[row]
        }
        NSGraphicsContext.restoreGraphicsState()

        if let data = out.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("states escrito en \(path)")
        }
    }

    /// A day heavy enough to overflow the list and trigger the scroll fade.
    private static func seedLong(_ folder: URL) {
        guard let date = Calendar.current.date(byAdding: .day, value: -4, to: Date())
        else { return }
        let key = DayKey(date)
        let body = (1...9).map { index in
            "- [ ] pendiente número \(index) de un día cargado, con texto largo para que envuelva\n"
        }.joined()
        try? body.write(to: folder.appendingPathComponent("\(key.fileName).md"),
                        atomically: true, encoding: .utf8)
    }

    /// Renders one state alone at 1x with no surrounding chrome, so a pixel in the PNG is a
    /// point in the layout and leading edges can be measured directly.
    static func renderMeasure(to path: String, state: String) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bloc-measure-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if state != "vacio" { seed(folder) }
        let store = Store(folder: folder)

        var initial = ContentView.Initial()
        switch state {
        case "pendientes": initial = .init(tab: .pending)
        case "busqueda": initial = .init(query: "max")
        case "deshacer": initial = .init(showUndo: true)
        default: break
        }

        let host = NSHostingView(rootView: ContentView(store: store, onClose: {}, initial: initial)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: state.hasSuffix("-dark") ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: Theme.Metric.panelWidth, height: 1)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.frame = NSRect(x: 0, y: 0, width: Theme.Metric.panelWidth,
                            height: max(host.fittingSize.height, 200))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("medible \(state): \(Int(host.bounds.width))x\(Int(host.bounds.height)) pt -> \(path)")
        }
        try? FileManager.default.removeItem(at: folder)
    }


    /// Renders one focused NoteRow alone at 1x, actions visible, so the vertical centring of
    /// checkbox, star, text and action icons can be measured pixel by pixel. This is the state
    /// the full-popover renders never show, because hover and focus need a live window.
    static func renderRow(to path: String) {
        let note = Note(text: "Armar product general overview en metabase",
                        starred: true, day: .today)
        let host = NSHostingView(rootView:
            NoteRow(note: note, isFocused: true, isExpanded: false,
                    onToggle: {}, onStar: {}, onDelete: {}, onEdit: { _ in }, onExpand: {})
                .frame(width: 326)
                .background(Color.white)
        )
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 326, height: 1)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.frame = NSRect(x: 0, y: 0, width: 326,
                            height: max(host.fittingSize.height, 28))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("row: \(Int(host.bounds.width))x\(Int(host.bounds.height)) pt -> \(path)")
        }
    }

    /// Sample notes across several days, so the tick strip has a real shape.
    private static func seed(_ folder: URL) {
        let calendar = Calendar.current
        let content: [(Int, String)] = [
            (0, "- [ ] !Marina quiere coordinar la prueba el jueves\n- [ ] preguntar a Max si el CUIT del pagador persiste\n- [x] idea: tab de retenciones en el dashboard\n"),
            (1, "- [ ] !mandar el doc de integración a MENZE\n- [ ] revisar por qué fc_dup falta en 20 cards\n"),
            (2, "- [x] cerrar el ciclo 3 en Notion\n"),
            (3, "- [ ] pedir a Cumplimiento el guion de aperturas\n- [x] armar el T3 de Odoo\n- [x] chequear rebotes SAMAC\n- [ ] leer la comunicación de BCRA\n"),
            (5, "- [x] pulso semanal\n"),
            (6, "- [ ] revisar el deck del webinar\n- [x] responder a Fede\n"),
            (9, "- [x] baseline de conciliación\n- [x] limpiar leads\n"),
            (12, "- [ ] escribir la spec de import masivo\n"),
        ]
        for (daysAgo, body) in content {
            guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let key = DayKey(date)
            try? body.write(to: folder.appendingPathComponent("\(key.fileName).md"),
                            atomically: true, encoding: .utf8)
        }
    }


}
