import Foundation
import os

/// Locks a session to a set of herdr workspaces. herdr cannot veto a focus
/// change, so the guard listens for `workspace.focused` and, when the new
/// workspace is not allowed, focuses the last allowed one the user was in
/// and shows a toast inside herdr. The bounce itself lands on an allowed
/// workspace, so it never loops.
@MainActor
final class HerdrWorkspaceGuard: LockListener {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "herdr-guard")

    private let client: HerdrControlling
    private let taskTitle: () -> String

    /// Allowed workspace labels, lowercased.
    private(set) var allowedLabels: Set<String> = []
    private(set) var isActive = false
    /// Where a bounce goes: the last allowed workspace the user focused.
    private(set) var returnTarget: String?

    private var labelsByID: [String: String] = [:]
    private var orderedIDs: [String] = []
    private var eventTask: Task<Void, Never>?
    private var lastNoticeAt: Date?

    init(client: HerdrControlling, taskTitle: @escaping () -> String) {
        self.client = client
        self.taskTitle = taskTitle
    }

    // MARK: LockListener

    func lockStateChanged(active: Bool, rules: [Rule], mode: Mode) {
        let labels = Self.allowedLabels(in: rules)
        if active, !labels.isEmpty {
            activate(labels: labels)
        } else {
            deactivate()
        }
    }

    /// Labels of every allow rule with herdr scope, lowercased and trimmed.
    static func allowedLabels(in rules: [Rule]) -> Set<String> {
        var labels = Set<String>()
        for rule in rules where rule.effect == .allow && rule.scope == .herdr {
            let label = rule.pattern.trimmingCharacters(in: .whitespaces).lowercased()
            if !label.isEmpty {
                labels.insert(label)
            }
        }
        return labels
    }

    // MARK: Lifecycle

    func activate(labels: Set<String>) {
        if isActive, labels == allowedLabels { return }
        deactivate()
        guard client.isAvailable else {
            Self.log.info("herdr socket not present — workspace lock inactive")
            return
        }
        setAllowedLabels(labels)
        Self.log.info("locking to herdr workspaces: \(labels.sorted().joined(separator: ", "), privacy: .public)")
        eventTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// The allowed set without the event loop: `activate` calls it before
    /// starting the loop, tests drive bootstrap and events by hand.
    func setAllowedLabels(_ labels: Set<String>) {
        allowedLabels = Set(labels.map { $0.lowercased() })
        isActive = !allowedLabels.isEmpty
    }

    func deactivate() {
        isActive = false
        eventTask?.cancel()
        eventTask = nil
        allowedLabels = []
        labelsByID = [:]
        orderedIDs = []
        returnTarget = nil
    }

    /// Bootstrap, then follow events; reconnects with backoff while locked.
    private func run() async {
        var backoff: Duration = .seconds(1)
        while isActive, !Task.isCancelled {
            do {
                try await bootstrap()
                backoff = .seconds(1)
                for await event in client.events() {
                    guard isActive else { return }
                    await handle(event)
                }
            } catch {
                Self.log.info("herdr unavailable: \(String(describing: error), privacy: .public)")
            }
            guard isActive, !Task.isCancelled else { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    /// Reads the current state and bounces immediately if the user is
    /// already somewhere not allowed.
    func bootstrap() async throws {
        let snapshot = try await client.snapshot()
        apply(snapshot)
        if let focused = snapshot.focusedWorkspaceID {
            await handle(.workspaceFocused(id: focused))
        }
    }

    func apply(_ snapshot: HerdrSnapshot) {
        labelsByID = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.id, $0.label) })
        orderedIDs = snapshot.workspaces.map(\.id)
        if let target = returnTarget, !isAllowed(target) {
            returnTarget = nil
        }
    }

    // MARK: Events

    func handle(_ event: HerdrEvent) async {
        switch event {
        case .workspaceFocused(let id):
            if isAllowed(id) {
                returnTarget = id
                return
            }
            guard let target = returnTarget ?? orderedIDs.first(where: isAllowed) else {
                // None of the allowed workspaces is open: nothing to bounce to.
                return
            }
            do {
                try await client.focusWorkspace(id: target)
                Self.log.info("bounced \(id, privacy: .public) → \(target, privacy: .public)")
            } catch {
                Self.log.error("focus \(target, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return
            }
            await notifyBounce(to: labelsByID[target] ?? target)
        case .workspaceRenamed(let id, let label):
            if let label {
                labelsByID[id] = label
            }
            if let target = returnTarget, !isAllowed(target) {
                returnTarget = nil
            }
        case .workspaceClosed(let id):
            labelsByID[id] = nil
            orderedIDs.removeAll { $0 == id }
            if returnTarget == id {
                returnTarget = nil
            }
        case .workspaceCreated(let workspace):
            labelsByID[workspace.id] = workspace.label
            if !orderedIDs.contains(workspace.id) {
                orderedIDs.append(workspace.id)
            }
        case .other:
            break
        }
    }

    func isAllowed(_ workspaceID: String) -> Bool {
        guard let label = labelsByID[workspaceID] else { return false }
        return allowedLabels.contains(label.lowercased())
    }

    private func notifyBounce(to label: String) async {
        let now = Date()
        if let last = lastNoticeAt, now.timeIntervalSince(last) < 4 { return }
        lastNoticeAt = now
        await client.notify(
            title: "Tunnel Vision: locked to \"\(taskTitle())\"",
            body: "Back to \(label). Allowed workspaces: \(allowedLabels.sorted().joined(separator: ", "))"
        )
    }
}
