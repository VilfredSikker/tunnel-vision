import Foundation

/// The MCP tools and how each maps onto a control method. Tool arguments are
/// passed to the app as method params unchanged, except `tunnelvision_session`,
/// whose `action` picks the method.
public enum ControlTools {
    /// Computed: `[String: Any]` schemas are not Sendable, so no stored statics.
    public static var all: [MCPTool] { [
        MCPTool(
            name: "tunnelvision_state",
            description: "Current session state of Tunnel Vision, the menu bar focus timer: phase (idle, work, paused, break), remaining seconds, whether a break is the long one, the active task, the next task up (the first still due today in the order the panel shows, which follows task_sort), today's day key, sessions completed today, and task_sort: the order the panel shows open tasks in (manual, created, or priority, high first).",
            inputSchema: object([:])
        ),
        MCPTool(
            name: "tunnelvision_list_tasks",
            description: "List the tasks in list order for a day (today unless `day` is given as yyyy-MM-dd). Each has id, title, duration, preset, goal, allowlist rules, priority (high, medium or low), created_at, done_when (the outcome that finishes it), sessions (how many tasks share its series: it and its copies) against sessions_done (those checked off; per day for a repeating task), whether it repeats daily, whether it was done on the day, and whether it is open (on the day's list as the app shows it; a one-off checked off on an earlier day is not).",
            inputSchema: object(["day": string("Day key yyyy-MM-dd; defaults to today")])
        ),
        MCPTool(
            name: "tunnelvision_add_task",
            description: "Add a task to the end of the list. `preset` is a preset name or id (for example Coding, Writing, Comms, Reading); `rules` are extra allowlist rules layered on the preset, or the whole allowlist when there is no preset. Anything not allowed is hidden, quit or frozen while the task runs. A task with `repeat_daily` true comes back on tomorrow's list once checked off. Scope each task to one checkable outcome (`done_when`) that fits its duration; steady work that needs several sessions is duplicated with tunnelvision_duplicate_task. With `background` true the task goes to a Claude Code agent in a herdr pane (your own unless `assign_to` names another) when the user next starts a focus session; it never runs on the timer.",
            inputSchema: object([
                "title": string("What to work on"),
                "duration_minutes": integer("Work duration in minutes; defaults to the settings default (25)"),
                "preset": string("Preset name or id; omit for a custom allowlist made of `rules` only"),
                "rules": rulesSchema,
                "repeat_daily": boolean("True to keep the task on the list every day after it is checked off"),
                "priority": priority,
                "done_when": doneWhen,
                "goal": string("Goal title or id this task is a step toward"),
                "background": boolean(backgroundDescription),
                "assign_to": string(assignToDescription),
            ], required: ["title"])
        ),
        MCPTool(
            name: "tunnelvision_update_task",
            description: "Change a task's title, duration, preset, priority, done_when, its own rules (the rules replace the task's existing extra rules), whether it repeats daily, or whether it is a background task and which agent it goes to. Pass an empty string as `preset` to detach the preset. A running task relocks at once.",
            inputSchema: object([
                "id": string("Task id"),
                "title": string("New title"),
                "duration_minutes": integer("New duration in minutes"),
                "preset": string("Preset name or id, or an empty string to remove the preset"),
                "rules": rulesSchema,
                "repeat_daily": boolean("True to keep the task on the list every day after it is checked off"),
                "priority": priority,
                "done_when": doneWhen,
                "goal": string("Goal title or id, or an empty string to take the task out of its goal"),
                "background": boolean("True to hand the task to a Claude Code agent (your own herdr pane unless assign_to says otherwise), false to make it an ordinary focus task again"),
                "assign_to": string("herdr pane id or workspace label of the agent to send it to, or an empty string to unassign; a task already sent keeps its agent"),
            ], required: ["id"])
        ),
        MCPTool(
            name: "tunnelvision_duplicate_task",
            description: "Add one more session of a task: an open copy (same title, duration, allowlist, priority, goal and schedule) goes right after it, unstarted. The task and its copies count together as `sessions` in the task list.",
            inputSchema: object(["id": string("Task id")], required: ["id"])
        ),
        MCPTool(
            name: "tunnelvision_delete_task",
            description: "Delete a task. The running task cannot be deleted.",
            inputSchema: object(["id": string("Task id")], required: ["id"])
        ),
        MCPTool(
            name: "tunnelvision_reorder_tasks",
            description: "Put the given tasks first, in this order; the rest keep their order after them. The first task still due today is what starts next.",
            inputSchema: object(["ids": array(string("Task id"), "Task ids in the wanted order")], required: ["ids"])
        ),
        MCPTool(
            name: "tunnelvision_set_task_done",
            description: "Check a task off, or uncheck it, for a day (today unless `day` is given). Checking off the running task ends its session with credit.",
            inputSchema: object([
                "id": string("Task id"),
                "done": boolean("true to check off (default), false to uncheck"),
                "day": string("Day key yyyy-MM-dd; defaults to today"),
            ], required: ["id"])
        ),
        MCPTool(
            name: "tunnelvision_history",
            description: "Ended work runs between two days (inclusive; the last 7 days by default, at most a year): each run's task title and id, start and end, focus minutes (pauses left out) and outcome (completed, skippedToBreak, stopped), plus per-day totals of completed sessions and focus minutes.",
            inputSchema: object([
                "from": string("First day yyyy-MM-dd; defaults to 6 days before `to`"),
                "to": string("Last day yyyy-MM-dd; defaults to today"),
            ])
        ),
        MCPTool(
            name: "tunnelvision_list_goals",
            description: "List goals: outcomes bigger than one task, each with id, title, done_when, priority, whether it is finished, and its tasks (the session-sized steps toward it) with tasks_total and tasks_finished. Keep the next one to three steps of an open goal on the list rather than every step up front.",
            inputSchema: object([:])
        ),
        MCPTool(
            name: "tunnelvision_add_goal",
            description: "Add a goal. Add its steps with tunnelvision_add_task and `goal` set to this goal.",
            inputSchema: object([
                "title": string("The outcome, e.g. Ship the Platform Agent PoC"),
                "done_when": string("What finishing the goal looks like"),
                "priority": priority,
            ], required: ["title"])
        ),
        MCPTool(
            name: "tunnelvision_update_goal",
            description: "Change a goal's title, done_when or priority, or finish it (done true) or reopen it (done false). Finishing a goal leaves its open tasks on the list.",
            inputSchema: object([
                "goal": string("Goal title or id"),
                "title": string("New title"),
                "done_when": string("What finishing the goal looks like"),
                "priority": priority,
                "done": boolean("true to finish the goal, false to reopen it"),
            ], required: ["goal"])
        ),
        MCPTool(
            name: "tunnelvision_delete_goal",
            description: "Delete a goal. Its tasks stay on the list, outside any goal.",
            inputSchema: object(["goal": string("Goal title or id")], required: ["goal"])
        ),
        MCPTool(
            name: "tunnelvision_list_presets",
            description: "List the presets: name, id, built-in flag, mode (dark hides other apps, closed quits them, frozen pauses them) and allowlist rules.",
            inputSchema: object([:])
        ),
        MCPTool(
            name: "tunnelvision_create_preset",
            description: "Create a named, reusable allowlist. Rules allow whole apps (scope app), single windows by title fragment (scope window, needs Accessibility), sites inside a browser (scope url, pattern host[/path] such as github.com/org/repo) or herdr workspaces by label (scope herdr).",
            inputSchema: object([
                "name": string("Preset name, unique"),
                "mode": mode,
                "rules": rulesSchema,
                "urls_to_open": array(string("URL"), "URLs to open when a task with this preset starts"),
            ], required: ["name"])
        ),
        MCPTool(
            name: "tunnelvision_update_preset",
            description: "Change a preset's name, mode, rules (replace the whole rule list) or URLs to open. Built-in presets can change everything but their name.",
            inputSchema: object([
                "preset": string("Preset name or id"),
                "name": string("New name"),
                "mode": mode,
                "rules": rulesSchema,
                "urls_to_open": array(string("URL"), "URLs to open when a task with this preset starts"),
            ], required: ["preset"])
        ),
        MCPTool(
            name: "tunnelvision_delete_preset",
            description: "Delete a preset. Tasks using it fall back to a custom allowlist made of their own rules.",
            inputSchema: object(["preset": string("Preset name or id")], required: ["preset"])
        ),
        MCPTool(
            name: "tunnelvision_session",
            description: "Drive the timer: start a task (needs task_id; refused while another session runs), pause, resume, stop (early, no credit, no break), done (check the running task off and take the break), skip_break, or extend by minutes.",
            inputSchema: object([
                "action": ["type": "string", "enum": ["start", "pause", "resume", "stop", "done", "skip_break", "extend"], "description": "What to do"],
                "task_id": string("Task to start (action start)"),
                "minutes": integer("Minutes to add (action extend)"),
            ], required: ["action"])
        ),
        MCPTool(
            name: "tunnelvision_list_apps",
            description: "Running apps with their bundle ids and open window titles, for building allowlists. Rules also accept names of installed apps (looked up in /Applications) in place of bundle ids.",
            inputSchema: object([:])
        ),
        MCPTool(
            name: "tunnelvision_list_agents",
            description: "Claude Code and other agents running in herdr panes: pane id, workspace id and label, status (idle, working, blocked, done, unknown), whether focused, working directory and Claude session id. Background tasks are assigned to one of these with assign_to (a pane id or a workspace label).",
            inputSchema: object([:])
        ),
        MCPTool(
            name: "tunnelvision_report_background",
            description: "Report a background task as finished. Call this when you are done with a task Tunnel Vision sent you: the task id from the brief, a one-line summary of what you did, and a link to the result (a PR URL or a file path) if there is one. The task then waits for the user's review.",
            inputSchema: object([
                "id": string("Task id from the brief"),
                "summary": string("One line: what was done"),
                "link": string("PR URL or file path of the result"),
            ], required: ["id", "summary"])
        ),
        MCPTool(
            name: "tunnelvision_list_approvals",
            description: "Prompts that agents working on background tasks are waiting on (permission, question or plan approval), each with id, pane, task, title, question, a few body lines, the numbered options, which option the cursor is on, and whether an option needs typed input (those are answered in the pane).",
            inputSchema: object([:])
        ),
        MCPTool(
            name: "tunnelvision_answer_approval",
            description: "Answer a pending approval with one of its numbered options. Refused when the prompt on screen changed, the agent is no longer waiting, or the option needs typed input.",
            inputSchema: object([
                "id": string("Approval id from tunnelvision_list_approvals"),
                "option": integer("Number of the option to choose"),
            ], required: ["id", "option"])
        ),
    ] }

