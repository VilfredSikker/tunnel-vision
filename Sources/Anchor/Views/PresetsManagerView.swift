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
        HStack(spacing: 0) {
            listPane
            Divider()
            detailPane
        }
        .frame(width: 640, height: 460)
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
            Text("Tasks using it fall back to a custom allowlist.")
        }
    }

    // MARK: List pane

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Presets")
                    .font(.headline)
                Spacer()
                Button {
                    let preset = model.addPreset(name: uniqueName("New Preset"), mode: model.settings.defaultMode)
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
        }
        .frame(width: 230)
    }

    private func uniqueName(_ base: String) -> String {
        let existing = Set(model.presets.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
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
                if !preset.isBuiltIn {
                    Button("Delete", role: .destructive) {
                        pendingDeleteID = preset.id
                        showDeleteAlert = true
                    }
                }
            }

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
                .frame(maxWidth: 260)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RulesEditorView(rules: Binding(
                    get: { draft?.rules ?? [] },
                    set: { draft?.rules = $0 }
                ))
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
}
