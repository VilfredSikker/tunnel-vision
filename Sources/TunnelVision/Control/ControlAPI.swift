import TunnelVisionControlKit
import AppKit
import Foundation

/// The control methods an agent can call, mapped onto the model. Params and
/// results use snake_case JSON; ids are UUID strings; days are yyyy-MM-dd.
@MainActor
final class ControlAPI {
    private let model: AppState

    init(model: AppState) {
        self.model = model
    }

    func handle(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "state.get":
            return ["state": stateJSON()]

        case "tasks.list":
            let day = try dayParam(params) ?? model.todayKey
            return ["day": day, "tasks": tasksJSON(day: day)]

        case "tasks.add":
            let title = try requiredString("title", in: params)
            let minutes = try minutesParam(params) ?? Int(model.settings.workSeconds / 60)
            let presetID = try presetIDParam(params["preset"])
            let rules = try rulesParam(params["rules"]) ?? []
            let repeatDaily = params["repeat_daily"] as? Bool ?? false
            let task = model.addTask(title: title, durationSeconds: TimeInterval(minutes * 60), presetID: presetID, overrides: rules, repeatDaily: repeatDaily)
            return ["task": taskJSON(task, day: model.todayKey)]

        case "tasks.update":
            var task = try taskParam(params)
            if let title = params["title"] as? String {
                guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ControlError.invalidParams("title is empty") }
                task.title = title
            }
            if let minutes = try minutesParam(params) {
                task.durationSeconds = TimeInterval(minutes * 60)
            }
            if params.keys.contains("preset") {
                task.presetID = try presetIDParam(params["preset"])
            }
            if let rules = try rulesParam(params["rules"]) {
                task.overrides = rules
            }
            if let repeatDaily = params["repeat_daily"] as? Bool {
                task.repeatDaily = repeatDaily
            }
            model.updateTask(task)
            return ["task": taskJSON(model.tasks.first { $0.id == task.id } ?? task, day: model.todayKey)]

        case "tasks.delete":
            let task = try taskParam(params)
            guard task.id != model.activeTaskID else { throw ControlError.refused("the running task cannot be deleted; stop the session first") }
            model.deleteTask(id: task.id)
            return ["deleted": task.id.uuidString]

        case "tasks.reorder":
            guard let raw = params["ids"] as? [String], !raw.isEmpty else { throw ControlError.invalidParams("ids is required") }
            let ids = try raw.map { text -> UUID in
                guard let id = UUID(uuidString: text) else { throw ControlError.invalidParams("not a task id: \(text)") }
                return id
            }
            model.reorderTasks(ids: ids)
            return ["tasks": tasksJSON(day: model.todayKey)]

        case "tasks.set_done":
            let task = try taskParam(params)
            let done = params["done"] as? Bool ?? true
            let day = try dayParam(params)
            model.setTaskDone(id: task.id, done: done, on: day)
            return ["task": taskJSON(model.tasks.first { $0.id == task.id } ?? task, day: day ?? model.todayKey)]

        case "presets.list":
            return ["presets": model.presets.map(presetJSON)]

        case "presets.create":
            let name = try requiredString("name", in: params)
            guard findPreset(name) == nil else { throw ControlError.refused("a preset named “\(name)” exists") }
            let mode = try modeParam(params["mode"]) ?? model.settings.defaultMode
            var preset = model.addPreset(name: name, mode: mode)
            preset.rules = try rulesParam(params["rules"]) ?? []
            preset.urlsToOpen = params["urls_to_open"] as? [String] ?? []
            model.updatePreset(preset)
            return ["preset": presetJSON(model.presets.first { $0.id == preset.id } ?? preset)]

        case "presets.update":
            var preset = try presetParam(params)
            if let name = params["name"] as? String, name != preset.name {
                guard !preset.isBuiltIn else { throw ControlError.refused("built-in presets keep their name; duplicate it instead") }
                guard findPreset(name) == nil else { throw ControlError.refused("a preset named “\(name)” exists") }
                preset.name = name
            }
            if let mode = try modeParam(params["mode"]) {
                preset.mode = mode
            }
            if let rules = try rulesParam(params["rules"]) {
                preset.rules = rules
            }
            if let urls = params["urls_to_open"] as? [String] {
                preset.urlsToOpen = urls
            }
            model.updatePreset(preset)
            return ["preset": presetJSON(model.presets.first { $0.id == preset.id } ?? preset)]

        case "presets.delete":
            let preset = try presetParam(params)
            model.deletePreset(id: preset.id)
            return ["deleted": preset.id.uuidString]

        case "session.start":
            let task = try taskParam(params)
            guard model.phase != .work, model.phase != .paused else {
                throw ControlError.refused("a session is already running; pause, stop or finish it first")
            }
            model.startTask(id: task.id)
            return ["state": stateJSON()]

