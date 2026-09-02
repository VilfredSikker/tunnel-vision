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

    init(model: AppState) {
        self.model = model
        let settings = model.settings
        _workMinutes = State(initialValue: Int(settings.workSeconds / 60))
        _breakMinutes = State(initialValue: Int(settings.breakSeconds / 60))
        _defaultMode = State(initialValue: settings.defaultMode)
        _strictMode = State(initialValue: settings.strictMode)
        _soundOn = State(initialValue: settings.soundOn)
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

            Section("Coming in the next build") {
                Text("App enforcement (dark / closed / frozen), the visual picker overlay, hotkeys, launch at login and browsers to manage are next; their settings land here.")
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
    }

    private func apply() {
        model.updateSettings(Settings(
            workSeconds: TimeInterval(workMinutes * 60),
            breakSeconds: TimeInterval(breakMinutes * 60),
            strictMode: strictMode,
            defaultMode: defaultMode,
            soundOn: soundOn
        ))
    }
}
