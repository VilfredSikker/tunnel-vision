import Foundation
import Observation
import os
import TunnelVisionControlKit

/// Phase of the session state machine.
enum SessionPhase: Equatable, Sendable {
    case idle
    case work
    case paused
    case breakTime
}

/// A phase change the timer made on its own, which the app announces with a
/// popup that stays until dismissed. Changes the user makes (skip, stop,
/// done) are not announced: they already know.
enum PhaseAlert: Equatable, Sendable {
    /// Work time ran out; the break has begun.
    case workEnded(taskTitle: String, breakSeconds: TimeInterval)
    /// The break ran out; nothing is locked until the next start. The next
    /// task is fixed here so the popup starts the task it names, even if
    /// the list changes while it is up.
    case breakEnded(nextTaskID: UUID?, nextTaskTitle: String?)
}

/// Receives session-lock changes so the app enforcer can react without the
/// model depending on AppKit.
@MainActor
protocol LockListener: AnyObject {
    func lockStateChanged(active: Bool, rules: [Rule], mode: Mode)
}

/// Single source of truth: tasks, presets, settings, today's bookkeeping and
/// the session engine. Everything is persisted as one JSON file in
/// Application Support so it can be inspected or edited by hand.
@MainActor
@Observable
final class AppState {
    private static let log = Logger(subsystem: "com.tunnelvision.timer", category: "engine")

    /// App-enforcement hook. Weak: the enforcer outlives the model in the
    /// app, and tests never set it.
    weak var lockListener: LockListener?

    /// Opens a starting task's preset URLs; the app sets it to NSWorkspace.
    var urlOpener: (([URL]) -> Void)?

    /// A session started; the app confirms what is now locked.
    var onSessionStarted: ((TaskItem) -> Void)?

    /// A pause used up the session's pause budget and it resumed by itself.
    var onPauseLimitReached: (() -> Void)?

    /// What the running task locks to, or nil for an open session (no
    /// preset and no rules of its own): the same decision the lock makes.
    var activeLock: (rules: [Rule], mode: Mode)? {
        guard phase == .work, let task = activeTask else { return nil }
        if task.presetID != nil {
            return (effectiveRules(for: task), activePreset?.mode ?? settings.defaultMode)
        }
        guard !task.overrides.isEmpty else { return nil }
        return (effectiveRules(for: task), settings.defaultMode)
    }
    // MARK: Persisted data

    private(set) var tasks: [TaskItem] = []
    private(set) var presets: [Preset] = []
    private(set) var settings: Settings = .default
    private(set) var lastUsedPresetID: UUID?
    private(set) var todayCount: Int = 0
    private(set) var countDay: String = ""
    /// Plants of today's ended sessions, each as far as it got.
    private(set) var todayGarden: [GrowthRecord] = []

    // MARK: Session engine state

    private(set) var phase: SessionPhase = .idle
    private(set) var activeTaskID: TaskItem.ID?
    private(set) var nextTaskID: TaskItem.ID?
    /// The plant the running session grows; nil outside work and pause.
    private(set) var growth: GrowthPlan?

    /// The timer's last phase change, until the user dismisses it or starts
    /// something. Never persisted.
    private(set) var phaseAlert: PhaseAlert?

    func dismissPhaseAlert() {
        phaseAlert = nil
    }

    /// Enforcement layers not working as configured, by layer (e.g. window
    /// rules without Accessibility). Shown in the session header so a lock
    /// that silently weakened does not pass for a real one.
    private(set) var lockWarnings: [String: String] = [:]

    func setLockWarning(_ message: String?, layer: String) {
        if lockWarnings[layer] != message {
            lockWarnings[layer] = message
        }
    }

    /// The warnings in a stable order.
    var lockWarningMessages: [String] {
        lockWarnings.keys.sorted().compactMap { lockWarnings[$0] }
    }

    // MARK: UI requests

    /// Set by the menu bar quick action; the main panel opens the new-task
    /// sheet when it sees it and clears it. Never persisted.
    private(set) var pendingNewTask = false

    func requestNewTask() {
        pendingNewTask = true
    }

