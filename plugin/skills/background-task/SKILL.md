---
name: background-task
description: Hand the work in the current conversation to this agent as a Tunnel Vision background task, which starts on its own with the user's next focus session. Use when the user wants the current scope handed off, run in the background, or picked up by this agent while they focus on something else.
---

# Background task from the current scope

Turn what this conversation is about into one background task assigned to this agent's own herdr pane. The next time the user starts a focus session, Tunnel Vision sends the task back to this pane as a prompt, and this agent does the work while the user focuses elsewhere.

The Tunnel Vision tools are named `tunnelvision_*`; they may carry a server prefix. If none are available, the app is not running or the MCP server is not connected: say so and stop.

## Steps

1. **Find the scope.** Take the work from the conversation: what was being discussed, planned or left unfinished. Text the user passed with the command narrows or replaces it. If the conversation holds no clear piece of work, ask one question naming the candidates and stop. Done: one piece of work an agent can finish without the user.
2. **Shape it** per `../TASK-SHAPE.md`, with two differences:
   - **Title:** what the agent will do, verb-first ("Add the Repeat button to the time's-up popup").
   - **`done_when`:** required. A result someone can check without asking the agent: "tests pass and the change is committed on branch X", "PR opened", "notes written to docs/plan.md". A background task without one never starts.
   Leave out duration and preset: background tasks don't use the timer or the allowlist.
   Done: a title and a `done_when`.
3. **Create it.** Call `tunnelvision_add_task` with `title`, `done_when` and `background: true`, and no `assign_to`: the task is assigned to the pane this conversation runs in. Done: the reply shows the task with `background.ready` true and an assignee. When `ready` is false or there is no assignee (this session runs outside herdr), report that and say how to fix it: pick an agent in the task editor.
4. **Report** in two lines: the title and `done_when` as created, and that it starts with the next focus session in this pane, so this session should be left idle until then.
