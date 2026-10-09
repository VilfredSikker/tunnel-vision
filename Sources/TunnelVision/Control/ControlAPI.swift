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

    /// The socket's entry point. Methods that depend on herdr ask it first
    /// (the agents list behind `assign_to`, the screen behind an answer);
    /// everything else is `handle`.
    func respond(method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "tasks.add", "tasks.update":
            if params["background"] != nil || params["assign_to"] != nil {
                await model.background.refreshAgents()
            }
        case "agents.list":
            await model.background.refreshAgents()
        case "approvals.answer":
            return try await answerApproval(params)
        default:
            break
        }
        return try handle(method: method, params: params)
    }

    /// Everything that needs no herdr round trip. herdr-backed methods
    /// read the last agents list here; `respond` refreshes it first.
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
            let priority = try priorityParam(params["priority"]) ?? 2
            let doneWhen = params["done_when"] as? String ?? ""
            let urls = params["urls_to_open"] as? [String] ?? []
            let goalID = try goalParam(params["goal"])?.id
            // `assign_to` alone makes a background task too.
            let wantsBackground = params["background"] as? Bool ?? (params["assign_to"] is String)
            let background = wantsBackground ? BackgroundInfo(assignee: try assigneeParam(params)) : nil
            let task = model.addTask(title: title, durationSeconds: TimeInterval(minutes * 60), presetID: presetID, overrides: rules, repeatDaily: repeatDaily, priority: priority, doneWhen: doneWhen, goalID: goalID, background: background, urlsToOpen: urls)
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
            if let priority = try priorityParam(params["priority"]) {
                task.priority = priority
            }
            if let doneWhen = params["done_when"] as? String {
                task.doneWhen = doneWhen
            }
            if let urls = params["urls_to_open"] as? [String] {
                task.urlsToOpen = urls
            }
            if params.keys.contains("goal") {
                task.goalID = try goalParam(params["goal"])?.id
            }
            if let flag = params["background"] as? Bool {
                if !flag {
                    task.background = nil
                } else if task.background == nil {
                    task.background = BackgroundInfo(assignee: try assigneeParam(params))
                }
            }
            if params["assign_to"] is String {
                // An empty value unassigns; the caller's pane is not implied here.
                let target = (params["assign_to"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let assignee = target.isEmpty ? nil : try assigneeParam(params)
                var info = task.background ?? BackgroundInfo()
                if info.assignee != assignee {
                    guard info.sentAt == nil else {
                        throw ControlError.refused("the task was already sent to its agent and stays with it")
                    }
                    info.assignee = assignee
                }
                task.background = info
            }
            model.updateTask(task)
            return ["task": taskJSON(model.tasks.first { $0.id == task.id } ?? task, day: model.todayKey)]

        case "tasks.duplicate":
            let task = try taskParam(params)
            guard let copy = model.duplicateTask(id: task.id) else { throw ControlError.invalidParams("unknown task") }
            return ["task": taskJSON(copy, day: model.todayKey)]

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

        case "history.list":
            let to = try dayParam(params, key: "to") ?? model.todayKey
            let from = try dayParam(params, key: "from") ?? DayKey.key(byAdding: -6, to: to) ?? to
            guard from <= to else { throw ControlError.invalidParams("from must not be after to") }
            guard let limit = DayKey.key(byAdding: 365, to: from), to <= limit else {
                throw ControlError.invalidParams("the range can span at most a year")
            }
            return historyJSON(from: from, to: to)

        case "goals.list":
            return ["goals": model.goals.map(goalJSON)]

        case "goals.add":
            let title = try requiredString("title", in: params)
            let priority = try priorityParam(params["priority"]) ?? 2
            let goal = model.addGoal(title: title, doneWhen: params["done_when"] as? String ?? "", priority: priority)
            return ["goal": goalJSON(goal)]

        case "goals.update":
            var goal = try goalParam(params["goal"], required: true)!
            if let title = params["title"] as? String {
                guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ControlError.invalidParams("title is empty") }
                goal.title = title
            }
            if let doneWhen = params["done_when"] as? String {
                goal.doneWhen = doneWhen
            }
            if let priority = try priorityParam(params["priority"]) {
                goal.priority = priority
            }
            model.updateGoal(goal)
            if let done = params["done"] as? Bool {
                model.setGoalDone(id: goal.id, done: done)
            }
            return ["goal": goalJSON(model.goal(id: goal.id) ?? goal)]

        case "goals.delete":
            let goal = try goalParam(params["goal"], required: true)!
            model.deleteGoal(id: goal.id)
            return ["deleted": goal.id.uuidString]

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
            guard model.deletePreset(id: preset.id) else {
                throw ControlError.refused("built-in presets can be duplicated or edited, not deleted")
            }
            return ["deleted": preset.id.uuidString]

        case "session.start":
            let task = try taskParam(params)
            guard !task.isBackground else {
                throw ControlError.refused("a background task goes to its agent and never runs in a focus session; start another task and it goes out with it")
            }
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
            // Strict mode's friction is typing the title by hand; an API
            // call would skip it.
            guard !model.settings.strictMode else {
                throw ControlError.refused("strict mode is on: end the session from Tunnel Vision itself")
            }
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
            return ["apps": WindowCatalogue.openApps().map { app in
                [
                    "name": app.name,
                    "bundle_id": app.bundleID,
                    "windows": app.windows.compactMap(\.title),
                ] as [String: Any]
            }]

        case "agents.list":
            return [
                "herdr_reachable": model.background.isHerdrReachable,
                "agents": model.background.agents.map(agentJSON),
            ]

        case "background.report":
            let task = try taskParam(params)
            guard task.isBackground else { throw ControlError.refused("“\(task.title)” is not a background task") }
            let summary = try requiredString("summary", in: params)
            model.reportBackground(id: task.id, summary: summary, link: params["link"] as? String)
            return ["task": taskJSON(model.tasks.first { $0.id == task.id } ?? task, day: model.todayKey)]

        case "approvals.list":
            return ["approvals": model.background.approvals.map(approvalJSON)]

        case "approvals.answer":
            // It reads the pane and waits on it; only `respond` can.
            throw ControlError.refused("approvals.answer needs the socket's asynchronous path")

        default:
            throw ControlError.unknownMethod(method)
        }
    }

    /// Re-checks the prompt on screen and answers it, or says why not.
    private func answerApproval(_ params: [String: Any]) async throws -> [String: Any] {
        let text = try requiredString("id", in: params)
        guard let id = UUID(uuidString: text) else { throw ControlError.invalidParams("not an approval id: \(text)") }
        let option: Int
        if let value = params["option"] as? Int {
            option = value
        } else if let value = (params["option"] as? String).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            option = value
        } else {
            throw ControlError.invalidParams("option is required: the number of the choice")
        }
        switch await model.background.answer(approvalID: id, option: option) {
        case .answered:
            return ["answered": true]
        case .stillShowing:
            throw ControlError.refused("the keys went in but the prompt is still showing; open the pane to answer it")
        case .refused(let reason):
            throw ControlError.refused(reason)
        }
    }

    /// `assign_to` (a pane id or workspace label), else the calling pane the
    /// MCP helper passes as `caller_pane`. Nil when neither is there.
    private func assigneeParam(_ params: [String: Any]) throws -> AgentRef? {
        do {
            return try model.background.resolveAssignee(
                target: params["assign_to"] as? String,
                callerPane: params["caller_pane"] as? String,
                callerWorkspace: params["caller_workspace"] as? String
            )
        } catch BackgroundError.unknownAgent(let target) {
            if !model.background.isHerdrReachable {
                throw ControlError.unavailable("herdr is not reachable, so “\(target)” cannot be looked up")
            }
            throw ControlError.notFound("no herdr agent in a pane or workspace “\(target)”; tunnelvision_list_agents lists them")
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

    /// The panel's red, yellow and green dots.
    private static let priorityNames = [1: "high", 2: "medium", 3: "low"]

    /// high, medium or low; 1 to 3 is accepted too.
    private func priorityParam(_ raw: Any?) throws -> Int? {
        guard let raw else { return nil }
        if let text = raw as? String,
           let match = Self.priorityNames.first(where: { $0.value == text.lowercased().trimmingCharacters(in: .whitespaces) }) {
            return match.key
        }
        if let value = raw as? Int, Self.priorityNames[value] != nil {
            return value
        }
        throw ControlError.invalidParams("priority must be high, medium or low")
    }

    private func dayParam(_ params: [String: Any], key: String = "day") throws -> String? {
        guard let day = params[key] as? String, !day.isEmpty else { return nil }
        guard DayKey.date(from: day) != nil else { throw ControlError.invalidParams("\(key) must be yyyy-MM-dd") }
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

    /// A goal by id or title (case-insensitive). An empty string is no goal,
    /// which `required` refuses.
    private func goalParam(_ raw: Any?, required: Bool = false) throws -> Goal? {
        guard let raw else {
            if required { throw ControlError.invalidParams("goal is required") }
            return nil
        }
        guard let text = raw as? String else { throw ControlError.invalidParams("goal must be a title or id") }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if required { throw ControlError.invalidParams("goal is required") }
            return nil
        }
        if let id = UUID(uuidString: trimmed), let goal = model.goal(id: id) {
            return goal
        }
        guard let goal = model.goals.first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw ControlError.notFound("no goal titled or with id “\(trimmed)”")
        }
        return goal
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
            // The order the panel shows the open tasks in.
            "task_sort": model.settings.taskSort.rawValue,
        ]
        if let remaining = model.remainingSeconds {
            state["remaining_seconds"] = remaining
        }
        if model.phase == .breakTime {
            state["long_break"] = model.isLongBreak
        }
        if let active = model.activeTask {
            state["active_task"] = taskJSON(active, day: model.todayKey)
        }
        // What starts next, in the order the panel shows, other than the task
        // already running.
        if let nextID = model.nextUpID(on: model.todayKey, excluding: model.activeTaskID),
           let next = model.tasks.first(where: { $0.id == nextID }) {
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
            // On the day's open list, as the panel shows it.
            "open": model.isOpen(task, on: day),
            "repeat_daily": task.repeatDaily,
            "priority": Self.priorityNames[task.priority] ?? "medium",
            "sessions": model.sessionProgress(for: task, on: day).total,
            "sessions_done": model.sessionProgress(for: task, on: day).done,
            "done_when": task.doneWhen,
            "urls_to_open": task.urlsToOpen,
            "active": task.id == model.activeTaskID,
        ]
        if task.createdDate != .distantPast {
            json["created_at"] = ISO8601DateFormatter().string(from: task.createdDate)
        }
        if let presetID = task.presetID, let preset = model.presets.first(where: { $0.id == presetID }) {
            json["preset"] = ["id": preset.id.uuidString, "name": preset.name]
        } else {
            json["preset"] = NSNull()
        }
        if let goal = model.goal(id: task.goalID) {
            json["goal"] = ["id": goal.id.uuidString, "title": goal.title]
        } else {
            json["goal"] = NSNull()
        }
        if let time = task.doneTime(on: day) {
            json["done_at"] = ISO8601DateFormatter().string(from: time)
        }
        if let position {
            json["position"] = position
        }
        json["background"] = task.background.map { backgroundJSON($0, task: task) } ?? NSNull()
        return json
    }

    private func backgroundJSON(_ info: BackgroundInfo, task: TaskItem) -> [String: Any] {
        var json: [String: Any] = [
            "status": Self.backgroundStatusNames[info.status] ?? info.status.rawValue,
            "ready": model.isReadyBackground(task),
            "summary": info.summary,
        ]
        json["link"] = info.link ?? NSNull()
        json["sent_at"] = info.sentAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        if let assignee = info.assignee {
            var agent: [String: Any] = [
                "pane_id": assignee.paneID,
                "workspace_id": assignee.workspaceID,
                "label": assignee.label,
            ]
            agent["session_id"] = assignee.sessionID ?? NSNull()
            json["assignee"] = agent
        } else {
            json["assignee"] = NSNull()
        }
        return json
    }

    /// snake_case, as everything else on the wire.
    private static let backgroundStatusNames: [BackgroundStatus: String] = [.paneClosed: "pane_closed"]

    private func agentJSON(_ agent: HerdrAgent) -> [String: Any] {
        var json: [String: Any] = [
            "pane_id": agent.paneID,
            "workspace_id": agent.workspaceID,
            "label": model.background.workspaceLabels[agent.workspaceID] ?? agent.workspaceID,
            "status": agent.status.rawValue,
            "focused": agent.focused,
        ]
        json["agent"] = agent.agent ?? NSNull()
        json["cwd"] = agent.cwd ?? NSNull()
        json["session_id"] = agent.sessionID ?? NSNull()
        return json
    }

    private func approvalJSON(_ approval: PendingApproval) -> [String: Any] {
        [
            "id": approval.id.uuidString,
            "pane_id": approval.paneID,
            "task_id": approval.taskID.uuidString,
            "task_title": model.tasks.first { $0.id == approval.taskID }?.title ?? "",
            "title": approval.title,
            "question": approval.question,
            "body": approval.body,
            "cursor": approval.options.indices.contains(approval.cursorIndex) ? approval.options[approval.cursorIndex].number : 1,
            "options": approval.options.map { option in
                [
                    "number": option.number,
                    "label": option.label,
                    "detail": option.detail,
                    // Opens a text field: answer it in the pane.
                    "needs_typed_input": option.needsTypedInput,
                ] as [String: Any]
            },
        ]
    }

    /// Every ended run between the two days, inclusive, oldest first, with a
    /// total per day. Sessions count only completed runs, as the history
    /// window does; focus time counts every run.
    private func historyJSON(from: String, to: String) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let records = model.history
            .filter { $0.day >= from && $0.day <= to }
            .sorted { $0.startedAt < $1.startedAt }
        let runs: [[String: Any]] = records.map { record in
            var json: [String: Any] = [
                "day": record.day,
                "title": record.title,
                "started_at": iso.string(from: record.startedAt),
                "ended_at": iso.string(from: record.endedAt),
                "focus_minutes": Int((record.focusSeconds / 60).rounded()),
                "outcome": record.outcome.rawValue,
            ]
            json["task_id"] = record.taskID?.uuidString ?? NSNull()
            return json
        }
        var days: [[String: Any]] = []
        var day: String? = from
        while let key = day, key <= to {
            let onDay = records.filter { $0.day == key }
            days.append([
                "day": key,
                "sessions": onDay.filter { $0.outcome == .completed }.count,
                "focus_minutes": Int((onDay.reduce(0) { $0 + $1.focusSeconds } / 60).rounded()),
            ])
            day = DayKey.key(byAdding: 1, to: key)
        }
        return ["from": from, "to": to, "days": days, "runs": runs]
    }

    /// A goal with its tasks in list order. A task counts as finished once
    /// checked off on any day; `open` is whether it is on today's list.
    private func goalJSON(_ goal: Goal) -> [String: Any] {
        let today = model.todayKey
        let steps = model.tasks.filter { $0.goalID == goal.id }
        var json: [String: Any] = [
            "id": goal.id.uuidString,
            "title": goal.title,
            "done_when": goal.doneWhen,
            "priority": Self.priorityNames[goal.priority] ?? "medium",
            "created_at": ISO8601DateFormatter().string(from: goal.createdDate),
            "done": goal.doneAt != nil,
            "tasks_total": steps.count,
            "tasks_finished": steps.filter { $0.lastDoneDay != nil }.count,
            "tasks": steps.map { task in
                [
                    "id": task.id.uuidString,
                    "title": task.title,
                    "done_when": task.doneWhen,
                    "open": model.isOpen(task, on: today),
                    "finished": task.lastDoneDay != nil,
                    "sessions": model.sessionProgress(for: task, on: today).total,
                    "sessions_done": model.sessionProgress(for: task, on: today).done,
                ] as [String: Any]
            },
        ]
        if let doneAt = goal.doneAt {
            json["done_at"] = ISO8601DateFormatter().string(from: doneAt)
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
