---
name: break-down
description: Break a big piece of work into a Tunnel Vision goal and its next session-sized steps. Use when the user wants work broken down or turned into a goal, a task is too big for one session, or they ask what's next on a goal.
---

# Break down

Turn an outcome into a Tunnel Vision goal with 1–3 steps of runway, so the next session is always ready.

The Tunnel Vision tools are named `tunnelvision_*`; they may carry a server prefix. If none are available, the app is not running or the MCP server is not connected: say so and stop.

## Steps

1. **Read.** Call `tunnelvision_list_goals`, `tunnelvision_list_tasks` and `tunnelvision_list_presets`, and read `../TASK-SHAPE.md`. Done: you know whether the work is an existing goal, an existing task, or new.
2. **Pin the outcome.** Settle the goal's title and `done_when` with the user: one checkable end state ("PoC demoed to the team", "migration merged and running in prod"). For an existing goal, reuse its record and note its finished steps and current runway. When the user asks what's next on a goal and it already has 1–3 steps of runway, report its first open step in list order and stop. Done: a goal title and `done_when` the user agrees on.
3. **Find the next steps.** Work out the next 1–3 steps toward the outcome, using what the conversation, the repo, and connected tools show about the work. Each step passes `../TASK-SHAPE.md`. Steady, same-shaped work inside the goal is one step plus N-1 copies (`tunnelvision_duplicate_task`). Leave later steps unwritten; name the rough path ahead in one line so the user sees where the steps lead. Skip steps the existing runway already covers. Done: the goal's runway reaches 1–3 open steps, and each new step has a title, `done_when`, minutes, priority and preset.
4. **Propose.** Show the goal (new or existing, with its `done_when` and priority) and a table of its steps: existing open steps first, then the new ones. When the work came from an existing big task, offer to replace it. When it is a one-off that is not done, rewrite it as the first step so it keeps its place in the list; it keeps its own check-off state. Otherwise add the first step as a new task and offer to check off or delete the old one. When it is running, offer to make the change after the session ends. Wait for the user to approve or adjust.
5. **Write.** In order:
   1. `tunnelvision_add_goal` for a new goal, or `tunnelvision_update_goal` for approved changes to an existing one.
   2. When rewriting a big task in place: `tunnelvision_update_task` on it with the first step's title, `done_when`, duration and `goal`.
   3. `tunnelvision_add_task` for each other new step, with `goal` set; then `tunnelvision_set_task_done` or `tunnelvision_delete_task` on a replaced task, as the user chose.
   Done: each call returned without error, or the refusal is reported with its message.
6. **Check.** Call `tunnelvision_list_goals`. Done: the goal shows every new step as open, and its runway is 1–3 steps.
