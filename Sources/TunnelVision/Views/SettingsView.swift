import AppKit
import SwiftUI

/// Settings window: durations, defaults, launch at login, shortcuts, the
/// floating countdown, the browsers Tunnel Vision steers, and the permissions the
/// window and browser layers need.
struct SettingsView: View {
    let model: AppState

    @State private var workMinutes: Int
    @State private var breakMinutes: Int
    @State private var defaultMode: Mode
    @State private var strictMode: Bool
    @State private var soundOn: Bool
    @State private var toggleHotKey: HotKey?
    @State private var newTaskHotKey: HotKey?
    @State private var startPauseHotKey: HotKey?
    @State private var pickerHotKey: HotKey?
    @State private var showCountdownWindow: Bool
    @State private var countdownStyle: CountdownStyle
    @State private var unmanagedBrowsers: Set<String>
    @State private var launchAtLogin: Bool
    @State private var launchAtLoginError = ""
    @State private var installedBrowsers: [Browsers.Installed]

    init(model: AppState) {
        self.model = model
        let settings = model.settings
        _workMinutes = State(initialValue: Int(settings.workSeconds / 60))
        _breakMinutes = State(initialValue: Int(settings.breakSeconds / 60))
        _defaultMode = State(initialValue: settings.defaultMode)
        _strictMode = State(initialValue: settings.strictMode)
        _soundOn = State(initialValue: settings.soundOn)
        _toggleHotKey = State(initialValue: settings.toggleHotKey)
        _newTaskHotKey = State(initialValue: settings.newTaskHotKey)
        _startPauseHotKey = State(initialValue: settings.startPauseHotKey)
        _pickerHotKey = State(initialValue: settings.pickerHotKey)
        _showCountdownWindow = State(initialValue: settings.showCountdownWindow)
        _countdownStyle = State(initialValue: settings.countdownStyle)
        _unmanagedBrowsers = State(initialValue: Set(settings.unmanagedBrowsers))
        _launchAtLogin = State(initialValue: LaunchAtLogin.state == .enabled)
        _installedBrowsers = State(initialValue: Browsers.installed())
    }

