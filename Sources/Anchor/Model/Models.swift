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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .app: "App"
        case .window: "Window"
        case .url: "URL"
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
        let bundle = bundleID.trimmingCharacters(in: .whitespaces)
        guard !bundle.isEmpty else { return false }
        switch scope {
        case .app: return true
        case .window, .url:
            return !pattern.trimmingCharacters(in: .whitespaces).isEmpty
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

    init(
        id: UUID = UUID(),
        title: String,
        durationSeconds: TimeInterval,
        presetID: UUID? = nil,
        overrides: [Rule] = [],
        doneDays: [String] = []
    ) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds
        self.presetID = presetID
        self.overrides = overrides
        self.doneDays = doneDays
    }

    func isDone(on day: String) -> Bool {
        doneDays.contains(day)
    }

    mutating func setDone(_ done: Bool, on day: String) {
        if done {
            if !doneDays.contains(day) { doneDays.append(day) }
        } else {
            doneDays.removeAll { $0 == day }
        }
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
    /// Small always-on-top countdown while a session or break runs.
    var showCountdownWindow: Bool = true

    static let `default` = Settings()

    enum CodingKeys: String, CodingKey {
        case workSeconds, breakSeconds, strictMode, defaultMode, soundOn, toggleHotKey, showCountdownWindow
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
        showCountdownWindow = try container.decodeIfPresent(Bool.self, forKey: .showCountdownWindow) ?? base.showCountdownWindow
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

    static let currentVersion = 1
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
}
