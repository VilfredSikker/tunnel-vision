import Foundation
import XCTest

@testable import Anchor

/// Deterministic tests: a mutable fake clock, no tick loop, sounds off.
@MainActor
final class AppStateTests: XCTestCase {
    /// Reference date so tests stay independent of the real clock.
    private let epoch = Date(timeIntervalSince1970: 1_752_000_000) // 2025-07-16
    private var now: Date = Date()
    private var url: URL!

    override func setUp() async throws {
        now = Date(timeIntervalSince1970: 1_752_000_000)
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnchorTests-\(UUID().uuidString)")
            .appendingPathComponent("data.json")
    }

    override func tearDown() async throws {
        if let url {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func makeState() -> AppState {
        let state = AppState(fileURL: url, clock: { [weak self] in self?.now ?? Date() }, autoTick: false)
        // Silence session sounds in tests.
        var quiet = state.settings
        quiet.soundOn = false
        state.updateSettings(quiet)
        return state
    }

    private func seedTwoTasks(in state: AppState) -> (first: TaskItem, second: TaskItem) {
        let coding = state.preset(named: "Coding")!
        let a = state.addTask(title: "Deep work", durationSeconds: 25 * 60, presetID: coding.id, overrides: [])
        let b = state.addTask(title: "Reply mail", durationSeconds: 10 * 60, presetID: nil, overrides: [])
        return (a, b)
    }

    // MARK: Seeding & persistence

    func testFirstLaunchSeedsBuiltinsAndDefaultPreset() {
        let state = makeState()
        XCTAssertEqual(state.presets.map(\.name), ["Coding", "Writing", "Comms", "Reading"])
        XCTAssertTrue(state.tasks.isEmpty)
        XCTAssertEqual(state.todayCount, 0)
        XCTAssertEqual(state.defaultPresetID, state.codingPresetID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testStatePersistsAcrossReload() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.setTaskDone(id: a.id, done: true)
        state.updateSettings(Settings(workSeconds: 50 * 60, breakSeconds: 10 * 60, strictMode: true, defaultMode: .closed, soundOn: false))

        let reloaded = makeState()
        XCTAssertEqual(reloaded.tasks.count, 2)
        XCTAssertEqual(reloaded.tasks.first?.title, "Deep work")
        XCTAssertTrue(reloaded.tasks.first?.isDone(on: reloaded.todayKey) ?? false)
        XCTAssertEqual(reloaded.tasks.first?.overrides.count, 0)
        XCTAssertEqual(reloaded.settings.workSeconds, 50 * 60)
        XCTAssertEqual(reloaded.settings.strictMode, true)
        XCTAssertEqual(reloaded.settings.defaultMode, .closed)
    }

    func testTaskCRUD() {
        let state = makeState()
        let task = state.addTask(title: "  One  ", durationSeconds: 1500, presetID: nil, overrides: [Rule(bundleID: "")])
        XCTAssertEqual(task.title, "One")
        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertTrue(state.tasks[0].overrides.isEmpty, "incomplete rules are dropped")

        var updated = task
        updated.title = "Renamed"
        updated.durationSeconds = 3000
        state.updateTask(updated)
        XCTAssertEqual(state.tasks[0].title, "Renamed")
        XCTAssertEqual(state.tasks[0].durationSeconds, 3000)

        state.deleteTask(id: task.id)
        XCTAssertTrue(state.tasks.isEmpty)
    }

    func testReorderPersistsOrder() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        let c = state.addTask(title: "Third", durationSeconds: 600, presetID: nil, overrides: [])
        state.moveTask(id: c.id, before: a.id)
        XCTAssertEqual(state.tasks.map(\.title), ["Third", "Deep work", "Reply mail"])
        state.moveTask(id: b.id, before: nil)
        XCTAssertEqual(state.tasks.map(\.title), ["Third", "Deep work", "Reply mail"])

        let reloaded = makeState()
        XCTAssertEqual(reloaded.tasks.map(\.title), ["Third", "Deep work", "Reply mail"])
    }

    // MARK: Presets

    func testPresetCRUD() {
        let state = makeState()
        let coding = state.preset(named: "Coding")!

        XCTAssertTrue(state.duplicatePreset(id: coding.id) != nil)
        let copy = state.presets.last!
        XCTAssertEqual(copy.name, "Coding Copy")
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.rules, coding.rules)

        state.renamePreset(id: copy.id, to: "Deep Work")
        XCTAssertEqual(state.presets.last?.name, "Deep Work")
        state.renamePreset(id: coding.id, to: "Nope")
        XCTAssertEqual(state.preset(named: "Coding")?.name, "Coding", "built-ins cannot be renamed")

        XCTAssertFalse(state.deletePreset(id: coding.id), "built-ins cannot be deleted")
        XCTAssertTrue(state.deletePreset(id: copy.id))
        XCTAssertNil(state.presets.first { $0.id == copy.id })
    }

    func testDeletePresetClearsOnlyItsOwnTaskReferences() {
        let state = makeState()
        let coding = state.preset(named: "Coding")!
        let task = state.addTask(title: "T", durationSeconds: 1500, presetID: coding.id, overrides: [])
        let dup = state.duplicatePreset(id: coding.id)!
        let dupTask = state.addTask(title: "U", durationSeconds: 900, presetID: dup.id, overrides: [])
        state.deletePreset(id: dup.id)
        XCTAssertEqual(state.tasks.first { $0.id == task.id }?.presetID, coding.id)
        XCTAssertNil(state.tasks.first { $0.id == dupTask.id }?.presetID,
                     "tasks referencing the deleted preset fall back to custom")
    }

    // MARK: Session engine

    func testFullSessionTimeline() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)

