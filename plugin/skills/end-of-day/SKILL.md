---
name: end-of-day
description: Close out the day in Tunnel Vision — check off finished work, refill each goal's runway, defer what won't fit tomorrow, and optionally log the day. Use when the user wraps up for the day or asks for an end-of-day shutdown.
---

# End of day

Leave tomorrow's Tunnel Vision list true and ready: what finished is checked off, every open goal has its next steps, and tomorrow starts on the right task.

The Tunnel Vision tools are named `tunnelvision_*`; they may carry a server prefix. If none are available, the app is not running or the MCP server is not connected: say so and stop.

## Steps

1. **Read.** Call `tunnelvision_state`, `tunnelvision_list_tasks`, `tunnelvision_list_goals`, and `tunnelvision_history` with `from` and `to` set to today, and read `../TASK-SHAPE.md`. Done: you know today's runs, the running task, every open task, and every goal's runway.
2. **Check off.** Ask about the running task and every open task that had a run today but was stopped or skipped, or belongs to a series with sessions left: is its `done_when` met? Done: each of those tasks has the user's answer, finished or still open.
3. **Carry over.** Open one-offs stay on tomorrow's list by themselves; list them so the user sees what carries over. Done: the list of carried-over tasks.
4. **Refill runway.** For each open goal whose runway drops below 1 step after the check-offs, propose its next step per `../TASK-SHAPE.md`. For a goal whose `done_when` is met, propose finishing it and say what happens to its open steps. Done: every open goal ends with 1–3 steps of runway or a proposal to finish it.
5. **Defer and reprioritize.** The app has no due dates: to defer a task, move it to the end of the list or lower its priority. Propose these for tasks that won't fit tomorrow, and a new order with tomorrow's first task leading. Done: a proposed order for tomorrow.
6. **Propose and write.** Show the check-offs, new steps, goal changes, priority changes and order as one list. Wait for the user to approve or adjust, then apply with `tunnelvision_session` (`done` for a finished running task, `stop` when the user wants the session ended), `tunnelvision_set_task_done`, `tunnelvision_add_task` (with `goal`), `tunnelvision_update_goal`, `tunnelvision_update_task` and one `tunnelvision_reorder_tasks` (the running task first, if one remains). Done: each call returned without error, or the refusal is reported with its message.
7. **Check.** Call `tunnelvision_state`, `tunnelvision_list_tasks` and `tunnelvision_list_goals` again. Done: approved check-offs show as done, every open goal shows its runway, and `next_up` is tomorrow's first task that is not running.
8. **Log.** Offer a short log of the day: completed sessions, focus minutes, tasks finished, and goals moved (steps finished, goals finished). Write it only to a file or note the user names; with no location named, show it in the reply.