        case "session.pause":
            guard model.phase == .work else { throw ControlError.refused("no running session to pause") }
            model.pause()
            return ["state": stateJSON()]

        case "session.resume":
            guard model.phase == .paused else { throw ControlError.refused("no paused session to resume") }
            model.resume()
            return ["state": stateJSON()]

        case "session.stop":
            guard model.phase == .work || model.phase == .paused else { throw ControlError.refused("no session to stop") }
            model.stopNow()
            return ["state": stateJSON()]

        case "session.done":
            guard model.phase == .work || model.phase == .paused else { throw ControlError.refused("no session to finish") }
            model.finishTaskDone()
            return ["state": stateJSON()]

        case "session.skip_break":
            guard model.phase == .breakTime else { throw ControlError.refused("not on a break") }
            model.skipBreak()
            return ["state": stateJSON()]

        case "session.extend":
            guard model.phase == .work || model.phase == .paused else { throw ControlError.refused("no session to extend") }
            guard let minutes = try minutesParam(params), minutes > 0 else { throw ControlError.invalidParams("minutes is required") }
            model.extend(bySeconds: TimeInterval(minutes * 60))
            return ["state": stateJSON()]

        case "apps.list":
            return ["apps": WindowCatalogue.onScreenApps().map { app in
                [
                    "name": app.name,
                    "bundle_id": app.bundleID,
                    "windows": app.windows.compactMap(\.title),
                ] as [String: Any]
            }]

