import AppKit
import SwiftUI

/// Automation is granted per browser; each has its own answer.
enum AutomationPermission {
    enum Status: Equatable {
        case granted
        case declined
        /// macOS will ask the first time Tunnel Vision reads the browser.
        case notAsked
        /// The answer can only be read while the browser runs.
        case notRunning
    }

    /// Reads the recorded answer without prompting.
    static func status(bundleID: String) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .notAsked }
        return status(for: AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false))
    }

    static func status(for code: OSStatus) -> Status {
        switch code {
        case noErr: .granted
        case OSStatus(errAEEventNotPermitted): .declined
        case OSStatus(procNotFound): .notRunning
        default: .notAsked
        }
    }
}

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
                VStack(alignment: .leading, spacing: 6) {
                    step(
                        title: "Automation, per browser",
                        granted: nil,
                        detail: "Site rules: each managed browser asks once, the first time Tunnel Vision reads its tabs. A declined browser is left alone; re-enable it under Automation.",
                        grant: ("Open Automation…", {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        })
                    )
                    ForEach(browsers) { browser in
                        browserRow(browser)
                    }
                }
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

    /// Read once per window: the list changes only when a browser is
    /// installed or removed.
    @State private var browsers = Browsers.installed()

    private func browserRow(_ browser: Browsers.Installed) -> some View {
        let status = AutomationPermission.status(bundleID: browser.bundleID)
        let (label, symbol, color): (String, String, Color) = switch status {
        case .granted: ("Allowed", "checkmark.circle.fill", Theme.allowed)
        case .declined: ("Declined", "xmark.circle.fill", Theme.blocked)
        case .notAsked: ("Not asked yet", "circle", .secondary)
        case .notRunning: ("Open it to check", "circle.dashed", .secondary)
        }
        return HStack {
            Text(browser.name)
                .font(.caption)
            Spacer()
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(color)
        }
        .padding(.leading, 12)
    }

    /// `granted` nil: no single status (Automation is answered per
    /// browser; the rows below show each).
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
