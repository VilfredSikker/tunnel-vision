import Foundation
import Observation

/// Phase of the session state machine.
enum SessionPhase: Equatable, Sendable {
    case idle
    case work
    case paused
    case breakTime
}

/// Single source of truth: tasks, presets, settings, today's bookkeeping and
/// the session engine. Everything is persisted as one JSON file in
/// Application Support so it can be inspected or edited by hand.
@MainActor
@Observable
final class AppState {
    // MARK: Persisted data

    private(set) var tasks: [TaskItem] = []
    private(set) var presets: [Preset] = []
    private(set) var settings: Settings = .default
    private(set) var lastUsedPresetID: UUID?
    private(set) var todayCount: Int = 0
    private(set) var countDay: String = ""

    // MARK: Session engine state

    private(set) var phase: SessionPhase = .idle
    private(set) var activeTaskID: TaskItem.ID?
    private(set) var nextTaskID: TaskItem.ID?
    /// When the current work run ends (phase == .work).
    private var workEndsAt: Date?
    /// Remaining work seconds captured at pause time.
    private var pausedRemaining: TimeInterval?
    /// Total work seconds of the current run, for ring progress.
    private var workTotal: TimeInterval = 0
    /// When the break ends (phase == .breakTime).
    private var breakEndsAt: Date?

    // MARK: Machinery

    private let fileURL: URL
    private let clock: () -> Date
    private var tickTask: Task<Void, Never>?
    private let tickInterval: TimeInterval = 0.5

    /// - Parameters:
    ///   - fileURL: JSON archive location. Defaults to Application Support/Anchor/data.json.
    ///   - clock: injectable time source (tests advance it manually).
    ///   - autoTick: when false the loop is never started; call `tick()` by hand (tests).
    init(
        fileURL: URL? = nil,
        clock: @escaping () -> Date = { Date() },
        autoTick: Bool = true
    ) {
        let fallback = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
            .appendingPathComponent("Anchor", isDirectory: true)
            .appendingPathComponent("data.json")
        self.fileURL = fileURL ?? fallback
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

    var isActiveTaskDoneToday: Bool {
        guard let task = activeTask else { return false }
        return task.isDone(on: todayKey)
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

    // MARK: - Tasks

    @discardableResult
    func addTask(
        title: String,
        durationSeconds: TimeInterval,
        presetID: UUID?,
        overrides: [Rule]
    ) -> TaskItem {
        let task = TaskItem(
            title: title.trimmingCharacters(in: .whitespaces),
            durationSeconds: durationSeconds,
            presetID: presetID,
            overrides: overrides.filter(\.isComplete)
        )
        tasks.append(task)
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
    }

    func moveTask(id: TaskItem.ID, before targetID: TaskItem.ID?) {
        guard let from = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks.remove(at: from)
        if let targetID, let to = tasks.firstIndex(where: { $0.id == targetID }) {
            tasks.insert(task, at: to)
        } else {
            tasks.append(task)
        }
        persist()
    }

    func deleteTask(id: TaskItem.ID) {
        guard id != activeTaskID else { return }
        tasks.removeAll { $0.id == id }
        if nextTaskID == id { nextTaskID = nil }
        persist()
    }

    /// Check a task off (or uncheck it) for today. Checking off the running
    /// task ends the session the same way the Done button does.
    func setTaskDone(id: TaskItem.ID, done: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if done, id == activeTaskID, phase == .work || phase == .paused {
            completeWork(creditSession: true)
            return
        }
        tasks[index].setDone(done, on: todayKey)
        if phase == .breakTime {
            // The break banner's "next up" must stay accurate while the break
            // runs; recompute after any check-off during it. The completed
            // task is already marked done, so no id exclusion is needed.
            nextTaskID = tasks.first { !$0.isDone(on: todayKey) }?.id
        }
        persist()
    }

    func setTaskPreset(id: TaskItem.ID, presetID: UUID?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].presetID = presetID
        rememberPreset(presetID)
        persist()
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
            name: "\(source.name) Copy",
            isBuiltIn: false,
            mode: source.mode,
            rules: source.rules,
            urlsToOpen: source.urlsToOpen
        )
        presets.append(copy)
        persist()
        return copy
    }

    func renamePreset(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltIn else { return }
        presets[index].name = trimmed
        persist()
    }

    /// Built-ins can never be deleted.
    @discardableResult
    func deletePreset(id: UUID) -> Bool {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltIn else { return false }
        presets.remove(at: index)
        if lastUsedPresetID == id { lastUsedPresetID = nil }
        for taskIndex in tasks.indices where tasks[taskIndex].presetID == id {
            tasks[taskIndex].presetID = nil
        }
        persist()
        return true
    }

