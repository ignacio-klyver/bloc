import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Uses Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor, because the
/// Carbon route needs no Accessibility permission. Asking for Accessibility on first launch
/// for a note-taking app would be both surprising and, for capture, fatal to the first run.
final class HotKey {

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_Space`.
    ///   - modifiers: Carbon modifier mask, e.g. `UInt32(cmdKey | shiftKey)`.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = HotKey.nextID
        HotKey.nextID += 1

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async {
                HotKey.instances[hotKeyID.id]?.action()
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        guard status == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x424C4F43) /* 'BLOC' */, id: id)
        let registered = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
        guard registered == noErr, ref != nil else { return nil }

        HotKey.instances[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.instances[id] = nil
    }
}
