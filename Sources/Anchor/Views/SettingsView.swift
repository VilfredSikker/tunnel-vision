import SwiftUI

/// Settings window. Only surfaces that already exist in this build step are
/// editable; the rest is listed as coming next.
struct SettingsView: View {
    let model: AppState

    @State private var workMinutes: Int
    @State private var breakMinutes: Int
    @State private var defaultMode: Mode
    @State private var strictMode: Bool
    @State private var soundOn: Bool
    @State private var toggleHotKey: HotKey?
    @State private var showCountdownWindow: Bool

    init(model: AppState) {
        self.model = model
        let settings = model.settings
        _workMinutes = State(initialValue: Int(settings.workSeconds / 60))
        _breakMinutes = State(initialValue: Int(settings.breakSeconds / 60))
        _defaultMode = State(initialValue: settings.defaultMode)
        _strictMode = State(initialValue: settings.strictMode)
        _soundOn = State(initialValue: settings.soundOn)
        _toggleHotKey = State(initialValue: settings.toggleHotKey)
        _showCountdownWindow = State(initialValue: settings.showCountdownWindow)
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

            Section("Shortcut") {
                LabeledContent("Open or close Anchor") {
                    HStack(spacing: 6) {
                        ShortcutRecorder(hotKey: $toggleHotKey)
                        if toggleHotKey != nil {
                            Button {
                                toggleHotKey = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove the shortcut")
                        }
                    }
                }
                Text("Works from any app. Click the field and press the keys; Esc cancels, Delete clears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Countdown") {
                Toggle("Floating countdown while a session runs", isOn: $showCountdownWindow)
                Text("A small always-on-top timer for when the menu bar is out of sight, such as in full-screen apps. Drag it anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Coming in the next build") {
                Text("Per-window and per-URL discipline (window-level matching via Accessibility, site rules inside browsers), launch at login, shortcuts for start/pause and the picker, browsers to manage, and picker support on every display are next; their settings land here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: workMinutes) { _, _ in apply() }
        .onChange(of: breakMinutes) { _, _ in apply() }
        .onChange(of: defaultMode) { _, _ in apply() }
        .onChange(of: strictMode) { _, _ in apply() }
        .onChange(of: soundOn) { _, _ in apply() }
        .onChange(of: toggleHotKey) { _, _ in apply() }
        .onChange(of: showCountdownWindow) { _, _ in apply() }
    }

    private func apply() {
        model.updateSettings(Settings(
            workSeconds: TimeInterval(workMinutes * 60),
            breakSeconds: TimeInterval(breakMinutes * 60),
            strictMode: strictMode,
            defaultMode: defaultMode,
            soundOn: soundOn,
            toggleHotKey: toggleHotKey,
            showCountdownWindow: showCountdownWindow
        ))
    }
}