        default:
            throw ControlError.unknownMethod(method)
        }
    }

    // MARK: Params

    private func requiredString(_ key: String, in params: [String: Any]) throws -> String {
        guard let value = (params[key] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            throw ControlError.invalidParams("\(key) is required")
        }
        return value
    }

    private func minutesParam(_ params: [String: Any]) throws -> Int? {
        let raw = params["duration_minutes"] ?? params["minutes"]
        guard let raw else { return nil }
        let minutes: Int?
        if let value = raw as? Int {
            minutes = value
        } else if let value = raw as? Double {
            // JSON can carry huge finite doubles (1e308); a plain `Int(value)`
            // traps on overflow, so only finite whole values in range survive.
            guard value.isFinite else { throw ControlError.invalidParams("minutes must be a finite number") }
            minutes = Int(exactly: value.rounded())
        } else if let text = raw as? String {
            minutes = Int(text)
        } else {
            minutes = nil
        }
        guard let minutes, (1...600).contains(minutes) else { throw ControlError.invalidParams("minutes must be between 1 and 600") }
        return minutes
    }

    private func dayParam(_ params: [String: Any]) throws -> String? {
        guard let day = params["day"] as? String, !day.isEmpty else { return nil }
        guard DayKey.date(from: day) != nil else { throw ControlError.invalidParams("day must be yyyy-MM-dd") }
        return day
    }

    private func taskParam(_ params: [String: Any]) throws -> TaskItem {
        let text = try requiredString("id", in: params)
        guard let id = UUID(uuidString: text), let task = model.tasks.first(where: { $0.id == id }) else {
            throw ControlError.notFound("no task with id \(text)")
        }
        return task
    }

    private func presetParam(_ params: [String: Any]) throws -> Preset {
        let text = try requiredString("preset", in: params)
        guard let preset = findPreset(text) else { throw ControlError.notFound("no preset named or with id “\(text)”") }
        return preset
    }

    /// Nil when absent, null or empty (no preset); else the preset must exist.
    private func presetIDParam(_ raw: Any?) throws -> UUID? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let text = raw as? String else { throw ControlError.invalidParams("preset must be a name or id") }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let preset = findPreset(trimmed) else { throw ControlError.notFound("no preset named or with id “\(trimmed)”") }
        return preset.id
    }

    private func findPreset(_ text: String) -> Preset? {
        if let id = UUID(uuidString: text), let preset = model.presets.first(where: { $0.id == id }) {
            return preset
        }
        return model.presets.first { $0.name.caseInsensitiveCompare(text) == .orderedSame }
    }

    private func modeParam(_ raw: Any?) throws -> Mode? {
        guard let raw else { return nil }
        guard let text = raw as? String, let mode = Mode(rawValue: text.lowercased()) else {
            throw ControlError.invalidParams("mode must be dark, closed or frozen")
        }
        return mode
    }

    private func rulesParam(_ raw: Any?) throws -> [Rule]? {
        guard let raw else { return nil }
        guard let list = raw as? [[String: Any]] else { throw ControlError.invalidParams("rules must be a list of objects") }
        return try list.map { entry in
            let scopeText = (entry["scope"] as? String)?.lowercased() ?? "app"
            guard let scope = RuleScope(rawValue: scopeText) else {
                throw ControlError.invalidParams("scope must be app, window, url or herdr")
            }
            let pattern = (entry["pattern"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            var bundleID = (entry["bundle_id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if bundleID.isEmpty, let app = entry["app"] as? String {
                bundleID = try AppResolver.bundleID(for: app)
            }
            let rule = Rule(bundleID: bundleID, scope: scope, pattern: pattern)
            guard rule.isComplete else {
                throw ControlError.invalidParams("incomplete rule: scope \(scope.rawValue) needs \(scope == .herdr ? "a pattern" : scope == .app ? "an app" : "an app and a pattern")")
            }
            return rule
        }
    }

    // MARK: JSON

    private func stateJSON() -> [String: Any] {
        var state: [String: Any] = [
            "phase": phaseName(model.phase),
            "today": model.todayKey,
            "sessions_today": model.todayCount,
        ]
        if let remaining = model.remainingSeconds {
            state["remaining_seconds"] = remaining
        }
        if let active = model.activeTask {
            state["active_task"] = taskJSON(active, day: model.todayKey)
        }
        // What starts next: the first task still not done today other than
        // the one already running. Retired one-offs do not count; when
        // everything is checked off, the first repeating task is the next up.
        if let activeID = model.activeTaskID {
            if let next = model.tasks.first(where: { task in
                guard task.id != activeID else { return false }
                return task.isDone(on: model.todayKey) ? task.repeatDaily : !task.isRetired(by: model.todayKey)
            }) {
                state["next_up"] = taskJSON(next, day: model.todayKey)
            }
        } else if let next = model.tasks.first(where: { task in
            task.isDone(on: model.todayKey) ? task.repeatDaily : !task.isRetired(by: model.todayKey)
        }) {
            state["next_up"] = taskJSON(next, day: model.todayKey)
        }
        return state
    }

    private func phaseName(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .work: "work"
        case .paused: "paused"
        case .breakTime: "break"
        }
    }

    private func tasksJSON(day: String) -> [[String: Any]] {
        model.tasks.enumerated().map { taskJSON($0.element, day: day, position: $0.offset) }
    }

    private func taskJSON(_ task: TaskItem, day: String, position: Int? = nil) -> [String: Any] {
        var json: [String: Any] = [
            "id": task.id.uuidString,
            "title": task.title,
            "duration_minutes": Int(task.durationSeconds / 60),
            "rules": task.overrides.map(ruleJSON),
            "effective_rules": model.effectiveRules(for: task).map(ruleJSON),
            "done": task.isDone(on: day),
            "repeat_daily": task.repeatDaily,
            "active": task.id == model.activeTaskID,
        ]
        if let presetID = task.presetID, let preset = model.presets.first(where: { $0.id == presetID }) {
            json["preset"] = ["id": preset.id.uuidString, "name": preset.name]
        } else {
            json["preset"] = NSNull()
        }
        if let time = task.doneTime(on: day) {
            json["done_at"] = ISO8601DateFormatter().string(from: time)
        }
        if let position {
            json["position"] = position
        }
        return json
    }

    private func presetJSON(_ preset: Preset) -> [String: Any] {
        [
            "id": preset.id.uuidString,
            "name": preset.name,
            "built_in": preset.isBuiltIn,
            "mode": preset.mode.rawValue,
            "rules": preset.rules.map(ruleJSON),
            "urls_to_open": preset.urlsToOpen,
        ]
    }

    private func ruleJSON(_ rule: Rule) -> [String: Any] {
        var json: [String: Any] = [
            "bundle_id": rule.bundleID,
            "scope": rule.scope.rawValue,
            "pattern": rule.pattern,
        ]
        if let name = AppCatalog.displayName(forBundleID: rule.bundleID) {
            json["app"] = name
        }
        return json
    }
}

/// App names to bundle ids, for rules written by an agent.
@MainActor
enum AppResolver {
    private static let applicationFolders = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    static func bundleID(for text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ControlError.invalidParams("app is empty") }
        // Something like com.apple.dt.Xcode is a bundle id already.
        if trimmed.contains("."), !trimmed.contains(" "), NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) != nil {
            return trimmed
        }
        if let running = AppCatalog.runningApps.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return running.bundleID
        }
        let wanted = trimmed.lowercased().hasSuffix(".app") ? trimmed.lowercased() : trimmed.lowercased() + ".app"
        for folder in applicationFolders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.lowercased() == wanted {
                if let bundle = Bundle(url: URL(fileURLWithPath: folder).appendingPathComponent(name))?.bundleIdentifier {
                    return bundle
                }
            }
        }
        if trimmed.contains("."), !trimmed.contains(" ") {
            // Not installed here, but a plausible bundle id: keep it as given.
            return trimmed
        }
        throw ControlError.invalidParams("unknown app “\(trimmed)”; pass its bundle id (tunnelvision_list_apps shows running ones)")
    }
}
