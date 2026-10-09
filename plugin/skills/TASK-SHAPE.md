# Task shape

How every Tunnel Vision task is shaped. The skills point here whenever they create or rewrite a task or goal.

## One task, one session, one checkable outcome

- **Title:** verb-first, naming the finished outcome ("Reply to Tim's review on #142", "Draft the Q3 plan outline").
- **`done_when`:** a result the user can check at the end of the session: "PR opened", "5 open questions answered in the doc", "inbox at zero".
- **`duration_minutes`:** what the work takes in one sitting (default 25).

## Work bigger than one session

Pick one of two shapes:

- **Steady, same-shaped work** (reading, reviewing, inbox, practice): add the task once, then call `tunnelvision_duplicate_task` N-1 times. A task and its copies form a series: each copy is its own open task on the list, with its own duration, and one more session of the same work. `tunnelvision_list_tasks` reports `sessions` (tasks in the series) and `sessions_done` (how many are checked off) on every task in the series. A timer that runs out always checks the task off.
- **Work with distinct parts** heading to one outcome: a **goal** (`tunnelvision_add_goal`, with its own `done_when`) whose steps are ordinary session-sized tasks with `goal` set.

## Runway

A goal's **runway** is its open steps on the list. Keep 1–3 steps of runway per open goal: enough that the next session is always ready, few enough that the list stays honest. Add the next step as one finishes; leave later steps unwritten until the work ahead shows what they are. A goal with zero runway stalls, so propose its next step.

## Capacity

Open tasks need the sum of their `duration_minutes` in focus time; each copy in a series counts as its own task. Sessions left in a series is `sessions - sessions_done`; for a `repeat_daily` task, `sessions_done` counts today only.

## Finishing a goal

`tunnelvision_update_goal` with `done: true` finishes the goal and leaves its open steps on the list. Before finishing one, check off, detach (`goal: ""`), or delete each open step, as the user chooses.