    func clearNewTaskRequest() {
        pendingNewTask = false
    }
    /// When the current work run ends (phase == .work).
    private var workEndsAt: Date?
    /// Remaining work seconds captured at pause time.
    private var pausedRemaining: TimeInterval?
    /// When the current pause began.
    private var pausedAt: Date?
    /// Pause time this session has used, the running pause not counted.
    private var pauseUsed: TimeInterval = 0
    /// Total work seconds of the current run, for ring progress. Grows when
    /// the session is extended.
    private var workTotal: TimeInterval = 0
    /// Growth re-anchors on every extension so the plant never shrinks: from
    /// this checkpoint it grows from the base progress to 1 over the time left.
    private var growthBaseProgress: Double = 0
    private var growthBaseElapsed: TimeInterval = 0
    /// When the break ends (phase == .breakTime).
    private var breakEndsAt: Date?

    // MARK: Machinery

    private let fileURL: URL
    private let clock: () -> Date
    private var tickTask: Task<Void, Never>?
    private let tickInterval: TimeInterval = 0.5
    private var tickCount = 0

    /// - Parameters:
    ///   - fileURL: JSON archive location. Defaults to Application Support/TunnelVision/data.json.
    ///   - clock: injectable time source (tests advance it manually).
    ///   - autoTick: when false the loop is never started; call `tick()` by hand (tests).
    init(
        fileURL: URL? = nil,
        clock: @escaping () -> Date = { Date() },
        autoTick: Bool = true
    ) {
        // Every Tunnel Vision installation on this machine shares this file.
        // Renaming the support directory orphans existing data.
        self.fileURL = fileURL ?? AppIdentity.supportDirectory.appendingPathComponent("data.json")
        self.clock = clock
        loadOrSeed()
        if autoTick {
            startLoop()
        }
    }

    // MARK: - Derived state

    var activeTask: TaskItem? {
        guard let id = activeTaskID else { return nil }
        return tasks.first { $0.id == id }
    }

    var activePreset: Preset? {
        guard let id = activeTask?.presetID else { return nil }
        return presets.first { $0.id == id }
    }

    var nextTask: TaskItem? {
        guard let id = nextTaskID else { return nil }
        return tasks.first { $0.id == id }
    }

    var todayKey: String {
        DayKey.key(for: clock())
    }

    /// Complete rule set a task runs with: preset rules plus task overrides.
    func effectiveRules(for task: TaskItem) -> [Rule] {
        var rules: [Rule] = []
        if let presetID = task.presetID, let preset = presets.first(where: { $0.id == presetID }) {
            rules += preset.rules
        }
        rules += task.overrides
        return rules
    }

    // MARK: Remaining time (reads the clock, so the menu bar label can be
    // refreshed independently of the tick loop)

    var remainingSeconds: Int? {
        switch phase {
        case .idle:
            return nil
        case .work:
            guard let endsAt = workEndsAt else { return nil }
            return max(0, Int(ceil(endsAt.timeIntervalSince(clock()))))
        case .paused:
            guard let remaining = pausedRemaining else { return nil }
            return max(0, Int(ceil(remaining)))
        case .breakTime:
            guard let endsAt = breakEndsAt else { return nil }
            return max(0, Int(ceil(endsAt.timeIntervalSince(clock()))))
        }
    }

    /// 0...1 elapsed fraction of the current work run (for the progress ring).
    var workElapsedFraction: Double {
        guard workTotal > 0 else { return 0 }
        switch phase {
        case .work:
            guard let endsAt = workEndsAt else { return 0 }
            let remaining = max(0, endsAt.timeIntervalSince(clock()))
            return min(1, 1 - remaining / workTotal)
        case .paused:
            guard let remaining = pausedRemaining else { return 0 }
            return min(1, 1 - remaining / workTotal)
        case .idle, .breakTime:
            return 0
        }
    }

    /// Seconds of the current work run that have passed.
    var workElapsedSeconds: TimeInterval {
        guard workTotal > 0 else { return 0 }
        switch phase {
        case .work:
            guard let endsAt = workEndsAt else { return 0 }
            return min(workTotal, workTotal - max(0, endsAt.timeIntervalSince(clock())))
        case .paused:
            guard let remaining = pausedRemaining else { return 0 }
            return min(workTotal, workTotal - remaining)
        case .idle, .breakTime:
            return 0
        }
    }

