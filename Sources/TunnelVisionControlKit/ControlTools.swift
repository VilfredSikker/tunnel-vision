import Foundation

/// The MCP tools and how each maps onto a control method. Tool arguments are
/// passed to the app as method params unchanged, except `tunnelvision_session`,
/// whose `action` picks the method.
public enum ControlTools {
    /// Computed: `[String: Any]` schemas are not Sendable, so no stored statics.
    public static var all: [MCPTool] { [
        MCPTool(
            name: "tunnelvision_state",
            description: "Current session state of Tunnel Vision, the menu bar focus timer: phase (idle, work, paused, break), remaining seconds, the active task, the next task up (first still due today), today's day key and sessions completed today.",
            inputSchema: object([:])
        ),
        MCPTool(
            name: "tunnelvision_list_tasks",
            description: "List the tasks in order with id, title, duration, preset, allowlist rules, whether each was done on the day, and whether it repeats daily (today unless `day` is given as yyyy-MM-dd).",
            inputSchema: object(["day": string("Day key yyyy-MM-dd; defaults to today")])
        ),
        MCPTool(
            name: "tunnelvision_add_task",
            description: "Add a task to the end of the list. `preset` is a preset name or id (for example Coding, Writing, Comms, Reading); `rules` are extra allowlist rules layered on the preset, or the whole allowlist when there is no preset. Anything not allowed is hidden, quit or frozen while the task runs. A task with `repeat_daily` true comes back on tomorrow's list once checked off.",
            inputSchema: object([
                "title": string("What to work on"),
                "duration_minutes": integer("Work duration in minutes; defaults to the settings default (25)"),
                "preset": string("Preset name or id; omit for a custom allowlist made of `rules` only"),
                "rules": rulesSchema,
                "repeat_daily": boolean("True to keep the task on the list every day after it is checked off"),
            ], required: ["title"])
        ),
        MCPTool(
            name: "tunnelvision_update_task",
            description: "Change a task's title, duration, preset, its own rules (the rules replace the task's existing extra rules) or whether it repeats daily. Pass an empty string as `preset` to detach the preset. A running task relocks at once.",
            inputSchema: object([
                "id": string("Task id"),
                "title": string("New title"),
                "duration_minutes": integer("New duration in minutes"),
                "preset": string("Preset name or id, or an empty string to remove the preset"),
                "rules": rulesSchema,
                "repeat_daily": boolean("True to keep the task on the list every day after it is checked off"),
            ], required: ["id"])
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
            description: "Running apps with their bundle ids and on-screen window titles, for building allowlists. Rules also accept names of installed apps (looked up in /Applications) in place of bundle ids.",
            inputSchema: object([:])
        ),
    ] }

    /// The control method and params for a tool call; nil for an unknown tool.
    public static func route(tool: String, arguments: [String: Any]) -> (method: String, params: [String: Any])? {
        switch tool {
        case "tunnelvision_state": return ("state.get", [:])
        case "tunnelvision_list_tasks": return ("tasks.list", arguments)
        case "tunnelvision_add_task": return ("tasks.add", arguments)
        case "tunnelvision_update_task": return ("tasks.update", arguments)
        case "tunnelvision_delete_task": return ("tasks.delete", arguments)
        case "tunnelvision_reorder_tasks": return ("tasks.reorder", arguments)
        case "tunnelvision_set_task_done": return ("tasks.set_done", arguments)
        case "tunnelvision_list_presets": return ("presets.list", [:])
        case "tunnelvision_create_preset": return ("presets.create", arguments)
        case "tunnelvision_update_preset": return ("presets.update", arguments)
        case "tunnelvision_delete_preset": return ("presets.delete", arguments)
        case "tunnelvision_list_apps": return ("apps.list", [:])
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
