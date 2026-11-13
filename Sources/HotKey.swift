// The global shortcut (⌥Space by default), through Carbon's hot-key API. It needs no
// permission, and works whichever app is in front.

import Carbon
import Foundation

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: (pressed: () -> Void, released: () -> Void)] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// Nil when macOS refuses the combination (another app may have it). `released` is for
    /// hold-to-talk.
    init?(keyCode: UInt32, modifiers: UInt32, pressed: @escaping () -> Void, released: @escaping () -> Void = {}) {
        HotKey.install()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4354_4646), id: id) // "CTFF"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.handlers[id] = (pressed, released)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                guard let h = HotKey.handlers[id] else { return }
                pressed ? h.pressed() : h.released()
            }
            return noErr
        }, 2, &specs, nil, nil)
    }
}
