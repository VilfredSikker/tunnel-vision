import AppKit
import Carbon.HIToolbox
import os

/// Registers the global shortcut with Carbon. RegisterEventHotKey works from
/// an accessory app without Accessibility or Input Monitoring, unlike
/// NSEvent global monitors, and never sees other keystrokes.
@MainActor
final class HotKeyCenter {
    private static let log = Logger(subsystem: "com.anchor.timer", category: "hotkeys")
    private static let signature: OSType = 0x414E_4348 // 'ANCH'
    private static let toggleID: UInt32 = 1

    /// Fired when the toggle shortcut is pressed.
    var onTogglePanel: (() -> Void)?

    private var handlerRef: EventHandlerRef?
    private var toggleRef: EventHotKeyRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().fire(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr {
            Self.log.error("hot key handler install failed: \(status)")
        }
    }

    /// Replaces the toggle shortcut; nil unregisters it.
    func registerToggle(_ hotKey: HotKey?) {
        if let toggleRef {
            UnregisterEventHotKey(toggleRef)
            self.toggleRef = nil
        }
        guard let hotKey else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.toggleID)
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            toggleRef = ref
            Self.log.info("toggle shortcut registered: \(hotKey.display, privacy: .public)")
        } else {
            Self.log.error("toggle shortcut \(hotKey.display, privacy: .public) not registered: \(status)")
        }
    }

    private func fire(id: UInt32) {
        if id == Self.toggleID {
            onTogglePanel?()
        }
    }
}