    /// 0...1 of the session's plant that has grown. Follows elapsed time, and
    /// after an extension slows down so it still finishes with the timer
    /// instead of shrinking when the total grows.
    var growthProgress: Double {
        guard phase == .work || phase == .paused else { return 0 }
        let span = workTotal - growthBaseElapsed
        guard span > 0 else { return growthBaseProgress }
        let fraction = (workElapsedSeconds - growthBaseElapsed) / span
        let grown = growthBaseProgress + (1 - growthBaseProgress) * fraction
        return min(1, max(growthBaseProgress, grown))
    }

    // MARK: - Tasks

    @discardableResult
    func addTask(
        title: String,
        durationSeconds: TimeInterval,
        presetID: UUID?,
        overrides: [Rule],
        repeatDaily: Bool = false,
        priority: Int = 2
    ) -> TaskItem {
        let task = TaskItem(
            title: title.trimmingCharacters(in: .whitespaces),
            durationSeconds: durationSeconds,
            presetID: presetID,
            overrides: overrides.filter(\.isComplete),
            repeatDaily: repeatDaily,
            priority: min(3, max(1, priority)),
            createdDate: clock()
        )
        tasks.append(task)
        if phase == .breakTime {
            // A task added during a break can become the new "next up" (e.g.
            // when everything else was already done).
            recomputeNextTask()
        }
        rememberPreset(presetID)
        persist()
        return task
    }

    func updateTask(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var updated = task
        updated.title = task.title.trimmingCharacters(in: .whitespaces)
        updated.overrides = task.overrides.filter(\.isComplete)
        tasks[index] = updated
        rememberPreset(task.presetID)
        persist()
        if updated.id == activeTaskID, phase == .work || phase == .paused {
            notifyLockChange()
        }
    }

    /// Moves `id` to sit directly before `targetID` (or to the end when
    /// targetID is nil). The running task never moves and no other task may
    /// be pushed across it; everything else is free to reorder.
    func moveTask(id: TaskItem.ID, before targetID: TaskItem.ID?) {
        guard id != activeTaskID else { return }
        guard let from = tasks.firstIndex(where: { $0.id == id }) else { return }
        // A task cannot jump over the running one: that would change which
        // task the enforcer locks to.
        if let activeIndex = tasks.firstIndex(where: { $0.id == activeTaskID }) {
            let beforeIndex = targetID.flatMap { t in tasks.firstIndex(where: { $0.id == t }) } ?? tasks.endIndex
            if (from < activeIndex && beforeIndex > activeIndex) || (from > activeIndex && beforeIndex < activeIndex) {
                return
            }
        }
        let task = tasks.remove(at: from)
        if let targetID, let to = tasks.firstIndex(where: { $0.id == targetID }) {
            tasks.insert(task, at: to)
        } else {
            tasks.append(task)
        }
        if phase == .breakTime {
            recomputeNextTask()
        }
        persist()
    }

    func deleteTask(id: TaskItem.ID) {
        guard id != activeTaskID else { return }
        tasks.removeAll { $0.id == id }
        if phase == .breakTime {
            // The deleted task may have been the banner's "next up".
            recomputeNextTask()
        } else if nextTaskID == id {
            nextTaskID = nil
        }
        persist()
    }

    /// Check a task off (or uncheck it) for a day, today unless given.
    /// Checking off the running task for today ends the session the same
    /// way the Done button does.
    func setTaskDone(id: TaskItem.ID, done: Bool, on day: String? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let day = day ?? todayKey
        if done, day == todayKey, id == activeTaskID, phase == .work || phase == .paused {
            completeWork(creditSession: true)
            return
        }
        tasks[index].setDone(done, on: day, at: clock())
        if phase == .breakTime, day == todayKey {
            // The break banner's "next up" must stay accurate while the break
            // runs; recompute after any check-off during it.
            recomputeNextTask()
        }
        persist()
    }

    /// Tasks still offered on the day: not done, and not retired. A done
    /// one-off is retired from the day after its check-off; a repeating task
    /// is never retired, so it stays on the list even when checked off today.
    func openTasks(on day: String) -> [TaskItem] {
        tasks.filter { task in
            if task.isDone(on: day) {
                return task.repeatDaily
            }
            return !task.isRetired(by: day)
        }
    }

