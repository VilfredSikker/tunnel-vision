---
name: plan-day
description: Plan today's Tunnel Vision list — order, priorities, durations and goal runway fitted to the focus time available. Use when the user asks to plan the day or decide what to work on first.
---

# Plan the day

Turn today's Tunnel Vision list into a plan that fits the day, then write it back to the app so the panel and the timer follow it.

The Tunnel Vision tools are named `tunnelvision_*`; they may carry a server prefix. If none are available, the app is not running or the MCP server is not connected: say so and stop.

## How the app orders work

- `task_sort` (from `tunnelvision_state`) is the order the panel shows open tasks in: `manual`, `created`, or `priority` (high, then medium, then low; list order within each).
- `next_up` and the start shortcut always take the first open task in **list order**, whatever the sort. `tunnelvision_reorder_tasks` sets list order, so the plan's first task must also be first in the list.
- The running task (`active: true`) is already under way: it leads the plan and leads the reorder, and `next_up` is the plan's second task.

## Steps

1. **Read.** Call `tunnelvision_state`, `tunnelvision_list_tasks`, `tunnelvision_list_goals` and `tunnelvision_history` (default range: the last 7 days). Work only with tasks where `open` is true. Done: you know the sort, the running task, every open task's priority, duration and goal (and, for a series, sessions left), every open goal's runway, and the average completed sessions and focus minutes per day over the days that had any.
2. **Capacity.** Ask the user how much focus time today holds (meetings, hard stops) unless they already said. Offer the history average as the default. Done: a number of focus minutes for today.
3. **Shape.** Read `../TASK-SHAPE.md`, then check the list against it:
   - A task without `done_when`, or with one that can't be checked: propose one.
   - A vague title: rewrite it verb-first.
   - A task too big for one session: propose duplicating the task (`tunnelvision_duplicate_task`) for steady work, or a goal with its first steps (the `break-down` skill does this in full).
   - An open goal with no runway: propose its next step.
   Done: every open task and every proposed task passes `../TASK-SHAPE.md`.
4. **Plan.** Order the open tasks into the capacity:
   - Highest priority first. Under `task_sort: priority`, keep the groups in order (high before medium before low) and order within each; to move a task across groups, propose a priority change.
   - Within a priority: deadlines and tasks that unblock other people first, then short tasks that clear the way, then long deep work while energy is high.
   - Count each task's capacity as in `../TASK-SHAPE.md` (its `duration_minutes`; each copy is its own task). Whatever falls past the capacity is **deferred**: it stays on the list, below the cut. A series may straddle the cut; note how many of its copies fit today.
   Done: every open task is either in the plan or deferred, and the plan fits the capacity.
5. **Propose.** Show one table: position, task, goal, priority, minutes, `done_when`, and a short note on each change. Mark the capacity cut. List the edits it implies: reorder, priority and duration changes, duplicated or deleted copies, new `done_when`s, new steps and tasks. Wait for the user to approve or adjust.
6. **Write.** Apply the approved edits: `tunnelvision_update_task` for changes to existing tasks, `tunnelvision_add_goal` and `tunnelvision_add_task` (with `goal`) for new goals, steps and tasks, `tunnelvision_duplicate_task` for extra sessions, then one `tunnelvision_reorder_tasks` with every open task id in plan order (the running task first), deferred ones last. Start a session only when the user asks.
7. **Check.** Call `tunnelvision_state`, `tunnelvision_list_tasks` and `tunnelvision_list_goals` again. Done: the list order matches the plan, `next_up` is the first planned task that is not running, and every approved step sits under its goal. Report any edit the app refused, with its message.
