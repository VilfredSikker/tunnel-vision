---
name: capture-task
description: Turn the work in the current conversation into a Tunnel Vision focus task for the user's own list. Use when the user wants the current scope saved as a task, put on today's list, or captured for later.
---

# Focus task from the current scope

Turn what this conversation is about into one task on the user's Tunnel Vision list, shaped for one focus session.

The Tunnel Vision tools are named `tunnelvision_*`; they may carry a server prefix. If none are available, the app is not running or the MCP server is not connected: say so and stop.

## Steps

1. **Find the scope.** Take the work from the conversation: what the user still has to do themselves. Text the user passed with the command narrows or replaces it. If the conversation holds no clear piece of work, ask one question naming the candidates and stop. Done: one piece of work for the user.
2. **Shape it** per `../TASK-SHAPE.md`: a verb-first title, a checkable `done_when` and a duration. Work bigger than one session becomes a series or a goal, as that file describes; the `break-down` skill does a goal in full. Pick a preset from `tunnelvision_list_presets` when one clearly fits the work (Coding, Writing, Comms, Reading); otherwise leave it out. Done: a title, `done_when`, minutes and, when one fits, a preset.
3. **Create it.** Call `tunnelvision_add_task` with those fields. Done: the reply shows the task, or the refusal is reported with its message.
4. **Report** in one line: the title, minutes and `done_when` as created.