    /// Applies a sort to a list of open tasks. Done tasks stay
    /// most-recent-first and should not be passed through here.
    func sortedOpen(_ tasks: [TaskItem], for sort: TaskSort) -> [TaskItem] {
        switch sort {
        case .manual:
            return tasks
        case .created:
            return tasks.sorted { $0.createdDate < $1.createdDate }
        case .priority:
            return tasks.sorted { $0.priority < $1.priority }
        }
    }

    /// Tasks checked off on the day, most recent first; ones without a
    /// recorded time (older archives) keep list order after them.
    func doneTasks(on day: String) -> [TaskItem] {
        tasks.enumerated()
            .filter { $0.element.isDone(on: day) }
            .sorted { lhs, rhs in
                switch (lhs.element.doneTime(on: day), rhs.element.doneTime(on: day)) {
                case let (l?, r?): return l > r
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// The first task still due on the day: the one that starts on a shortcut
    /// or appears on the break banner. A one-off done on the day is spent; a
    /// repeating one is due again every day, including one already checked off.
    func nextUpID(on day: String) -> TaskItem.ID? {
        tasks.first { task in
            task.isDone(on: day) ? task.repeatDaily : !task.isRetired(by: day)
        }?.id
    }

    /// Puts the given tasks first, in that order; everything else follows in
    /// its current order. Unknown ids are ignored.
    func reorderTasks(ids: [TaskItem.ID]) {
        var picked: [TaskItem] = []
        for id in ids {
            guard let task = tasks.first(where: { $0.id == id }), !picked.contains(where: { $0.id == id }) else { continue }
            picked.append(task)
        }
        guard !picked.isEmpty else { return }
        let rest = tasks.filter { task in !picked.contains { $0.id == task.id } }
        tasks = picked + rest
        if phase == .breakTime {
            recomputeNextTask()
        }
        persist()
    }

    /// Points a task at a preset, or removes the preset. Removing it (nil)
    /// keeps the allowlist: the previous preset's rules move into the task's
    /// own overrides, so the task keeps locking the same apps instead of
    /// silently opening up.
    func setTaskPreset(id: TaskItem.ID, presetID: UUID?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let previous = tasks[index].presetID.flatMap { pid in presets.first { $0.id == pid } }
        if presetID == nil, let previous {
            for rule in previous.rules where !tasks[index].overrides.contains(where: { $0 == rule }) {
                tasks[index].overrides.append(rule)
            }
        }
        tasks[index].presetID = presetID
        rememberPreset(presetID)
        persist()
        if id == activeTaskID, phase == .work || phase == .paused {
            notifyLockChange()
        }
    }

    // MARK: - Presets

    var builtinPresetID: UUID? {
        presets.first { $0.isBuiltIn }?.id
    }

    var codingPresetID: UUID? {
        presets.first { $0.name == "Coding" }?.id
    }

    func preset(named name: String) -> Preset? {
        presets.first { $0.name == name }
    }

    @discardableResult
    func addPreset(name: String, mode: Mode = .dark) -> Preset {
        let preset = Preset(name: name, mode: mode)
        presets.append(preset)
        persist()
        return preset
    }

    @discardableResult
    func duplicatePreset(id: UUID) -> Preset? {
        guard let source = presets.first(where: { $0.id == id }) else { return nil }
        let copy = Preset(
            name: uniquePresetName(basedOn: "\(source.name) Copy"),
            isBuiltIn: false,
            mode: source.mode,
            rules: source.rules,
            urlsToOpen: source.urlsToOpen
        )
        presets.append(copy)
        persist()
        return copy
    }

    /// A preset name that is not taken: the base when free, else "base 2",
    /// "base 3"…, so two presets never share a name.
    func uniquePresetName(basedOn base: String) -> String {
        let existing = Set(presets.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func renamePreset(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltIn else { return }
        presets[index].name = trimmed
        persist()
    }

    /// Deletes a user preset. Built-ins can be duplicated and edited, never
    /// deleted (DESIGN_BRIEF §4). Tasks that referenced the preset keep
    /// their allowlist: its rules move into the task's own overrides.
    @discardableResult
    func deletePreset(id: UUID) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == id }), !presets[index].isBuiltIn else { return false }
        let removed = presets.remove(at: index)
        if lastUsedPresetID == id { lastUsedPresetID = nil }
        let touchedActiveTask = (phase == .work || phase == .paused) && activeTask?.presetID == id
        for taskIndex in tasks.indices where tasks[taskIndex].presetID == id {
            tasks[taskIndex].presetID = nil
            for rule in removed.rules where !tasks[taskIndex].overrides.contains(where: { $0 == rule }) {
                tasks[taskIndex].overrides.append(rule)
            }
        }
        persist()
        if touchedActiveTask {
            // The running session lost its preset → its own allowlist applies.
            notifyLockChange()
        }
        return true
    }

    func updatePreset(_ preset: Preset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = preset
        updated.name = preset.name.trimmingCharacters(in: .whitespaces)
        updated.rules = preset.rules.filter(\.isComplete)
        updated.urlsToOpen = preset.urlsToOpen
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        presets[index] = updated
        persist()
        // The running session's allowlist may have changed (rules or mode).
        if (phase == .work || phase == .paused), activeTask?.presetID == preset.id {
            notifyLockChange()
        }
    }

    // MARK: - Settings

    func updateSettings(_ new: Settings) {
        settings = new
        persist()
    }

    // MARK: - Session engine

    /// Start a timed run of the given task. Refused while a session runs
    /// (pause or end it first); starting during a break skips the rest of
    /// it. A task already done today can be repeated: it stays checked off
    /// and each completed run counts as another session.
    func startTask(id: TaskItem.ID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        guard phase != .work, phase != .paused else { return }
        if phase == .breakTime {
            breakEndsAt = nil
        }
        activeTaskID = task.id
        nextTaskID = nil
        workTotal = max(1, task.durationSeconds)
        workEndsAt = clock().addingTimeInterval(workTotal)
        growth = GrowthPlan(startedAt: clock(), durationSeconds: workTotal)
        growthBaseProgress = 0
        growthBaseElapsed = 0
        pauseUsed = 0
        phase = .work
        phaseAlert = nil
        rememberPreset(task.presetID)
        persist()
        Self.log.info("session started: task=\(task.title, privacy: .public) duration=\(Int(self.workTotal))s mode=\(self.activePreset?.mode.displayName ?? "none", privacy: .public)")
        notifyLockChange()
        openPresetURLs(for: task)
        onSessionStarted?(task)
    }

    /// The preset's "URLs to open when a task starts" (DESIGN_BRIEF §4).
    /// Entries without a scheme are treated as https.
    private func openPresetURLs(for task: TaskItem) {
        guard let presetID = task.presetID, let preset = presets.first(where: { $0.id == presetID }) else { return }
        let urls = preset.urlsToOpen.compactMap(Self.openableURL)
        guard !urls.isEmpty else { return }
        urlOpener?(urls)
    }

    static func openableURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme, encodingInvalidCharacters: false),
              url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// A pause lifts the lock, so pausing is budgeted: this much in total
    /// per session. A pause that uses up the budget ends by itself, and
    /// pausing again straight away does not reset it.
    static let maxPauseSeconds: TimeInterval = 5 * 60

    /// Pause time left in this session, the running pause counted.
    var pauseSecondsLeft: TimeInterval {
        var used = pauseUsed
        if phase == .paused, let pausedAt {
            used += clock().timeIntervalSince(pausedAt)
        }
        return max(0, Self.maxPauseSeconds - used)
    }

    /// The running session can still be paused.
    var canPause: Bool {
        phase == .work && pauseSecondsLeft > 0
    }

    /// When the running pause ends by itself (phase == .paused).
    var pauseEndsAt: Date? {
        guard phase == .paused, let pausedAt else { return nil }
        return pausedAt.addingTimeInterval(Self.maxPauseSeconds - pauseUsed)
    }

    func pause() {
        guard canPause, let endsAt = workEndsAt else { return }
        pausedRemaining = max(0, endsAt.timeIntervalSince(clock()))
        pausedAt = clock()
        phase = .paused
        persist()
        Self.log.info("session paused: remaining=\(Int(self.pausedRemaining ?? 0))s")
        // Pausing lifts the app enforcement: the user is stepping away.
        notifyLockChange()
    }

    func resume() {
        guard phase == .paused, let remaining = pausedRemaining else { return }
        workEndsAt = clock().addingTimeInterval(remaining)
        if let pausedAt {
            pauseUsed = min(Self.maxPauseSeconds, pauseUsed + clock().timeIntervalSince(pausedAt))
        }
        pausedAt = nil
        phase = .work
        persist()
        Self.log.info("session resumed: remaining=\(Int(remaining))s")
        // Resuming re-applies the lock for the running task.
        notifyLockChange()
    }

    func togglePause() {
        switch phase {
        case .work: pause()
        case .paused: resume()
        default: break
        }
    }

    /// The first task still not done today: what the start shortcut starts
    /// and the picker shortcut edits when nothing runs.
    var nextUpTask: TaskItem? {
        guard let id = nextUpID(on: todayKey) else { return nil }
        return tasks.first { $0.id == id }
    }

    /// The task the picker shortcut edits: the running one, else next up.
    var taskAtHand: TaskItem? {
        activeTask ?? nextUpTask
    }

    /// The start/pause shortcut: pauses a running session, resumes a paused
    /// one, and otherwise starts the next task that is not done today (a
    /// break ends early for it). Nothing to start: nothing happens.
    func startOrPause() {
        switch phase {
        case .work:
            pause()
        case .paused:
            resume()
        case .idle, .breakTime:
            guard let next = nextUpTask else { return }
            startTask(id: next.id)
        }
    }

    /// Re-run of a task done today: a fresh copy with the same title,
    /// duration, allowlist and schedule (including repeat daily) goes right
    /// after it and starts. The original stays checked off with its own
    /// history. Refused while a session runs.
    @discardableResult
    func repeatTask(id: TaskItem.ID) -> TaskItem? {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        guard phase != .work, phase != .paused else { return nil }
        let copy = tasks[index].repeatedCopy()
        tasks.insert(copy, at: index + 1)
        persist()
        startTask(id: copy.id)
        return copy
    }

    /// Adds time to the running or paused session without touching the
    /// task's stored duration. The plant keeps growing from where it is and
    /// finishes with the new end.
    func extend(bySeconds seconds: TimeInterval) {
        guard phase == .work || phase == .paused, seconds > 0 else { return }
        // Tunnel Vision before the total changes, so growth continues seamlessly.
        growthBaseProgress = growthProgress
        growthBaseElapsed = workElapsedSeconds
        switch phase {
        case .work:
            workEndsAt = workEndsAt?.addingTimeInterval(seconds)
        case .paused:
            pausedRemaining = (pausedRemaining ?? 0) + seconds
        case .idle, .breakTime:
            return
        }
        workTotal += seconds
        persist()
        Self.log.info("session extended: +\(Int(seconds))s total=\(Int(self.workTotal))s")
    }

    /// Early stop: ends the session immediately, no break, no credit. The
    /// plant stays in the garden as far as it got.
    func stopNow() {
        guard phase == .work || phase == .paused else { return }
        recordGrowth()
        phase = .idle
        clearRun()
        persist()
        Self.log.info("session stopped early")
        notifyLockChange()
    }

    /// The "Done" action: checks the running task off and goes to the break.
    func finishTaskDone() {
        guard phase == .work || phase == .paused else { return }
        completeWork(creditSession: true)
    }

    /// Quick action "skip to break": end work now and take the break, without
    /// counting the session or checking the task off.
    func skipToBreak() {
        guard phase == .work || phase == .paused else { return }
        completeWork(creditSession: false)
    }

    func skipBreak() {
        guard phase == .breakTime else { return }
        phase = .idle
        nextTaskID = nil
        phaseAlert = nil
        persist()
        Self.log.info("break skipped")
        notifyLockChange()
    }

    /// Backstop used by the tick loop; tests call it directly with a fake clock.
    func tick() {
        normalizeDay()
        switch phase {
        case .work:
            if let endsAt = workEndsAt, clock() >= endsAt {
                completeWork(creditSession: true, announce: true)
            } else if tickCount % 30 == 0, let remaining = remainingSeconds {
                Self.log.info("heartbeat: remaining=\(remaining)s")
            }
        case .breakTime:
            if let endsAt = breakEndsAt, clock() >= endsAt {
                let next = nextTask
                phase = .idle
                nextTaskID = nil
                phaseAlert = .breakEnded(nextTaskID: next?.id, nextTaskTitle: next?.title)
                persist()
                if settings.soundOn {
                    SoundPlayer.breakEnd()
                }
                Self.log.info("break ended")
                notifyLockChange()
            }
        case .paused:
            if let pauseEndsAt, clock() >= pauseEndsAt {
                Self.log.info("pause limit reached")
                resume()
                onPauseLimitReached?()
            }
        case .idle:
            break
        }
        tickCount += 1
    }

    // MARK: - Session internals

    /// - Parameter announce: the timer ran out on its own, so the break
    ///   start is announced with a popup.
    private func completeWork(creditSession: Bool, announce: Bool = false) {
        let title = activeTask?.title ?? "Focus session"
        recordGrowth()
        if creditSession {
            todayCount += 1
        }
        if let id = activeTaskID, let index = tasks.firstIndex(where: { $0.id == id }),
           creditSession {
            tasks[index].setDone(true, on: todayKey, at: clock())
        }
        // "Next up" is always the first task still not done today: after a
        // credited end that excludes the finished task, and after an early
        // skip-to-break it points back at the abandoned task itself.
        recomputeNextTask()
        phase = .breakTime
        breakEndsAt = clock().addingTimeInterval(max(1, settings.breakSeconds))
        phaseAlert = announce ? .workEnded(taskTitle: title, breakSeconds: max(1, settings.breakSeconds)) : nil
        clearRun()
        persist()
        if settings.soundOn {
            SoundPlayer.sessionEnd()
        }
        Self.log.info("session ended: credit=\(creditSession) counted=\(self.todayCount)")
        notifyLockChange()
    }

    private func clearRun() {
        activeTaskID = nil
        workEndsAt = nil
        pausedRemaining = nil
        pausedAt = nil
        pauseUsed = 0
        workTotal = 0
        growth = nil
        growthBaseProgress = 0
        growthBaseElapsed = 0
    }

    /// Runs shorter than this are false starts and leave no plant behind.
    static let gardenMinimumSeconds: TimeInterval = 60

    /// The ending session joins today's garden as far as it grew. Runs
    /// before the phase changes, while elapsed time is still live.
    private func recordGrowth() {
        guard let growth else { return }
        guard workElapsedSeconds >= Self.gardenMinimumSeconds else { return }
        todayGarden.append(GrowthRecord(plan: growth, progress: growthProgress))
    }

    private func rememberPreset(_ id: UUID?) {
        if let id, presets.contains(where: { $0.id == id }) {
            lastUsedPresetID = id
        }
    }

    /// "Next up" is always the first task still due today. Called on
    /// session completion and whenever the list or check-offs change during a
    /// break (the banner must never point at a done or vanished task).
    private func recomputeNextTask() {
        nextTaskID = nextUpID(on: todayKey)
    }

    /// The preset an Add-task sheet should be pre-filled with.
    var defaultPresetID: UUID? {
        if let lastUsedPresetID, presets.contains(where: { $0.id == lastUsedPresetID }) {
            return lastUsedPresetID
        }
        return codingPresetID
    }

    // MARK: - Lock notifications (app enforcement)

    /// Tells the enforcer what the current session allows. Called after every
    /// transition that can change the lock state or its rule set.
    ///
    /// A running task with no preset and no overrides is an open session:
    /// nothing is blocked. Preset tasks lock to the preset's mode and rules;
    /// no-preset tasks with their own custom allowlist lock to those rules
    /// under the settings' default mode. A paused session lifts the lock:
    /// the user is stepping away and apps should not be blocked.
    func notifyLockChange() {
        guard let listener = lockListener else { return }
        if let lock = activeLock {
            listener.lockStateChanged(active: true, rules: lock.rules, mode: lock.mode)
        } else {
            // Idle, break, paused and open sessions all lift the lock.
            listener.lockStateChanged(active: false, rules: [], mode: settings.defaultMode)
        }
    }

    /// "Add to preset" from the blocked-app notice: appends a whole-app allow
    /// rule to the running task's preset (or its own overrides for custom
    /// tasks) so the app stops being blocked.
    func allowInActiveTask(bundleID: String) {
        allowInActiveTask(rule: Rule(bundleID: bundleID))
    }

    /// "Add to preset" for any block: the rule (whole app, window title or
    /// site) joins the running task's preset, or the task's own overrides for
    /// a custom task. A rule already there is not added twice.
    func allowInActiveTask(rule proposed: Rule) {
        guard let id = activeTaskID, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var rule = proposed
        rule.bundleID = proposed.bundleID.trimmingCharacters(in: .whitespaces)
        rule.pattern = proposed.pattern.trimmingCharacters(in: .whitespaces)
        guard rule.isComplete else { return }
        func sameRule(_ existing: Rule) -> Bool {
            existing.effect == .allow && existing.bundleID == rule.bundleID
                && existing.scope == rule.scope && existing.pattern.lowercased() == rule.pattern.lowercased()
        }
        if let presetID = tasks[index].presetID,
           let presetIndex = presets.firstIndex(where: { $0.id == presetID }) {
            guard !presets[presetIndex].rules.contains(where: sameRule) else { return }
            presets[presetIndex].rules.append(rule)
        } else {
            guard !tasks[index].overrides.contains(where: sameRule) else { return }
            tasks[index].overrides.append(rule)
        }
        persist()
        notifyLockChange()
    }

    /// The picker's result for an existing task. A preset saved from the
    /// picker becomes the task's preset; otherwise the task gets its own copy
    /// of the rules and drops the preset, as in the editor: what you see is
    /// what locks. A running task relocks at once.
    func applyPickedAllowlist(taskID: TaskItem.ID, rules: [Rule], savedPresetID: UUID?) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if let savedPresetID, presets.contains(where: { $0.id == savedPresetID }) {
            tasks[index].presetID = savedPresetID
            tasks[index].overrides = []
            rememberPreset(savedPresetID)
        } else {
            tasks[index].presetID = nil
            tasks[index].overrides = rules.filter(\.isComplete)
        }
        persist()
        if taskID == activeTaskID, phase == .work || phase == .paused {
            notifyLockChange()
        }
    }

