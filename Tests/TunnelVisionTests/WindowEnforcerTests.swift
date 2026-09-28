import Foundation
import XCTest

@testable import TunnelVision

/// Stands in for the Accessibility API: windows per pid, minimise calls recorded.
@MainActor
final class FakeWindowManager: WindowManaging {
    var trusted = true
    var apps: [ProcessSnapshot] = []
    var windowsByPID: [pid_t: [AXWindowSnapshot]] = [:]
    var calls: [(id: CGWindowID, minimized: Bool)] = []
    var observed: Set<pid_t> = []

    var isTrusted: Bool { trusted }

    func runningApplications() -> [ProcessSnapshot] { apps }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { windowsByPID[pid] ?? [] }

    /// Windows that ignore a minimise (a full-screen window). Like the live
    /// cache: the first attempt is assumed to work, later ones report the
    /// refusal. The window stays up either way.
    var refusesMinimise: Set<CGWindowID> = []
    private var refusalSeen: Set<CGWindowID> = []
    /// Windows whose minimise now works but is still reported refused, as
    /// the live cache does until it sees a success.
    var reportRefusalFor: Set<CGWindowID> = []

    func setMinimized(_ minimized: Bool, windowID: CGWindowID, pid: pid_t) -> Bool {
        guard var list = windowsByPID[pid], let index = list.firstIndex(where: { $0.id == windowID }) else { return false }
        if minimized, refusesMinimise.contains(windowID) {
            calls.append((windowID, minimized))
            return refusalSeen.insert(windowID).inserted
        }
        let reported = !(minimized && reportRefusalFor.contains(windowID))
        let old = list[index]
        list[index] = AXWindowSnapshot(id: old.id, title: old.title, isMinimized: minimized, isStandard: old.isStandard)
        windowsByPID[pid] = list
        calls.append((windowID, minimized))
        return reported
    }

    func observe(pid: pid_t, onChange: @escaping @MainActor () -> Void) { observed.insert(pid) }
    func stopObserving(pid: pid_t) { observed.remove(pid) }

    var onWindowsChanged: ((pid_t) -> Void)?
    var forgotten: [pid_t] = []
    var drained = 0
    func forget(pid: pid_t) { forgotten.append(pid) }
    func drainWrites(timeout: TimeInterval) { drained += 1 }
    var invalidations = 0
    func invalidateSnapshots() { invalidations += 1 }

    // MARK: Helpers

    func launch(_ bundleID: String, name: String, pid: pid_t) {
        apps.append(ProcessSnapshot(pid: pid, name: name, bundleID: bundleID, isSelf: false, isRegularApp: true))
    }

    func addWindow(_ id: CGWindowID, pid: pid_t, title: String, minimized: Bool = false, standard: Bool = true) {
        windowsByPID[pid, default: []].append(AXWindowSnapshot(id: id, title: title, isMinimized: minimized, isStandard: standard))
    }

    func retitle(_ id: CGWindowID, pid: pid_t, to title: String) {
        guard var list = windowsByPID[pid], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let old = list[index]
        list[index] = AXWindowSnapshot(id: old.id, title: title, isMinimized: old.isMinimized, isStandard: old.isStandard)
        windowsByPID[pid] = list
    }

    func isMinimized(_ id: CGWindowID, pid: pid_t) -> Bool {
        windowsByPID[pid]?.first { $0.id == id }?.isMinimized ?? false
    }

    var minimised: [CGWindowID] { calls.filter(\.minimized).map(\.id) }
    var restored: [CGWindowID] { calls.filter { !$0.minimized }.map(\.id) }
}

private let xcode = "com.apple.dt.Xcode"
private let helium = "net.imput.helium"
private let slack = "com.example.slack"

