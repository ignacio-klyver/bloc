import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var hosting: NSHostingView<ContentView>?
    private var hotKey: HotKey?
    private let store = Store()

    /// The app that was in front before the panel opened. Restoring it on close is what
    /// makes the round trip feel like two seconds; without it the user is left on the desktop.
    private var previousApp: NSRunningApplication?

    /// True while a close we started is in flight, so a close caused by the user clicking
    /// another app does not drag them back to where they were before.
    private var closingOurselves = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "note.text",
                                   accessibilityDescription: "Bloc")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePanel)
            button.setAccessibilityLabel("Bloc, notas rápidas")
        }

        // Register first, so the panel can be built already knowing whether it has a shortcut.
        let shortcut = Shortcut.current
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.togglePanel()
        }
        let warning = hotKey == nil
            ? "\(shortcut.display) está tomado por otra app. El atajo no funciona."
            : nil

        let view = NSHostingView(
            rootView: ContentView(store: store,
                                  onClose: { [weak self] in self?.close() },
                                  onResize: { [weak self] size in self?.contentResized(size) },
                                  shortcutWarning: warning)
        )
        hosting = view
        panel = PanelBuilder.build(hosting: view)
        panel.delegate = self

        // The tooltip always states the combination actually held, never a hardcoded one, so
        // the app can never promise a shortcut it does not have.
        statusItem.button?.toolTip = hotKey == nil
            ? "Bloc · \(shortcut.display) está tomado por otra app. Abrí desde acá o cambialo."
            : "Bloc · \(shortcut.display)"

        registerLoginItem()
    }

    /// AppKit resolves ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z against the main menu, so without one the text
    /// field has no clipboard and no undo at all. The menu bar itself never appears because
    /// the activation policy is .accessory; only the key equivalents matter here.
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Salir de Bloc", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edición")
        // nil actions travel the responder chain and land on whatever text view is first
        // responder, which is exactly what a single-field capture panel needs.
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rehacer", action: Selector(("redo:")),
                                keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: Showing

    @objc private func togglePanel() {
        panel.isVisible ? close() : show()
    }

    private func show() {
        guard let screen = PanelBuilder.activeScreen(), let hosting else { return }

        previousApp = NSWorkspace.shared.frontmostApplication

        // Lay the content out and place the panel at its real size before showing it, so it
        // never appears at one size and jumps to another.
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize
        let size = NSSize(width: Theme.Metric.panelWidth,
                          height: max(fitted.height, 120))
        PanelBuilder.place(panel, size: size, on: screen)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView?.firstFocusableDescendant())

        // Only after the panel is on screen and the caret is ready. Reading and parsing the
        // whole folder first was work charged to the two seconds the user is counting.
        store.openSession()
    }

    private func close() {
        closingOurselves = true
        panel.orderOut(nil)

        // Hand focus back to whatever the user was doing, but only when Bloc is the one
        // closing on purpose.
        defer { previousApp = nil; closingOurselves = false }
        guard let previousApp,
              previousApp.processIdentifier != NSRunningApplication.current.processIdentifier,
              !previousApp.isTerminated
        else { return }
        previousApp.activate()
    }

    /// The panel is transient like Spotlight: clicking anywhere else dismisses it. No focus
    /// restore in that case; the user already chose where they want to be.
    func windowDidResignKey(_ notification: Notification) {
        guard !closingOurselves, panel.isVisible else { return }
        panel.orderOut(nil)
        previousApp = nil
    }

    /// The content grew or shrank (the field wrapping, the list changing day). The panel
    /// follows with its top edge pinned, so the caret never moves under the user's eyes.
    private func contentResized(_ size: CGSize) {
        guard panel.isVisible else { return }
        let target = NSSize(width: Theme.Metric.panelWidth, height: max(size.height, 120))
        if abs(panel.frame.height - target.height) > 0.5 {
            PanelBuilder.resize(panel, to: target)
        }
    }

    // MARK: Login item

    private func registerLoginItem() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Launching at login is a convenience, never a reason to fail startup.
            NSLog("Bloc: no se pudo registrar el arranque al login: \(error.localizedDescription)")
        }
    }
}

private extension NSView {
    /// First descendant that can actually take keyboard input.
    func firstFocusableDescendant() -> NSView? {
        if let textView = self as? NSTextView, textView.isEditable { return textView }
        for sub in subviews {
            if let found = sub.firstFocusableDescendant() { return found }
        }
        return nil
    }
}

// Top-level code already runs on the main thread; this states it so the main-actor
// isolated delegate can be constructed here.
MainActor.assumeIsolated {
    // Offscreen verification of the ruled-line alignment, no window and no permissions.
    if CommandLine.arguments.contains("--selftest") {
        exit(SelfTest.run())
    }
    if CommandLine.arguments.contains("--shortcut") {
        print("atajo actual: \(Shortcut.current.display)")
        print("para cambiarlo:  Bloc --set-shortcut \"alt+cmd+b\"")
        exit(0)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--set-shortcut"),
       CommandLine.arguments.count > index + 1 {
        let spec = CommandLine.arguments[index + 1]
        guard let shortcut = Shortcut.parse(spec) else {
            print("no entendí «\(spec)». Ejemplos: \"alt+cmd+b\", \"ctrl+opt+space\", \"cmd+shift+n\"")
            exit(1)
        }
        shortcut.save()
        print("atajo guardado: \(shortcut.display)")
        print("reiniciá Bloc para que tome efecto.")
        exit(0)
    }
    if CommandLine.arguments.contains("--diagnose-geometry") {
        GeometryDiagnostic.run()
    }
    if let index = CommandLine.arguments.firstIndex(of: "--render-ui"),
       CommandLine.arguments.count > index + 1 {
        _ = NSApplication.shared
        Proof.renderUI(to: CommandLine.arguments[index + 1])
        exit(0)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--render-states"),
       CommandLine.arguments.count > index + 1 {
        _ = NSApplication.shared
        Proof.renderStates(to: CommandLine.arguments[index + 1])
        exit(0)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--render-row"),
       CommandLine.arguments.count > index + 1 {
        _ = NSApplication.shared
        Proof.renderRow(to: CommandLine.arguments[index + 1])
        exit(0)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--render-measure"),
       CommandLine.arguments.count > index + 2 {
        _ = NSApplication.shared
        Proof.renderMeasure(to: CommandLine.arguments[index + 1],
                            state: CommandLine.arguments[index + 2])
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // The delegate is only referenced weakly by NSApplication.
    objc_setAssociatedObject(app, "BlocDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
