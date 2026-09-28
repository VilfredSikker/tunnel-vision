import Foundation
import XCTest

@testable import TunnelVision

/// A backend that answers slowly or not at all, the way a busy app does.
final class SlowAXBackend: AXWindowBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _answers: [[AXWindowSnapshot]?] = []
    private var _reads = 0
    private var _writes: [(id: CGWindowID, minimized: Bool)] = []
    /// Windows whose minimise the app refuses (full screen).
    var refusesMinimise: Set<CGWindowID> = []
    let readDelay: TimeInterval
    let writeDelay: TimeInterval

    init(readDelay: TimeInterval = 0, writeDelay: TimeInterval = 0) {
        self.readDelay = readDelay
        self.writeDelay = writeDelay
    }

    /// Queued answers, one per read; the last repeats.
    func answer(_ answers: [AXWindowSnapshot]?...) {
        lock.withLock { _answers = answers }
    }

    var reads: Int { lock.withLock { _reads } }
    var writes: [(id: CGWindowID, minimized: Bool)] { lock.withLock { _writes } }

    func windows(pid: pid_t) -> [AXWindowSnapshot]? {
        Thread.sleep(forTimeInterval: readDelay)
        return lock.withLock {
            _reads += 1
            guard !_answers.isEmpty else { return [] }
            return _answers.count > 1 ? _answers.removeFirst() : _answers[0]
        }
    }

    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool {
        Thread.sleep(forTimeInterval: writeDelay)
        return lock.withLock {
            _writes.append((windowID, minimized))
            if minimized, refusesMinimise.contains(windowID) { return false }
            // Later answers show the write, like a real app would.
            _answers = _answers.map { answer in
                answer?.map { window in
                    window.id == windowID
                        ? AXWindowSnapshot(id: window.id, title: window.title, isMinimized: minimized, isStandard: window.isStandard)
                        : window
                }
            }
            return true
        }
    }
}

@MainActor
final class AXWindowCacheTests: XCTestCase {
    private let pid: pid_t = 42
    private let window = AXWindowSnapshot(id: 7, title: "Notes", isMinimized: false, isStandard: true)

    /// Waits on the main actor, letting background completions hop back.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Before: every read ran on the main thread and a busy app stalled the
    /// menu bar for as long as it took to answer.
    func testASlowAppDoesNotBlockTheCaller() async {
        let backend = SlowAXBackend(readDelay: 0.3)
        backend.answer([window])
        let cache = AXWindowCache(backend: backend)
        var changed: [pid_t] = []
        cache.onChanged = { changed.append($0) }

        let started = Date()
        XCTAssertEqual(cache.windows(forPID: pid), [], "nothing cached yet")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05, "the read happens in the background")

