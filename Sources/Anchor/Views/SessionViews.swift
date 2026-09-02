import SwiftUI

/// Running or paused session: progress ring around the remaining time,
/// task title with preset chip, and the control row.
struct SessionHeader: View {
    let model: AppState
    let onStrictStop: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ring
            taskLine
            controls
            if model.phase == .paused {
                Text("Paused — resume when you are ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .padding(.horizontal, 14)
    }

    private var fraction: Double {
        Theme.ringFraction(model.workElapsedFraction)
    }

    private var ring: some View {
        // Clock-derived values don't mutate @Observable storage, so a plain
        // body would freeze while the popover stays open. Periodic re-eval
        // keeps the countdown and progress ring live.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Smooth the once-per-second ring step under the periodic
                    // re-evaluation.
                    .animation(.linear(duration: 0.9), value: fraction)
                VStack(spacing: 2) {
                    Text(TimeFormat.clock(model.remainingSeconds ?? 0))
                        .font(.system(size: 34, weight: .semibold))
                        .monospacedDigit()
                    Text(model.phase == .paused ? "paused" : "focus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(1)
                }
            }
            .frame(width: 132, height: 132)
        }
    }

    private var ringColor: Color {
        model.phase == .paused ? Color.secondary : Theme.allowed
    }

    private var taskLine: some View {
        HStack(spacing: 6) {
            Text(model.activeTask?.title ?? "Focus session")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            presetChip
        }
    }

    private var presetChip: some View {
        Menu {
            if let task = model.activeTask, task.presetID != nil {
                Button("Remove preset") { model.setTaskPreset(id: task.id, presetID: nil) }
                Divider()
            }
            ForEach(model.presets) { preset in
                Button(preset.name) {
                    if let task = model.activeTask {
                        model.setTaskPreset(id: task.id, presetID: preset.id)
                    }
                }
            }
        } label: {
            Text(model.activePreset?.name ?? "No preset")
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Preset applied to this task — click to change")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                model.togglePause()
            } label: {
                Label(model.phase == .work ? "Pause" : "Resume",
                      systemImage: model.phase == .work ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(Theme.allowed)

            Button {
                model.finishTaskDone()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.isActiveTaskDoneToday)

            HoldStopButton(strict: model.settings.strictMode) {
                if model.settings.strictMode {
                    onStrictStop()
                } else {
                    model.stopNow()
                }
            }
        }
    }
}

/// The break banner: countdown, the next task, start-next / skip.
struct BreakHeader: View {
    let model: AppState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cup.and.heat.waves.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Break")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(TimeFormat.clock(model.remainingSeconds ?? 0))
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
            }
            if let next = model.nextTask {
                Text("Next up: \(next.title)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("All of today's tasks are done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let next = model.nextTask {
                    Button {
                        model.startTask(id: next.id)
                    } label: {
                        Label("Start next", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .tint(Theme.allowed)
                }
                Button("Skip break") { model.skipBreak() }
                    .controlSize(.large)
            }
            .padding(.top, 2)
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}

/// Stop with friction: hold two seconds (design constraint, early stop).
/// Keyboard follow-up: Space fires the (empty) Button action and the
/// DragGesture only tracks the pointer, so a keyboard stop path still needs
/// a click-safe design — noted as a follow-up.
/// In strict mode a single click redirects to the type-the-title sheet.
private struct HoldStopButton: View {
    let strict: Bool
    let action: () -> Void

    @State private var holding = false
    @State private var beganAt: Date?
    @State private var fired = false
    @State private var holdTask: Task<Void, Never>?

    private let holdDuration: TimeInterval = 2

    init(strict: Bool, action: @escaping () -> Void) {
        self.strict = strict
        self.action = action
    }

    var body: some View {
        Button(action: {}) {
            Text("Stop")
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
        .tint(Theme.blocked)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginHoldIfNeeded() }
                .onEnded { _ in endHold() }
        )
        .overlay(alignment: .bottom) {
            if holding && !strict {
                Text("Keep holding…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .fixedSize()
                    .offset(y: 16)
            }
        }
        .help(strict ? "Click to end early (strict mode)" : "Hold for two seconds to stop early")
    }

    private func beginHoldIfNeeded() {
        guard beganAt == nil else { return }
        holding = true
        beganAt = Date()
        fired = false
        guard !strict else { return }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(holdDuration))
            guard !Task.isCancelled, !fired else { return }
            fired = true
            SoundPlayer.hapticTick()
            action()
        }
    }

    private func endHold() {
        holdTask?.cancel()
        holdTask = nil
        let started = beganAt ?? Date()
        beganAt = nil
        holding = false
        let heldLongEnough = Date().timeIntervalSince(started) >= holdDuration
        if strict {
            // Single click or hold: strict mode always asks for the title.
            if !fired {
                action()
            }
        } else if heldLongEnough && !fired {
            fired = true
            action()
        }
    }
}

/// Strict mode: type the task title to end the session early.
struct StrictStopView: View {
    @Environment(\.dismiss) private var dismiss

    let taskTitle: String
    let onEnd: () -> Void

    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("End the session early?")
                .font(.headline)
            Text("Strict mode is on. Type “\(taskTitle)” to confirm the stop.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Task title", text: $typed)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("End session") {
                    dismiss()
                    onEnd()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(typed.trimmingCharacters(in: .whitespaces) != taskTitle)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
