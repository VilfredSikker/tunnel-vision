import AppKit
import SwiftUI

/// A short, non-blocking line under the menu bar item that fades on its
/// own: the session-start confirmation and the pick result.
@MainActor
final class ToastController {
    private let anchorWindow: () -> NSWindow?
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    init(anchorWindow: @escaping () -> NSWindow?) {
        self.anchorWindow = anchorWindow
    }

    func show(title: String, detail: String, symbol: String, seconds: Int = 5) {
        dismiss()
        let width: CGFloat = 336
        let hosting = NSHostingView(rootView: ToastView(title: title, detail: detail, symbol: symbol).frame(width: width))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let anchor = anchorWindow()
        let screen = anchor?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let midX = anchor?.frame.midX ?? visible.midX
        let x = min(max(midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: visible.maxY - panel.frame.height - 6))
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
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
}

private struct ToastView: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.allowed)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
