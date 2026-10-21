---
name: capture-task
description: Turn the work in the current conversation into a Tunnel Vision focus task for the user's own list. Use when the user wants the current scope saved as a task, put on today's list, or captured for later.
---

# Focus task from the current scope

Turn what this conversation is about into focus tasks on the user's Tunnel Vision list, each shaped for one pomodoro: one task when the work fits a session, a goal with steps or a series when it does not.

The Tunnel Vision tools are named `tunnelvision_*`; they may carry a server prefix. If none are available, the app is not running or the MCP server is not connected: say so and stop.

## Steps

1. **Find the scope.** Take the work from the conversation: what the user still has to do themselves. Text the user passed with the command narrows or replaces it. If the conversation holds no clear piece of work, ask one question naming the candidates and stop. Done: one piece of work for the user.
2. **Size it.** Estimate the work in pomodoros (25 minutes each). One pomodoro, or up to 50 minutes of deep work: one task. More: split it per `../TASK-SHAPE.md`, as a goal with its first 1–3 steps when the parts differ, or one task plus copies when every session does the same work. Done: one task, a series, or a goal with steps, each step at most 50 minutes.
3. **Shape it** per `../TASK-SHAPE.md`: a verb-first title, a checkable `done_when`, a duration, and a checklist when the session has distinct moves. Pick a preset from `tunnelvision_list_presets` when one clearly fits the work (Coding, Writing, Comms, Reading); otherwise leave it out. Facts gathered in the conversation go in `description`; on a goal, put them on the first step. Done: each task has a title, `done_when`, minutes and, when they fit, a checklist and a preset.
4. **Create it.** For a goal, call `tunnelvision_add_goal` first, then `tunnelvision_add_task` for each step with `goal` set. For a series, call `tunnelvision_add_task` once, then `tunnelvision_duplicate_task` for each extra session. Otherwise call `tunnelvision_add_task` once. Done: each reply shows its task or goal, or the refusal is reported with its message.
5. **Report** in one line per task: the title, minutes and `done_when` as created. For a goal, lead with its title and `done_when` and name the rough path past the steps written.
