# Tunnel Vision mod for Claude Code

Puts [Tunnel Vision](https://github.com/VilfredSikker/tunnel-vision)'s focus timer inside Claude Code:

- a status line with the running task and the time left
- `/tv` commands to start, pause, finish and extend sessions, and to add tasks (`/tv later`, `/tv next`)
- a task pane (`/tv`) with today's open tasks grouped by goal, and a check-in when a session runs out: Done, One more session, or a next step in the same goal
- the running task, its goal and its "done when" outcome in Claude's system prompt, so Claude keeps the work on it and says when the outcome looks met

It talks to the app over its control socket, so Tunnel Vision must be installed and running. It is a plugin of function hooks, which need a recent Claude Code build. The skills plugin (`tunnelvision`) works without it.

## Install

At the prompt of a terminal session:

```
/plugin install tunnelvision-mod --marketplace VilfredSikker/tunnel-vision
```

Answer `y` to add the marketplace, then pick a scope (user is first).

## Develop

```
claude plugin validate plugin-mod
claude plugin test plugin-mod
```
