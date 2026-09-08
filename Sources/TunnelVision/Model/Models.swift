import Foundation

// MARK: - Mode

/// What happens to apps that are not allowed during a session.
enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark
    case closed
    case frozen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dark: "Dark"
        case .closed: "Closed"
        case .frozen: "Frozen"
        }
    }

    var detail: String {
        switch self {
        case .dark: "Non-allowed apps are hidden"
        case .closed: "Non-allowed apps are quit"
        case .frozen: "Non-allowed apps pause in place"
        }
    }
}

// MARK: - Rule scope & effect

/// What a rule matches inside its target app.
enum RuleScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case app
    case window
    case url
    /// A herdr workspace inside the terminal, matched by label.
    case herdr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .app: "App"
        case .window: "Window"
        case .url: "URL"
        case .herdr: "Herdr workspace"
        }
    }
}

enum RuleEffect: String, Codable, Sendable {
    case allow
    case deny
}

/// One entry in an allowlist. Mirrors the feasibility study:
/// `Rule { bundleID, scope: .app | .window(titlePattern) | .url(pattern), effect }`.
struct Rule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var bundleID: String
    var scope: RuleScope
    /// Window title pattern (`.window`) or URL pattern (`.url`).
    var pattern: String
    var effect: RuleEffect

    init(
        id: UUID = UUID(),
        bundleID: String = "",
        scope: RuleScope = .app,
        pattern: String = "",
        effect: RuleEffect = .allow
    ) {
        self.id = id
        self.bundleID = bundleID
        self.scope = scope
        self.pattern = pattern
        self.effect = effect
    }

    /// The rule is complete enough to be meaningful.
    var isComplete: Bool {
        let hasBundle = !bundleID.trimmingCharacters(in: .whitespaces).isEmpty
        let hasPattern = !pattern.trimmingCharacters(in: .whitespaces).isEmpty
        switch scope {
        case .app: return hasBundle
        case .window, .url: return hasBundle && hasPattern
        case .herdr:
            // The bundle is the terminal hosting herdr, when known; the
            // label is what identifies the workspace.
            return hasPattern
        }
    }

    var summary: String {
        let target = bundleID.isEmpty ? "an app" : bundleID
        switch scope {
        case .app: return target
        case .window:
            let p = pattern.isEmpty ? "window title" : pattern
            return "\(target) · window “\(p)”"
        case .url:
            let p = pattern.isEmpty ? "URL" : pattern
            return "\(target) · \(p)"
        case .herdr:
            let p = pattern.isEmpty ? "workspace" : pattern
            return "herdr · “\(p)”"
        }
    }
}

// MARK: - Task sort order

/// How the day's open tasks are ordered.
enum TaskSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case created
    case priority

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .created: return "Created"
        case .priority: return "Priority"
        }
    }
}

// MARK: - Task

/// A thing to do. Carries a preset reference plus optional override rules.
struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    /// Total work duration in seconds.
    var durationSeconds: TimeInterval
    var presetID: UUID?
    /// Extra rules layered on top of the preset's rules.
    var overrides: [Rule]
    /// Day keys (yyyy-MM-dd) on which this task was checked off.
    var doneDays: [String]
    /// When it was checked off, per day key; orders the done list.
    var doneAt: [String: Date]
    /// Repeats every day until it is deleted: a checked-off repeating task
    /// stays on today's list. Plain tasks retire once checked off and only
    /// come back as a fresh copy via repeat.
    var repeatDaily: Bool
    /// 1 = high, 2 = medium, 3 = low.
    var priority: Int
    /// When the task was created; used for the "Created" sort.
    var createdDate: Date

    init(
        id: UUID = UUID(),
        title: String,
        durationSeconds: TimeInterval,
        presetID: UUID? = nil,
        overrides: [Rule] = [],
        doneDays: [String] = [],
        doneAt: [String: Date] = [:],
        repeatDaily: Bool = false,
        priority: Int = 2,
        createdDate: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds
        self.presetID = presetID
        self.overrides = overrides
        self.doneDays = doneDays
        self.doneAt = doneAt
        self.repeatDaily = repeatDaily
        self.priority = priority
        self.createdDate = createdDate
    }

    func isDone(on day: String) -> Bool {
        doneDays.contains(day)
    }

    /// When the task was checked off on that day, if the time was recorded.
    func doneTime(on day: String) -> Date? {
        doneAt[day]
    }

    /// A task is retired for `day` when it no longer belongs on that day's
    /// open list. A one-off retires from the day after its last check-off
    /// (checked-off today it sits under Done instead); repeating tasks come
    /// back each day, so they never retire.
    func isRetired(by day: String) -> Bool {
        guard !repeatDaily else { return false }
        guard let last = lastDoneDay else { return false }
        return last <= day
    }

    /// The latest day (yyyy-MM-dd) the task was checked off, nil when never.
    var lastDoneDay: String? {
        doneDays.max()
    }

    mutating func setDone(_ done: Bool, on day: String, at time: Date = Date()) {
        if done {
            if !doneDays.contains(day) { doneDays.append(day) }
            doneAt[day] = time
        } else {
            doneDays.removeAll { $0 == day }
            doneAt[day] = nil
        }
    }

    /// Copies the task's schedule (including repeatDaily) onto a fresh copy.
    /// Used by the re-run flow so a repeated one-off stays a one-off and a
    /// repeating task's copy keeps repeating.
    func repeatedCopy(id: UUID = UUID()) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            durationSeconds: durationSeconds,
            presetID: presetID,
            overrides: overrides,
            repeatDaily: repeatDaily,
            priority: priority,
            createdDate: createdDate
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, title, durationSeconds, presetID, overrides, doneDays, doneAt, repeatDaily, priority, createdDate
    }
}

