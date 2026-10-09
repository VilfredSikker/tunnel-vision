import SwiftUI

/// Add or edit a task: title, duration (15/25/60 quick picks plus a minutes
/// field), preset (none until one is picked) and allowlist rules.
/// The visual picker overlay replaces manual rule editing in a later build step.
/// A background task swaps the focus rows (preset, duration, allowlist) for
/// its done-when and the herdr agent it goes to.
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
    @State private var isBackground: Bool
    @State private var doneWhen: String
    @State private var assignee: AgentRef?
    @State private var urlsText: String

    init(model: AppState, task: TaskItem?) {
        self.model = model
        self.task = task
        _title = State(initialValue: task?.title ?? "")
        _minutes = State(initialValue: Int((task?.durationSeconds ?? 25 * 60) / 60))
        _presetID = State(initialValue: task?.presetID)
        _overrides = State(initialValue: task?.overrides ?? [])
        _repeatDaily = State(initialValue: task?.repeatDaily ?? false)
        _priority = State(initialValue: task?.priority ?? 2)
        _editingRules = State(initialValue: task != nil && !(task?.overrides.isEmpty ?? true))
        _isBackground = State(initialValue: task?.isBackground ?? false)
        _doneWhen = State(initialValue: task?.doneWhen ?? "")
        _assignee = State(initialValue: task?.background?.assignee)
        _urlsText = State(initialValue: (task?.urlsToOpen ?? []).joined(separator: "\n"))
    }

    private var isEditing: Bool { task != nil }
    /// Already with its agent: the agent can no longer change.
    private var sentStatus: BackgroundStatus? {
        guard let info = task?.background, info.sentAt != nil else { return nil }
        return info.status
    }
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

            Toggle(isOn: $isBackground) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Run in the background")
                        .font(.callout)
                    Text("A Claude Code agent in herdr works on it while you focus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            // An agent working on it keeps it; turning it back into a focus
            // task would leave its prompts without a row.
            .disabled(sentStatus?.holdsPane == true)
            .help(sentStatus?.holdsPane == true ? "Its agent is working on it" : "")

            if isBackground {
                backgroundSection
            } else {
                presetAndDuration
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

            if !isBackground {
                urlsSection
            }

            if !isBackground {
                allowlistSection
            }

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

    // MARK: Focus task

    @ViewBuilder
    private var presetAndDuration: some View {
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
    }

    // MARK: Background task

    /// The outcome the agent works toward and the agent it goes to.
    @ViewBuilder
    private var backgroundSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Done when")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            TextField("Done when…", text: $doneWhen, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
        }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Agent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                agentMenu
                    .disabled(sentStatus != nil)
                    .help(sentStatus != nil ? "Already sent; a sent task keeps its agent" : "The herdr agent that works on this task")
                Spacer()
            }
            Text(BackgroundPresentation.readinessHint(
                doneWhen: doneWhen,
                assignee: assignee,
                stored: model.tasks.first { $0.id == task?.id }?.background,
                startsWithFocus: model.settings.startBackgroundTasksWithFocus
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 68)
        }
        .task {
            await model.background.refreshAgents()
        }
    }

    private var agentMenu: some View {
        Menu {
            Button("Unassigned") { assignee = nil }
            Divider()
            if !model.background.isHerdrReachable {
                Text("herdr isn't running")
            } else if model.background.agents.isEmpty {
                Text("No agents in herdr")
            }
            ForEach(BackgroundPresentation.agentGroups(model.background.agents, labels: model.background.workspaceLabels), id: \.label) { group in
                Section(group.label) {
                    ForEach(group.agents) { agent in
                        Button {
                            assignee = model.background.reference(for: agent)
                        } label: {
                            if assignee?.paneID == agent.paneID {
                                Label(BackgroundPresentation.agentTitle(agent), systemImage: "checkmark")
                            } else {
                                Text(BackgroundPresentation.agentTitle(agent))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(assignee.map { BackgroundPresentation.workspaceLabel(for: $0, labels: model.background.workspaceLabels) } ?? "Unassigned")
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
    }

    private func durationChip(_ minutesValue: Int) -> some View {
        Button("\(minutesValue)") {
            minutes = minutesValue
        }
        .buttonStyle(.bordered)
        .tint(minutes == minutesValue ? .accentColor : nil)
        .controlSize(.small)
    }

    /// One URL per line, opened when the task starts (after the preset's own).
    private var urlsSection: some View {
        HStack(alignment: .top) {
            Text("Open")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
                .padding(.top, 4)
            TextEditor(text: $urlsText)
                .font(.callout.monospaced())
                .frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .help("URLs to open when the task starts, one per line, e.g. github.com/you/repo")
        }
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
                Spacer()
            }
            if !visualPickNotice.isEmpty {
                Text(visualPickNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        // The model keeps the run state of a task already out; the editor
        // only decides whether it is background and who it goes to.
        let urls = AppState.urlLines(urlsText)
        var background: BackgroundInfo?
        if isBackground {
            background = task?.background ?? BackgroundInfo()
            background?.assignee = assignee
        }
        if let task {
            var updated = task
            updated.title = trimmed
            updated.durationSeconds = TimeInterval(minutes * 60)
            updated.presetID = presetID
            updated.overrides = overrides
            updated.repeatDaily = repeatDaily
            updated.priority = priority
            updated.urlsToOpen = urls
            if isBackground {
                updated.doneWhen = doneWhen
            }
            updated.background = background
            model.updateTask(updated)
        } else {
            model.addTask(
                title: trimmed,
                durationSeconds: TimeInterval(minutes * 60),
                presetID: presetID,
                overrides: overrides,
                repeatDaily: repeatDaily,
                priority: priority,
                doneWhen: isBackground ? doneWhen : "",
                background: background,
                urlsToOpen: urls
            )
        }
        dismiss()
    }
}
