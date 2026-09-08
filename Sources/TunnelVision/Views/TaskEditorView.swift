import SwiftUI

/// Add or edit a task: title, duration (15/25/60 quick picks plus a minutes
/// field), preset (pre-filled with the last used preset) and allowlist rules.
/// The visual picker overlay replaces manual rule editing in a later build step.
struct TaskEditorView: View {
    let model: AppState
    let task: TaskItem?

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var minutes: Int
    @State private var presetID: UUID?
    @State private var overrides: [Rule]
    @State private var repeatDaily: Bool
    @State private var priority: Int
    @State private var editingRules = false
    @State private var visualPickNotice = ""

    init(model: AppState, task: TaskItem?) {
        self.model = model
        self.task = task
        _title = State(initialValue: task?.title ?? "")
        _minutes = State(initialValue: Int((task?.durationSeconds ?? 25 * 60) / 60))
        _presetID = State(initialValue: task?.presetID ?? model.defaultPresetID)
        _overrides = State(initialValue: task?.overrides ?? [])
        _repeatDaily = State(initialValue: task?.repeatDaily ?? false)
        _priority = State(initialValue: task?.priority ?? 2)
        _editingRules = State(initialValue: task != nil && !(task?.overrides.isEmpty ?? true))
    }

    private var isEditing: Bool { task != nil }
    private var selectedPreset: Preset? {
        guard let presetID else { return nil }
        return model.presets.first { $0.id == presetID }
    }
    /// Menu label when no preset is selected: "No preset" when the task is
    /// open (nothing allowed is locked), "Custom allowlist" when it carries
    /// its own rules.
    private var presetMenuFallback: String {
        overrides.isEmpty ? "No preset" : "Custom allowlist"
    }
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit task" : "New task")
                .font(.headline)

            TextField("What are you working on?", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Text("Preset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Menu {
                    Button("No preset") {
                        presetID = nil
                        overrides = []
                    }
                    Button("Custom allowlist") {
                        presetID = nil
                        editingRules = true
                    }
                    Divider()
                    ForEach(model.presets) { preset in
                        Button(preset.name) {
                            presetID = preset.id
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedPreset?.name ?? presetMenuFallback)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }

            HStack {
                Text("Duration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                HStack(spacing: 6) {
                    durationChip(15)
                    durationChip(25)
                    durationChip(60)
                }
                TextField("min", value: $minutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 52)
                    .onChange(of: minutes) { _, value in
                        // Anything from a minute to ten hours.
                        minutes = min(600, max(1, value))
                    }
                Text("min")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Toggle(isOn: $repeatDaily) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Repeat daily")
                        .font(.callout)
                    Text("Comes back each day until checked off or deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                Text("Priority")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Picker("Priority", selection: $priority) {
                    Text("High").tag(1)
                    Text("Medium").tag(2)
                    Text("Low").tag(3)
                }
                .pickerStyle(.segmented)
                Spacer()
            }

            allowlistSection

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add task") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func durationChip(_ minutesValue: Int) -> some View {
        Button("\(minutesValue)") {
            minutes = minutesValue
        }
        .buttonStyle(.bordered)
        .tint(minutes == minutesValue ? .accentColor : nil)
        .controlSize(.small)
    }

    // MARK: Allowlist

    @ViewBuilder
    private var allowlistSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    startVisualPicker()
                } label: {
                    Label("Pick windows & apps…", systemImage: "macwindow.on.rectangle")
                        .font(.callout)
                }
                if !visualPickNotice.isEmpty {
                    Text(visualPickNotice)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if let preset = selectedPreset {
                HStack {
                    Text("Allowlist from “\(preset.name)” — \(preset.rules.count) rule\(preset.rules.count == 1 ? "" : "s"), \(preset.mode.displayName.lowercased()) mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(editingRules ? "Hide extra rules" : "Edit allowlist") {
                        editingRules.toggle()
                        if overrides.isEmpty && !editingRules {
                            overrides = []
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
                if editingRules {
                    RulesEditorView(rules: $overrides)
                }
            } else if !overrides.isEmpty {
                Text("Custom allowlist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RulesEditorView(rules: $overrides)
            } else {
                // No preset and no custom rules: the session runs open with
                // every app allowed.
                Text("No preset — every app may run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Visual picker

    /// The picker edits the complete allowlist. Because the result may remove
    /// apps the preset allowed (no deny rules yet), the task materialises its
    /// own copy and drops the preset reference — "what you see is what locks".
    private func startVisualPicker() {
        let baseRules: [Rule]
        let startMode: Mode
        if let presetID, let preset = model.presets.first(where: { $0.id == presetID }) {
            baseRules = preset.rules + overrides
            startMode = preset.mode
        } else {
            baseRules = overrides
            startMode = model.settings.defaultMode
        }
        let hadPreset = presetID != nil
        PickerOverlayPresenter.shared.present(
            model: model,
            initialRules: baseRules,
            mode: startMode,
            allowPresetSave: true
        ) { [self] result in
            guard let result else { return }
            if let savedPresetID = result.savedPresetID {
                presetID = savedPresetID
                overrides = []
                visualPickNotice = ""
            } else {
                presetID = nil
                overrides = result.rules
                visualPickNotice = hadPreset
                    ? "Switched to a custom allowlist for this task — “\(result.mode.displayName)” applies as default mode."
                    : "Custom allowlist — “\(result.mode.displayName)” mode applies from Settings."
            }
            editingRules = presetID == nil && !overrides.isEmpty
        }
    }

    // MARK: Save

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let task {
            var updated = task
            updated.title = trimmed
            updated.durationSeconds = TimeInterval(minutes * 60)
            updated.presetID = presetID
            updated.overrides = overrides
            updated.repeatDaily = repeatDaily
            updated.priority = priority
            model.updateTask(updated)
        } else {
            model.addTask(
                title: trimmed,
                durationSeconds: TimeInterval(minutes * 60),
                presetID: presetID,
                overrides: overrides,
                repeatDaily: repeatDaily,
                priority: priority
            )
        }
        dismiss()
    }
}
