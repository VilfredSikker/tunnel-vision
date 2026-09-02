# Design brief: Pomodoro Cop (working name)

## What it is

A macOS menu bar Pomodoro timer that locks your Mac down to the one task in front of
you. You keep a short list of tasks. Each task carries an allowlist of apps, windows
and URLs. When you start a task, every other app goes dark, closes, or freezes until
the timer ends or you finish the task. Setup happens visually: an exposé-style
overlay shows every open window and you click the ones you want to keep.

It is a personal discipline tool, single user, no accounts, no sync. It should feel
like a native macOS utility: calm, quiet, keyboard friendly, native controls, light
and dark appearance.

## Vocabulary

- Task: a thing to do, with a title, a duration, and a preset or custom allowlist.
- Session: one timed run of a task. Ends on timer, on "done", or on an early stop.
- Break: the untimed or short timed pause after a session. Everything is unlocked.
- Preset: a named, reusable allowlist plus a default mode. Built-in or user made.
- Rule: one entry in an allowlist. Scope is a whole app, a window matched by title,
  or a URL pattern inside a browser.
- Mode: what happens to apps that are not allowed. Dark hides them. Closed quits
  them. Frozen pauses them in place and resumes them afterwards.

## Surfaces and features

### 1. Menu bar item

- Idle: small icon only.
- Running: icon plus remaining time, optionally the task title truncated.
- Break: distinct icon state and break countdown.
- Paused: visibly paused state.
- Click opens the main panel. Right click or long press gives quick actions: pause,
  skip to break, end session, open picker.

### 2. Main panel (popover from the menu bar)

- Current task at the top with a large remaining time, progress ring or bar, and
  buttons for start, pause, done, and stop.
- Preset chip on the current task, click to change or edit.
- Today's task list below: reorder by drag, check off, add inline. Each row shows
  title, duration, preset name and a small icon strip of the allowed apps.
- Add task: title, duration picker with defaults of 25 and 50 minutes, preset dropdown
  pre-filled with the last used preset, and an "edit allowlist" link that opens the
  picker overlay.
- Footer: presets, settings, quit.

### 3. Picker overlay (the exposé)

- Full screen on every display, dimmed backdrop, every open window as a tile packed
  in a grid and grouped by app, close to Mission Control in feel.
- Tile shows the window thumbnail when available, otherwise the app icon and window
  title.
- Click a tile to include that window. Click the app header to include the whole app.
  Click again to exclude. Included tiles get a clear positive badge and full
  brightness, excluded tiles stay dimmed.
- Browser windows show the current tab URL and offer "this URL", "this site", or
  "whole browser" as the rule scope.
- Search field to filter tiles by app or title.
- Bottom bar: summary of what is allowed, mode selector (Dark, Closed, Frozen), "Save
  as preset", Cancel, Done. Esc cancels.

### 4. Presets manager

- List of presets with built-ins marked. Built-ins to ship: Coding, Writing, Comms,
  Reading.
- Preset detail: name, mode, rule list, URLs to open when a task starts. Rules are
  editable inline with scope and pattern fields. "Pick visually" opens the overlay
  pre-filled with the preset's rules.
- Duplicate, rename, delete. Built-ins can be duplicated and edited, not deleted.

### 5. Session behaviour

- Starting a task applies the allowlist immediately. A short confirmation shows what
  is now locked.
- When a blocked app is opened during a session, it is hidden, closed or frozen at
  once, and a small non-blocking notice appears near the menu bar with two actions:
  "allow for this session" and "add to preset". Keyboard shortcut to dismiss.
- Hotkey pick: press a hotkey, click any window, it is allowed for this session.
- Ending a session early has friction: hold the stop button for two seconds, or in
  strict mode type the task title. Strict mode is a setting.
- Session end: sound, everything unlocks, break starts. Break panel shows the next
  task and "start next" or "skip break".
- Marking a task done ends the session and checks the task off.

### 6. Onboarding and permissions

- First launch explains the three permissions and what each unlocks. Accessibility
  for window level control. Automation per browser for tab URLs. Screen Recording,
  optional, only for thumbnails in the picker.
- Each permission has its own step with a "grant" button that deep links to System
  Settings and a status indicator. The app works with fewer permissions and says what
  is missing.

### 7. Settings

- Default durations for work and break.
- Default mode for new presets.
- Strict mode on or off.
- Sounds and notifications.
- Launch at login.
- Hotkeys: start or pause, open picker, hotkey pick.
- Browsers to manage, with a note that a managed badge appears in the browser while a
  session runs.

## Design constraints

- Native macOS look, SF Symbols, system materials in the popover, system fonts.
- Popover width around 340 points, height grows with the task list up to a limit.
- Overlay must work on multiple displays and with many windows, forty or more.
- Light and dark appearance throughout, including the overlay.
- Keyboard first: every action in the popover and overlay reachable without a mouse.
- No gamification, no streaks, no confetti. The tone is a quiet assistant.
- Colours: one accent for included or allowed, one muted red for blocked or excluded,
  neutral for everything else.

## Out of scope for v1

- iOS companion, sync, accounts.
- Statistics dashboards beyond a count of sessions completed today.
- Blocking at the network level or inside Safari.
- Calendar integration.

## Screens to design

1. Menu bar item in idle, running, paused and break states.
2. Main panel: idle with task list, running, break.
3. Add or edit task.
4. Picker overlay: empty selection, partial selection, browser window scope choice,
   save as preset.
5. Presets manager: list and detail.
6. Blocked app notice.
7. Early stop friction, normal and strict.
8. Onboarding permission steps.
9. Settings.
