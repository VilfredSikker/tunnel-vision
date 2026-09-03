import AppKit
import SwiftUI

/// Small always-on-top countdown shown while a session or break runs, for
/// when the menu bar is out of sight (full-screen apps, hidden status
/// items). Non-activating, joins every Space, draggable, remembers where it
/// was put.
@MainActor
final class CountdownWindowController {
    private static let originKey = "CountdownWindow.origin"

    private let model: AppState
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    init(model: AppState) {
        self.model = model
        observe()
        refresh()
    }

    private func observe() {
        withObservationTracking {
            _ = model.phase
            _ = model.settings.showCountdownWindow
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refresh() {
        let wanted = model.settings.showCountdownWindow && model.phase != .idle
        if wanted {
            let panel = self.panel ?? makePanel()
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = PassthroughHostingView(rootView: CountdownHUDView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let dragSurface = DragSurfaceView()
        dragSurface.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: dragSurface.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: dragSurface.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: dragSurface.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: dragSurface.bottomAnchor),
        ])
        panel.contentView = dragSurface

        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(savedOrigin(for: size) ?? defaultOrigin(for: size))

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rememberOrigin()
            }
        }
        self.panel = panel
        return panel
    }

    // MARK: Placement

    /// Top-right corner of the main screen, under the menu bar.
    private func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
    }

    /// The last dragged position, if it still lands on a connected screen.
    private func savedOrigin(for size: NSSize) -> NSPoint? {
        guard let stored = UserDefaults.standard.string(forKey: Self.originKey) else { return nil }
        let origin = NSPointFromString(stored)
        let frame = NSRect(origin: origin, size: size)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        return onScreen ? origin : nil
    }

    private func rememberOrigin() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }
}

// MARK: - Views

/// Lets clicks fall through to the drag surface beneath: the HUD has no
/// controls, and a click anywhere on it should move it.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DragSurfaceView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct CountdownHUDView: View {
    let model: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(TimeFormat.clock(model.remainingSeconds ?? 0))
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 176)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        switch model.phase {
        case .idle, .work: "timer"
        case .paused: "pause.fill"
        case .breakTime: "cup.and.heat.waves.fill"
        }
    }

    private var tint: Color {
        model.phase == .work ? Theme.allowed : .secondary
    }

    private var caption: String {
        switch model.phase {
        case .idle: ""
        case .work: model.activeTask?.title ?? "Focus"
        case .paused: "Paused · \(model.activeTask?.title ?? "Focus")"
        case .breakTime: "Break"
        }
    }
}
