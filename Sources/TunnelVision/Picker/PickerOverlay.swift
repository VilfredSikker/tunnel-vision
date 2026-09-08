import AppKit
import Observation
import SwiftUI

/// Selection state for the picker overlay.
@MainActor
@Observable
final class PickerOverlayModel {
    /// Mutable so browser URLs can be filled in after the overlay opens.
    private(set) var apps: [PickerAppInfo]
    var search = ""
    var wholeAppBundles: Set<String>
    var windowIDs: Set<CGWindowID>
    /// Picked browser windows whose rule covers the whole site, not the page.
    var siteWideWindowIDs: Set<CGWindowID>
    /// Picked herdr workspace labels, lowercased.
    var herdrLabels: Set<String>
    /// herdr workspaces and the terminal hosting them; arrives asynchronously.
    var herdr: PickerHerdrInfo?
    var mode: Mode
    let allowsPresetSave: Bool

    // Save-as-preset state lives here so every display shows the same thing.
    var showPresetField = false
    var presetName = ""
    var savedPresetID: UUID?

    init(
        apps: [PickerAppInfo],
        wholeAppBundles: Set<String>,
        windowIDs: Set<CGWindowID>,
        siteWideWindowIDs: Set<CGWindowID> = [],
        herdrLabels: Set<String> = [],
        mode: Mode,
        allowsPresetSave: Bool
    ) {
        self.apps = apps
        self.wholeAppBundles = wholeAppBundles
        self.windowIDs = windowIDs
        self.siteWideWindowIDs = siteWideWindowIDs
        self.herdrLabels = herdrLabels
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
            let appMatches = app.name.lowercased().contains(query)
                || app.bundleID.lowercased().contains(query)
                || herdrWorkspaces(hostedBy: app).contains { $0.label.lowercased().contains(query) }
            let windows = app.windows.filter { ($0.displayName?.lowercased() ?? "").contains(query) }
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
            siteWideWindowIDs.remove(window.id)
        }
    }

    /// Click on a window tile: if the whole app was included, narrow down to
    /// just this window; otherwise toggle the window. Narrowing to a window
    /// without a title or URL is refused — such a pick could never become a
    /// rule and would silently un-allow the app.
    func toggleWindow(_ window: PickerWindowInfo, in app: PickerAppInfo) {
        guard window.displayName != nil else { return }
        if wholeAppBundles.contains(app.bundleID) {
            wholeAppBundles.remove(app.bundleID)
        }
        if windowIDs.contains(window.id) {
            windowIDs.remove(window.id)
            siteWideWindowIDs.remove(window.id)
        } else {
            windowIDs.insert(window.id)
        }
    }

    // MARK: Browser windows: page or site

    /// A browser window is picked by URL; the rule covers the page (host and
    /// path) or, site-wide, everything on the host.
    func isSiteWide(_ window: PickerWindowInfo) -> Bool {
        siteWideWindowIDs.contains(window.id)
    }

    func setSiteWide(_ siteWide: Bool, for window: PickerWindowInfo) {
        if siteWide {
            siteWideWindowIDs.insert(window.id)
        } else {
            siteWideWindowIDs.remove(window.id)
        }
    }

    /// The URL pattern a picked browser window turns into, for the tile.
    func urlPattern(for window: PickerWindowInfo) -> String? {
        guard let url = window.url, let page = PickerWindowInfo.pattern(fromURL: url) else { return nil }
        return isSiteWide(window) ? (URLPattern.site(fromURL: url) ?? page) : page
    }

    // MARK: herdr workspaces

    /// The herdr workspaces shown under this app's section (only the host).
    func herdrWorkspaces(hostedBy app: PickerAppInfo) -> [HerdrWorkspace] {
        guard let herdr, herdr.hostBundleID == app.bundleID else { return [] }
        return herdr.workspaces
    }

    /// herdr workspaces whose host terminal is unknown or not listed get
    /// their own section.
    var standaloneHerdr: PickerHerdrInfo? {
        guard let herdr else { return nil }
        if let host = herdr.hostBundleID, apps.contains(where: { $0.bundleID == host }) {
            return nil
        }
        return herdr
    }

    func isPicked(_ workspace: HerdrWorkspace) -> Bool {
        herdrLabels.contains(workspace.label.lowercased())
    }

    /// Multi-select: each workspace toggles on its own.
    func toggleHerdr(_ workspace: HerdrWorkspace) {
        let key = workspace.label.lowercased()
        if herdrLabels.contains(key) {
            herdrLabels.remove(key)
        } else {
            herdrLabels.insert(key)
        }
    }

    /// Labels as picked, with the display casing of a live workspace when
    /// one matches (rules seeded from a preset may name closed workspaces).
    func pickedHerdrRefs() -> [PickedHerdrRef] {
        let host = herdr?.hostBundleID
        return herdrLabels.sorted().map { key in
            let live = herdr?.workspaces.first { $0.label.lowercased() == key }
            return PickedHerdrRef(hostBundleID: host, label: live?.label ?? key)
        }
    }

    // MARK: Summary and rules

    /// Distinct allowed bundles, how many were picked window-only, and how
    /// many herdr workspaces are picked. herdr picks admit their host
    /// terminal as an app.
    var summary: (appCount: Int, windowCount: Int, herdrCount: Int) {
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
        if !herdrLabels.isEmpty, let host = herdr?.hostBundleID {
            bundles.insert(host)
        }
        return (bundles.count, windowOnly, herdrLabels.count)
    }

    var nothingPicked: Bool {
        wholeAppBundles.isEmpty && summary.windowCount == 0 && herdrLabels.isEmpty
    }

    func pickedWindowRefs() -> [PickedWindowRef] {
        var refs: [PickedWindowRef] = []
        for app in apps where !wholeAppBundles.contains(app.bundleID) {
            for window in app.windows where windowIDs.contains(window.id) {
                refs.append(PickedWindowRef(
                    bundleID: app.bundleID,
                    windowID: window.id,
                    title: window.title,
                    url: window.url,
                    siteWide: siteWideWindowIDs.contains(window.id)
                ))
            }
        }
        return refs
    }

    /// Browser URLs arrive after the overlay opens. Windows get their URL
    /// name, and URL rules the seed could only honour as whole-app picks
    /// narrow to the matching windows now that those can be identified.
    func applyWindowURLs(_ urls: [CGWindowID: String], seededFrom rules: [Rule]) {
        guard !urls.isEmpty else { return }
        for appIndex in apps.indices {
            for windowIndex in apps[appIndex].windows.indices {
                if let url = urls[apps[appIndex].windows[windowIndex].id] {
                    apps[appIndex].windows[windowIndex].url = url
                }
            }
        }
        let explicitWhole = Set(rules.filter { $0.effect == .allow && $0.scope == .app }.map(\.bundleID))
        for rule in rules where rule.effect == .allow && rule.scope == .url {
            let matched = SelectionBuilder.windowsMatching(urlRule: rule, in: apps)
            guard !matched.isEmpty else { continue }
            windowIDs.formUnion(matched)
            if SelectionBuilder.isSiteWide(rule.pattern) {
                siteWideWindowIDs.formUnion(matched)
            }
            if !explicitWhole.contains(rule.bundleID) {
                wholeAppBundles.remove(rule.bundleID)
            }
        }
    }

    func rules() -> [Rule] {
        SelectionBuilder.rules(wholeAppBundles: wholeAppBundles, windows: pickedWindowRefs(), herdr: pickedHerdrRefs())
    }
}

