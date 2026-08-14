import AppKit
import SwiftUI

/// Prints where the floating panel actually lands on the active screen.
/// Run with `Bloc --diagnose-geometry`; it shows the real panel, reports every frame
/// involved and exits.
@MainActor
enum GeometryDiagnostic {

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bloc-geo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = Store(folder: folder)

        let hosting = NSHostingView(rootView: ContentView(store: store, onClose: {}))
        let panel = PanelBuilder.build(hosting: hosting)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let screen = PanelBuilder.activeScreen() else {
                print("no hay pantalla activa")
                exit(1)
            }
            hosting.layoutSubtreeIfNeeded()
            let size = NSSize(width: Theme.Metric.panelWidth,
                              height: max(hosting.fittingSize.height, 120))
            PanelBuilder.place(panel, size: size, on: screen)
            panel.orderFront(nil)

            let visible = screen.visibleFrame
            print("pantalla visibleFrame : \(visible)")
            print("panel frame           : \(panel.frame)")
            let fromTop = visible.maxY - panel.frame.maxY
            let expected = visible.height * 0.18
            print(">>> distancia del techo: \(fromTop) pt (esperado \(expected))")
            let dx = panel.frame.midX - visible.midX
            print(">>> desvío horizontal respecto del centro: \(dx) pt")

            try? FileManager.default.removeItem(at: folder)
            exit(abs(dx) < 1 && abs(fromTop - expected) < 1 ? 0 : 1)
        }
        app.run()
    }
}
