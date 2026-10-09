---
name: review-tasks
description: Review Tunnel Vision tasks, goals and focus history — what got done, where time went, how estimates held — and tidy the list. Use when the user asks for a daily or weekly review, a standup, or to clean up their task list.
---

# Review tasks

Look back over a stretch of Tunnel Vision work, report it plainly, and leave the list cleaner than you found it.

The Tunnel Vision tools are named `tunnelvision_*`; they may carry a server prefix. If none are available, the app is not running or the MCP server is not connected: say so and stop.

## Steps

1. **Range and format.** Today unless the user names a range ("this week" is the last 7 days). `tunnelvision_history` covers at most a year. When the user asks for a standup, follow **Standup** below instead of steps 2–5.
2. **Read.** Call `tunnelvision_history` for the range, `tunnelvision_list_tasks` with `day` set to each day in the range (`done` and a repeating task's `sessions_done` are per day), and `tunnelvision_list_goals`. Done: every run in the range, every task it touches, and every goal is in hand.
3. **Measure.** Work out, from the data only:
   - **Done:** tasks checked off in the range, and completed sessions and focus minutes per day.
   - **Slipped:** runs with outcome `stopped` or `skippedToBreak`, grouped by task.
   - **Estimates:** for each task with runs, focus minutes against `duration_minutes`. For a series, its total focus minutes against `sessions × duration_minutes`. A series whose runs keep getting stopped, or that needed copies added after its runs began, ran over.
   - **Goals:** for each goal, `tasks_finished` of `tasks_total`, which steps finished in the range, and its runway (open steps). An open goal with no runway, or no run in the range, is stalled.
   - **Shape:** open tasks without a checkable `done_when`.
   - **Stale:** open one-off tasks with a `created_at` more than 7 days back and no run in the range.
   - **Balance:** the share of focus minutes that went to high, medium and low priority tasks, and to each goal; runs whose task was deleted count as unknown.
   Done: every run is counted once, and each figure traces back to tool output.
4. **Report.** A short recap: the headline numbers, goal progress, then one line per finding that matters (a task planned at 2 sessions that took 5, a high-priority goal stalled all week, most time spent on low priority). Name a pattern only when the data shows it at least twice.
5. **Tidy.** Propose concrete edits, each tied to a finding and shaped per `../TASK-SHAPE.md`: change a duration to what the task actually takes, or duplicate the task or delete a spare open copy to match the sessions the work needs, add a `done_when`, turn a task that keeps running over into a goal with steps, propose the next step of a stalled goal, finish a goal whose `done_when` is met, change a priority, delete a stale task, or check off one the user says is finished. Wait for the user to pick, then apply the chosen ones with the task and goal tools. The running task can't be deleted. Done: each applied edit is confirmed by the tool's reply, and any refusal is reported with its message.

## Standup

Read `tunnelvision_history` for the last 7 days, `tunnelvision_list_tasks` for today and for yesterday (`day` set), and `tunnelvision_list_goals`. Then write three short sections the user can paste:

- **Yesterday:** the most recent earlier day with runs (so Monday covers Friday). Tasks completed that day and the goals they moved, with focus minutes.
- **Today:** the first open tasks in list order that fit the average daily focus minutes of the last 7 days, with their goals; the running task first.
- **Blockers:** the app records none. List that day's `stopped` runs as candidates, and ask the user what is blocking them.

Make no edits in this format unless the user asks.
