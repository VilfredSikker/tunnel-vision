import AppKit
import SwiftUI

/// Non-blocking notice near the menu bar when the enforcer blocks an app.
/// Offers "allow for this session" and "add to preset", then auto-dismisses.
@MainActor
final class BlockedNoticeController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    private let anchorWindow: () -> NSWindow?
    private let taskTitleProvider: () -> String
    private let modeProvider: () -> Mode
    private let onAllowForSession: (String) -> Void
    private let onAddToPreset: (String) -> Void

    init(
        anchorWindow: @escaping () -> NSWindow?,
        taskTitleProvider: @escaping () -> String,
        modeProvider: @escaping () -> Mode,
        onAllowForSession: @escaping (String) -> Void,
        onAddToPreset: @escaping (String) -> Void
    ) {
        self.anchorWindow = anchorWindow
        self.taskTitleProvider = taskTitleProvider
        self.modeProvider = modeProvider
        self.onAllowForSession = onAllowForSession
        self.onAddToPreset = onAddToPreset
        installDismissMonitors()
    }

    func show(appName: String, bundleID: String) {
        dismiss(immediately: true)
        guard let anchor = anchorWindow() else { return }

        let panel = makePanel()
        let width: CGFloat = 336
        let view = BlockedNoticeView(
            appName: appName,
            taskTitleProvider: taskTitleProvider,
            modeProvider: modeProvider,
            onAllow: { [weak self] in
                self?.onAllowForSession(bundleID)
                self?.dismiss(immediately: true)
            },
            onAddToPreset: { [weak self] in
                self?.onAddToPreset(bundleID)
                self?.dismiss(immediately: true)
            },
            onDismiss: { [weak self] in
                self?.dismiss(immediately: true)
            }
        )
        .frame(width: width)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 10
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        let fitting = hosting.fittingSize
        panel.setContentSize(NSSize(width: width, height: min(max(fitting.height, 96), 140)))

        // Under the status item, on the screen the menu bar is on.
        let screen = anchor.screen ?? NSScreen.main
        let anchorFrame = anchor.frame
        let x = min(max(anchorFrame.midX - panel.frame.width / 2, 8), (screen?.visibleFrame.maxX ?? 800) - panel.frame.width - 8)
        let y = (screen?.visibleFrame.maxY ?? 0) - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        self.panel = panel
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            self?.dismiss(immediately: true)
        }
    }

    func dismiss(immediately: Bool = true) {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
        _ = immediately
    }

    // MARK: Panel + dismissal

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        return panel
    }

    private func installDismissMonitors() {
        // Clicks elsewhere in our own app dismiss the notice.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            self.dismiss(immediately: true)
            return event
        })
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss(immediately: true)
            }
        }
    }
}

private struct BlockedNoticeView: View {
    let appName: String
    let taskTitleProvider: () -> String
    let modeProvider: () -> Mode
    let onAllow: () -> Void
    let onAddToPreset: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: modeSymbol)
                    .foregroundStyle(Theme.blocked)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(appName) was \(modeVerb)")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("not in “\(taskTitleProvider())” — \(modeDetail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Allow for this session", action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Add to preset", action: onAddToPreset)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var mode: Mode { modeProvider() }

    private var modeSymbol: String {
        switch mode {
        case .dark: "eye.slash"
        case .closed: "xmark.circle"
        case .frozen: "snowflake"
        }
    }

    private var modeVerb: String {
        switch mode {
        case .dark: "hidden"
        case .closed: "quit"
        case .frozen: "frozen"
        }
    }

    private var modeDetail: String {
        switch mode {
        case .dark: "it will stay out of sight while this task runs"
        case .closed: "it will be quit if you open it again"
        case .frozen: "it is paused and will resume after this task"
        }
    }
}