    func updatePreset(_ preset: Preset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var updated = preset
        updated.name = preset.name.trimmingCharacters(in: .whitespaces)
        updated.rules = preset.rules.filter(\.isComplete)
        presets[index] = updated
        persist()
    }

    // MARK: - Settings

    func updateSettings(_ new: Settings) {
        settings = new
        persist()
    }

    // MARK: - Session engine

    /// Start a timed run of the given task. Refused while a session runs
    /// (pause or end it first) and for tasks already done today (uncheck
    /// first); starting during a break skips the rest of it.
    func startTask(id: TaskItem.ID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        guard phase != .work, phase != .paused else { return }
        guard !task.isDone(on: todayKey) else { return }
        if phase == .breakTime {
            breakEndsAt = nil
        }
        activeTaskID = task.id
        nextTaskID = nil
        workTotal = max(1, task.durationSeconds)
        workEndsAt = clock().addingTimeInterval(workTotal)
        phase = .work
        rememberPreset(task.presetID)
        persist()
    }

    func pause() {
        guard phase == .work, let endsAt = workEndsAt else { return }
        pausedRemaining = max(0, endsAt.timeIntervalSince(clock()))
        phase = .paused
        persist()
    }

    func resume() {
        guard phase == .paused, let remaining = pausedRemaining else { return }
        workEndsAt = clock().addingTimeInterval(remaining)
        phase = .work
        persist()
    }

    func togglePause() {
        switch phase {
        case .work: pause()
        case .paused: resume()
        default: break
        }
    }

    /// Early stop: ends the session immediately, no break, no credit.
    func stopNow() {
        guard phase == .work || phase == .paused else { return }
        phase = .idle
        clearRun()
        persist()
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
        persist()
    }

    /// Backstop used by the tick loop; tests call it directly with a fake clock.
    func tick() {
        normalizeDay()
        switch phase {
        case .work:
            if let endsAt = workEndsAt, clock() >= endsAt {
                completeWork(creditSession: true)
            }
        case .breakTime:
            if let endsAt = breakEndsAt, clock() >= endsAt {
                phase = .idle
                nextTaskID = nil
                persist()
                if settings.soundOn {
                    SoundPlayer.breakEnd()
                }
            }
        case .idle, .paused:
            break
        }
    }

    // MARK: - Session internals

    private func completeWork(creditSession: Bool) {
        if creditSession {
            todayCount += 1
        }
        if let id = activeTaskID, let index = tasks.firstIndex(where: { $0.id == id }),
           creditSession {
            tasks[index].setDone(true, on: todayKey)
        }
        // The completed task is now done for today, so the next "up" is simply
        // the first task that is still not done.
        nextTaskID = tasks.first { !$0.isDone(on: todayKey) }?.id
        phase = .breakTime
        breakEndsAt = clock().addingTimeInterval(max(1, settings.breakSeconds))
        clearRun()
        persist()
        if settings.soundOn {
            SoundPlayer.sessionEnd()
        }
    }

    private func clearRun() {
        activeTaskID = nil
        workEndsAt = nil
        pausedRemaining = nil
        workTotal = 0
    }

    private func rememberPreset(_ id: UUID?) {
        if let id, presets.contains(where: { $0.id == id }) {
            lastUsedPresetID = id
        }
    }

    /// The preset an Add-task sheet should be pre-filled with.
    var defaultPresetID: UUID? {
        if let lastUsedPresetID, presets.contains(where: { $0.id == lastUsedPresetID }) {
            return lastUsedPresetID
        }
        return codingPresetID
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
            normalizeDay()
            ensureBuiltins()
            return
        }
        // Fresh install, or the archive failed to read/decode. Never silently
        // overwrite a damaged archive: quarantine it first so nothing is lost.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let stamp = ISO8601DateFormatter().string(from: clock())
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("data.json.corrupt-\(stamp)")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                NSLog("Anchor: archive at %@ could not be read — moved to %@ and reseeded.", fileURL.path, backup.path)
            } catch {
                NSLog("Anchor: archive at %@ could not be read and could not be quarantined: %@", fileURL.path, String(describing: error))
            }
        }
        presets = BuiltinPresets.all()
        settings = .default
        lastUsedPresetID = codingPresetID
        todayCount = 0
        countDay = todayKey
        persist()
    }

    /// Built-ins are re-created if missing (e.g. archive from an older build).
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
                lastUsedPresetID: lastUsedPresetID
            )
            let data = try encoder.encode(archive)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Anchor: failed to persist state: \(error)")
        }
    }
}
