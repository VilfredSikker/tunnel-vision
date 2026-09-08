import AppKit
import Carbon.HIToolbox
import os

/// Registers the global shortcuts with Carbon. RegisterEventHotKey works from
/// an accessory app without Accessibility or Input Monitoring, unlike
/// NSEvent global monitors, and never sees other keystrokes.
@MainActor
final class HotKeyCenter {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "hotkeys")
    private static let signature: OSType = 0x544E_564E // 'TNVN'

    /// One shortcut each; the raw value is the Carbon hot key id.
    enum Slot: UInt32, CaseIterable, Sendable {
        case togglePanel = 1
        case newTask = 2
        case startPause = 3
        case openPicker = 4

        var name: String {
            switch self {
            case .togglePanel: "toggle"
            case .newTask: "new task"
            case .startPause: "start/pause"
            case .openPicker: "picker"
            }
        }

        /// The label the settings row shows.
        var title: String {
            switch self {
            case .togglePanel: "Open or close Tunnel Vision"
            case .newTask: "New task"
            case .startPause: "Start or pause"
            case .openPicker: "Open the picker"
            }
        }
    }

    /// Fired with the slot whose shortcut was pressed.
    var onFire: ((Slot) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var refs: [Slot: EventHotKeyRef] = [:]
    /// What each slot is registered as, so unchanged settings are a no-op.
    private var current: [Slot: HotKey] = [:]

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

    /// Registers every slot from the settings; a missing slot unregisters.
    func apply(_ hotKeys: [Slot: HotKey]) {
        for slot in Slot.allCases {
            register(hotKeys[slot], for: slot)
        }
    }

    /// Replaces the shortcut in `slot`; nil unregisters it.
    func register(_ hotKey: HotKey?, for slot: Slot) {
        guard current[slot] != hotKey else { return }
        current[slot] = hotKey
        if let existing = refs.removeValue(forKey: slot) {
            UnregisterEventHotKey(existing)
        }
        guard let hotKey else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[slot] = ref
            Self.log.info("\(slot.name, privacy: .public) shortcut registered: \(hotKey.display, privacy: .public)")
        } else {
            current[slot] = nil
            Self.log.error("\(slot.name, privacy: .public) shortcut \(hotKey.display, privacy: .public) not registered: \(status)")
        }
    }

    private func fire(id: UInt32) {
        guard let slot = Slot(rawValue: id) else { return }
        onFire?(slot)
    }
}