/// herdr's workspaces plus the terminal app that hosts the herdr client.
struct PickerHerdrInfo: Equatable, Sendable {
    /// Nil when no running regular app has a herdr client in its process tree.
    let hostBundleID: String?
    let workspaces: [HerdrWorkspace]
}

// MARK: - View

/// Full-screen exposé-style allowlist picker.
struct PickerOverlayView: View {
    @Bindable var model: PickerOverlayModel
    /// Window titles are available (Screen Recording or Accessibility granted).
    let titlesAvailable: Bool
    let onRequestTitles: () -> Void
    /// Creates or updates the named preset (rules + mode) and returns its id,
    /// or nil when the name is empty.
    let onSavePreset: (_ rules: [Rule], _ mode: Mode, _ name: String, _ existingID: UUID?) -> UUID?
    let onCancel: () -> Void
    let onDone: (_ rules: [Rule], _ mode: Mode, _ savedPresetID: UUID?) -> Void

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
                            if let herdr = model.standaloneHerdr, !herdr.workspaces.isEmpty {
                                herdrSection(herdr, standalone: true)
                            }
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
            if !titlesAvailable {
                Button {
                    onRequestTitles()
                } label: {
                    Label("Enable window titles", systemImage: "accessibility")
                        .font(.caption)
                }
                .controlSize(.small)
                .help("Window titles need the Accessibility permission (window-level locking uses it too). Whole-app picks work without it — reopen the picker after granting to pick single windows.")
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
            Text("No other apps are running right now.")
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

            if let herdr = model.herdr, herdr.hostBundleID == app.bundleID, !herdr.workspaces.isEmpty {
                herdrSection(herdr, standalone: false)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: herdr workspaces

    /// Pick any number of workspaces. While the session runs, switching to
    /// another workspace inside herdr bounces back to a picked one.
    private func herdrSection(_ herdr: PickerHerdrInfo, standalone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: standalone ? 20 : 13))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(standalone ? "herdr" : "herdr workspaces")
                        .font(standalone ? .system(size: 15, weight: .semibold) : .caption.weight(.semibold))
                    Text("Pick the workspaces this task may use. Switching to any other bounces back.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if standalone, herdr.hostBundleID == nil {
                    Text("terminal not identified — allow it as an app too")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 10)], spacing: 10) {
                ForEach(herdr.workspaces) { workspace in
                    herdrTile(workspace)
                }
            }
        }
    }

    private func herdrTile(_ workspace: HerdrWorkspace) -> some View {
        let picked = model.isPicked(workspace)
        return Button {
            model.toggleHerdr(workspace)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(picked ? Theme.allowed : Color.secondary.opacity(0.5))
                }
                Spacer()
                Text(workspace.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(herdrCaption(workspace))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(picked ? 0.07 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(picked ? Theme.allowed : Color.secondary.opacity(0.25), lineWidth: picked ? 2 : 1)
            )
            .opacity(picked ? 1 : 0.75)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(picked ? "Allowed herdr workspace — click to drop" : "Allow the herdr workspace “\(workspace.label)”")
    }

    private func herdrCaption(_ workspace: HerdrWorkspace) -> String {
        var parts: [String] = []
        if let repo = workspace.repoName, repo.lowercased() != workspace.label.lowercased() {
            parts.append(repo)
        }
        if workspace.focused {
            parts.append("focused now")
        }
        return parts.isEmpty ? "workspace" : parts.joined(separator: " · ")
    }

    private func windowTile(_ window: PickerWindowInfo, app: PickerAppInfo) -> some View {
        let included = model.isIncluded(window, in: app)
        let whole = model.isWhole(app)
        let name = window.displayName
        // A browser window picked on its own carries a page-or-site choice.
        let showsScope = included && !whole && window.url != nil && model.urlPattern(for: window) != nil
        return VStack(alignment: .leading, spacing: 0) {
            Button {
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
                        Text(name ?? "Untitled window")
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(windowCaption(window, whole: whole))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A window with nothing to match on cannot be picked, whole app or
            // not — an enabled tile that does nothing reads as broken.
            .disabled(name == nil)
            .help(windowTitleHelp(window, app: app))

            if showsScope {
                scopeRow(window)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(included ? 0.07 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(included ? Theme.allowed : Color.secondary.opacity(0.25), lineWidth: included ? 2 : 1)
        )
        .opacity(included ? 1 : 0.75)
    }

    /// Page keeps the host and path; Site widens the rule to the whole host.
    private func scopeRow(_ window: PickerWindowInfo) -> some View {
        let siteWide = model.isSiteWide(window)
        return HStack(spacing: 4) {
            scopeChip("This page", selected: !siteWide) { model.setSiteWide(false, for: window) }
            scopeChip("Whole site", selected: siteWide) { model.setSiteWide(true, for: window) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .help(siteWide
            ? "Every page on \(URLPattern.site(fromURL: window.url ?? "") ?? "this site") is allowed"
            : "Only \(model.urlPattern(for: window) ?? "this page") and pages under it are allowed")
    }

    private func scopeChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(selected ? Theme.allowed.opacity(0.18) : Color.secondary.opacity(0.12)))
                .foregroundStyle(selected ? Theme.allowed : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func windowCaption(_ window: PickerWindowInfo, whole: Bool) -> String {
        guard window.displayName != nil else {
            return titlesAvailable ? "no title to pick it by" : "title needs Accessibility"
        }
        if whole { return "included with app · click for just this one" }
        if let pattern = model.urlPattern(for: window) {
            return model.windowIDs.contains(window.id) ? pattern : "click to allow by URL · \(pattern)"
        }
        return "click to allow just this window"
    }

    private func windowTitleHelp(_ window: PickerWindowInfo, app: PickerAppInfo) -> String {
        if window.displayName == nil {
            return titlesAvailable
                ? "This window has neither a title nor a URL to match on — include \(app.name) as a whole app instead"
                : "Window titles need the Accessibility permission — include \(app.name) as a whole app instead"
        }
        if model.isWhole(app) { return "\(app.name) is included as a whole app — click to keep only this window" }
        if window.url != nil { return "Allow only this page (or site) in \(app.name); other pages are steered back during a session" }
        return "Allow only this window of \(app.name); its other windows are minimised during a session"
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
                if model.showPresetField || !model.allowsPresetSave {
                    modePicker
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button {
                    // A previously saved preset is updated with the final
                    // selection so later toggles are never lost.
                    let saved = model.showPresetField ? savePresetNow() : model.savedPresetID
                    onDone(model.rules(), model.mode, saved)
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
            parts.append("\(summary.windowCount) by window or site")
        }
        if summary.herdrCount > 0 {
            parts.append("\(summary.herdrCount) herdr workspace\(summary.herdrCount == 1 ? "" : "s")")
        }
        if model.nothingPicked {
            parts = ["nothing allowed yet"]
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var savePresetRow: some View {
        if model.showPresetField {
            HStack(spacing: 8) {
                Text("Save as preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Preset name", text: $model.presetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { _ = savePresetNow() }
                Button("Save") { _ = savePresetNow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.savedPresetID != nil {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.allowed)
                }
                Spacer()
            }
        } else {
            HStack {
                Button {
                    model.showPresetField = true
                    if model.presetName.isEmpty {
                        model.presetName = "My allowlist"
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
        let name = model.presetName.trimmingCharacters(in: .whitespaces)
        // Updating an existing preset keeps its stored name when the field
        // was cleared; creating still requires a name.
        if model.savedPresetID == nil && name.isEmpty { return nil }
        let id = onSavePreset(model.rules(), model.mode, name, model.savedPresetID)
        if let id {
            model.savedPresetID = id
        }
        return id
    }
}
