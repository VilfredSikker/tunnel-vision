import AppKit
import Observation
import SwiftUI

/// The popup for a phase change the timer made on its own: work time ran
/// out, or the break did. Both are easy to miss from the menu bar alone, so
/// the popup sits in the middle of the active screen, above other windows
/// and on every Space, until it is dismissed or the next phase is started
/// from it.
@MainActor
final class PhaseAlertController {
    private let model: AppState
    private var panel: NSPanel?
    private var shown: PhaseAlert?

    init(model: AppState) {
        self.model = model
        follow()
    }

    /// Re-arms on every change of the model's alert, the same tracking
    /// pattern the settings use.
    private func follow() {
        let alert = withObservationTracking {
            model.phaseAlert
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.follow()
            }
        }
        render(alert)
    }

    private func render(_ alert: PhaseAlert?) {
        guard alert != shown else { return }
        shown = alert
        panel?.orderOut(nil)
        panel = nil
        guard let alert else { return }

        let view = PhaseAlertView(
            alert: alert,
            onDismiss: { [weak self] in self?.model.dismissPhaseAlert() },
            onSkipBreak: { [weak self] in self?.model.skipBreak() },
            onStartNext: { [weak self] in
                guard let self, let next = self.model.nextUpTask else { return }
                self.model.startTask(id: next.id)
            }
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The screen the pointer is on: where the user is looking.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2 + visible.height * 0.12
            ))
        }
        // Never key: the timer fires while the user types elsewhere, and a
        // stray Return must not dismiss the popup or start a session. It
        // goes away on a click only.
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct PhaseAlertView: View {
    let alert: PhaseAlert
    let onDismiss: () -> Void
    let onSkipBreak: () -> Void
    let onStartNext: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(Theme.allowed)
            VStack(spacing: 4) {
                Text(headline)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                buttons
            }
            .padding(.top, 2)
        }
        .padding(22)
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var buttons: some View {
        switch alert {
        case .workEnded:
            Button("Skip break", action: onSkipBreak)
                .controlSize(.large)
            Button("OK", action: onDismiss)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
        case .breakEnded(let next):
            Button("Later", action: onDismiss)
                .controlSize(.large)
            if let next {
                Button("Start “\(next)”", action: onStartNext)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.allowed)
                    .lineLimit(1)
            }
        }
    }

    private var symbol: String {
        switch alert {
        case .workEnded: "cup.and.heat.waves.fill"
        case .breakEnded: "play.circle.fill"
        }
    }

    private var headline: String {
        switch alert {
        case .workEnded(let title, _): "Time’s up on “\(title)”"
        case .breakEnded: "Break’s over"
        }
    }

    private var detail: String {
        switch alert {
        case .workEnded(_, let seconds):
            "Your \(TimeFormat.minutes(seconds)) break has started. Everything is unlocked."
        case .breakEnded(let next):
            next.map { "Next up: \($0)" } ?? "Nothing left on today’s list."
        }
    }
}
