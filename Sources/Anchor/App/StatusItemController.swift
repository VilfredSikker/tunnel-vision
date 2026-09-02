import AppKit
import SwiftUI

/// Owns the NSStatusItem: icon + remaining time in the menu bar, left click
/// toggles the main panel popover, right click offers quick actions.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppState
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var refreshTimer: Timer?
    private var escMonitor: Any?
    private var outsideMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// The status item's window, for anchoring popovers and notices.
    var statusButtonWindow: NSWindow? {
        statusItem?.button?.window
    }

    init(model: AppState) {
        self.model = model
        super.init()        // Deterministic dismissal: we close on outside clicks, Esc and app
        // deactivation ourselves. Relying on .transient auto-close re-opens
        // the popover when the status item itself is clicked (close-then-
        // toggle race).
        popover.behavior = .applicationDefined
        popover.animates = true
        let hosting = NSHostingController(rootView: MainPanel(model: model))
        popover.contentViewController = hosting
    }

    // No deinit teardown needed: the controller is an app-lifetime singleton,
    // the refresh Timer retains it via its selector target while scheduled,
    // and all event monitors/observers capture self weakly.
    deinit {}

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }
        refreshLabel()
        let timer = Timer(timeInterval: 1.0, target: self, selector: #selector(refreshTimerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        installEscMonitor()
        installOutsideClickMonitor()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
            }
        }
    }

    // MARK: - Menu bar label

    private var symbolName: String {
        switch model.phase {
        case .idle: return "timer"
        case .work: return "timer"
        case .paused: return "pause.fill"
        case .breakTime: return "cup.and.heat.waves.fill"
        }
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        refreshLabel()
    }

    private func refreshLabel() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: model.phase == .breakTime ? "On break" : "Anchor timer"
        )
        image?.isTemplate = true
        button.image = image

        if let remaining = model.remainingSeconds {
            let text = TimeFormat.clock(remaining)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
            button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attributes)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = tooltip
    }

    private var tooltip: String {
        switch model.phase {
        case .idle: return "Anchor — click for your tasks"
        case .work:
            let title = model.activeTask?.title ?? "Focus session"
            return "\(title) — click to pause or end"
        case .paused: return "Paused — click to resume"
        case .breakTime: return "On break"
        }
    }

    // MARK: - Click handling

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let eventType = NSApp.currentEvent?.type
        if eventType == .rightMouseUp {
            popover.performClose(nil)
            let menu = buildQuickMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            resizePopoverToFit()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The panel lays out inside a fixed width; height follows content.
    private func resizePopoverToFit() {
        guard let view = popover.contentViewController?.view else { return }
        let fitting = view.fittingSize
        let width = min(max(fitting.width, 300), 380)
        let height = min(max(fitting.height, 220), 640)
        popover.contentSize = NSSize(width: width, height: height)
    }

    // MARK: - Quick actions (right click)

    private func buildQuickMenu() -> NSMenu {
        let menu = NSMenu()
        switch model.phase {
        case .idle:
            let item = NSMenuItem(title: "Nothing running", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .work:
            menu.addItem(makeItem("Pause", #selector(quickPauseResume)))
        case .paused:
            menu.addItem(makeItem("Resume", #selector(quickPauseResume)))
        case .breakTime:
            break
        }
        if model.phase == .work || model.phase == .paused {
            menu.addItem(makeItem("Skip to break", #selector(quickSkipToBreak)))
            menu.addItem(NSMenuItem.separator())
            let end = makeItem("End session…", #selector(quickEndSession))
            end.isEnabled = true
            menu.addItem(end)
        }
        if model.phase == .breakTime {
            menu.addItem(makeItem("Skip break", #selector(quickSkipBreak)))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Quit Anchor", #selector(quickQuit)))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func quickPauseResume() {
        model.togglePause()
        refreshLabel()
    }

    @objc private func quickSkipToBreak() {
        model.skipToBreak()
        refreshLabel()
    }

    @objc private func quickSkipBreak() {
        model.skipBreak()
        refreshLabel()
    }

    @objc private func quickEndSession() {
        guard let task = model.activeTask else { return }
        if model.settings.strictMode {
            confirmEndStrict(taskTitle: task.title)
        } else {
            confirmEnd(taskTitle: task.title)
        }
    }

    /// Normal mode: one warning dialog.
    private func confirmEnd(taskTitle: String) {
        let alert = NSAlert()
        alert.messageText = "End the session early?"
        alert.informativeText = "“\(taskTitle)” stops now and nothing is counted. Consider a break instead."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            model.stopNow()
            refreshLabel()
        }
    }

    /// Strict mode: the quick action must not bypass the type-the-title
    /// friction that applies to early stops.
    private func confirmEndStrict(taskTitle: String) {
        let alert = NSAlert()
        alert.messageText = "End the session early?"
        alert.informativeText = "Strict mode is on — type “\(taskTitle)” to confirm."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Task title"
        alert.accessoryView = field
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        // NSAlert does not focus accessory views on its own; without this the
        // first keystrokes land on the buttons and the loop never sees text.
        alert.window.initialFirstResponder = field
        while true {
            let response = alert.runModal()
            if response != .alertFirstButtonReturn { return }
            alert.window.initialFirstResponder = field
            if field.stringValue.trimmingCharacters(in: .whitespaces) == taskTitle {
                model.stopNow()
                refreshLabel()
                return
            }
            NSSound.beep()
            field.stringValue = ""
        }
    }

    @objc private func quickQuit() {
        popover.performClose(nil)
        NSApp.terminate(nil)
    }

    // MARK: - Keyboard & outside clicks

    /// Esc closes the popover when it is key — unless the popover has an
    /// attached sheet, which owns Esc (cancel) itself.
    private func installEscMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.popover.isShown {
                let attachedSheet = self.popover.contentViewController?.view.window?.attachedSheet
                guard attachedSheet == nil else { return event }
                self.popover.performClose(nil)
                return nil
            }
            return event
        }
    }

    /// With .applicationDefined the popover stays up until we close it: clicks
    /// outside the popover (but in our own app — other apps deactivate us,
    /// handled by the resign observer above) dismiss it. Clicks on the status
    /// item itself and on the popover's attached sheets/children are exempt so
    /// the toggle and sheet editing keep working.
    private func installOutsideClickMonitor() {
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown, let clicked = event.window else { return event }
            guard let popoverWindow = self.popover.contentViewController?.view.window else { return event }
            if clicked === popoverWindow { return event }
            if clicked === self.statusItem?.button?.window { return event }
            if clicked.sheetParent === popoverWindow { return event }
            var ancestor = clicked.parent
            while let a = ancestor {
                if a === popoverWindow { return event }
                ancestor = a.parent
            }
            self.popover.performClose(nil)
            return event
        }
    }
}