    // MARK: - Tick loop

    private func startLoop() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    // MARK: - Persistence

    private func normalizeDay() {
        let key = todayKey
        if countDay != key {
            todayCount = 0
            todayGarden = []
            countDay = key
        }
    }

    private func loadOrSeed() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: fileURL),
           let archive = try? decoder.decode(Archive.self, from: data) {
            tasks = archive.tasks
            presets = archive.presets
            settings = archive.settings
            lastUsedPresetID = archive.lastUsedPresetID
            todayCount = archive.todayCount
            countDay = archive.countDay
            todayGarden = archive.garden
            normalizeDay()
            ensureBuiltins()
            return
        }
        // Fresh install, or the archive failed to read/decode. Never silently
        // overwrite a damaged archive: quarantine it first so nothing is lost.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let stamp = ISO8601DateFormatter().string(from: clock())
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("data.json.corrupt-\(stamp)-\(UUID().uuidString.prefix(8))")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                NSLog("Tunnel Vision: archive at %@ could not be read — moved to %@ and reseeded.", fileURL.path, backup.path)
            } catch {
                NSLog("Tunnel Vision: archive at %@ could not be read and could not be quarantined: %@", fileURL.path, String(describing: error))
            }
        }
        presets = BuiltinPresets.all()
        settings = .default
        lastUsedPresetID = codingPresetID
        todayCount = 0
        todayGarden = []
        countDay = todayKey
        persist()
    }

    /// Built-ins are re-created if missing: an archive from an older build,
    /// or one that still let built-ins be deleted.
    private func ensureBuiltins() {
        var changed = false
        for builtin in BuiltinPresets.all() where !presets.contains(where: { $0.name == builtin.name }) {
            presets.append(builtin)
            changed = true
        }
        if changed {
            persist()
        }
    }

    private func persist() {
        normalizeDay()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let archive = Archive(
                version: Archive.currentVersion,
                tasks: tasks,
                presets: presets,
                settings: settings,
                todayCount: todayCount,
                countDay: countDay,
                lastUsedPresetID: lastUsedPresetID,
                removedBuiltinNames: [],
                garden: todayGarden
            )
            let data = try encoder.encode(archive)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Tunnel Vision: failed to persist state: \(error)")
        }
    }
}