        await waitUntil { !changed.isEmpty }
        XCTAssertEqual(changed, [pid])
        XCTAssertEqual(cache.windows(forPID: pid), [window])
    }

    func testAReadThatTimesOutKeepsTheLastSnapshot() async {
        let backend = SlowAXBackend()
        backend.answer([window], nil)
        let cache = AXWindowCache(backend: backend)
        var changes = 0
        cache.onChanged = { _ in changes += 1 }

        cache.refresh(pid: pid)
        await waitUntil { changes == 1 }
        cache.refresh(pid: pid)
        await waitUntil { backend.reads == 2 }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(changes, 1, "no answer is not a change")
        XCTAssertEqual(cache.windows(forPID: pid), [window], "and not an empty window list")
    }

    func testAnUnchangedReadDoesNotReportAChange() async {
        let backend = SlowAXBackend()
        backend.answer([window])
        let cache = AXWindowCache(backend: backend)
        var changes = 0
        cache.onChanged = { _ in changes += 1 }

        cache.refresh(pid: pid)
        await waitUntil { changes == 1 }
        cache.refresh(pid: pid)
        await waitUntil { backend.reads == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(changes, 1, "a sweep that follows a change must not start another one")
    }

    /// A refresh asked for mid-read is not dropped: a window created just
    /// then would otherwise wait for the next sweep.
    func testARefreshDuringAReadRunsAfterIt() async {
        let backend = SlowAXBackend(readDelay: 0.1)
        backend.answer([], [window])
        let cache = AXWindowCache(backend: backend)
        cache.refresh(pid: pid)
        cache.refresh(pid: pid)
        cache.refresh(pid: pid)
        await waitUntil { cache.windows(forPID: self.pid) == [self.window] }
        XCTAssertEqual(cache.windows(forPID: pid), [window])
        XCTAssertLessThanOrEqual(backend.reads, 3, "repeated asks while reading collapse into one more read")
    }

    func testMinimiseThenRestoreLandInOrder() {
        let backend = SlowAXBackend(writeDelay: 0.05)
        let cache = AXWindowCache(backend: backend)
        cache.setMinimized(true, windowID: 7, pid: pid)
        cache.setMinimized(false, windowID: 7, pid: pid)
        XCTAssertTrue(cache.drain(timeout: 2))
        XCTAssertEqual(backend.writes.map(\.minimized), [true, false], "a window must not stay minimised after its restore")
    }

    func testAWriteShowsInTheCacheAtOnce() async {
        let backend = SlowAXBackend()
        backend.answer([window])
        let cache = AXWindowCache(backend: backend)
        var changes = 0
        cache.onChanged = { _ in changes += 1 }
        cache.refresh(pid: pid)
        await waitUntil { changes == 1 }

        cache.setMinimized(true, windowID: 7, pid: pid)
        XCTAssertEqual(cache.windows(forPID: pid).first?.isMinimized, true, "the next sweep does not minimise it twice")
    }

    /// A sweep reads, then minimises: the read sits ahead of the write in
    /// the app's queue and answers with the window still up. That answer
    /// must not undo the write and set off a second minimise.
    func testAReadQueuedBeforeAWriteDoesNotUndoIt() async {
        let backend = SlowAXBackend(readDelay: 0.05)
        backend.answer([window])
        let cache = AXWindowCache(backend: backend)
        var changes = 0
        cache.onChanged = { _ in changes += 1 }
        cache.refresh(pid: pid)
        await waitUntil { changes == 1 }

        _ = cache.windows(forPID: pid)
        cache.setMinimized(true, windowID: 7, pid: pid)
        await waitUntil { backend.reads >= 3 }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(cache.windows(forPID: pid).first?.isMinimized, true)
        XCTAssertEqual(changes, 1, "the stale answer is dropped, not reported as a change")
        XCTAssertEqual(backend.writes.count, 1)
    }

    /// A refused minimise (full-screen window) makes the next attempt
    /// report false, as the synchronous call did: the enforcer then retries
    /// quietly instead of announcing a minimise that never happens.
    func testARefusedMinimiseIsReportedOnTheNextAttempt() async {
        let backend = SlowAXBackend()
        backend.refusesMinimise = [7]
        backend.answer([window])
        let cache = AXWindowCache(backend: backend)
        var changes = 0
        cache.onChanged = { _ in changes += 1 }
        cache.refresh(pid: pid)
        await waitUntil { changes == 1 }

        XCTAssertTrue(cache.setMinimized(true, windowID: 7, pid: pid), "unknown yet: assumed to work")
        XCTAssertTrue(cache.drain(timeout: 2))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(cache.setMinimized(true, windowID: 7, pid: pid))
        XCTAssertEqual(cache.windows(forPID: pid).first?.isMinimized, false, "the cache does not claim it minimised")
        XCTAssertTrue(cache.drain(timeout: 2))
        XCTAssertEqual(backend.writes.count, 2, "the attempt is still sent")
    }

    /// Between sessions the user minimises or closes windows; the next
    /// session's first sweep must not act on the old reading.
    func testInvalidatedSnapshotsAreNotServed() async {
        let backend = SlowAXBackend()
        backend.answer([window])
        let cache = AXWindowCache(backend: backend)
        var changes = 0
        cache.onChanged = { _ in changes += 1 }
        cache.refresh(pid: pid)
        await waitUntil { changes == 1 }

        cache.invalidateSnapshots()
        XCTAssertEqual(cache.windows(forPID: pid), [], "nothing to act on until a fresh read lands")
        await waitUntil { changes == 2 }
        XCTAssertEqual(cache.windows(forPID: pid), [window])
    }

    /// A read queued before the new session answers for the old one; it is
    /// dropped and read again, not served.
    func testAReadInFlightAcrossInvalidationIsReadAgain() async {
        let backend = SlowAXBackend(readDelay: 0.1)
        let minimised = AXWindowSnapshot(id: 7, title: "Notes", isMinimized: true, isStandard: true)
        backend.answer([window], [minimised])
        let cache = AXWindowCache(backend: backend)
        var seen: [[AXWindowSnapshot]] = []
        cache.onChanged = { [weak cache] pid in seen.append(cache?.windows(forPID: pid) ?? []) }

        cache.refresh(pid: pid)
        cache.invalidateSnapshots()
        await waitUntil { !seen.isEmpty }
        XCTAssertEqual(seen.first, [minimised], "only the read made after the new session began is used")
        XCTAssertEqual(backend.reads, 2)
    }

    /// Quit and signal exits wait for the restores, or the process would
    /// die with windows still minimised.
    func testDrainWaitsForQueuedWritesAndGivesUpAtItsTimeout() {
        let backend = SlowAXBackend(writeDelay: 0.2)
        let cache = AXWindowCache(backend: backend)
        cache.setMinimized(false, windowID: 7, pid: pid)
        XCTAssertTrue(cache.drain(timeout: 2))
        XCTAssertEqual(backend.writes.count, 1)

        let stuck = AXWindowCache(backend: SlowAXBackend(writeDelay: 1))
        stuck.setMinimized(false, windowID: 7, pid: pid)
        let started = Date()
        XCTAssertFalse(stuck.drain(timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testAForgottenAppIsNotReportedLater() async {
        let backend = SlowAXBackend(readDelay: 0.1)
        backend.answer([window])
        let cache = AXWindowCache(backend: backend)
        var changes = 0
        cache.onChanged = { _ in changes += 1 }
        cache.refresh(pid: pid)
        cache.forget(pid: pid)
        await waitUntil { backend.reads == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(changes, 0, "the app quit while the read ran")
    }
}
