import Foundation
import XCTest

@testable import TunnelVision

/// Deterministic tests: a mutable fake clock, no tick loop, sounds off.
/// Records lock-state calls for transition tests.
@MainActor
final class RecordingLockListener: LockListener {
    struct Call: Equatable {
        let active: Bool
        let rules: [Rule]
        let mode: Mode
    }

    var calls: [Call] = []

    func lockStateChanged(active: Bool, rules: [Rule], mode: Mode) {
        calls.append(Call(active: active, rules: rules, mode: mode))
    }
}

@MainActor
final class AppStateTests: XCTestCase {
    /// Reference date so tests stay independent of the real clock.
    private let epoch = Date(timeIntervalSince1970: 1_752_000_000) // 2025-07-16
    private var now: Date = Date()
    private var url: URL!

    override func setUp() async throws {
        now = Date(timeIntervalSince1970: 1_752_000_000)
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelVisionTests-\(UUID().uuidString)")
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

    func testPriorityPersistsAcrossReload() {
        let state = makeState()
        let task = state.addTask(title: "Urgent", durationSeconds: 1500, presetID: nil, overrides: [], priority: 1)
        XCTAssertEqual(task.priority, 1)
        XCTAssertEqual(state.tasks[0].priority, 1)

        var updated = task
        updated.priority = 3
        state.updateTask(updated)
        XCTAssertEqual(state.tasks[0].priority, 3)

        let reloaded = makeState()
        XCTAssertEqual(reloaded.tasks.count, 1)
        XCTAssertEqual(reloaded.tasks[0].priority, 3)
    }

    func testPriorityClampedToOneThree() {
        let state = makeState()
        let low = state.addTask(title: "Low", durationSeconds: 600, presetID: nil, overrides: [], priority: 0)
        XCTAssertEqual(low.priority, 1, "below 1 clamps up to 1")
        let high = state.addTask(title: "High", durationSeconds: 600, presetID: nil, overrides: [], priority: 99)
        XCTAssertEqual(high.priority, 3, "above 3 clamps down to 3")
    }

    func testCreatedDateIsSetOnAdd() {
        let state = makeState()
        let before = now
        let task = state.addTask(title: "Timed", durationSeconds: 600, presetID: nil, overrides: [])
        XCTAssertEqual(task.createdDate, before, "createdDate is the clock at creation")

        now = now.addingTimeInterval(120)
        let later = state.addTask(title: "Later", durationSeconds: 600, presetID: nil, overrides: [])
        XCTAssertEqual(later.createdDate, now, "later task gets a later createdDate")
        XCTAssertEqual(state.tasks[0].createdDate, before, "the first task keeps its createdDate")
    }

    func testDefaultPriorityIsMedium() {
        let state = makeState()
        let task = state.addTask(title: "Default", durationSeconds: 600, presetID: nil, overrides: [])
        XCTAssertEqual(task.priority, 2, "default priority is medium (2)")
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

        // A second duplicate must not collide with the first one's name.
        let copy2 = state.duplicatePreset(id: coding.id)!
        XCTAssertEqual(copy2.name, "Coding Copy 2")
        XCTAssertEqual(state.presets.filter { $0.name == "Coding Copy" }.count, 1)

        state.renamePreset(id: copy.id, to: "Deep Work")
        XCTAssertEqual(state.preset(named: "Deep Work")?.id, copy.id)
        state.renamePreset(id: coding.id, to: "Nope")
        XCTAssertEqual(state.preset(named: "Coding")?.name, "Coding", "built-ins cannot be renamed")

        XCTAssertTrue(state.deletePreset(id: copy.id))
        XCTAssertNil(state.presets.first { $0.id == copy.id })
        XCTAssertFalse(state.deletePreset(id: coding.id), "built-ins can be duplicated and edited, not deleted")
        XCTAssertNotNil(state.preset(named: "Coding"))
    }

    /// Older builds let built-ins be deleted and remembered them so they
    /// stayed gone. Built-ins are permanent now, so they come back.
    func testBuiltinDeletedByAnOlderBuildIsReseeded() throws {
        _ = makeState()
        var archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        archive.presets.removeAll { $0.name == "Reading" }
        archive.removedBuiltinNames = ["Reading"]
        try JSONEncoder().encode(archive).write(to: url)

        let reloaded = makeState()
        XCTAssertEqual(reloaded.presets.filter { $0.name == "Reading" }.count, 1)
        let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        XCTAssertTrue(saved.removedBuiltinNames.isEmpty)
    }

    func testArchiveWithoutRemovedBuiltinsKeyStillDecodes() throws {
        let json = """
        {"version":1,"tasks":[],"presets":[],"settings":{},"todayCount":2,"countDay":"2025-07-16","lastUsedPresetID":null}
        """
        let archive = try JSONDecoder().decode(Archive.self, from: Data(json.utf8))
        XCTAssertEqual(archive.todayCount, 2)
        XCTAssertTrue(archive.removedBuiltinNames.isEmpty)
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
                     "tasks referencing the deleted preset fall back to their own allowlist")
        XCTAssertEqual(state.tasks.first { $0.id == dupTask.id }?.overrides, dup.rules,
                       "the deleted preset's rules move into the task's overrides")
    }

    func testRemovePresetKeepsTheAllowlist() {
        let state = makeState()
        let coding = state.preset(named: "Coding")!
        let task = state.addTask(title: "Deep", durationSeconds: 1500, presetID: coding.id, overrides: [])
        state.setTaskPreset(id: task.id, presetID: nil)
        XCTAssertNil(state.tasks.first { $0.id == task.id }?.presetID)
        XCTAssertEqual(state.tasks.first { $0.id == task.id }?.overrides, coding.rules,
                       "removing the preset copies its rules into the task's overrides")
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

    // MARK: Garden

    func testSessionGrowsAPlantAndLeavesItInTheGarden() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        XCTAssertNil(state.growth)
        XCTAssertTrue(state.todayGarden.isEmpty)

        state.startTask(id: a.id)
        let plan = state.growth
        XCTAssertEqual(plan?.tier, .flower, "25 minutes grows a flower")
        XCTAssertEqual(plan?.durationSeconds, 1500)

        now = now.addingTimeInterval(600)
        state.pause()
        now = now.addingTimeInterval(300)
        XCTAssertEqual(state.growth, plan, "pausing keeps the same plant")
        XCTAssertEqual(state.growthProgress, 0.4, accuracy: 0.001, "and it stops growing")

        state.resume()
        now = now.addingTimeInterval(901)
        state.tick()
        XCTAssertEqual(state.phase, .breakTime)
        XCTAssertNil(state.growth, "the break grows nothing")
        XCTAssertEqual(state.todayGarden.count, 1)
        XCTAssertEqual(state.todayGarden.first?.plan, plan)
        XCTAssertEqual(state.todayGarden.first?.progress ?? 0, 1, accuracy: 0.0001, "the timer ran out: fully grown")
    }