        state.startTask(id: a.id)
        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.remainingSeconds, 1500)
        XCTAssertEqual(state.activeTaskID, a.id)

        // Pause: time passes but the remaining time stays frozen.
        state.pause()
        XCTAssertEqual(state.phase, .paused)
        now = now.addingTimeInterval(600)
        XCTAssertEqual(state.remainingSeconds, 1500, "paused time must not drain")

        state.resume()
        XCTAssertEqual(state.phase, .work)
        now = now.addingTimeInterval(1490)
        state.tick()
        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.remainingSeconds, 10)

        now = now.addingTimeInterval(11)
        state.tick()
        XCTAssertEqual(state.phase, .breakTime)
        XCTAssertEqual(state.todayCount, 1)
        XCTAssertTrue(state.tasks[0].isDone(on: state.todayKey))
        XCTAssertEqual(state.nextTaskID, b.id, "next incomplete task is offered on the break panel")

        // Skip the break.
        state.skipBreak()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.nextTaskID)
        XCTAssertNil(state.remainingSeconds)
    }

    func testEarlyStopGivesNoCreditAndNoBreak() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(100)
        state.stopNow()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.todayCount, 0)
        XCTAssertFalse(state.tasks[0].isDone(on: state.todayKey))
    }

    func testDoneDuringSessionChecksOffAndBreaks() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(300)
        state.finishTaskDone()
        XCTAssertEqual(state.phase, .breakTime)
        XCTAssertEqual(state.todayCount, 1)
        XCTAssertTrue(state.tasks[0].isDone(on: state.todayKey))
    }

    func testCheckoffRunningTaskActsLikeDone() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.setTaskDone(id: a.id, done: true)
        XCTAssertEqual(state.phase, .breakTime)
        XCTAssertEqual(state.todayCount, 1)
    }

    func testUncheckingDoesNotRunCount() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.setTaskDone(id: a.id, done: true)
        XCTAssertEqual(state.todayCount, 0, "checking off idle is not a session")
        XCTAssertTrue(state.tasks[0].isDone(on: state.todayKey))
        state.setTaskDone(id: a.id, done: false)
        XCTAssertFalse(state.tasks[0].isDone(on: state.todayKey))
    }

    func testBreakAutoEnds() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        var settings = state.settings
        settings.breakSeconds = 60
        state.updateSettings(settings)

        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)
        state.tick() // work over → break
        XCTAssertEqual(state.phase, .breakTime)
        XCTAssertEqual(state.remainingSeconds, 60)

        now = now.addingTimeInterval(61)
        state.tick()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.nextTaskID)
    }

    func testSkipToBreakDoesNotCredit() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.skipToBreak()
        XCTAssertEqual(state.phase, .breakTime)
        XCTAssertEqual(state.todayCount, 0)
        XCTAssertFalse(state.tasks[0].isDone(on: state.todayKey))
    }

    func testEngineRefusesStartWhileRunning() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.startTask(id: b.id)
        XCTAssertEqual(state.activeTaskID, a.id, "must pause or end the current session first")
        XCTAssertEqual(state.phase, .work)
    }

    func testStartDuringBreakRestartsWork() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)
        state.tick()
        XCTAssertEqual(state.phase, .breakTime)

        state.startTask(id: b.id)
        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.activeTaskID, b.id)
        XCTAssertEqual(state.todayCount, 1)
    }

    func testCompletedCountResetsOnNewDay() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)
        state.tick()
        XCTAssertEqual(state.todayCount, 1)
        XCTAssertEqual(state.countDay, DayKey.key(for: now))

        // Next day: the reloaded store must reset the counter.
        now = Calendar.current.date(byAdding: .day, value: 2, to: now)!
        let nextDay = makeState()
        XCTAssertEqual(nextDay.todayCount, 0)
        XCTAssertEqual(nextDay.countDay, DayKey.key(for: now))
        XCTAssertFalse(nextDay.tasks[0].isDone(on: nextDay.todayKey), "done marks are per-day")
    }

    func testCheckoffDuringBreakRefreshesNextTask() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)
        state.tick() // work over → break, next = b
        XCTAssertEqual(state.nextTaskID, b.id)

        // The user checks b off while on the break.
        state.setTaskDone(id: b.id, done: true)
        XCTAssertNil(state.nextTaskID, "break banner must not offer a done task")
    }

    func testCheckoffDuringBreakKeepsOtherPendingNextTask() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        let c = state.addTask(title: "Third", durationSeconds: 600, presetID: nil, overrides: [])
        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)
        state.tick() // break after a; first not-done is b
        XCTAssertEqual(state.nextTaskID, b.id)

        // Checking off the *third* task mid-break must not clear the banner:
        // b is still pending.
        state.setTaskDone(id: c.id, done: true)
        XCTAssertEqual(state.nextTaskID, b.id, "b is still pending and must stay on the banner")
        state.setTaskDone(id: b.id, done: true)
        XCTAssertNil(state.nextTaskID)
    }

    func testCorruptArchiveIsQuarantinedNotOverwritten() throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("this is not a json archive".utf8).write(to: url)

        let state = makeState() // loadOrSeed must quarantine, then reseed
        XCTAssertEqual(state.presets.map(\.name), ["Coding", "Writing", "Comms", "Reading"])

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backups = siblings.filter { $0.hasPrefix("data.json.corrupt-") }
        XCTAssertEqual(backups.count, 1, "the damaged archive must be moved aside, not overwritten")
    }

    func testEngineRefusesStartingDoneTask() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.setTaskDone(id: a.id, done: true)
        state.startTask(id: a.id)
        XCTAssertEqual(state.phase, .idle, "a task done today needs an uncheck before rerun")
        state.setTaskDone(id: a.id, done: false)
        state.startTask(id: a.id)
        XCTAssertEqual(state.phase, .work)
    }

    func testDefaultPresetFollowsLastUsed() {
        let state = makeState()
        let comms = state.preset(named: "Comms")!
        state.addTask(title: "T", durationSeconds: 1500, presetID: comms.id, overrides: [])
        XCTAssertEqual(state.defaultPresetID, comms.id)
    }
}