    /// Params a tool call adds about where it comes from: the herdr pane and
    /// workspace the MCP helper runs in, which herdr puts in the agent's
    /// environment. A background task added without `assign_to` goes to
    /// that pane. Only task adds and updates carry them.
    public static func addingCaller(to params: [String: Any], method: String, environment: [String: String]) -> [String: Any] {
        guard method == "tasks.add" || method == "tasks.update" else { return params }
        var params = params
        if let pane = environment["HERDR_PANE_ID"], !pane.isEmpty {
            params["caller_pane"] = pane
        }
        if let workspace = environment["HERDR_WORKSPACE_ID"], !workspace.isEmpty {
            params["caller_workspace"] = workspace
        }
        return params
    }

    /// The control method and params for a tool call; nil for an unknown tool.
    public static func route(tool: String, arguments: [String: Any]) -> (method: String, params: [String: Any])? {
        switch tool {
        case "tunnelvision_state": return ("state.get", [:])
        case "tunnelvision_list_tasks": return ("tasks.list", arguments)
        case "tunnelvision_add_task": return ("tasks.add", arguments)
        case "tunnelvision_update_task": return ("tasks.update", arguments)
        case "tunnelvision_duplicate_task": return ("tasks.duplicate", arguments)
        case "tunnelvision_delete_task": return ("tasks.delete", arguments)
        case "tunnelvision_reorder_tasks": return ("tasks.reorder", arguments)
        case "tunnelvision_set_task_done": return ("tasks.set_done", arguments)
        case "tunnelvision_history": return ("history.list", arguments)
        case "tunnelvision_list_goals": return ("goals.list", [:])
        case "tunnelvision_add_goal": return ("goals.add", arguments)
        case "tunnelvision_update_goal": return ("goals.update", arguments)
        case "tunnelvision_delete_goal": return ("goals.delete", arguments)
        case "tunnelvision_list_presets": return ("presets.list", [:])
        case "tunnelvision_create_preset": return ("presets.create", arguments)
        case "tunnelvision_update_preset": return ("presets.update", arguments)
        case "tunnelvision_delete_preset": return ("presets.delete", arguments)
        case "tunnelvision_list_apps": return ("apps.list", [:])
        case "tunnelvision_list_agents": return ("agents.list", [:])
        case "tunnelvision_report_background": return ("background.report", arguments)
        case "tunnelvision_list_approvals": return ("approvals.list", [:])
        case "tunnelvision_answer_approval": return ("approvals.answer", arguments)
        case "tunnelvision_session":
            guard let action = arguments["action"] as? String else { return nil }
            var params: [String: Any] = [:]
            if let taskID = arguments["task_id"] { params["id"] = taskID }
            if let minutes = arguments["minutes"] { params["minutes"] = minutes }
            return ("session." + action, params)
        default:
            return nil
        }
    }

