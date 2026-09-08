import SwiftUI

/// Presets manager: list of presets with built-ins marked, detail pane with
/// name, mode, rule list and URLs to open. Built-ins can be duplicated and
/// edited but never deleted.
struct PresetsManagerView: View {
    let model: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: Preset.ID?
    @State private var draft: Preset?
    @State private var showDeleteAlert = false
    @State private var pendingDeleteID: Preset.ID?

    private var selection: Preset? {
        guard let selectedID else { return nil }
        return model.presets.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                listPane
                Divider()
                detailPane
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 640, height: 500)
        .onChange(of: selectedID) { _, newValue in
            guard let newValue, let preset = model.presets.first(where: { $0.id == newValue }) else {
                draft = nil
                return
            }
            draft = preset
        }
        .alert("Delete this preset?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                guard let pendingDeleteID else { return }
                model.deletePreset(id: pendingDeleteID)
                if selectedID == pendingDeleteID {
                    selectedID = nil
                    draft = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        let isBuiltIn = model.presets.first { $0.id == pendingDeleteID }?.isBuiltIn ?? false
        var text = "Tasks using it fall back to a custom allowlist."
        if isBuiltIn {
            text += " Deleted built-ins can be restored from the list."
        }
        return text
    }

    // MARK: List pane

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Presets")
                    .font(.headline)
                Spacer()
                Button {
                    let preset = model.addPreset(name: model.uniquePresetName(basedOn: "New Preset"), mode: model.settings.defaultMode)
                    selectedID = preset.id
                    draft = preset
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New preset")
            }
            .padding(12)

            List(model.presets, selection: $selectedID) { preset in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(preset.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if preset.isBuiltIn {
                            Text("Built-in")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }
                    Text("\(preset.mode.displayName) · \(preset.rules.count) rule\(preset.rules.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(preset.id)
            }
            .listStyle(.inset)

            if !model.removedBuiltinNames.isEmpty {
                Button {
                    model.restoreBuiltins()
                } label: {
                    Label("Restore built-in presets", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(12)
                .help("Bring back \(model.removedBuiltinNames.joined(separator: ", "))")
            }
        }
        .frame(width: 230)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let draft {
            detail(for: draft)
        } else if let preset = selection {
            // First selection of a session (before any onChange fired).
            Color.clear.onAppear { self.draft = preset }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("Select a preset")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(for preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if preset.isBuiltIn {
                    Text(preset.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                } else {
                    TextField("Name", text: Binding(
                        get: { draft?.name ?? "" },
                        set: { draft?.name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(maxWidth: 220)
                }
                Spacer()
                Button("Duplicate") { duplicate(preset) }
                Button("Delete", role: .destructive) {
                    pendingDeleteID = preset.id
                    showDeleteAlert = true
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Picker("Mode", selection: Binding(
                        get: { draft?.mode ?? .dark },
                        set: { draft?.mode = $0 }
                    )) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    Spacer()
                }
                // What the picked mode does to apps that are not allowed.
                Text("\((draft?.mode ?? .dark).detail) while a task with this preset runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 68)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rules")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        pickVisually(for: preset)
                    } label: {
                        Label("Pick visually…", systemImage: "macwindow.on.rectangle")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .help("Choose windows and apps for this preset with the picker overlay")
                }
                // Long rule lists scroll here, so the header, the mode row
                // and the save row stay in place.
                ScrollView {
                    RulesEditorView(rules: Binding(
                        get: { draft?.rules ?? [] },
                        set: { draft?.rules = $0 }
                    ))
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            Divider()

            HStack {
                Text("Save changes")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { draft = selection }
                    .buttonStyle(.bordered)
                Button("Save") {
                    if var preset = draft {
                        preset.name = preset.name.trimmingCharacters(in: .whitespaces)
                        model.updatePreset(preset)
                        draft = selection
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft == selection)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func duplicate(_ preset: Preset) {
        if let copy = model.duplicatePreset(id: preset.id) {
            selectedID = copy.id
            draft = copy
        }
    }

    /// Opens the exposé overlay seeded with the preset's rules; the result
    /// edits the unsaved draft (mode included).
    private func pickVisually(for preset: Preset) {
        PickerOverlayPresenter.shared.present(
            model: model,
            initialRules: preset.rules,
            mode: preset.mode,
            allowPresetSave: false
        ) { [self] result in
            guard let result else { return }
            self.draft?.rules = result.rules
            self.draft?.mode = result.mode
        }
    }
}
