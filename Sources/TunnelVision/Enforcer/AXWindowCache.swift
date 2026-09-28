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
        queue(for: pid).async {
            let result = backend.windows(pid: pid)
            Task { @MainActor [weak self] in
                self?.finishRead(pid: pid, result: result)
            }
        }
    }

    private func finishRead(pid: pid_t, result: [AXWindowSnapshot]?) {
        reading.remove(pid)
        // Only a known queue is still wanted; a forgotten app stays gone.
        guard queues[pid] != nil else { return }
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

    /// Sent in the background; the cache assumes it worked. True when the
    /// request was queued.
    @discardableResult
    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool {
        if var list = snapshots[pid], let index = list.firstIndex(where: { $0.id == windowID }) {
            let old = list[index]
            list[index] = AXWindowSnapshot(id: old.id, title: old.title, isMinimized: minimized, isStandard: old.isStandard)
            snapshots[pid] = list
        }
        let backend = backend
        let writes = writes
        writes.enter()
        queue(for: pid).async {
            backend.setMinimized(minimized, windowID: windowID, pid: pid)
            writes.leave()
        }
        return true
    }

    /// The app quit: drop what is known about it.
    func forget(pid: pid_t) {
        snapshots[pid] = nil
        queues[pid] = nil
        reading.remove(pid)
        stale.remove(pid)
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
