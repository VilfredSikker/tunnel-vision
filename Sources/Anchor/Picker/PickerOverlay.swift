import AppKit
import Observation
import SwiftUI

/// Selection state for the picker overlay.
@MainActor
@Observable
final class PickerOverlayModel {
    let apps: [PickerAppInfo]
    var search = ""
    var wholeAppBundles: Set<String>
    var windowIDs: Set<CGWindowID>
    var mode: Mode
    let allowsPresetSave: Bool

    init(
        apps: [PickerAppInfo],
        wholeAppBundles: Set<String>,
        windowIDs: Set<CGWindowID>,
        mode: Mode,
        allowsPresetSave: Bool
    ) {
        self.apps = apps
        self.wholeAppBundles = wholeAppBundles
        self.windowIDs = windowIDs
        self.mode = mode
        self.allowsPresetSave = allowsPresetSave
    }

    var anyTitlesAvailable: Bool {
        apps.contains { app in app.windows.contains { $0.title != nil } }
    }

    var filteredApps: [PickerAppInfo] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.compactMap { app in
            let appMatches = app.name.lowercased().contains(query) || app.bundleID.lowercased().contains(query)
            let windows = app.windows.filter { ($0.title?.lowercased() ?? "").contains(query) }
            if appMatches {
                return app
            } else if !windows.isEmpty {
                var filtered = app
                filtered.windows = windows
                return filtered
            }
            return nil
        }
    }

    func isWhole(_ app: PickerAppInfo) -> Bool {
        wholeAppBundles.contains(app.bundleID)
    }

    func isIncluded(_ window: PickerWindowInfo, in app: PickerAppInfo) -> Bool {
        isWhole(app) || windowIDs.contains(window.id)
    }

    /// Click on the app header: include (or drop) the whole app. Window
    /// picks of that app become meaningless either way and are cleared.
    func toggleApp(_ app: PickerAppInfo) {
        if wholeAppBundles.contains(app.bundleID) {
            wholeAppBundles.remove(app.bundleID)
        } else {
            wholeAppBundles.insert(app.bundleID)
        }
        for window in app.windows {
            windowIDs.remove(window.id)
        }
    }

    /// Click on a window tile: if the whole app was included, narrow down to
    /// just this window; otherwise toggle the window.
    func toggleWindow(_ window: PickerWindowInfo, in app: PickerAppInfo) {
        if wholeAppBundles.contains(app.bundleID) {
            wholeAppBundles.remove(app.bundleID)
        }
        if windowIDs.contains(window.id) {
            windowIDs.remove(window.id)
        } else {
            windowIDs.insert(window.id)
        }
    }

    /// Distinct allowed bundles and how many of them were picked window-only.
    var summary: (appCount: Int, windowCount: Int) {
        var bundles = wholeAppBundles
        var windowOnly = 0
        for app in apps {
            for window in app.windows where windowIDs.contains(window.id) {
                if !bundles.contains(app.bundleID) {
                    bundles.insert(app.bundleID)
                    windowOnly += 1
                }
            }
        }
        return (bundles.count, windowOnly)
    }

    func pickedWindowRefs() -> [PickedWindowRef] {
        var refs: [PickedWindowRef] = []
        for app in apps where !wholeAppBundles.contains(app.bundleID) {
            for window in app.windows where windowIDs.contains(window.id) {
                refs.append(PickedWindowRef(bundleID: app.bundleID, windowID: window.id, title: window.title))
            }
        }
        return refs
    }

    func rules() -> [Rule] {
        SelectionBuilder.rules(wholeAppBundles: wholeAppBundles, windows: pickedWindowRefs())
    }
}

// MARK: - View

/// Full-screen exposé-style allowlist picker.
struct PickerOverlayView: View {
    @Bindable var model: PickerOverlayModel
    let screenRecordingAllowed: Bool
    let onRequestScreenRecording: () -> Void
    /// Creates the preset (rules + mode) and returns its id, or nil.
    let onSavePreset: (_ rules: [Rule], _ mode: Mode, _ name: String) -> UUID?
    let onCancel: () -> Void
    let onDone: (_ rules: [Rule], _ mode: Mode, _ savedPresetID: UUID?) -> Void

