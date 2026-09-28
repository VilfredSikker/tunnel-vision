import ApplicationServices
import Foundation

/// The Accessibility calls against another app's windows. Each can block
/// for as long as that app takes to answer, so the cache runs them off the
/// main thread. Only pids, window ids and snapshots cross threads; every
/// AXUIElement is created and used inside one call.
protocol AXWindowBackend: Sendable {
    /// The app's windows; nil when it did not answer in time, which is not
    /// the same as having no windows.
    func windows(pid: pid_t) -> [AXWindowSnapshot]?
    @discardableResult
    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool
}

/// The live backend. A busy app gets 0.25 s per call.
struct LiveAXWindowBackend: AXWindowBackend {
    static let timeout: Float = 0.25

    func windows(pid: pid_t) -> [AXWindowSnapshot]? {
        guard let elements = Self.elements(forPID: pid) else { return nil }
        return elements.compactMap { element in
            // Each window element has its own timeout; it is not documented
            // to inherit the application's.
            AXUIElementSetMessagingTimeout(element, Self.timeout)
            var windowID: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else { return nil }
            let subrole = Self.attribute(element, kAXSubroleAttribute) as? String
            return AXWindowSnapshot(
                id: windowID,
                title: (Self.attribute(element, kAXTitleAttribute) as? String) ?? "",
                isMinimized: (Self.attribute(element, kAXMinimizedAttribute) as? Bool) ?? false,
                isStandard: subrole == kAXStandardWindowSubrole
            )
        }
    }

    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool {
        for element in Self.elements(forPID: pid) ?? [] {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success, id == windowID else { continue }
            // Set on the window too: whether it inherits the application
            // element's timeout is not documented.
            AXUIElementSetMessagingTimeout(element, Self.timeout)
            let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
            return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, value) == .success
        }
        return false
    }

    /// Nil when the app did not answer; empty when it has no windows.
    private static func elements(forPID pid: pid_t) -> [AXUIElement]? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) {
        case .success:
            return value as? [AXUIElement] ?? []
        case .noValue, .attributeUnsupported:
            return []
        default:
            return nil
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Window snapshots per app, read and written off the main thread.
///
/// Reads return what is cached at once and schedule a fresh read; when the
/// fresh read differs, `onChanged` tells the enforcer to judge the app
/// again. Writes are sent in the background and applied to the cache right
/// away, so the next sweep does not send them twice. Each app has its own
/// serial queue: its reads and writes stay in order (a minimise can never
/// land after the restore that follows it), and one busy app holds up only
/// itself.
@MainActor
final class AXWindowCache {
    private let backend: AXWindowBackend
    private var snapshots: [pid_t: [AXWindowSnapshot]] = [:]
    private var queues: [pid_t: DispatchQueue] = [:]
    private var reading: Set<pid_t> = []
    /// A read was asked for while one was running: read again after it.
    private var stale: Set<pid_t> = []
    /// Writes queued per app. A read queued before a write sees the window
    /// as it was; its answer is dropped and read again after the write.
    private var writeCount: [pid_t: Int] = [:]
    /// Bumped when snapshots are invalidated: a read queued before that
    /// answers for the previous session and is read again.
    private var epoch = 0
    /// Windows whose last minimise the app refused (a full-screen window).
    /// Later attempts are still sent but report false, as the synchronous
    /// call did, so a retry every sweep stays silent.
    private var refused: [pid_t: Set<CGWindowID>] = [:]
    private let writes = DispatchGroup()

    /// A fresh read changed what the app shows.
    var onChanged: ((pid_t) -> Void)?

    init(backend: AXWindowBackend = LiveAXWindowBackend()) {
        self.backend = backend
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] {
        refresh(pid: pid)
        return snapshots[pid] ?? []
    }

    func refresh(pid: pid_t) {
        guard !reading.contains(pid) else {
            stale.insert(pid)
            return
        }
        reading.insert(pid)
        let backend = backend
        let writesBefore = writeCount[pid, default: 0]
        let epochBefore = epoch
        queue(for: pid).async {
            let result = backend.windows(pid: pid)
            Task { @MainActor [weak self] in
                self?.finishRead(pid: pid, result: result, writesBefore: writesBefore, epochBefore: epochBefore)
            }
        }
    }

    private func finishRead(pid: pid_t, result: [AXWindowSnapshot]?, writesBefore: Int, epochBefore: Int) {
        reading.remove(pid)
        // Only a known queue is still wanted; a forgotten app stays gone.
        guard queues[pid] != nil else { return }
        guard writeCount[pid, default: 0] == writesBefore, epoch == epochBefore else {
            // A write was queued after this read (the answer predates it
            // and would undo the optimistic update), or a new session
            // began. Read again behind it.
            stale.remove(pid)
            refresh(pid: pid)
            return
        }
        var changed = false
        // A read that timed out keeps the last snapshot: "no answer" must
        // not turn into "no windows".
        if let result, result != snapshots[pid] {
            snapshots[pid] = result
            changed = true
        }
        if stale.remove(pid) != nil {
            refresh(pid: pid)
        }
        if changed {
            onChanged?(pid)
        }
    }

    /// Sent in the background; the cache assumes it worked. False only for
    /// a minimise of a window whose last minimise the app refused.
    @discardableResult
    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool {
        let knownRefusal = minimized && refused[pid]?.contains(windowID) == true
        if !knownRefusal, var list = snapshots[pid], let index = list.firstIndex(where: { $0.id == windowID }) {
            let old = list[index]
            list[index] = AXWindowSnapshot(id: old.id, title: old.title, isMinimized: minimized, isStandard: old.isStandard)
            snapshots[pid] = list
        }
        writeCount[pid, default: 0] += 1
        let backend = backend
        let writes = writes
        writes.enter()
        queue(for: pid).async {
            let done = backend.setMinimized(minimized, windowID: windowID, pid: pid)
            // Left here, not on main: `drain` blocks the main thread at exit
            // and would otherwise wait for itself.
            writes.leave()
            Task { @MainActor [weak self] in
                self?.finishWrite(pid: pid, windowID: windowID, minimized: minimized, done: done)
            }
        }
        return !knownRefusal
    }

    private func finishWrite(pid: pid_t, windowID: CGWindowID, minimized: Bool, done: Bool) {
        guard queues[pid] != nil, minimized else { return }
        if done {
            refused[pid]?.remove(windowID)
            return
        }
        refused[pid, default: []].insert(windowID)
        // Undo the optimistic update: the window is still up.
        if var list = snapshots[pid], let index = list.firstIndex(where: { $0.id == windowID }), list[index].isMinimized {
            let old = list[index]
            list[index] = AXWindowSnapshot(id: old.id, title: old.title, isMinimized: false, isStandard: old.isStandard)
            snapshots[pid] = list
        }
    }

    /// A new session starts: what was read during or after the last one is
    /// out of date (windows closed, the user minimised some), so no sweep
    /// acts on it. Queues and write counts stay, so a restore still queued
    /// from the last session keeps its place ahead of new writes.
    func invalidateSnapshots() {
        snapshots = [:]
        refused = [:]
        epoch += 1
    }

    /// Runs notification registration for the app on a queue of its own:
    /// registering can take seconds on an app that is just launching, and
    /// its reads and writes (a restore at exit above all) must not wait
    /// behind it. Registrations for one app stay in order.
    func performRegistration(pid: pid_t, _ work: @escaping @Sendable () -> Void) {
        registrationQueue(for: pid).async(execute: work)
    }

    private var registrationQueues: [pid_t: DispatchQueue] = [:]

    private func registrationQueue(for pid: pid_t) -> DispatchQueue {
        if let queue = registrationQueues[pid] { return queue }
        let queue = DispatchQueue(label: "com.tunnelvision.ax-observe.\(pid)", qos: .utility)
        registrationQueues[pid] = queue
        return queue
    }

    /// The app quit: drop what is known about it.
    func forget(pid: pid_t) {
        snapshots[pid] = nil
        queues[pid] = nil
        reading.remove(pid)
        stale.remove(pid)
        writeCount[pid] = nil
        refused[pid] = nil
    }

    /// Blocks until every queued write went out, or the timeout passed.
    /// Only for exit, where the process must not die with windows still
    /// minimised. True when everything went out.
    @discardableResult
    func drain(timeout: TimeInterval) -> Bool {
        writes.wait(timeout: .now() + timeout) == .success
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "com.tunnelvision.ax.\(pid)", qos: .userInitiated)
        queues[pid] = queue
        return queue
    }
}