    var body: some View {
        Form {
            Section("Durations") {
                Stepper(value: $workMinutes, in: 5...240, step: 5) {
                    LabeledContent {
                        Text("\(workMinutes) min").monospacedDigit()
                    } label: {
                        Text("Default work")
                    }
                }
                Stepper(value: $breakMinutes, in: 1...60) {
                    LabeledContent {
                        Text("\(breakMinutes) min").monospacedDigit()
                    } label: {
                        Text("Default break")
                    }
                }
            }

            Section("Defaults") {
                Picker("Mode for new presets", selection: $defaultMode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("Strict mode", isOn: $strictMode)
                Text("In strict mode, ending a session early requires typing the task title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Sounds", isOn: $soundOn)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .disabled(LaunchAtLogin.state == .unavailable)
                Text(launchAtLoginCaption)
                    .font(.caption)
                    .foregroundStyle(launchAtLoginError.isEmpty ? .secondary : Theme.blocked)
                if LaunchAtLogin.state == .requiresApproval {
                    Button("Open Login Items…") { LaunchAtLogin.openLoginItemsSettings() }
                        .controlSize(.small)
                }
            }

            Section("Shortcuts") {
                shortcutRow(.togglePanel, hotKey: $toggleHotKey)
                shortcutRow(.newTask, hotKey: $newTaskHotKey)
                shortcutRow(.startPause, hotKey: $startPauseHotKey)
                shortcutRow(.openPicker, hotKey: $pickerHotKey)
                Text("Work from any app. Click a field and press the keys; Esc cancels, Delete clears. Start or pause starts the next task when nothing runs. The picker opens for the running task, else the next one up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Countdown") {
                Toggle("Floating countdown while a session runs", isOn: $showCountdownWindow)
                Text("A small always-on-top timer for when the menu bar is out of sight, such as in full-screen apps. Drag it anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Style", selection: $countdownStyle) {
                    ForEach(CountdownStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!showCountdownWindow)
                Text("Garden grows a flower over a short session, a plant over a medium one and a forest over a long one. It keeps whatever grew when a session stops early.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Browsers") {
                if installedBrowsers.isEmpty {
                    Text("No supported browser is installed. Site rules work in Safari and Chromium browsers such as Chrome, Brave, Edge, Vivaldi, Arc and Helium.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(installedBrowsers) { browser in
                        Toggle(browser.name, isOn: managedBinding(browser.bundleID))
                    }
                }
                Text("In a managed browser, a task's site rules hold: a window that wanders off its allowed sites is sent back within a second. Each browser asks once for Automation permission. Firefox exposes nothing to scripting and cannot be managed; its site rules allow the whole app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    permissionRows
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onChange(of: workMinutes) { _, _ in apply() }
        .onChange(of: breakMinutes) { _, _ in apply() }
        .onChange(of: defaultMode) { _, _ in apply() }
        .onChange(of: strictMode) { _, _ in apply() }
        .onChange(of: soundOn) { _, _ in apply() }
        .onChange(of: toggleHotKey) { _, value in
            keepShortcutUnique(value, in: .togglePanel)
            apply()
        }
        .onChange(of: newTaskHotKey) { _, value in
            keepShortcutUnique(value, in: .newTask)
            apply()
        }
        .onChange(of: startPauseHotKey) { _, value in
            keepShortcutUnique(value, in: .startPause)
            apply()
        }
        .onChange(of: pickerHotKey) { _, value in
            keepShortcutUnique(value, in: .openPicker)
            apply()
        }
        .onChange(of: showCountdownWindow) { _, _ in apply() }
        .onChange(of: countdownStyle) { _, _ in apply() }
        .onChange(of: unmanagedBrowsers) { _, _ in apply() }
        .onChange(of: launchAtLogin) { _, value in applyLaunchAtLogin(value) }
    }

    // MARK: Rows

    private func shortcutRow(_ slot: HotKeyCenter.Slot, hotKey: Binding<HotKey?>) -> some View {
        LabeledContent(slot.title) {
            HStack(spacing: 6) {
                ShortcutRecorder(hotKey: hotKey)
                if hotKey.wrappedValue != nil {
                    Button {
                        hotKey.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the shortcut")
                }
            }
        }
    }

    /// One key, one job: the same shortcut cannot register twice.
    private func keepShortcutUnique(_ value: HotKey?, in slot: HotKeyCenter.Slot) {
        guard let value else { return }
        if slot != .togglePanel, toggleHotKey == value { toggleHotKey = nil }
        if slot != .newTask, newTaskHotKey == value { newTaskHotKey = nil }
        if slot != .startPause, startPauseHotKey == value { startPauseHotKey = nil }
        if slot != .openPicker, pickerHotKey == value { pickerHotKey = nil }
    }

    private func managedBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(
            get: { !unmanagedBrowsers.contains(bundleID) },
            set: { managed in
                if managed {
                    unmanagedBrowsers.remove(bundleID)
                } else {
                    unmanagedBrowsers.insert(bundleID)
                }
            }
        )
    }

    @ViewBuilder
    private var permissionRows: some View {
        let trusted = AccessibilityPermission.isTrusted
        LabeledContent("Accessibility") {
            HStack(spacing: 8) {
                Label(trusted ? "Granted" : "Not granted", systemImage: trusted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(trusted ? Theme.allowed : .secondary)
                    .font(.caption)
                if !trusted {
                    Button("Grant…") { AccessibilityPermission.request() }
                        .controlSize(.small)
                }
            }
        }
        Text("Window rules need it: inside an app allowed by window, other windows are minimised, and the picker shows window titles. Without it, a window rule allows the whole app.")
            .font(.caption)
            .foregroundStyle(.secondary)
        LabeledContent("Automation") {
            Button("Open System Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
            .controlSize(.small)
        }
        Text("Each managed browser asks once, the first time Tunnel Vision reads its windows. Declined browsers are left alone; re-enable them under Automation.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var launchAtLoginCaption: String {
        if !launchAtLoginError.isEmpty { return launchAtLoginError }
        switch LaunchAtLogin.state {
        case .enabled: return "Tunnel Vision starts with your Mac, as a menu bar item."
        case .disabled: return "Start Tunnel Vision with your Mac, as a menu bar item."
        case .requiresApproval: return "Waiting for approval in System Settings > General > Login Items."
        case .unavailable: return "Available when Tunnel Vision runs from its app bundle (make app)."
        }
    }

    // MARK: Apply

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (LaunchAtLogin.state == .enabled || LaunchAtLogin.state == .requiresApproval) else { return }
        do {
            try LaunchAtLogin.set(enabled)
            launchAtLoginError = ""
        } catch {
            launchAtLoginError = "Could not change login items: \(error.localizedDescription)"
            launchAtLogin = LaunchAtLogin.state == .enabled
        }
    }

    private func apply() {
        model.updateSettings(Settings(
            workSeconds: TimeInterval(workMinutes * 60),
            breakSeconds: TimeInterval(breakMinutes * 60),
            strictMode: strictMode,
            defaultMode: defaultMode,
            soundOn: soundOn,
            toggleHotKey: toggleHotKey,
            newTaskHotKey: newTaskHotKey,
            startPauseHotKey: startPauseHotKey,
            pickerHotKey: pickerHotKey,
            showCountdownWindow: showCountdownWindow,
            countdownStyle: countdownStyle,
            unmanagedBrowsers: unmanagedBrowsers.sorted()
        ))
    }
}
