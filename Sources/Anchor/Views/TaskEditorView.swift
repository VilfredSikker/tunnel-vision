import SwiftUI

/// Add or edit a task: title, duration (25/50 defaults plus custom), preset
/// (pre-filled with the last used preset) and allowlist rules.
/// The visual picker overlay replaces manual rule editing in a later build step.
struct TaskEditorView: View {
    let model: AppState
    let task: TaskItem?

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var minutes: Int
    @State private var presetID: UUID?
    @State private var overrides: [Rule]
    @State private var editingRules = false

    init(model: AppState, task: TaskItem?) {
        self.model = model
        self.task = task
        _title = State(initialValue: task?.title ?? "")
        _minutes = State(initialValue: Int((task?.durationSeconds ?? 25 * 60) / 60))
        _presetID = State(initialValue: task?.presetID ?? model.defaultPresetID)
        _overrides = State(initialValue: task?.overrides ?? [])
        _editingRules = State(initialValue: task != nil && !(task?.overrides.isEmpty ?? true))
    }

    private var isEditing: Bool { task != nil }
    private var selectedPreset: Preset? {
        guard let presetID else { return nil }
        return model.presets.first { $0.id == presetID }
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
                        Text(selectedPreset?.name ?? "Custom allowlist")
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
                    durationChip(25)
                    durationChip(50)
                }
                Stepper(value: $minutes, in: 1...240) {
                    Text("\(minutes) min")
                        .monospacedDigit()
                        .frame(minWidth: 56)
                }
                .fixedSize()
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
            } else {
                Text("Custom allowlist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RulesEditorView(rules: $overrides)
            }
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
            model.updateTask(updated)
        } else {
            model.addTask(
                title: trimmed,
                durationSeconds: TimeInterval(minutes * 60),
                presetID: presetID,
                overrides: overrides
            )
        }
        dismiss()
    }
}
