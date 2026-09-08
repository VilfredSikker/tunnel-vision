import AppKit
import SwiftUI

/// Click, press a combination, done. Esc cancels the recording, Delete
/// clears the shortcut. A combination needs ⌘, ⌥ or ⌃ (or a function key)
/// so plain typing can never be swallowed system-wide.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey?

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.hotKey = hotKey
        view.onChange = { hotKey = $0 }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.hotKey = hotKey
        view.onChange = { hotKey = $0 }
    }
}

final class ShortcutRecorderView: NSView {
    var hotKey: HotKey? {
        didSet { needsDisplay = true }
    }
    var onChange: ((HotKey?) -> Void)?

    private var recording = false {
        didSet { needsDisplay = true }
    }
    private var preview: String?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    private var eventMonitor: Any?

    override func mouseDown(with event: NSEvent) {
        // An accessory app (LSUIElement) isn't active by default, so its
        // windows never become key and can't receive key events. Force
        // activation, then grab the keys with a local monitor so recording
        // works regardless of first-responder quirks in SwiftUI hosting.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        recording = true
        installEventMonitor()
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording else { return event }
            if event.type == .keyDown {
                self.handle(event)
            }
            return nil
        }
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    /// ⌘-combinations travel as key equivalents before keyDown; while
    /// recording they are the shortcut being typed, not commands.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        let code = event.keyCode
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if code == 53 { // Esc
            endRecording()
            return
        }
        if (code == 51 || code == 117), flags.isEmpty { // Delete, forward delete
            commit(nil)
            return
        }
        let isFunctionKey = HotKeyDisplay.functionKeyNames[code] != nil
        guard isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty else {
            // Bare typing key with no modifier: would swallow every keystroke.
            NSSound.beep()
            return
        }
        commit(HotKey(
            keyCode: UInt32(code),
            carbonModifiers: HotKeyDisplay.carbonModifiers(from: flags),
            keyLabel: HotKeyDisplay.keyLabel(for: event)
        ))
    }

    private func previewLabel(code: UInt16, flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(HotKeyDisplay.keyLabel(code: code))
        return parts.joined()
    }

    private func commit(_ hotKey: HotKey?) {
        self.hotKey = hotKey
        onChange?(hotKey)
        endRecording()
    }

    private func endRecording() {
        recording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text: String
        let color: NSColor
        let weight: NSFont.Weight
        if recording {
            text = "Press keys…"
            color = .secondaryLabelColor
            weight = .regular
        } else if let hotKey {
            text = hotKey.display
            color = .labelColor
            weight = .medium
        } else {
            text = "Click to record"
            color = .secondaryLabelColor
            weight = .regular
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: weight),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// AppKit ⇄ Carbon glue for recorded shortcuts.
enum HotKeyDisplay {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= HotKey.command }
        if flags.contains(.shift) { modifiers |= HotKey.shift }
        if flags.contains(.option) { modifiers |= HotKey.option }
        if flags.contains(.control) { modifiers |= HotKey.control }
        return modifiers
    }

    static let functionKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let specialKeyNames: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// What the key prints as on the current layout, without modifiers.
    static func keyLabel(for event: NSEvent) -> String {
        if let name = functionKeyNames[event.keyCode] ?? specialKeyNames[event.keyCode] {
            return name
        }
        if let characters = event.characters(byApplyingModifiers: []),
           let scalar = characters.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar) {
            return characters.uppercased()
        }
        return "Key \(event.keyCode)"
    }

    /// Key label from just a keyCode (for dead-key previews where the event
    /// has no usable characters).
    static func keyLabel(code: UInt16) -> String {
        if let name = functionKeyNames[code] ?? specialKeyNames[code] {
            return name
        }
        return "Key \(code)"
    }

}