@MainActor
final class WindowEnforcerTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_752_000_000)

    private func makeEnforcer(_ fake: FakeWindowManager) -> WindowEnforcer {
        WindowEnforcer(windows: fake, clock: { [self] in now }, autoSweep: false)
    }

    private func xcodeWorld() -> FakeWindowManager {
        let fake = FakeWindowManager()
        fake.launch(xcode, name: "Xcode", pid: 10)
        fake.addWindow(1, pid: 10, title: "Anchor — AppState.swift")
        fake.addWindow(2, pid: 10, title: "Other — main.swift")
        return fake
    }

    // MARK: Policy

    func testTitlePatternsSkipWholeAppAndURLBundles() {
        let rules = [
            Rule(bundleID: xcode, scope: .window, pattern: " Anchor "),
            Rule(bundleID: slack, scope: .window, pattern: "Engineering"),
            Rule(bundleID: slack),
            Rule(bundleID: helium, scope: .window, pattern: "Docs"),
            Rule(bundleID: helium, scope: .url, pattern: "github.com"),
            Rule(bundleID: xcode, scope: .window, pattern: "Denied", effect: .deny),
            Rule(bundleID: "", scope: .window, pattern: "Orphan"),
        ]
        let patterns = WindowLockPolicy.titlePatterns(rules: rules)
        XCTAssertEqual(patterns, [xcode: ["anchor"]], "an app rule allows Slack whole; Helium's URL rules make it the browser layer's")
        XCTAssertTrue(WindowLockPolicy.matches(title: "anchor — Models.swift", patterns: ["anchor"]))
        XCTAssertFalse(WindowLockPolicy.matches(title: "Something", patterns: [""]))
    }

    // MARK: Lock

    func testLockMinimisesNonMatchingWindowsAndKeepsMatching() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        var notices: [String] = []
        enforcer.onBlockedWindow = { _, _, title in notices.append(title) }

        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertTrue(enforcer.isActive)
        XCTAssertEqual(fake.minimised, [2], "only the window off the rule goes")
        XCTAssertFalse(fake.isMinimized(1, pid: 10))
        XCTAssertEqual(notices, ["Other — main.swift"])
        XCTAssertTrue(fake.observed.contains(10), "the app is watched for new and retitled windows")
    }

    func testMatchedWindowStaysAllowedWhenRetitled() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])

        // The editor switches files: the title no longer contains "Anchor".
        fake.retitle(1, pid: 10, to: "Untitled 3")
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(1, pid: 10), "a window that matched once is allowed for the session")
        XCTAssertEqual(fake.minimised, [2])
    }

    func testNewWindowsAreJudgedByTitle() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])

        fake.addWindow(3, pid: 10, title: "Anchor — Tests.swift")
        fake.addWindow(4, pid: 10, title: "Reddit")
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(3, pid: 10))
        XCTAssertTrue(fake.isMinimized(4, pid: 10))

        // The user brings the blocked one back: it goes again.
        fake.setMinimized(false, windowID: 4, pid: 10)
        enforcer.sweepAll()
        XCTAssertTrue(fake.isMinimized(4, pid: 10))
    }

    func testUnlockRestoresOnlyWhatItMinimised() {
        let fake = xcodeWorld()
        fake.addWindow(5, pid: 10, title: "Parked", minimized: true)
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertEqual(fake.minimised, [2], "a window the user had minimised is not touched")

        enforcer.unlock()
        XCTAssertFalse(enforcer.isActive)
        XCTAssertEqual(fake.restored, [2])
        XCTAssertTrue(fake.isMinimized(5, pid: 10), "the user's own minimised window stays put")
        XCTAssertTrue(fake.observed.isEmpty)
    }

    func testAllowForSessionBringsMatchingWindowsBack() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertTrue(fake.isMinimized(2, pid: 10))

        enforcer.allowForSession(bundleID: xcode, titlePattern: "Other — main.swift")
        XCTAssertFalse(fake.isMinimized(2, pid: 10))
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(2, pid: 10), "and it is not minimised again")
        fake.addWindow(6, pid: 10, title: "[other — main.swift] copy")
        fake.addWindow(7, pid: 10, title: "Other — README.md")
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(6, pid: 10), "the session pattern matches new windows too, case-insensitively")
        XCTAssertTrue(fake.isMinimized(7, pid: 10), "but it is the whole title, not a word of it")
    }

    func testRelockAllowingTheWholeAppRestoresItsWindows() {
        let fake = xcodeWorld()
        fake.launch(slack, name: "Slack", pid: 20)
        fake.addWindow(21, pid: 20, title: "General")
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [
            Rule(bundleID: xcode, scope: .window, pattern: "Anchor"),
            Rule(bundleID: slack, scope: .window, pattern: "Engineering"),
        ])
        XCTAssertEqual(Set(fake.minimised), [2, 21])

        // "Add to preset" allowed Slack as a whole app.
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor"), Rule(bundleID: slack)])
        XCTAssertEqual(fake.restored, [21])
        XCTAssertTrue(enforcer.isActive)
        XCTAssertTrue(fake.isMinimized(2, pid: 10), "Xcode's discipline continues")
    }

    func testNoWindowRulesMeansInactive() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode)])
        XCTAssertFalse(enforcer.isActive)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testWithoutAccessibilityTheLayerIsInert() {
        let fake = xcodeWorld()
        fake.trusted = false
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertFalse(enforcer.isActive, "a window rule falls back to allowing the whole app")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    /// Before: missing Accessibility only reached the log, so the lock
    /// looked real. Now it is reported, and granting it mid-session takes
    /// effect without a relock.
    func testMissingAccessibilityIsReportedAndPickedUpOnceGranted() {
        let fake = xcodeWorld()
        fake.trusted = false
        let enforcer = makeEnforcer(fake)
        var warnings: [String?] = []
        enforcer.onWarning = { warnings.append($0) }

        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertNotNil(warnings.last ?? nil)

        enforcer.recheckTrust()
        XCTAssertEqual(warnings.count, 1, "no repeat while nothing changed")

        fake.trusted = true
        enforcer.recheckTrust()
        XCTAssertTrue(enforcer.isActive, "the waiting rules apply once Accessibility is granted")
        XCTAssertTrue(fake.isMinimized(2, pid: 10))
        XCTAssertEqual(warnings.count, 2)
        XCTAssertNil(warnings.last ?? "still warning")
    }

    func testAccessibilityRevokedMidSessionIsReported() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        var warnings: [String?] = []
        enforcer.onWarning = { warnings.append($0) }
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertTrue(warnings.allSatisfy { $0 == nil })

        fake.trusted = false
        enforcer.recheckTrust()
        XCTAssertNotNil(warnings.last ?? nil)

        enforcer.unlock()
        XCTAssertNil(warnings.last ?? "still warning", "no session, nothing to warn about")
    }

    /// The live manager answers from a cache and reads in the background;
    /// when the fresh read lands, the app is judged again.
    func testAFreshWindowReadIsJudgedWhenItLands() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertEqual(fake.minimised, [2])

        fake.addWindow(3, pid: 10, title: "Scratch — notes.txt")
        fake.onWindowsChanged?(10)
        XCTAssertEqual(fake.minimised, [2, 3], "the manager's change callback reaches the enforcer")
    }

    /// Restores go to every window this layer minimised, even when the last
    /// read shows it as up: that read may be stale.
    func testUnlockRestoresWhatItMinimisedEvenIfTheReadLooksRestored() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertTrue(fake.isMinimized(2, pid: 10))

        // A stale snapshot: the window reads as up though it is minimised.
        fake.windowsByPID[10] = fake.windowsByPID[10]?.map {
            AXWindowSnapshot(id: $0.id, title: $0.title, isMinimized: false, isStandard: $0.isStandard)
        }
        enforcer.unlock()
        XCTAssertEqual(fake.restored, [2])
    }

    /// A window that ignores the minimise reads as up on every fresh read;
    /// re-sending from those reads would loop without pause. Only the timed
    /// sweep retries it.
    func testAWindowThatRefusesToMinimiseIsRetriedOnlyByTheTimedSweep() {
        let fake = xcodeWorld()
        fake.refusesMinimise = [2]
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertEqual(fake.minimised, [2])

        fake.onWindowsChanged?(10)
        fake.onWindowsChanged?(10)
        XCTAssertEqual(fake.minimised, [2], "fresh reads do not re-send")

        enforcer.sweepAll()
        XCTAssertEqual(fake.minimised, [2, 2], "the timed sweep does")
    }

    /// A window refused in one session may minimise in the next (the user
    /// left full screen) while the cache still reports the old refusal. It
    /// must still be restored when that session ends.
    func testAWindowWhoseMinimiseWasReportedRefusedIsStillRestored() {
        let fake = xcodeWorld()
        fake.refusesMinimise = [2]
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        enforcer.unlock()

        // Next session: the app now takes the minimise, but the manager
        // still reports the earlier refusal.
        fake.refusesMinimise = []
        fake.reportRefusalFor = [2]
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertTrue(fake.isMinimized(2, pid: 10))
        enforcer.unlock()
        XCTAssertFalse(fake.isMinimized(2, pid: 10), "restored although the minimise was reported refused")
    }

    func testARetriedMinimiseRaisesNoNewNotice() {
        let fake = xcodeWorld()
        fake.refusesMinimise = [2]
        let enforcer = makeEnforcer(fake)
        var notices = 0
        enforcer.onBlockedWindow = { _, _, _ in notices += 1 }
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        for _ in 0..<3 {
            now = now.addingTimeInterval(NoticeThrottle.interval + 1)
            enforcer.sweepAll()
        }
        XCTAssertEqual(notices, 1, "a refused window is retried without a notice every few seconds")
    }

    /// A picked untitled window stays up past the untitled grace.
    func testAWindowAllowedByIDStaysUp() {
        let fake = xcodeWorld()
        fake.addWindow(7, pid: 10, title: "")
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        now = now.addingTimeInterval(WindowEnforcer.untitledGrace + 0.1)
        enforcer.sweepAll()
        XCTAssertTrue(fake.isMinimized(7, pid: 10))

        enforcer.allowWindowForSession(bundleID: xcode, windowID: 7)
        XCTAssertFalse(fake.isMinimized(7, pid: 10), "the pick brings it back")
        now = now.addingTimeInterval(10)
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(7, pid: 10), "and it stays for the session")
    }

    /// Each session starts from fresh reads, not what was cached during or
    /// after the last one; a relock within a session keeps them.
    func testANewSessionDropsWindowsReadBeforeIt() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        let rules = [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")]
        enforcer.lock(rules: rules)
        XCTAssertEqual(fake.invalidations, 1)
        enforcer.lock(rules: rules + [Rule(bundleID: xcode, scope: .window, pattern: "Other")])
        XCTAssertEqual(fake.invalidations, 1, "a relock mid-session is the same session")
        enforcer.unlock()
        enforcer.lock(rules: rules)
        XCTAssertEqual(fake.invalidations, 2)
    }

    /// Registration is retried only when the app did not answer in time.
    func testOnlyATimedOutRegistrationIsRetried() {
        XCTAssertTrue(AccessibilityWindowManager.shouldRetryRegistration(.cannotComplete))
        for status: AXError in [.success, .notificationAlreadyRegistered, .notificationUnsupported, .notImplemented, .invalidUIElement] {
            XCTAssertFalse(AccessibilityWindowManager.shouldRetryRegistration(status), "\(status.rawValue)")
        }
    }

    func testDrainReachesTheManager() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.drainWrites(timeout: 1)
        XCTAssertEqual(fake.drained, 1)
    }

    func testHoldLeavesWindowsUpUntilReleased() {
        let fake = xcodeWorld()
        let enforcer = makeEnforcer(fake)
        enforcer.hold(true)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(2, pid: 10), "a window the user is about to pick stays up")

        enforcer.hold(false)
        XCTAssertTrue(fake.isMinimized(2, pid: 10))
    }

    func testUnlockDropsRulesWaitingForAccessibility() {
        let fake = xcodeWorld()
        fake.trusted = false
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        enforcer.unlock()
        fake.trusted = true
        enforcer.recheckTrust()
        XCTAssertFalse(enforcer.isActive, "a session that ended does not lock later")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testUntitledWindowsGetAGracePeriod() {
        let fake = xcodeWorld()
        fake.addWindow(7, pid: 10, title: "")
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertFalse(fake.isMinimized(7, pid: 10), "a window may still be getting its title")

        now = now.addingTimeInterval(WindowEnforcer.untitledGrace + 0.1)
        enforcer.sweepAll()
        XCTAssertTrue(fake.isMinimized(7, pid: 10), "still untitled after the grace: minimised")
    }

    func testUntitledWindowThatGainsAMatchingTitleIsAllowed() {
        let fake = xcodeWorld()
        fake.addWindow(7, pid: 10, title: "")
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        fake.retitle(7, pid: 10, to: "Anchor — New.swift")
        now = now.addingTimeInterval(5)
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(7, pid: 10))
    }

    func testMinimisedUntitledWindowIsRestoredWhenItsTitleMatches() {
        let fake = xcodeWorld()
        fake.addWindow(7, pid: 10, title: "")
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])

        // The window stayed untitled past its grace: it is minimised.
        now = now.addingTimeInterval(WindowEnforcer.untitledGrace + 0.1)
        enforcer.sweepAll()
        XCTAssertTrue(fake.isMinimized(7, pid: 10))

        // The app then names it with a matching title: it must come back,
        // not sit in the Dock for the rest of the session.
        fake.retitle(7, pid: 10, to: "Anchor — AppState.swift")
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(7, pid: 10), "a window that matches a rule is restored on screen")
        XCTAssertTrue(fake.restored.contains(7))
        enforcer.sweepAll()
        XCTAssertFalse(fake.isMinimized(7, pid: 10), "and stays up on later sweeps")
    }

    func testNonStandardWindowsAreIgnored() {
        let fake = xcodeWorld()
        fake.addWindow(8, pid: 10, title: "Find", standard: false)
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertFalse(fake.isMinimized(8, pid: 10), "palettes and dialogs are not disciplined")
    }

    func testBlockedWindowNoticesAreThrottledPerApp() {
        let fake = xcodeWorld()
        fake.addWindow(9, pid: 10, title: "Also off")
        let enforcer = makeEnforcer(fake)
        var notices: [String] = []
        enforcer.onBlockedWindow = { _, _, title in notices.append(title) }
        enforcer.lock(rules: [Rule(bundleID: xcode, scope: .window, pattern: "Anchor")])
        XCTAssertEqual(notices.count, 1, "two windows minimised in one sweep: one notice")

        now = now.addingTimeInterval(5)
        fake.setMinimized(false, windowID: 2, pid: 10)
        enforcer.sweepAll()
        XCTAssertEqual(notices.count, 2)
    }
}
