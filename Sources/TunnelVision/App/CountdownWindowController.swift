import AppKit
import SwiftUI

/// Small always-on-top countdown shown while a session or break runs, for
/// when the menu bar is out of sight (full-screen apps, hidden status
/// items). Non-activating, joins every Space, draggable, remembers where it
/// was put. A prompt from a background agent shows under the clock, and the
/// panel grows to fit it and shrinks back once it is answered.
@MainActor
final class CountdownWindowController {
    /// Where the panel's top-left corner was dragged to. The panel grows
    /// down from there, so a prompt never moves the clock.
    private static let topLeftKey = "CountdownWindow.topLeft"
    /// The bottom-left corner, as earlier builds stored it.
    private static let legacyOriginKey = "CountdownWindow.origin"

    private let model: AppState
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    /// The style the panel was sized for; a change rebuilds it.
    private var builtStyle: CountdownStyle?
    /// What the HUD reports about its own layout.
    private let layout = HUDLayout()
    /// The last frame set here; a move to any other frame is the user's drag.
    private var placedFrame: NSRect?

    init(model: AppState) {
        self.model = model
        layout.onSize = { [weak self] size in
            self?.place(size: size)
        }
        observe()
        refresh()
    }

    private func observe() {
        withObservationTracking {
            _ = model.phase
            _ = model.settings.showCountdownWindow
            _ = model.settings.countdownStyle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func refresh() {
        if let panel, builtStyle != model.settings.countdownStyle {
            // Compact and garden pills differ in height; start over.
            panel.orderOut(nil)
            if let moveObserver {
                NotificationCenter.default.removeObserver(moveObserver)
                self.moveObserver = nil
            }
            self.panel = nil
        }
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
        // Answering a prompt from the bar must not pull focus away from
        // the app the user works in.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = HUDHostingView(rootView: CountdownHUDView(model: model, layout: layout))
        hosting.layout = layout
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
        self.panel = panel

        let size = hosting.fittingSize
        if savedTopLeft(for: size) == nil, let legacy = legacyTopLeft(for: size) {
            UserDefaults.standard.set(NSStringFromPoint(legacy), forKey: Self.topLeftKey)
        }
        place(size: size)
        builtStyle = model.settings.countdownStyle

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rememberTopLeft()
            }
        }
        return panel
    }

    // MARK: Placement

    /// Puts the panel at its remembered top-left corner at `size`, pulled
    /// inside the screen where growing would spill over its edge.
    private func place(size: NSSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let anchor = savedTopLeft(for: size) ?? defaultTopLeft(for: size)
        var frame = NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        guard frame != panel.frame else { return }
        placedFrame = frame
        panel.setFrame(frame, display: true)
    }

    /// Top-right corner of the main screen, under the menu bar.
    private func defaultTopLeft(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return NSPoint(x: 0, y: size.height) }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - 16)
    }

    /// The last dragged position, if it still lands on a connected screen.
    private func savedTopLeft(for size: NSSize) -> NSPoint? {
        guard let stored = UserDefaults.standard.string(forKey: Self.topLeftKey) else { return nil }
        let topLeft = NSPointFromString(stored)
        return onScreen(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)) ? topLeft : nil
    }

    private func legacyTopLeft(for size: NSSize) -> NSPoint? {
        guard let stored = UserDefaults.standard.string(forKey: Self.legacyOriginKey) else { return nil }
        let origin = NSPointFromString(stored)
        return onScreen(NSRect(origin: origin, size: size)) ? NSPoint(x: origin.x, y: origin.y + size.height) : nil
    }

    private func onScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    /// Only the user's drags count; the panel's own resizing does not move
    /// where it lives.
    private func rememberTopLeft() {
        guard let panel, panel.frame != placedFrame else { return }
        placedFrame = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: Self.topLeftKey)
    }
}

// MARK: - Views

/// What the HUD tells its host: the area that takes clicks itself (the
/// prompt's buttons), and its size whenever that changes.
@MainActor
final class HUDLayout {
    /// In the hosting view's top-left coordinates.
    var interactiveRect: CGRect = .zero
    var onSize: ((CGSize) -> Void)?
}

/// Clicks fall through to the drag surface beneath, so a click anywhere
/// moves the HUD, except on the prompt, whose buttons answer on the first
/// click without the panel taking focus.
private final class HUDHostingView<Content: View>: NSHostingView<Content> {
    var layout: HUDLayout?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let layout, !layout.interactiveRect.isEmpty else { return nil }
        let local = convert(point, from: superview)
        let fromTop = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        guard layout.interactiveRect.contains(fromTop) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class DragSurfaceView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct HUDSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct HUDInteractiveKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

struct CountdownHUDView: View {
    let model: AppState
    /// Where the host learns the HUD's size and clickable area.
    var layout: HUDLayout?

    private static let gardenHeight: CGFloat = 64

    /// The oldest prompt waiting (or just answered), and how many more wait.
    private var shownApproval: (approval: PendingApproval, more: Int)? {
        BackgroundPresentation.barApproval(ApprovalReplies.shared.visible(model.background.approvals))
    }

    var body: some View {
        let shown = shownApproval
        VStack(alignment: .leading, spacing: 6) {
            clock
            if let shown {
                Divider()
                ApprovalView(model: model, approval: shown.approval, style: .compact, more: shown.more)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: HUDInteractiveKey.self, value: proxy.frame(in: .global))
                    })
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: shown == nil ? 176 : 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
        .background(GeometryReader { proxy in
            Color.clear.preference(key: HUDSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(HUDSizeKey.self) { size in
            MainActor.assumeIsolated { layout?.onSize?(size) }
        }
        .onPreferenceChange(HUDInteractiveKey.self) { rect in
            MainActor.assumeIsolated { layout?.interactiveRect = rect }
        }
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 4) {
                if model.settings.countdownStyle == .garden {
                    garden
                }
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
            }
        }
    }

    /// The session's plant, growing with the timer and standing still while
    /// paused; during the break, the plant the break follows. Always the same
    /// height so the panel keeps its size across phases.
    private var garden: some View {
        Group {
            if let shown = gardenPlant {
                // No animation on the once-per-second step: a session moves
                // the plant by a fraction too small to see, and animating it
                // kept the panel redrawing at the display's frame rate.
                GrowthSceneView(plan: shown.plan, progress: shown.progress)
            } else {
                Color.clear
            }
        }
        .frame(height: Self.gardenHeight)
    }

    private var gardenPlant: (plan: GrowthPlan, progress: Double)? {
        switch model.phase {
        case .work, .paused:
            guard let plan = model.growth else { return nil }
            return (plan, model.growthProgress)
        case .breakTime:
            guard let record = model.todayGarden.last else { return nil }
            return (record.plan, record.progress)
        case .idle:
            return nil
        }
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
        case .breakTime: model.isLongBreak ? "Long break" : "Break"
        }
    }
}