    @State private var showPresetField = false
    @State private var presetName = ""
    @State private var savedPresetID: UUID?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider()
                if model.apps.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                            ForEach(model.filteredApps) { app in
                                appSection(app)
                            }
                        }
                        .padding(24)
                    }
                }
                Divider()
                bottomBar
            }
            .frame(maxWidth: 980, maxHeight: 720)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 30)
            .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 1) {
                Text("Choose what stays open")
                    .font(.headline)
                Text("Click an app to include all of it. Click a window for just that window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps and windows", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            if !screenRecordingAllowed {
                Button {
                    onRequestScreenRecording()
                } label: {
                    Label("Enable window titles", systemImage: "record.circle")
                        .font(.caption)
                }
                .controlSize(.small)
                .help("Window titles need the Screen Recording permission. Whole-app picks work without it.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No other windows are open right now.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: App sections

    private func appSection(_ app: PickerAppInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                appIcon(app, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(app.windows.count) window\(app.windows.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.toggleApp(app)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.isWhole(app) ? "checkmark.circle.fill" : "plus.circle")
                        Text(model.isWhole(app) ? "Whole app" : "Include app")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(model.isWhole(app) ? Theme.allowed.opacity(0.18) : Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(model.isWhole(app) ? Theme.allowed : .primary)
                }
                .buttonStyle(.plain)
                .help("Include every window of \(app.name)")
            }
            .padding(.horizontal, 4)

            if app.windows.isEmpty {
                Text("No on-screen windows")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 10)], spacing: 10) {
                    ForEach(app.windows) { window in
                        windowTile(window, app: app)
                    }
                }
            }
        }
    }

    private func windowTile(_ window: PickerWindowInfo, app: PickerAppInfo) -> some View {
        let included = model.isIncluded(window, in: app)
        let whole = model.isWhole(app)
        return Button {
            model.toggleWindow(window, in: app)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Image(systemName: included ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(included ? Theme.allowed : Color.secondary.opacity(0.5))
                }
                Spacer()
                HStack(spacing: 6) {
                    appIcon(app, size: 22)
                    Text(window.title ?? "Untitled window")
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(whole ? "included with app" : (window.title == nil ? "titles need Screen Recording" : "click for details"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(included ? 0.07 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(included ? Theme.allowed : Color.secondary.opacity(0.25), lineWidth: included ? 2 : 1)
            )
            .opacity(included ? 1 : 0.75)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(window.title == nil && !whole)
        .help(windowTitleHelp(window, app: app))
    }

    private func windowTitleHelp(_ window: PickerWindowInfo, app: PickerAppInfo) -> String {
        if model.isWhole(app) { return "\(app.name) is included as a whole app" }
        if window.title == nil { return "Window titles need the Screen Recording permission — include \(app.name) as a whole app instead" }
        return "Allow only this window of \(app.name)"
    }

    @ViewBuilder
    private func appIcon(_ app: PickerAppInfo, size: CGFloat) -> some View {
        if let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app")
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if model.allowsPresetSave {
                savePresetRow
            }
            HStack(spacing: 12) {
                summaryText
                Spacer()
                if showPresetField || !model.allowsPresetSave {
                    modePicker
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button {
                    let id = savedPresetID ?? (showPresetField ? savePresetNow() : nil)
                    onDone(model.rules(), model.mode, id)
                } label: {
                    Text("Done")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var summaryText: some View {
        let summary = model.summary
        var parts = ["\(summary.appCount) app\(summary.appCount == 1 ? "" : "s") allowed"]
        if summary.windowCount > 0 {
            parts.append("\(summary.windowCount) by window title")
        }
        if model.wholeAppBundles.isEmpty && summary.windowCount == 0 {
            parts = ["nothing allowed yet"]
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var savePresetRow: some View {
        if showPresetField {
            HStack(spacing: 8) {
                Text("Save as preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Preset name", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { _ = savePresetNow() }
                Button("Save") { _ = savePresetNow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                if savedPresetID != nil {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.allowed)
                }
                Spacer()
            }
        } else {
            HStack {
                Button {
                    showPresetField = true
                    if presetName.isEmpty {
                        presetName = "My allowlist"
                    }
                } label: {
                    Label("Save as preset…", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var modePicker: some View {
        Picker("Mode", selection: $model.mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 230)
        .help("What happens to non-allowed apps")
    }

    @discardableResult
    private func savePresetNow() -> UUID? {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let id = onSavePreset(model.rules(), model.mode, name)
        if id != nil {
            savedPresetID = id
        }
        return id
    }
}
