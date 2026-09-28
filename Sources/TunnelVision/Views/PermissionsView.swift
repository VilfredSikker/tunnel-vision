import AppKit
import SwiftUI

/// The three permissions and what each unlocks (DESIGN_BRIEF §6), with a
/// live status and a way to grant each. Shared by Settings and onboarding.
struct PermissionSteps: View {
    var body: some View {
        // Grants happen in System Settings, outside the app; poll so the
        // status follows without reopening the window.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 14) {
                step(
                    title: "Accessibility",
                    granted: AccessibilityPermission.isTrusted,
                    detail: "Window rules: inside an app allowed by window, other windows are minimised, and the picker shows window titles. Without it, a window rule allows the whole app.",
                    grant: ("Grant…", { AccessibilityPermission.request() })
                )
                step(
                    title: "Automation, per browser",
                    granted: nil,
                    detail: "Site rules: each managed browser asks once, the first time Tunnel Vision reads its tabs. A declined browser is left alone; re-enable it under Automation.",
                    grant: ("Open Automation…", {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    })
                )
                step(
                    title: "Screen Recording (optional)",
                    granted: ScreenCapturePermission.isAllowed,
                    detail: "Only for window thumbnails in the picker. Without it, tiles show the app icon and window title.",
                    grant: ("Grant…", {
                        ScreenCapturePermission.request()
                        NSWorkspace.shared.open(ScreenCapturePermission.settingsURL)
                    })
                )
            }
        }
    }

    /// `granted` nil: the status cannot be read up front (Automation is
    /// granted per browser, when it first asks).
    private func step(title: String, granted: Bool?, detail: String, grant: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                if let granted {
                    Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(granted ? Theme.allowed : .secondary)
                        .font(.caption)
                }
                if granted != true {
                    Button(grant.0, action: grant.1)
                        .controlSize(.small)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// First launch: what Tunnel Vision does and the permissions it asks for.
/// The app works with fewer; the session header says what is missing.
struct OnboardingView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Tunnel Vision")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Start a task and every app it doesn’t need goes dark, closes or freezes until the timer ends. Tunnel Vision lives in the menu bar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Whole-app rules work right away. Finer rules need permissions:")
                .font(.callout)
            PermissionSteps()
            Divider()
            HStack {
                Text("You can come back to this from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
