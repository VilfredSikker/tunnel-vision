import AppKit
import SwiftUI

/// One thing the enforcement layers stopped: an app, a window inside an
/// allowed app, or a page inside an allowed browser.
enum BlockEvent: Equatable, Sendable {
    case app(name: String, bundleID: String)
    case window(appName: String, bundleID: String, title: String)
    case site(appName: String, bundleID: String, host: String)

    var bundleID: String {
        switch self {
        case .app(_, let bundleID), .window(_, let bundleID, _), .site(_, let bundleID, _): bundleID
        }
    }

    var appName: String {
        switch self {
        case .app(let name, _), .window(let name, _, _), .site(let name, _, _): name
        }
    }

    /// The allow rule "Add to preset" appends.
    var rule: Rule {
        switch self {
        case .app(_, let bundleID): Rule(bundleID: bundleID)
        case .window(_, let bundleID, let title): Rule(bundleID: bundleID, scope: .window, pattern: title)
        case .site(_, let bundleID, let host): Rule(bundleID: bundleID, scope: .url, pattern: host)
        }
    }
}

/// Non-blocking notice near the menu bar when an enforcement layer blocks
/// something. Offers "allow for this session" and "add to preset", then
/// auto-dismisses.
@MainActor
final class BlockedNoticeController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    private let anchorWindow: () -> NSWindow?
    private let taskTitleProvider: () -> String
    private let modeProvider: () -> Mode
    private let onAllowForSession: (BlockEvent) -> Void
    private let onAddToPreset: (BlockEvent) -> Void

    init(
        anchorWindow: @escaping () -> NSWindow?,
        taskTitleProvider: @escaping () -> String,
        modeProvider: @escaping () -> Mode,
        onAllowForSession: @escaping (BlockEvent) -> Void,
        onAddToPreset: @escaping (BlockEvent) -> Void
    ) {
        self.anchorWindow = anchorWindow
        self.taskTitleProvider = taskTitleProvider
        self.modeProvider = modeProvider
        self.onAllowForSession = onAllowForSession
        self.onAddToPreset = onAddToPreset
        installDismissMonitors()
    }

    func show(appName: String, bundleID: String) {
        show(.app(name: appName, bundleID: bundleID))
    }

    func show(_ event: BlockEvent) {
        dismiss()
        guard let anchor = anchorWindow() else { return }

        let panel = makePanel()
        let width: CGFloat = 336
        let view = BlockedNoticeView(
            event: event,
            taskTitleProvider: taskTitleProvider,
            modeProvider: modeProvider,
            onAllow: { [weak self] in
                self?.onAllowForSession(event)
                self?.dismiss()
            },
            onAddToPreset: { [weak self] in
                self?.onAddToPreset(event)
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
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
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
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
        let clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            self.dismiss()
            return event
        }
        if let clickMonitor {
            monitors.append(clickMonitor)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }
}

private struct BlockedNoticeView: View {
    let event: BlockEvent
    let taskTitleProvider: () -> String
    let modeProvider: () -> Mode
    let onAllow: () -> Void
    let onAddToPreset: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.blocked)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(detail)
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

    private var symbol: String {
        switch event {
        case .app:
            switch mode {
            case .dark: "eye.slash"
            case .closed: "xmark.circle"
            case .frozen: "snowflake"
            }
        case .window: "macwindow.badge.minus"
        case .site: "globe.badge.chevron.backward"
        }
    }

    private var headline: String {
        switch event {
        case .app(let name, _):
            "\(name) was \(modeVerb)"
        case .window(let appName, _, _):
            "A \(appName) window was minimised"
        case .site(let appName, _, let host):
            "\(host) steered away in \(appName)"
        }
    }

    private var detail: String {
        let task = taskTitleProvider()
        switch event {
        case .app:
            return "not in “\(task)” — \(modeDetail)"
        case .window(_, _, let title):
            let shown = title.isEmpty ? "an untitled window" : "“\(title)”"
            return "\(shown) matches no window rule of “\(task)” — only matching windows stay up"
        case .site:
            return "not a site allowed for “\(task)” — the window went back to an allowed page"
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
