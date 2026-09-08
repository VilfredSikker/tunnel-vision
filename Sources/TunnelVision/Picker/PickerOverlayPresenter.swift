import AppKit
import SwiftUI

/// Presents the full-screen picker overlay on every display and converts
/// the result (rules + mode + optional saved preset) back to the caller.
/// All panels show the same selection; the one under the mouse takes the
/// keyboard.
@MainActor
final class PickerOverlayPresenter {
    static let shared = PickerOverlayPresenter()

    struct Result {
        let rules: [Rule]
        let mode: Mode
        let savedPresetID: UUID?
    }

    private var panels: [NSPanel] = []
    private var escMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var completion: ((Result?) -> Void)?
    private weak var model: AppState?

    var isPresented: Bool { !panels.isEmpty }

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
        guard panels.isEmpty else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        self.model = model
        completion = onFinish

        let apps = WindowCatalogue.onScreenApps()
        let seed = SelectionBuilder.seed(apps: apps, rules: initialRules)
        let overlayModel = PickerOverlayModel(
            apps: apps,
            wholeAppBundles: seed.wholeAppBundles,
            windowIDs: seed.windowIDs,
            siteWideWindowIDs: seed.siteWideWindowIDs,
            herdrLabels: seed.herdrLabels,
            mode: mode,
            allowsPresetSave: allowPresetSave
        )
        loadHerdrWorkspaces(into: overlayModel)
        loadBrowserURLs(into: overlayModel, apps: apps, rules: initialRules)
        let titlesAvailable = ScreenCapturePermission.isAllowed || AccessibilityPermission.isTrusted
        let makeView = { [weak self] in
            PickerOverlayView(
                model: overlayModel,
                titlesAvailable: titlesAvailable,
                onRequestTitles: { AccessibilityPermission.request() },
                onSavePreset: { [weak self] rules, presetMode, name, existingID in
                    self?.upsertPreset(rules: rules, mode: presetMode, name: name, existingID: existingID)
                },
                onCancel: { [weak self] in self?.finish(with: nil) },
                onDone: { [weak self] rules, chosenMode, savedID in
                    self?.finish(with: Result(rules: rules, mode: chosenMode, savedPresetID: savedID))
                }
            )
        }

        for screen in screens {
            panels.append(makePanel(on: screen, view: makeView()))
        }
        let mouse = NSEvent.mouseLocation
        let keyPanel = panels.first { $0.frame.contains(mouse) } ?? panels.first
        for panel in panels where panel !== keyPanel {
            panel.orderFrontRegardless()
        }
        keyPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installEscMonitor()
        observeScreens()
    }

    func cancel() {
        finish(with: nil)
    }

    private func makePanel(on screen: NSScreen, view: PickerOverlayView) -> NSPanel {
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
        // By default the controller publishes the SwiftUI ideal size as its
        // preferredContentSize, and assigning it shrinks the panel to that.
        // The app list is a scroll view with no ideal height, so the picker
        // collapsed to its top and bottom bars. The panel is the whole screen.
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setFrame(screen.frame, display: true)
        return panel
    }

    /// Displays come and go: panels follow their screens, spares hide.
    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }
    }

    private func relayout() {
        let screens = NSScreen.screens
        for (index, panel) in panels.enumerated() {
            if index < screens.count {
                panel.setFrame(screens[index].frame, display: true)
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                }
            } else {
                panel.orderOut(nil)
            }
        }
    }

    /// Browser windows get named by their active tab's URL, asked over each
    /// browser's scripting interface. Untitled tiles become pickable as the
    /// answers land.
    private func loadBrowserURLs(into overlayModel: PickerOverlayModel, apps: [PickerAppInfo], rules: [Rule]) {
        guard apps.contains(where: { BrowserWindowURLs.supports($0.bundleID) && !$0.windows.isEmpty }) else { return }
        Task { @MainActor in
            let urls = await BrowserWindowURLs.fetch(for: apps)
            overlayModel.applyWindowURLs(urls, seededFrom: rules)
        }
    }

    /// herdr workspaces come over its socket; the overlay fills in the
    /// section when they arrive. No herdr, no section.
    private func loadHerdrWorkspaces(into overlayModel: PickerOverlayModel) {
        let client = HerdrSocketClient()
        guard client.isAvailable else { return }
        Task { @MainActor in
            guard let snapshot = try? await client.snapshot() else { return }
            overlayModel.herdr = PickerHerdrInfo(
                hostBundleID: HerdrHost.terminalBundleID(),
                workspaces: snapshot.workspaces
            )
        }
    }

    // MARK: Internals

    private func finish(with result: Result?) {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        escMonitor = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        let done = completion
        completion = nil
        model = nil
        done?(result)
    }

    private func installEscMonitor() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPresented else { return event }
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
        let preset = model.addPreset(name: model.uniquePresetName(basedOn: trimmed), mode: mode)
        var withRules = preset
        withRules.rules = rules
        model.updatePreset(withRules)
        return preset.id
    }
}

/// Borderless panels cannot become key by default; the overlay needs the key
/// window for its search field and shortcuts.
@MainActor
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