    func testEarlyStopLeavesTheHalfGrownPlant() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(600)
        state.stopNow()
        XCTAssertEqual(state.todayGarden.count, 1)
        XCTAssertEqual(state.todayGarden[0].progress, 0.4, accuracy: 0.001)
        XCTAssertEqual(state.todayCount, 0, "the garden keeps what the count leaves out")
    }

    func testFalseStartLeavesNothingBehind() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(20)
        state.stopNow()
        XCTAssertTrue(state.todayGarden.isEmpty, "under a minute is a false start")
    }

    func testGardenPersistsAndResetsWithTheDay() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(300)
        state.finishTaskDone()
        XCTAssertEqual(state.todayGarden.count, 1)
        XCTAssertEqual(state.todayGarden[0].progress, 0.2, accuracy: 0.001, "Done early keeps the plant as it stood")

        let reloaded = makeState()
        XCTAssertEqual(reloaded.todayGarden, state.todayGarden, "today's plants survive a relaunch")

        now = now.addingTimeInterval(24 * 60 * 60)
        reloaded.tick()
        XCTAssertTrue(reloaded.todayGarden.isEmpty, "a new day starts with an empty garden")
        XCTAssertEqual(reloaded.todayCount, 0)
    }

    // MARK: UI requests

    func testNewTaskRequestIsTransient() {
        let state = makeState()
        XCTAssertFalse(state.pendingNewTask)
        state.requestNewTask()
        XCTAssertTrue(state.pendingNewTask)
        XCTAssertFalse(makeState().pendingNewTask, "a request is never persisted")
        state.clearNewTaskRequest()
        XCTAssertFalse(state.pendingNewTask)
    }

    // MARK: Extending

    func testExtendAddsTimeAndKeepsThePlantGrowing() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(600)
        XCTAssertEqual(state.remainingSeconds, 900)
        XCTAssertEqual(state.growthProgress, 0.4, accuracy: 0.001)

        state.extend(bySeconds: 600)
        XCTAssertEqual(state.remainingSeconds, 1500, "ten more minutes on the clock")
        XCTAssertEqual(state.workElapsedFraction, 600.0 / 2100.0, accuracy: 0.001, "the ring reflects the longer run")
        XCTAssertEqual(state.growthProgress, 0.4, accuracy: 0.001, "the plant does not shrink")
        XCTAssertEqual(state.tasks[0].durationSeconds, 1500, "the task keeps its own duration")

        now = now.addingTimeInterval(750)
        XCTAssertEqual(state.growthProgress, 0.7, accuracy: 0.001, "it grows the rest of the way over the time left")
        now = now.addingTimeInterval(750)
        state.tick()
        XCTAssertEqual(state.phase, .breakTime)
        XCTAssertEqual(state.todayCount, 1)
        XCTAssertEqual(state.todayGarden.last?.progress ?? 0, 1, accuracy: 0.0001, "and finishes with the timer")
    }

    func testExtendWorksWhilePausedAndNotWhenIdle() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.extend(bySeconds: 300)
        XCTAssertNil(state.remainingSeconds, "nothing to extend while idle")

        state.startTask(id: a.id)
        now = now.addingTimeInterval(300)
        state.pause()
        state.extend(bySeconds: 300)
        XCTAssertEqual(state.remainingSeconds, 1500, "paused time gets the extension too")
        state.extend(bySeconds: -60)
        XCTAssertEqual(state.remainingSeconds, 1500, "negative extensions are ignored")
        state.resume()
        now = now.addingTimeInterval(1500)
        state.tick()
        XCTAssertEqual(state.phase, .breakTime)
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

    // MARK: Phase popups

    /// Both timer-driven transitions raise exactly one popup, and the tick
    /// that follows does not raise it again.
    func testTimerTransitionsRaiseOnePopupEach() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        var settings = state.settings
        settings.breakSeconds = 60
        state.updateSettings(settings)

        state.startTask(id: a.id)
        XCTAssertNil(state.phaseAlert)
        now = now.addingTimeInterval(26 * 60)
        state.tick()
        XCTAssertEqual(state.phaseAlert, .workEnded(taskTitle: "Deep work", breakSeconds: 60))
        state.dismissPhaseAlert()
        state.tick()
        XCTAssertNil(state.phaseAlert, "a dismissed popup does not come back on the next tick")

        now = now.addingTimeInterval(61)
        state.tick()
        XCTAssertEqual(state.phaseAlert, .breakEnded(nextTaskID: b.id, nextTaskTitle: b.title))
        state.tick()
        XCTAssertEqual(state.phaseAlert, .breakEnded(nextTaskID: b.id, nextTaskTitle: b.title))

        state.startTask(id: b.id)
        XCTAssertNil(state.phaseAlert, "starting the next task clears the popup")
    }

    /// The break-end popup replaces an undismissed work-end one: only the
    /// latest change is on screen.
    func testOnlyTheLatestTransitionIsShown() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        var settings = state.settings
        settings.breakSeconds = 60
        state.updateSettings(settings)

        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)
        state.tick()
        now = now.addingTimeInterval(61)
        state.tick()
        guard case .breakEnded = state.phaseAlert else {
            return XCTFail("expected the break-end popup, got \(String(describing: state.phaseAlert))")
        }
    }

    /// Changes the user makes are not announced.
    func testUserTransitionsRaiseNoPopup() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.skipToBreak()
        XCTAssertNil(state.phaseAlert)
        state.skipBreak()
        XCTAssertNil(state.phaseAlert)
        state.startTask(id: a.id)
        state.finishTaskDone()
        XCTAssertNil(state.phaseAlert)
    }

    // MARK: Pause limit

    /// A pause lifts the lock, so it ends by itself after five minutes.
    func testPauseResumesItselfAfterTheLimit() {
        let state = makeState()
        let listener = RecordingLockListener()
        state.lockListener = listener
        var limitsReached = 0
        state.onPauseLimitReached = { limitsReached += 1 }
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(60)
        state.pause()
        XCTAssertEqual(state.pauseEndsAt, now.addingTimeInterval(AppState.maxPauseSeconds))

        now = now.addingTimeInterval(AppState.maxPauseSeconds - 1)
        state.tick()
        XCTAssertEqual(state.phase, .paused)

        now = now.addingTimeInterval(2)
        state.tick()
        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(listener.calls.last?.active, true, "the lock comes back with the session")
        XCTAssertEqual(state.remainingSeconds, 24 * 60, "time spent paused is not taken from the session")
        XCTAssertNil(state.pauseEndsAt)
        XCTAssertEqual(limitsReached, 1, "the app is told, so it can say the lock is back")

        state.pause()
        state.resume()
        XCTAssertEqual(limitsReached, 1, "a resume by hand is not announced")
    }

    /// Before: each pause got a fresh five minutes, so pausing again right
    /// after the auto-resume kept the lock off for good.
    func testPauseTimeIsBudgetedPerSession() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        state.startTask(id: a.id)

        state.pause()
        now = now.addingTimeInterval(3 * 60)
        state.resume()
        XCTAssertEqual(state.pauseSecondsLeft, 2 * 60)

        state.pause()
        XCTAssertEqual(state.pauseEndsAt, now.addingTimeInterval(2 * 60), "the second pause gets what is left")
        now = now.addingTimeInterval(2 * 60 + 1)
        state.tick()
        XCTAssertEqual(state.phase, .work)

        XCTAssertFalse(state.canPause)
        state.pause()
        XCTAssertEqual(state.phase, .work, "no pause time left this session")

        state.stopNow()
        state.startTask(id: b.id)
        XCTAssertTrue(state.canPause, "the next session starts with a full budget")
    }

    // MARK: Preset URLs

    func testStartingATaskOpensItsPresetURLs() {
        let state = makeState()
        var opened: [[URL]] = []
        state.urlOpener = { opened.append($0) }
        var coding = state.preset(named: "Coding")!
        coding.urlsToOpen = ["github.com/me/repo", "https://docs.swift.org", "  ", "not a url"]
        state.updatePreset(coding)
        let (a, b) = seedTwoTasks(in: state)

        state.startTask(id: a.id)
        XCTAssertEqual(opened, [[URL(string: "https://github.com/me/repo")!, URL(string: "https://docs.swift.org")!]])

        state.pause()
        state.resume()
        XCTAssertEqual(opened.count, 1, "resuming is not a start")

        state.stopNow()
        state.startTask(id: b.id)
        XCTAssertEqual(opened.count, 1, "a task without a preset opens nothing")
    }

    /// Task, small, task, small, task, long, then the cycle starts over.
    func testEveryThirdSessionInARowEarnsTheLongBreak() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        var breaks: [Int?] = []
        var longs: [Bool] = []
        for _ in 0..<4 {
            state.startTask(id: a.id)
            state.finishTaskDone()
            breaks.append(state.remainingSeconds)
            longs.append(state.isLongBreak)
            state.skipBreak()
        }
        XCTAssertEqual(breaks, [5 * 60, 5 * 60, 20 * 60, 5 * 60])
        XCTAssertEqual(longs, [false, false, true, false])
    }

    func testTimedOutSessionsCountTowardTheLongBreakAndThePopupSaysSo() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        for _ in 0..<2 {
            state.startTask(id: a.id)
            state.finishTaskDone()
            state.skipBreak()
        }
        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)
        state.tick()
        XCTAssertEqual(state.phaseAlert, .workEnded(taskTitle: "Deep work", breakSeconds: 20 * 60, isLong: true))
    }

    func testEarlyStopBreaksTheRow() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        for _ in 0..<2 {
            state.startTask(id: a.id)
            state.finishTaskDone()
            state.skipBreak()
        }
        state.startTask(id: a.id)
        state.stopNow()
        state.startTask(id: a.id)
        state.finishTaskDone()
        XCTAssertFalse(state.isLongBreak)
        XCTAssertEqual(state.remainingSeconds, 5 * 60)
    }

    func testSkipToBreakNeitherCountsNorBreaksTheRow() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        for _ in 0..<2 {
            state.startTask(id: a.id)
            state.finishTaskDone()
            state.skipBreak()
        }
        state.startTask(id: a.id)
        state.skipToBreak()
        XCTAssertFalse(state.isLongBreak, "an unfinished task is not the third in the row")
        state.skipBreak()
        state.startTask(id: a.id)
        state.finishTaskDone()
        XCTAssertTrue(state.isLongBreak)
    }

    func testLongBreakSettingsSurviveOlderArchives() throws {
        let old = #"{"workSeconds":1500,"breakSeconds":300}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.longBreakSeconds, 20 * 60)
        XCTAssertEqual(settings.sessionsBeforeLongBreak, 3)
    }

    func testSkipToBreakDoesNotCredit() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.skipToBreak()
        XCTAssertEqual(state.phase, .breakTime)
        XCTAssertEqual(state.todayCount, 0)
        XCTAssertFalse(state.tasks[0].isDone(on: state.todayKey))
        // The abandoned task is still not done, so it stays "next up".
        XCTAssertEqual(state.nextTaskID, a.id)
    }

    func testDeleteNextUpDuringBreakPicksNextPending() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        let c = state.addTask(title: "Third", durationSeconds: 600, presetID: nil, overrides: [])
        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)
        state.tick() // break after a; next = b
        XCTAssertEqual(state.nextTaskID, b.id)

        state.deleteTask(id: b.id)
        XCTAssertEqual(state.nextTaskID, c.id, "banner must move to the next pending task")
    }

    func testAddDuringBreakRefreshesNextUp() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)
        state.tick() // break after a; next = b
        XCTAssertEqual(state.nextTaskID, b.id)

        // b done + a new task added mid-break: the newcomer becomes next up.
        state.setTaskDone(id: b.id, done: true)
        XCTAssertNil(state.nextTaskID)
        let c = state.addTask(title: "Fresh", durationSeconds: 600, presetID: nil, overrides: [])
        XCTAssertEqual(state.nextTaskID, c.id, "a task added during a break must appear on the banner")
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

    // MARK: Restart

    /// Rewrites one top-level key of the saved archive, as a crash could
    /// leave it or a hand edit could.
    private func editArchive(_ change: (inout [String: Any]) -> Void) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    func testRestartPicksUpTheRunningSession() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(300)

        let relaunched = makeState()
        XCTAssertEqual(relaunched.phase, .work)
        XCTAssertEqual(relaunched.activeTaskID, a.id)
        XCTAssertEqual(relaunched.remainingSeconds, 20 * 60)
        XCTAssertEqual(relaunched.growth, state.growth, "the same plant keeps growing")
        XCTAssertNotNil(relaunched.activeLock, "the lock comes back with it")
    }

    func testRestartRelocksThroughTheListener() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)

        let relaunched = makeState()
        let listener = RecordingLockListener()
        relaunched.lockListener = listener
        relaunched.notifyLockChange()
        XCTAssertEqual(listener.calls.last?.active, true)
    }

    func testRestartKeepsAPauseAndItsBudget() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(60)
        state.pause()
        now = now.addingTimeInterval(120)

        let relaunched = makeState()
        XCTAssertEqual(relaunched.phase, .paused)
        XCTAssertEqual(relaunched.remainingSeconds, 24 * 60)
        XCTAssertEqual(relaunched.pauseSecondsLeft, 3 * 60, "time paused before the restart still counts")
    }

    func testRestartKeepsTheLongBreakAndTheRow() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        for _ in 0..<2 {
            state.startTask(id: a.id)
            state.finishTaskDone()
            state.skipBreak()
        }
        let row = makeState()
        row.startTask(id: a.id)
        row.finishTaskDone()
        XCTAssertTrue(row.isLongBreak, "the row survived the restart")
        now = now.addingTimeInterval(60)

        let relaunched = makeState()
        XCTAssertEqual(relaunched.phase, .breakTime)
        XCTAssertTrue(relaunched.isLongBreak)
        XCTAssertEqual(relaunched.remainingSeconds, 19 * 60)
    }

    /// No lock ran while the app was down, so a run whose time passed then
    /// earns nothing.
    func testWorkThatRanOutWhileClosedEndsQuietly() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.finishTaskDone()
        state.skipBreak()
        state.startTask(id: a.id)
        now = now.addingTimeInterval(26 * 60)

        let relaunched = makeState()
        relaunched.tick()
        XCTAssertEqual(relaunched.phase, .idle)
        XCTAssertEqual(relaunched.todayCount, 1, "only the run finished before the restart")
        XCTAssertNil(relaunched.phaseAlert)
        XCTAssertEqual(relaunched.sessionsInARow, 0, "a dropped run starts the row over")
    }

    func testPauseThatRanOutWhileClosedEndsQuietly() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.pause()
        now = now.addingTimeInterval(AppState.maxPauseSeconds + 1)

        let relaunched = makeState()
        XCTAssertEqual(relaunched.phase, .idle)
        XCTAssertNil(relaunched.activeLock)
    }

    func testBreakThatRanOutWhileClosedLeavesItIdle() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.finishTaskDone()
        now = now.addingTimeInterval(6 * 60)

        let relaunched = makeState()
        XCTAssertEqual(relaunched.phase, .idle)
        XCTAssertEqual(relaunched.sessionsInARow, 1, "a break running out does not break the row")
    }

    func testRestartWithTheTaskGoneIsIdle() throws {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        try editArchive { json in
            let tasks = json["tasks"] as? [[String: Any]] ?? []
            json["tasks"] = tasks.filter { $0["id"] as? String != a.id.uuidString }
        }

        let relaunched = makeState()
        XCTAssertEqual(relaunched.phase, .idle)
        XCTAssertNil(relaunched.activeTaskID)
    }

    func testUnreadableSessionKeepsTheRestOfTheArchive() throws {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        try editArchive { $0["session"] = ["phase": "napping"] }

        let relaunched = makeState()
        XCTAssertEqual(relaunched.phase, .idle)
        XCTAssertEqual(relaunched.tasks.map(\.title), ["Deep work", "Reply mail"])
    }

    func testIdleSavesNoSession() throws {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.stopNow()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(json["session"])
    }

    // MARK: Auto-start

    private func makeAutoStartState(_ on: Bool) -> (AppState, TaskItem, TaskItem) {
        let state = makeState()
        var settings = state.settings
        settings.autoStartNextTask = on
        state.updateSettings(settings)
        let (a, b) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        state.finishTaskDone()
        return (state, a, b)
    }

    func testAutoStartRunsTheNextTaskWhenTheBreakEnds() {
        let (state, _, b) = makeAutoStartState(true)
        now = now.addingTimeInterval(5 * 60)
        state.tick()
        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.activeTaskID, b.id)
        XCTAssertNil(state.phaseAlert)
    }

    func testWithoutAutoStartTheBreakEndsIdle() {
        let (state, _, b) = makeAutoStartState(false)
        now = now.addingTimeInterval(5 * 60)
        state.tick()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.phaseAlert, .breakEnded(nextTaskID: b.id, nextTaskTitle: "Reply mail"))
    }

    func testAutoStartWaitsWhenTheBreakEndWasNoticedLate() {
        let (state, _, _) = makeAutoStartState(true)
        now = now.addingTimeInterval(5 * 60 + AppState.autoStartGraceSeconds + 1)
        state.tick()
        XCTAssertEqual(state.phase, .idle, "the Mac slept through the break's end")
    }

    func testAutoStartWithNothingLeftEndsIdle() {
        let (state, _, b) = makeAutoStartState(true)
        state.skipBreak()
        state.startTask(id: b.id)
        state.finishTaskDone()
        now = now.addingTimeInterval(5 * 60)
        state.tick()
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: History

    func testEveryKindOfEndIsRecorded() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(600)
        state.finishTaskDone()
        state.skipBreak()

        state.startTask(id: b.id)
        now = now.addingTimeInterval(120)
        state.skipToBreak()
        state.skipBreak()

        state.startTask(id: b.id)
        now = now.addingTimeInterval(90)
        state.stopNow()

        XCTAssertEqual(state.history.map(\.outcome), [.completed, .skippedToBreak, .stopped])
        XCTAssertEqual(state.history.map(\.focusSeconds), [600, 120, 90])
        XCTAssertEqual(state.history.map(\.title), ["Deep work", "Reply mail", "Reply mail"])
    }

    func testFalseStartsAreNotRecordedButQuickDonesAre() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(30)
        state.stopNow()
        XCTAssertTrue(state.history.isEmpty)

        state.startTask(id: a.id)
        now = now.addingTimeInterval(30)
        state.finishTaskDone()
        XCTAssertEqual(state.history.map(\.outcome), [.completed], "it counts as a session, so it is in the history")
    }

    func testPausesAreLeftOutOfFocusTime() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(60)
        state.pause()
        now = now.addingTimeInterval(200)
        state.resume()
        now = now.addingTimeInterval(60)
        state.finishTaskDone()
        XCTAssertEqual(state.history.first?.focusSeconds, 120)
        XCTAssertEqual(state.history.first?.endedAt.timeIntervalSince(state.history.first!.startedAt), 320)
    }

    func testATimedOutRunEndsWhenItsTimeWasUp() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        let started = now
        state.startTask(id: a.id)
        now = now.addingTimeInterval(40 * 60) // the Mac slept past the end
        state.tick()
        XCTAssertEqual(state.history.first?.endedAt, started.addingTimeInterval(25 * 60))
        XCTAssertEqual(state.history.first?.focusSeconds, 25 * 60)
    }

    func testHistorySurvivesARelaunchAndADayChange() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        now = now.addingTimeInterval(600)
        state.finishTaskDone()
        now = now.addingTimeInterval(2 * 86_400)

        let relaunched = makeState()
        XCTAssertEqual(relaunched.todayCount, 0)
        XCTAssertEqual(relaunched.history.count, 1)
        XCTAssertEqual(relaunched.history.first?.title, "Deep work")
    }

    func testDoneTaskCanBeRepeated() {
        let state = makeState()
        let (a, _) = seedTwoTasks(in: state)
        state.setTaskDone(id: a.id, done: true)
        XCTAssertEqual(state.todayCount, 0, "a plain check-off is not a session")

        state.startTask(id: a.id)
        XCTAssertEqual(state.phase, .work, "a task done today can run again")
        XCTAssertEqual(state.activeTaskID, a.id)

        state.finishTaskDone()
        XCTAssertEqual(state.phase, .breakTime)
        XCTAssertEqual(state.todayCount, 1, "the repeat counts as a session")
        XCTAssertTrue(state.tasks[0].isDone(on: state.todayKey), "and the task stays checked off")
        XCTAssertEqual(state.tasks[0].doneDays.count, 1, "no duplicate day marks")
    }

    func testRepeatTaskRunsAFreshCopyAfterTheOriginal() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        state.setTaskDone(id: a.id, done: true)

        let copy = state.repeatTask(id: a.id)
        XCTAssertNotNil(copy)
        XCTAssertEqual(state.tasks.map(\.id), [a.id, copy!.id, b.id], "the re-run sits right after the finished task")
        XCTAssertEqual(copy?.title, a.title)
        XCTAssertEqual(copy?.durationSeconds, a.durationSeconds)
        XCTAssertEqual(copy?.presetID, a.presetID)
        XCTAssertFalse(copy!.isDone(on: state.todayKey), "the copy is a new, open task")
        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.activeTaskID, copy?.id)
        XCTAssertNil(state.repeatTask(id: b.id), "refused while a session runs")

        state.finishTaskDone()
        XCTAssertTrue(state.tasks[1].isDone(on: state.todayKey))
        XCTAssertTrue(state.tasks[0].isDone(on: state.todayKey), "the original keeps its own check mark")
        XCTAssertEqual(state.todayCount, 1)

        let reloaded = makeState()
        XCTAssertEqual(reloaded.tasks.count, 3, "the copy is persisted")
    }

    func testStartOrPauseCyclesThroughThePhases() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        state.setTaskDone(id: a.id, done: true)

        state.startOrPause()
        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.activeTaskID, b.id, "idle: the first task not done today starts")
        state.startOrPause()
        XCTAssertEqual(state.phase, .paused)
        state.startOrPause()
        XCTAssertEqual(state.phase, .work)

        state.finishTaskDone()
        XCTAssertEqual(state.phase, .breakTime)
        state.startOrPause()
        XCTAssertEqual(state.phase, .breakTime, "everything is done: nothing to start, the break goes on")

        state.setTaskDone(id: a.id, done: false)
        state.startOrPause()
        XCTAssertEqual(state.phase, .work, "a break ends early for the next task")
        XCTAssertEqual(state.activeTaskID, a.id)
    }

    func testTaskAtHandIsTheRunningTaskElseNextUp() {
        let state = makeState()
        let (a, b) = seedTwoTasks(in: state)
        XCTAssertEqual(state.taskAtHand?.id, a.id)
        state.setTaskDone(id: a.id, done: true)
        XCTAssertEqual(state.taskAtHand?.id, b.id)
        state.startTask(id: b.id)
        XCTAssertEqual(state.taskAtHand?.id, b.id)
        state.setTaskDone(id: b.id, done: true)
        XCTAssertNil(state.taskAtHand, "on the break with everything done there is nothing to edit")
    }

    func testAllowInActiveTaskAddsAnyRuleOnce() {
        let state = makeState()
        let listener = RecordingLockListener()
        state.lockListener = listener
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        let before = state.preset(named: "Coding")!.rules.count

        state.allowInActiveTask(rule: Rule(bundleID: "net.imput.helium", scope: .url, pattern: " News.example "))
        state.allowInActiveTask(rule: Rule(bundleID: "net.imput.helium", scope: .url, pattern: "news.example"))
        state.allowInActiveTask(rule: Rule(bundleID: "com.apple.dt.Xcode", scope: .window, pattern: ""))
        let coding = state.preset(named: "Coding")!
        XCTAssertEqual(coding.rules.count, before + 1, "trimmed, case-insensitive duplicates and incomplete rules are not added")
        XCTAssertEqual(coding.rules.last, Rule(id: coding.rules.last!.id, bundleID: "net.imput.helium", scope: .url, pattern: "News.example"))
        XCTAssertEqual(listener.calls.count, 2, "one relock for the rule that was added")
        XCTAssertTrue(listener.calls.last!.rules.contains { $0.pattern == "News.example" })
    }

    func testApplyPickedAllowlistDetachesThePresetOrAdoptsTheSavedOne() {
        let state = makeState()
        let listener = RecordingLockListener()
        state.lockListener = listener
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)

        let picked = [Rule(bundleID: "com.apple.dt.Xcode", scope: .window, pattern: "Anchor")]
        state.applyPickedAllowlist(taskID: a.id, rules: picked + [Rule(bundleID: "")], savedPresetID: nil)
        XCTAssertNil(state.activeTask?.presetID, "what you see is what locks: the task owns its rules now")
        XCTAssertEqual(state.activeTask?.overrides, picked)
        XCTAssertEqual(listener.calls.last?.rules, picked, "the running session relocked")

        let saved = state.addPreset(name: "Picked")
        state.applyPickedAllowlist(taskID: a.id, rules: [], savedPresetID: saved.id)
        XCTAssertEqual(state.activeTask?.presetID, saved.id)
        XCTAssertEqual(state.activeTask?.overrides, [])
        XCTAssertEqual(state.defaultPresetID, saved.id, "the saved preset becomes the last used one")
    }

    func testDefaultPresetFollowsLastUsed() {
        let state = makeState()
        let comms = state.preset(named: "Comms")!
        state.addTask(title: "T", durationSeconds: 1500, presetID: comms.id, overrides: [])
        XCTAssertEqual(state.defaultPresetID, comms.id)
    }

    // MARK: Lock notifications

    func testLockListenerTracksSessionTransitions() {
        let state = makeState()
        let listener = RecordingLockListener()
        state.lockListener = listener
        let (a, _) = seedTwoTasks(in: state)

        XCTAssertTrue(listener.calls.isEmpty)
        state.startTask(id: a.id)
        XCTAssertEqual(listener.calls.map(\.active), [true])
        let lockCall = listener.calls.last!
        XCTAssertEqual(lockCall.mode, .dark)
        XCTAssertTrue(lockCall.rules.contains { $0.bundleID == "com.apple.dt.Xcode" })

        // Pausing lifts the lock; resuming re-applies it.
        state.pause()
        XCTAssertEqual(listener.calls.last?.active, false, "pause lifts the lock")
        state.resume()
        XCTAssertEqual(listener.calls.last?.active, true, "resume re-applies the lock")
        XCTAssertEqual(listener.calls.count, 3)

        state.stopNow()
        XCTAssertEqual(listener.calls.last?.active, false, "early stop unlocks")

        state.startTask(id: a.id)
        state.finishTaskDone()
        XCTAssertEqual(listener.calls.last?.active, false, "done → break unlocks")
    }

    func testPresetEditAndDeleteRelockActiveSession() {
        let state = makeState()
        let listener = RecordingLockListener()
        state.lockListener = listener
        let (a, _) = seedTwoTasks(in: state) // a uses Coding
        state.startTask(id: a.id)
        XCTAssertEqual(listener.calls.count, 1)

        // Editing the running preset's rules must reach the enforcer.
        let coding = state.preset(named: "Coding")!
        var edited = coding
        edited.rules.append(Rule(bundleID: "com.example.newapp"))
        state.updatePreset(edited)
        XCTAssertEqual(listener.calls.count, 2)
        XCTAssertTrue(listener.calls.last!.rules.contains { $0.bundleID == "com.example.newapp" })

        // Deleting a preset the running task does not use → no notification.
        let dup = state.duplicatePreset(id: coding.id)!
        state.deletePreset(id: dup.id)
        XCTAssertEqual(listener.calls.count, 2)

        // Point the running task at a custom preset copy, then delete it:
        // the preset's rules move into the task's own overrides so the lock
        // keeps the same allowlist.
        let dup2 = state.duplicatePreset(id: coding.id)!
        state.setTaskPreset(id: a.id, presetID: dup2.id)
        XCTAssertEqual(listener.calls.count, 3)
        XCTAssertTrue(listener.calls.last!.rules.contains { $0.bundleID == "com.apple.dt.Xcode" })

        state.deletePreset(id: dup2.id)
        XCTAssertEqual(listener.calls.count, 4)
        XCTAssertTrue(listener.calls.last!.active)
        XCTAssertTrue(listener.calls.last!.rules.contains { $0.bundleID == "com.apple.dt.Xcode" },
                       "preset gone → the task's own allowlist (the copied rules) applies")
        XCTAssertNil(state.tasks.first { $0.id == a.id }?.presetID)
        XCTAssertTrue(state.tasks.first { $0.id == a.id }?.overrides.contains { $0.bundleID == "com.apple.dt.Xcode" } ?? false)

        // Built-ins still cannot be deleted and never notify.
        state.deletePreset(id: coding.id)
        XCTAssertEqual(listener.calls.count, 4)
    }

    func testAllowInActiveTaskAppendsToPresetOrOverrides() {
        let state = makeState()
        let listener = RecordingLockListener()
        state.lockListener = listener

        let (a, b) = seedTwoTasks(in: state)
        state.startTask(id: a.id) // preset-based
        state.allowInActiveTask(bundleID: "com.example.slack")
        XCTAssertTrue(state.preset(named: "Coding")!.rules.contains { $0.bundleID == "com.example.slack" })
        XCTAssertEqual(listener.calls.last?.active, true)

        state.stopNow()
        state.startTask(id: b.id) // custom task
        state.allowInActiveTask(bundleID: "com.example.slack")
        let task = state.tasks.first { $0.id == b.id }!
        XCTAssertTrue(task.overrides.contains { $0.bundleID == "com.example.slack" })
        XCTAssertTrue(listener.calls.last!.rules.contains { $0.bundleID == "com.example.slack" })
    }

    func testNoPresetTaskWithoutRulesRunsOpen() {
        let state = makeState()
        let listener = RecordingLockListener()
        state.lockListener = listener
        let (_, b) = seedTwoTasks(in: state) // b: no preset, no overrides
        state.startTask(id: b.id)
        XCTAssertEqual(listener.calls.last?.active, false,
                       "a task with no preset and no custom rules runs open — nothing is blocked")
        XCTAssertEqual(listener.calls.last?.rules, [])
    }

    func testNoPresetTaskWithOverridesStillLocks() {
        let state = makeState()
        let listener = RecordingLockListener()
        state.lockListener = listener
        let (_, b) = seedTwoTasks(in: state)
        var locked = b
        locked.overrides = [Rule(bundleID: "com.example.editor")]
        state.updateTask(locked)
        state.startTask(id: b.id)
        XCTAssertEqual(listener.calls.last?.active, true)
        XCTAssertEqual(listener.calls.last?.mode, state.settings.defaultMode,
                       "a custom allowlist locks under the settings default mode")
        XCTAssertTrue(listener.calls.last!.rules.contains { $0.bundleID == "com.example.editor" })
    }

    func testUnsettingTheLockListenerStopsNotifications() {
        let state = makeState()
        let listener = RecordingLockListener()
        state.lockListener = listener
        let (a, _) = seedTwoTasks(in: state)
        state.startTask(id: a.id)
        XCTAssertEqual(listener.calls.map(\.active), [true])

        // The enforcer goes away (tests, teardown): later transitions must
        // not reach a stale listener.
        state.lockListener = nil
        listener.calls = []
        state.stopNow()
        XCTAssertTrue(listener.calls.isEmpty)
        XCTAssertEqual(state.phase, .idle)
    }
}

