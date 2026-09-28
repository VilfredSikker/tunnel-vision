import AppKit

/// The friction in front of ending a session early from a menu or from
/// Quit: one warning in normal mode, typing the task title in strict mode.
/// The panel's own Stop button has its hold instead.
@MainActor
enum EarlyEndConfirmation {
    /// True when the user confirmed ending "taskTitle" now.
    static func confirm(taskTitle: String, strict: Bool, action: String = "End Session") -> Bool {
        strict ? confirmStrict(taskTitle: taskTitle, action: action) : confirmNormal(taskTitle: taskTitle, action: action)
    }

    private static func confirmNormal(taskTitle: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "End the session early?"
        alert.informativeText = "“\(taskTitle)” stops now and nothing is counted. Consider a break instead."
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func confirmStrict(taskTitle: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "End the session early?"
        alert.informativeText = "Strict mode is on — type “\(taskTitle)” to confirm."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Task title"
        alert.accessoryView = field
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        // NSAlert does not focus accessory views on its own; without this the
        // first keystrokes land on the buttons and the loop never sees text.
        alert.window.initialFirstResponder = field
        NSApp.activate()
        while true {
            let response = alert.runModal()
            if response != .alertFirstButtonReturn { return false }
            alert.window.initialFirstResponder = field
            if field.stringValue.trimmingCharacters(in: .whitespaces) == taskTitle {
                return true
            }
            NSSound.beep()
            field.stringValue = ""
        }
    }

    /// The quit comes from logout, restart or shutdown, which must never be
    /// held up by a dialog.
    static var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }
            .contains(reason)
    }
}
