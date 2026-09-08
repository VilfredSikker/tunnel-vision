import AppKit
import SwiftUI

/// Manual allowlist rule editor. Scope + pattern fields per row, with running
/// apps offered for the bundle id. Fallback to the visual picker overlay when
/// no windows are open or a rule needs typing precision.
struct RulesEditorView: View {
    @Binding var rules: [Rule]

    var body: some View {
        VStack(spacing: 6) {
            if rules.isEmpty {
                Text("No rules yet — allow nothing, or add an app below.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach($rules) { $rule in
                RuleRowView(rule: $rule) {
                    rules.removeAll { $0.id == rule.id }
                }
            }
            Button {
                rules.append(Rule())
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption)
        }
    }
}

private struct RuleRowView: View {
    @Binding var rule: Rule
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                scopePicker
                appField
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove rule")
            }
            if rule.scope != .app {
                TextField(patternPlaceholder, text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var patternPlaceholder: String {
        switch rule.scope {
        case .window: "Window title pattern"
        case .herdr: "herdr workspace label, e.g. promodoro-cop"
        case .app, .url: "URL pattern, e.g. github.com/org/repo"
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $rule.scope) {
            ForEach(RuleScope.allCases) { scope in
                Text(scope.displayName).tag(scope)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 92)
    }

    private var appField: some View {
        HStack(spacing: 2) {
            TextField("bundle id", text: $rule.bundleID)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .overlay(alignment: .trailing) {
                    if !rule.bundleID.isEmpty, let name = AppCatalog.displayName(forBundleID: rule.bundleID) {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.trailing, 6)
                            .allowsHitTesting(false)
                    }
                }
            Menu {
                Section("Running apps") {
                    ForEach(AppCatalog.runningApps) { app in
                        Button(app.name) {
                            rule.bundleID = app.bundleID
                            if rule.scope == .url, rule.pattern.isEmpty {
                                // Default: the whole site is not guessable — leave empty.
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help("Pick a running app")
        }
    }
}