extension TaskItem {
    /// `doneAt`, `repeatDaily`, `priority`, and `createdDate` arrived after
    /// v1; older archives keep decoding without them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        presetID = try container.decodeIfPresent(UUID.self, forKey: .presetID)
        overrides = try container.decode([Rule].self, forKey: .overrides)
        doneDays = try container.decode([String].self, forKey: .doneDays)
        doneAt = try container.decodeIfPresent([String: Date].self, forKey: .doneAt) ?? [:]
        repeatDaily = try container.decodeIfPresent(Bool.self, forKey: .repeatDaily) ?? false
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 2
        createdDate = try container.decodeIfPresent(Date.self, forKey: .createdDate) ?? Date.distantPast
    }
}

// MARK: - Preset

/// A named, reusable allowlist plus a default mode. Built-in or user made.
struct Preset: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var isBuiltIn: Bool
    var mode: Mode
    var rules: [Rule]
    /// URLs to open in the browser when a task with this preset starts.
    var urlsToOpen: [String]

    init(
        id: UUID = UUID(),
        name: String,
        isBuiltIn: Bool = false,
        mode: Mode = .dark,
        rules: [Rule] = [],
        urlsToOpen: [String] = []
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.mode = mode
        self.rules = rules
        self.urlsToOpen = urlsToOpen
    }
}

// MARK: - Countdown style

/// What the floating countdown shows besides the clock.
enum CountdownStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    /// A plant grows over the session above the clock.
    case garden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .garden: "Garden"
        }
    }
}

// MARK: - Settings

struct Settings: Codable, Equatable, Sendable {
    /// Default work duration in seconds (25 minutes).
    var workSeconds: TimeInterval = 25 * 60
    /// Default break duration in seconds (5 minutes).
    var breakSeconds: TimeInterval = 5 * 60
    /// Strict mode: ending a session early requires typing the task title.
    var strictMode: Bool = false
    /// Default mode applied to new presets.
    var defaultMode: Mode = .dark
    /// Play sounds at session and break end.
    var soundOn: Bool = true
    /// Global shortcut that opens or closes the panel. Nil: none.
    var toggleHotKey: HotKey?
    /// Global shortcut that opens the panel on the new-task sheet. Nil: none.
    var newTaskHotKey: HotKey?
    /// Global shortcut that starts the next task, or pauses and resumes the
    /// running one. Nil: none.
    var startPauseHotKey: HotKey?
    /// Global shortcut that opens the picker for the task at hand. Nil: none.
    var pickerHotKey: HotKey?
    /// Small always-on-top countdown while a session or break runs.
    var showCountdownWindow: Bool = true
    /// Whether that countdown grows a plant over the session.
    var countdownStyle: CountdownStyle = .garden
    /// Supported browsers the user does not want steered during a session.
    /// Every other supported browser is managed, newly installed ones included.
    var unmanagedBrowsers: [String] = []
    /// How the day's open tasks are ordered.
    var taskSort: TaskSort = .manual

    static let `default` = Settings()

    /// Every configured shortcut, by slot.
    var hotKeys: [HotKeyCenter.Slot: HotKey] {
        var keys: [HotKeyCenter.Slot: HotKey] = [:]
        keys[.togglePanel] = toggleHotKey
        keys[.newTask] = newTaskHotKey
        keys[.startPause] = startPauseHotKey
        keys[.openPicker] = pickerHotKey
        return keys
    }

    enum CodingKeys: String, CodingKey {
        case workSeconds, breakSeconds, strictMode, defaultMode, soundOn, toggleHotKey, newTaskHotKey, startPauseHotKey, pickerHotKey, showCountdownWindow, countdownStyle, unmanagedBrowsers, taskSort
    }
}

