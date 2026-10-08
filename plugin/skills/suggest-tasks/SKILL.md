---
name: suggest-tasks
description: Suggest new Tunnel Vision tasks and goals from the work around the user — the current repo, open pull requests, the conversation, and connected tools like an issue tracker or calendar. Use when the user asks what they should work on, or wants work from somewhere turned into focus tasks.
---

# Suggest tasks

Find work the user hasn't put on their Tunnel Vision list yet, shape each piece as a focus task or goal, and add the ones they pick.

The Tunnel Vision tools are named `tunnelvision_*`; they may carry a server prefix. If none are available, the app is not running or the MCP server is not connected: say so and stop.

## Steps

1. **Read the list.** Call `tunnelvision_list_tasks`, `tunnelvision_list_goals` and `tunnelvision_list_presets`. Done: you know every open task and open goal (to avoid duplicates and to file findings under) and the preset names you can assign.
2. **Gather.** Look through each source that is actually available, quickly:
   - **This conversation:** commitments, follow-ups, and open questions the user mentioned.
   - **The current repo**, when there is one: uncommitted work, branches ahead of the default branch, and the user's open pull requests and requested reviews (`gh pr list --author @me`, `gh pr list --search "review-requested:@me"`).
   - **Connected tools:** an issue tracker (issues assigned to the user, in progress or due soon), a calendar (meetings that need prep), and chat (direct asks of the user).
   - **History:** `tunnelvision_history` for the last 7 days; a task stopped early or run many times may need a follow-up.
   Done: every listed source was checked or noted as unavailable.
3. **Shape.** Read `../TASK-SHAPE.md`, then turn each finding into a task:
   - Title, `done_when` and `duration_minutes` per `../TASK-SHAPE.md`; for steady work bigger than one session, one task plus N-1 copies (`tunnelvision_duplicate_task`).
   - `priority`: high for deadlines today and work blocking someone; low for nice-to-haves; medium otherwise.
   - `preset`: the existing preset that fits the work (Coding for repo work, Comms for replies, Writing for drafts), or none.
   - **Goal:** when a finding is a step toward an open goal, set that goal. When several findings share one outcome no goal covers, propose a new goal (title, `done_when`) with those findings as its first 1–3 steps of runway; leave the rest unwritten.
   Drop any finding already covered by an open task. Done: up to 8 suggestions, each with a source, each passing `../TASK-SHAPE.md`.
4. **Propose.** Show a table: title, goal (marking new ones), minutes (and sessions, for a series), priority, preset, `done_when`, and where it came from. Wait for the user to pick.
5. **Add.** For each picked new goal, call `tunnelvision_add_goal` first; then call `tunnelvision_add_task` for each picked task, with `goal` set where it has one, and `tunnelvision_duplicate_task` for each extra session of a series. New tasks land at the end of the list; offer to run the `plan-day` skill to fit them into today. Done: `tunnelvision_list_goals` and `tunnelvision_list_tasks` show every pick, under the right goal.