    // MARK: Schema helpers

    private static let backgroundDescription = "True to hand the task to a Claude Code agent in a herdr pane instead of a focus session. It goes out when the user next starts a focus session, if it has a done_when and an agent; it is never started on the timer"

    private static let assignToDescription = "herdr pane id (e.g. w5K:p1) or workspace label of the agent to send it to; omitted, a background task goes to the pane you are running in"

    private static var doneWhen: [String: Any] {
        string("The outcome that makes the task finished, checkable at the end of a session, e.g. \"PR opened\" or \"all 5 open questions answered in the doc\"")
    }

    private static var priority: [String: Any] {
        [
            "type": "string",
            "enum": ["high", "medium", "low"],
            "description": "Task priority, shown as a red, yellow or green dot; defaults to medium",
        ]
    }

    private static var mode: [String: Any] {
        [
            "type": "string",
            "enum": ["dark", "closed", "frozen"],
            "description": "What happens to apps that are not allowed",
        ]
    }

    private static var rulesSchema: [String: Any] { array([
        "type": "object",
        "properties": [
            "app": string("App name (installed or running) or bundle id"),
            "bundle_id": string("Bundle id, when known; takes precedence over app"),
            "scope": ["type": "string", "enum": ["app", "window", "url", "herdr"], "description": "app (default): the whole app; window: windows whose title contains pattern; url: pages under pattern in that browser; herdr: the herdr workspace labelled pattern"],
            "pattern": string("Window title fragment, site host[/path], or herdr workspace label; not used for scope app"),
        ] as [String: Any],
    ], "Allowlist rules") }

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func array(_ items: [String: Any], _ description: String) -> [String: Any] {
        ["type": "array", "items": items, "description": description]
    }
}
