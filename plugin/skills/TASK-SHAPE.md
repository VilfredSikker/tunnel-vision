# Task shape

How every Tunnel Vision task is shaped. The skills point here whenever they create or rewrite a task or goal.

## One task, one pomodoro, one checkable outcome

Tunnel Vision is a pomodoro timer: each task is one focus session, followed by a break. Keep tasks that small, so each break lands on a finished outcome.

- **Title:** verb-first, naming the finished outcome ("Reply to Tim's review on #142", "Draft the Q3 plan outline").
- **`done_when`:** a result the user can check at the end of the session: "PR opened", "5 open questions answered in the doc", "inbox at zero".
- **`duration_minutes`:** one pomodoro. Leave it out to get the settings default (25). Go up to 50 only for deep work that loses more to a mid-way break than it gains; never past 50.
- **`checklist`:** optional, for the 2–5 moves inside the session ("read the failing test", "patch the parser", "rerun the suite"). A checklist splits one session into its moves; it never makes a task longer.

## Work bigger than one session

When the work needs more than 50 minutes, or its honest estimate is more than one pomodoro, split it before creating anything. Never stretch one task to cover it. Pick one of two shapes:

- **Steady, same-shaped work** (reading, reviewing, inbox, practice): add the task once, then call `tunnelvision_duplicate_task` N-1 times. A task and its copies form a series: each copy is its own open task on the list, with its own duration, and one more session of the same work. `tunnelvision_list_tasks` reports `sessions` (tasks in the series) and `sessions_done` (how many are checked off) on every task in the series. A timer that runs out always checks the task off.
- **Work with distinct parts** heading to one outcome: a **goal** (`tunnelvision_add_goal`, with its own `done_when`) whose steps are ordinary session-sized tasks with `goal` set. Each step names its own checkable outcome ("Script copies one plate's media with copy_object", "Rerun copies nothing and source ETags are unchanged"), never "part 2 of 3".

Prefer a goal when the parts differ; a series of "keep going on X" sessions hides where the work stands. Use a series only when every session does the same kind of work.

## Runway

A goal's **runway** is its open steps on the list. Keep 1–3 steps of runway per open goal: enough that the next session is always ready, few enough that the list stays honest. Add the next step as one finishes; leave later steps unwritten until the work ahead shows what they are. A goal with zero runway stalls, so propose its next step.

## Capacity

Open tasks need the sum of their `duration_minutes` in focus time; each copy in a series counts as its own task. Sessions left in a series is `sessions - sessions_done`; for a `repeat_daily` task, `sessions_done` counts today only.

## Finishing a goal

`tunnelvision_update_goal` with `done: true` finishes the goal and leaves its open steps on the list. Before finishing one, check off, detach (`goal: ""`), or delete each open step, as the user chooses.