extension Settings {
    /// Every key is optional on read so archives written by an older build
    /// keep decoding (the synthesized decoder would reject them, and a
    /// rejected archive gets quarantined and reseeded).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = Settings()
        workSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .workSeconds) ?? base.workSeconds
        breakSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .breakSeconds) ?? base.breakSeconds
        strictMode = try container.decodeIfPresent(Bool.self, forKey: .strictMode) ?? base.strictMode
        defaultMode = try container.decodeIfPresent(Mode.self, forKey: .defaultMode) ?? base.defaultMode
        soundOn = try container.decodeIfPresent(Bool.self, forKey: .soundOn) ?? base.soundOn
        toggleHotKey = try container.decodeIfPresent(HotKey.self, forKey: .toggleHotKey)
        newTaskHotKey = try container.decodeIfPresent(HotKey.self, forKey: .newTaskHotKey)
        startPauseHotKey = try container.decodeIfPresent(HotKey.self, forKey: .startPauseHotKey)
        pickerHotKey = try container.decodeIfPresent(HotKey.self, forKey: .pickerHotKey)
        showCountdownWindow = try container.decodeIfPresent(Bool.self, forKey: .showCountdownWindow) ?? base.showCountdownWindow
        countdownStyle = try container.decodeIfPresent(CountdownStyle.self, forKey: .countdownStyle) ?? base.countdownStyle
        unmanagedBrowsers = try container.decodeIfPresent([String].self, forKey: .unmanagedBrowsers) ?? base.unmanagedBrowsers
        taskSort = try container.decodeIfPresent(TaskSort.self, forKey: .taskSort) ?? base.taskSort
    }
}

// MARK: - Hot key

/// A global keyboard shortcut, stored as a Carbon key code plus Carbon
/// modifier flags so it registers without translation. `keyLabel` is what
/// the key printed as when it was recorded (layouts differ); display only.
struct HotKey: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    // Carbon's cmdKey, shiftKey, optionKey, controlKey.
    static let command: UInt32 = 1 << 8
    static let shift: UInt32 = 1 << 9
    static let option: UInt32 = 1 << 11
    static let control: UInt32 = 1 << 12

    /// Modifiers in the system's canonical order (⌃⌥⇧⌘), then the key.
    var display: String {
        var text = ""
        if carbonModifiers & Self.control != 0 { text += "⌃" }
        if carbonModifiers & Self.option != 0 { text += "⌥" }
        if carbonModifiers & Self.shift != 0 { text += "⇧" }
        if carbonModifiers & Self.command != 0 { text += "⌘" }
        return text + keyLabel
    }
}

// MARK: - Persisted archive

struct Archive: Codable, Sendable {
    var version: Int
    var tasks: [TaskItem]
    var presets: [Preset]
    var settings: Settings
    /// Sessions completed today (reset when the day rolls over).
    var todayCount: Int
    /// Day key `todayCount` refers to.
    var countDay: String
    var lastUsedPresetID: UUID?
    /// Built-in presets the user deleted; they are not re-seeded on launch.
    var removedBuiltinNames: [String] = []
    /// Plants of the sessions that ended on `countDay`, in order.
    var garden: [GrowthRecord] = []

    static let currentVersion = 1

    enum CodingKeys: String, CodingKey {
        case version, tasks, presets, settings, todayCount, countDay, lastUsedPresetID, removedBuiltinNames, garden
    }
}

extension Archive {
    /// Keys added after v1 are optional on read so older archives keep
    /// decoding instead of being quarantined and reseeded.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        tasks = try container.decode([TaskItem].self, forKey: .tasks)
        presets = try container.decode([Preset].self, forKey: .presets)
        settings = try container.decode(Settings.self, forKey: .settings)
        todayCount = try container.decode(Int.self, forKey: .todayCount)
        countDay = try container.decode(String.self, forKey: .countDay)
        lastUsedPresetID = try container.decodeIfPresent(UUID.self, forKey: .lastUsedPresetID)
        removedBuiltinNames = try container.decodeIfPresent([String].self, forKey: .removedBuiltinNames) ?? []
        garden = try container.decodeIfPresent([GrowthRecord].self, forKey: .garden) ?? []
    }
}

// MARK: - Day keys

enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        formatter.date(from: key)
    }

    static func key(byAdding days: Int, to key: String) -> String? {
        guard let date = date(from: key),
              let shifted = formatter.calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return self.key(for: shifted)
    }

    /// "Today", "Yesterday", "Tomorrow", else a short weekday and date.
    static func label(for key: String, today: String) -> String {
        if key == today { return "Today" }
        if key == self.key(byAdding: -1, to: today) { return "Yesterday" }
        if key == self.key(byAdding: 1, to: today) { return "Tomorrow" }
        guard let date = date(from: key) else { return key }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = formatter.calendar
        f.dateFormat = "EEE d MMM"
        return f.string(from: date)
    }
}