// MARK: - Day view, done order and reordering

@MainActor
final class DayAndOrderTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_752_000_000)
    private var url: URL!

    override func setUp() async throws {
        now = Date(timeIntervalSince1970: 1_752_000_000)
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelVisionDay-\(UUID().uuidString)")
            .appendingPathComponent("data.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func makeState() -> AppState {
        let state = AppState(fileURL: url, clock: { [weak self] in self?.now ?? Date() }, autoTick: false)
        var quiet = state.settings
        quiet.soundOn = false
        state.updateSettings(quiet)
        return state
    }

    func testDoneTasksListMostRecentFirst() {
        let state = makeState()
        let a = state.addTask(title: "A", durationSeconds: 600, presetID: nil, overrides: [])
        _ = state.addTask(title: "B", durationSeconds: 600, presetID: nil, overrides: [])
        let c = state.addTask(title: "C", durationSeconds: 600, presetID: nil, overrides: [])
        state.setTaskDone(id: a.id, done: true)
        now = now.addingTimeInterval(60)
        state.setTaskDone(id: c.id, done: true)
        XCTAssertEqual(state.doneTasks(on: state.todayKey).map(\.title), ["C", "A"], "latest check-off first")
        XCTAssertEqual(state.openTasks(on: state.todayKey).map(\.title), ["B"])
        XCTAssertEqual(state.tasks[0].doneTime(on: state.todayKey), Date(timeIntervalSince1970: 1_752_000_000))

        state.setTaskDone(id: a.id, done: false)
        XCTAssertNil(state.tasks[0].doneTime(on: state.todayKey), "unchecking forgets the time")
    }

    func testCheckOffOnAnotherDayLeavesTodayAlone() {
        let state = makeState()
        let a = state.addTask(title: "A", durationSeconds: 600, presetID: nil, overrides: [])
        let yesterday = DayKey.key(byAdding: -1, to: state.todayKey)!
        state.startTask(id: a.id)
        state.setTaskDone(id: a.id, done: true, on: yesterday)
        XCTAssertEqual(state.phase, .work, "a past-day check-off does not end the running session")
        XCTAssertTrue(state.tasks[0].isDone(on: yesterday))
        XCTAssertFalse(state.tasks[0].isDone(on: state.todayKey))
        XCTAssertEqual(state.doneTasks(on: yesterday).map(\.title), ["A"])
    }

    func testReorderTasksPutsTheGivenOnesFirst() {
        let state = makeState()
        let a = state.addTask(title: "A", durationSeconds: 600, presetID: nil, overrides: [])
        _ = state.addTask(title: "B", durationSeconds: 600, presetID: nil, overrides: [])
        let c = state.addTask(title: "C", durationSeconds: 600, presetID: nil, overrides: [])
        state.reorderTasks(ids: [c.id, a.id, c.id, UUID()])
        XCTAssertEqual(state.tasks.map(\.title), ["C", "A", "B"], "duplicates and unknown ids are ignored, the rest follow")
        state.reorderTasks(ids: [])
        XCTAssertEqual(state.tasks.map(\.title), ["C", "A", "B"])
        XCTAssertEqual(makeState().tasks.map(\.title), ["C", "A", "B"], "persisted")
    }

    func testMoveTaskWorksDuringASession() {
        let state = makeState()
        let a = state.addTask(title: "A", durationSeconds: 600, presetID: nil, overrides: [])
        let b = state.addTask(title: "B", durationSeconds: 600, presetID: nil, overrides: [])
        let c = state.addTask(title: "C", durationSeconds: 600, presetID: nil, overrides: [])
        state.startTask(id: a.id)
        state.moveTask(id: c.id, before: b.id)
        XCTAssertEqual(state.tasks.map(\.title), ["A", "C", "B"])
        XCTAssertEqual(state.activeTaskID, a.id)
    }

    func testTaskDecodesWithoutDoneAt() throws {
        let json = """
        {"id":"7E7C5D02-3B4E-4B6D-9E2B-1B2C3D4E5F60","title":"Old","durationSeconds":1500,"overrides":[],"doneDays":["2026-09-01"]}
        """
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
        XCTAssertTrue(task.isDone(on: "2026-09-01"))
        XCTAssertNil(task.doneTime(on: "2026-09-01"), "older archives carry no times")
        XCTAssertFalse(task.repeatDaily, "older archives default to a one-off task")
        XCTAssertEqual(task.priority, 2, "older archives default to medium priority")
        XCTAssertEqual(task.createdDate, Date.distantPast, "older archives have no createdDate")
        let data = try JSONEncoder().encode(task)
        XCTAssertEqual(try JSONDecoder().decode(TaskItem.self, from: data), task)
    }

    func testTaskRoundTripsPriorityAndCreatedDate() throws {
        let task = TaskItem(title: "Full", durationSeconds: 600, presetID: nil, overrides: [], priority: 1, createdDate: Date(timeIntervalSince1970: 1_752_000_000))
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(TaskItem.self, from: data)
        XCTAssertEqual(decoded, task)
        XCTAssertEqual(decoded.priority, 1)
        XCTAssertEqual(decoded.createdDate, Date(timeIntervalSince1970: 1_752_000_000))
    }

    func testTaskRoundTripsRepeatDaily() throws {
        let task = TaskItem(title: "Stretch", durationSeconds: 600, presetID: nil, overrides: [], repeatDaily: true)
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(TaskItem.self, from: data)
        XCTAssertEqual(decoded, task)
        XCTAssertTrue(decoded.repeatDaily)
    }

    func testOneOffTaskDoneYesterdayDoesNotShowToday() {
        let state = makeState()
        let a = state.addTask(title: "A", durationSeconds: 600, presetID: nil, overrides: [])
        let b = state.addTask(title: "B", durationSeconds: 600, presetID: nil, overrides: [])
        let dayOne = state.todayKey
        state.setTaskDone(id: a.id, done: true) // today
        XCTAssertEqual(state.doneTasks(on: dayOne).map(\.title), ["A"], "a is checked off on dayOne")
        XCTAssertEqual(state.openTasks(on: dayOne).map(\.title), ["B"], "done today: only the open one is listed")

        // Roll to the next day: a is retired, b is still pending.
        now = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let dayTwo = state.todayKey
        XCTAssertNotEqual(dayTwo, dayOne, "the fake clock must actually roll over")
        XCTAssertEqual(state.openTasks(on: dayTwo).map(\.title), ["B"], "the finished one-off does not come back")
        XCTAssertEqual(state.nextUpID(on: dayTwo), b.id)
    }

    func testRepeatingTaskDoneTodayIsStillDueTomorrow() {
        let state = makeState()
        let repeatable = state.addTask(title: "Standup", durationSeconds: 600, presetID: nil, overrides: [], repeatDaily: true)
        let b = state.addTask(title: "B", durationSeconds: 600, presetID: nil, overrides: [])
        let dayOne = state.todayKey
        state.setTaskDone(id: repeatable.id, done: true) // repeat done today
        // A repeating task checked off today stays offered (done repeating
        // tasks are due again at once); the one-off b is still open too.
        XCTAssertEqual(state.openTasks(on: dayOne).map(\.title), ["Standup", "B"])
        XCTAssertEqual(state.nextUpID(on: dayOne), repeatable.id, "a done repeating task is due again at once")

        // Next day: the repeating task is still on the open list, b pending.
        now = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let dayTwo = state.todayKey
        let titles = state.openTasks(on: dayTwo).map(\.title)
        XCTAssertEqual(titles, ["Standup", "B"], "the repeating task is still there the next day")
        XCTAssertEqual(state.nextUpID(on: dayTwo), repeatable.id, "the repeating task is due first")
    }

    func testCheckingOffARepeatingTaskKeepsItListedToday() {
        let state = makeState()
        let repeatable = state.addTask(title: "Standup", durationSeconds: 600, presetID: nil, overrides: [], repeatDaily: true)
        state.setTaskDone(id: repeatable.id, done: true)
        XCTAssertEqual(state.openTasks(on: state.todayKey).map(\.title), ["Standup"],
                       "a repeating task checked off today is still due (offered to run again)")
        XCTAssertEqual(state.nextUpID(on: state.todayKey), repeatable.id,
                       "and it is the next thing up even though it is done today")
        XCTAssertEqual(state.doneTasks(on: state.todayKey).map(\.title), ["Standup"],
                       "its check-off for today still shows under Done")
    }

    func testOneOffDoneYesterdayIsRetiredToday() {
        let state = makeState()
        let a = state.addTask(title: "A", durationSeconds: 600, presetID: nil, overrides: [])
        let yesterday = DayKey.key(byAdding: -1, to: state.todayKey)!
        state.setTaskDone(id: a.id, done: true, on: yesterday)
        XCTAssertTrue(state.tasks[0].isDone(on: yesterday))
        // The one-off was checked off yesterday: it is not open today (its
        // work is done) — a fresh run needs an explicit repeat or new task.
        XCTAssertEqual(state.openTasks(on: state.todayKey).map(\.title), [])
        XCTAssertEqual(state.doneTasks(on: yesterday).map(\.title), ["A"])
        XCTAssertEqual(state.doneTasks(on: state.todayKey).map(\.title), [],
                       "today has no done marks of its own")
    }

    func testStartOrPauseSkipsRetiredTasks() {
        let state = makeState()
        let a = state.addTask(title: "A", durationSeconds: 600, presetID: nil, overrides: [])
        let dayOne = state.todayKey
        state.setTaskDone(id: a.id, done: true)
        now = Calendar.current.date(byAdding: .day, value: 1, to: now)! // a was done on dayOne
        let dayTwo = state.todayKey
        XCTAssertNotEqual(dayTwo, dayOne)
        XCTAssertFalse(state.openTasks(on: dayTwo).contains { $0.id == a.id }, "a was done on a past day")
        let b = state.addTask(title: "B", durationSeconds: 600, presetID: nil, overrides: [])
        state.startOrPause()
        XCTAssertEqual(state.phase, .work)
        XCTAssertEqual(state.activeTaskID, b.id, "must not start the retired task a")
    }

    func testRepeatOfRepeatingTaskKeepsRepeating() {
        let state = makeState()
        let repeatable = state.addTask(title: "Standup", durationSeconds: 600, presetID: nil, overrides: [], repeatDaily: true)
        let copy = state.repeatTask(id: repeatable.id)
        XCTAssertEqual(copy?.repeatDaily, true, "the re-run copy keeps repeating")
        XCTAssertEqual(copy?.title, "Standup")
    }

    func testDayKeyLabels() {
        XCTAssertEqual(DayKey.label(for: "2026-09-03", today: "2026-09-03"), "Today")
        XCTAssertEqual(DayKey.label(for: "2026-09-02", today: "2026-09-03"), "Yesterday")
        XCTAssertEqual(DayKey.label(for: "2026-09-04", today: "2026-09-03"), "Tomorrow")
        XCTAssertEqual(DayKey.label(for: "2026-08-31", today: "2026-09-03"), "Mon 31 Aug")
        XCTAssertEqual(DayKey.key(byAdding: 1, to: "2026-08-31"), "2026-09-01")
        XCTAssertNil(DayKey.date(from: "yesterday"))
    }

    // MARK: - Sorting

    func testSortByCreatedOldestFirst() {
        let state = makeState()
        // Default sort is manual; switch to created.
        var settings = state.settings
        settings.taskSort = .created
        state.updateSettings(settings)

        let a = state.addTask(title: "A", durationSeconds: 600, presetID: nil, overrides: [])
        now = now.addingTimeInterval(60)
        let b = state.addTask(title: "B", durationSeconds: 600, presetID: nil, overrides: [])
        now = now.addingTimeInterval(60)
        let c = state.addTask(title: "C", durationSeconds: 600, presetID: nil, overrides: [])

        // Manual order is insertion order.
        let manual = state.openTasks(on: state.todayKey)
        XCTAssertEqual(manual.map(\.title), ["A", "B", "C"])

        // Created sort: oldest first (same as insertion here).
        let sorted = state.sortedOpen(manual, for: state.settings.taskSort)
        XCTAssertEqual(sorted.map(\.title), ["A", "B", "C"])

        // Add a brand-new task: it sorts to the end under created.
        now = now.addingTimeInterval(120)
        let d = state.addTask(title: "D", durationSeconds: 600, presetID: nil, overrides: [])
        let sortedWithD = state.sortedOpen(state.openTasks(on: state.todayKey), for: state.settings.taskSort)
        XCTAssertEqual(sortedWithD.map(\.title), ["A", "B", "C", "D"])
        _ = a; _ = b; _ = c; _ = d
    }

    func testSortByPriority() {
        let state = makeState()
        var settings = state.settings
        settings.taskSort = .priority
        state.updateSettings(settings)

        _ = state.addTask(title: "Low", durationSeconds: 600, presetID: nil, overrides: [], priority: 3)
        _ = state.addTask(title: "High", durationSeconds: 600, presetID: nil, overrides: [], priority: 1)
        _ = state.addTask(title: "Medium", durationSeconds: 600, presetID: nil, overrides: [], priority: 2)

        let open = state.openTasks(on: state.todayKey)
        let sorted = state.sortedOpen(open, for: state.settings.taskSort)
        XCTAssertEqual(sorted.map(\.title), ["High", "Medium", "Low"], "1 (high) first, then 2, then 3")
    }

    func testTaskSortPersistsAcrossReload() {
        let state = makeState()
        var settings = state.settings
        settings.taskSort = .priority
        state.updateSettings(settings)

        let reloaded = makeState()
        XCTAssertEqual(reloaded.settings.taskSort, .priority)
    }

    func testUncompletedTaskCarriesOverToNextDay() {
        let state = makeState()
        let a = state.addTask(title: "Pending", durationSeconds: 600, presetID: nil, overrides: [])
        let dayOne = state.todayKey
        XCTAssertEqual(state.openTasks(on: dayOne).map(\.title), ["Pending"])

        // Roll to the next day without checking it off.
        now = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let dayTwo = state.todayKey
        XCTAssertNotEqual(dayTwo, dayOne)
        XCTAssertEqual(state.openTasks(on: dayTwo).map(\.title), ["Pending"],
                       "an uncompleted task carries over to the next day")
        XCTAssertEqual(state.nextUpID(on: dayTwo), a.id)
    }
}
