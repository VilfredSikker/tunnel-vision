import AppKit
import SwiftUI

/// Presents the full-screen picker overlay on the main display and converts
/// the result (rules + mode + optional saved preset) back to the caller.
@MainActor
final class PickerOverlayPresenter {
    static let shared = PickerOverlayPresenter()

    struct Result {
        let rules: [Rule]
        let mode: Mode
        let savedPresetID: UUID?
    }

    private var panel: NSPanel?
    private var escMonitor: Any?
    private var completion: ((Result?) -> Void)?
    private weak var model: AppState?

    var isPresented: Bool { panel != nil }

    /// - Parameters:
    ///   - initialRules: rules the selection starts from (preset rules or task overrides).
    ///   - allowPresetSave: shows "Save as preset…" (task flows). When false the
    ///     mode picker is always available and the result edits the preset itself.
    func present(
        model: AppState,
        initialRules: [Rule],
        mode: Mode,
        allowPresetSave: Bool,
        onFinish: @escaping (Result?) -> Void
    ) {
        guard panel == nil else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        self.model = model
        completion = onFinish

        let apps = WindowCatalogue.onScreenApps()
        let seed = SelectionBuilder.seed(apps: apps, rules: initialRules)
        let overlayModel = PickerOverlayModel(
            apps: apps,
            wholeAppBundles: seed.wholeAppBundles,
            windowIDs: seed.windowIDs,
            mode: mode,
            allowsPresetSave: allowPresetSave
        )
        let screenRecordingAllowed = ScreenCapturePermission.isAllowed
        let view = PickerOverlayView(
            model: overlayModel,
            screenRecordingAllowed: screenRecordingAllowed,
            onRequestScreenRecording: { ScreenCapturePermission.request() },
            onSavePreset: { [weak self] rules, presetMode, name, existingID in
                self?.upsertPreset(rules: rules, mode: presetMode, name: name, existingID: existingID)
            },
            onCancel: { [weak self] in self?.finish(with: nil) },
            onDone: { [weak self] rules, chosenMode, savedID in
                self?.finish(with: Result(rules: rules, mode: chosenMode, savedPresetID: savedID))
            }
        )

        let panel = KeyablePanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hosting = NSHostingController(rootView: view)
        panel.contentViewController = hosting
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel

        installEscMonitor()
    }

    func cancel() {
        finish(with: nil)
    }

    // MARK: Internals

    private func finish(with result: Result?) {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        escMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        let done = completion
        completion = nil
        model = nil
        done?(result)
    }

    private func installEscMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            if event.keyCode == 53 { // Esc cancels
                self.finish(with: nil)
                return nil
            }
            return event
        }
    }

    /// Saves the current selection into the preset — creating it when needed,
    /// updating the already-saved one otherwise so later toggles are kept.
    private func upsertPreset(rules: [Rule], mode: Mode, name: String, existingID: UUID?) -> UUID? {
        guard let model else { return nil }
        if let existingID,
           let index = model.presets.firstIndex(where: { $0.id == existingID }) {
            var preset = model.presets[index]
            preset.name = preset.name.trimmingCharacters(in: .whitespaces).isEmpty ? name : preset.name
            preset.rules = rules
            preset.mode = mode
            model.updatePreset(preset)
            return existingID
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let preset = model.addPreset(name: uniqueName(trimmed, in: model), mode: mode)
        var withRules = preset
        withRules.rules = rules
        model.updatePreset(withRules)
        return preset.id
    }

    private func uniqueName(_ base: String, in model: AppState) -> String {
        let existing = Set(model.presets.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// Borderless panels cannot become key by default; the overlay needs the key
/// window for its search field and shortcuts.
@MainActor
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
