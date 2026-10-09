# Tunnel Vision plugin for Claude Code

Skills that plan, review and fill your [Tunnel Vision](https://github.com/VilfredSikker/tunnel-vision) task list:

| Skill | Ask for it with | What it does |
| --- | --- | --- |
| `plan-day` | "plan my day" | Orders today's open tasks by priority into the focus time you have, gives each open goal its next step, then writes the order, priorities and durations back to the app. |
| `review-tasks` | "review my week", "give me my standup" | Reports what got done, where the focus time went, how estimates held and how goals moved, then offers to tidy the list. A standup lists yesterday's work, today's plan and blockers. |
| `suggest-tasks` | "what should I work on?" | Turns work from the conversation, the current repo, pull requests and connected tools into focus tasks, filed under your goals. |
| `break-down` | "break this down", "what's next on the launch goal?" | Turns a big piece of work into a goal and its next one to three session-sized steps, replacing the big task if there is one. |
| `end-of-day` | "wrap up my day" | Checks off what finished, refills each goal's next steps, defers what won't fit tomorrow, and offers a short log of the day. |
| `background-task` | "hand this off", `/tv bg` | Turns the work in the conversation into a background task for this agent's own herdr pane. It starts by itself with your next focus session. |
| `capture-task` | "make this a task", `/tv task` | Turns the work in the conversation into a focus task on your list. |

Every task is one focus session with a `done_when` you can check when the timer ends ("PR opened", "5 questions answered"). Work bigger than one session becomes either a task with several `sessions` (steady work such as reading or reviewing) or a goal whose next one to three steps, its runway, sit on the list and get refilled as they finish. The shared rules live in [`skills/TASK-SHAPE.md`](skills/TASK-SHAPE.md).

Every skill shows its proposal and waits for your go-ahead before it changes the list.

## Install

Tunnel Vision must be installed at `/Applications/TunnelVision.app` and running. The plugin starts the MCP server bundled in the app.

```
claude plugin marketplace add VilfredSikker/tunnel-vision
claude plugin install tunnelvision@tunnel-vision
```

If you registered the server by hand before (`make mcp-register` or `claude mcp add tunnelvision …`), remove that entry with `claude mcp remove tunnelvision` so the tools aren't listed twice.

## The mod (optional)

[`tunnelvision-mod`](../plugin-mod/README.md) puts Tunnel Vision inside Claude Code: a status line, `/tv` commands, a task pane, a check-in when a session ends, and the running task's goal and outcome in Claude's prompt. It needs a Claude Code build with function hooks:

```
claude plugin install tunnelvision-mod@tunnel-vision
```
