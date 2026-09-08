# Feasibility: locking apps, windows and URLs during a Pomodoro on macOS

Investigated 2026-09-02 on macOS 26.4.1 with Xcode 26.6. Everything below was checked
against the installed SDK or the installed browsers, except where marked "verify".

## Verdict

Feasible, in three layers with rising precision and rising permission cost.
Enforcement is soft by nature: you own the machine, so every mechanism can be undone
by quitting the timer app. That is acceptable for a self-discipline tool and is how
every focus app on the Mac works outside of MDM.

| Layer | What it locks | Mechanism | Permission | Status |
| --- | --- | --- | --- | --- |
| 1 | Whole apps | NSWorkspace notifications + NSRunningApplication hide/terminate, optional SIGSTOP | none | public API, typechecked |
| 2 | Single windows inside an app | Accessibility API (AXUIElement, AXObserver) | Accessibility (one TCC prompt) | public API, typechecked |
| 3a | URLs in Chromium browsers | Chromium enterprise policy via `defaults write <bundle-id> URLBlocklist/URLAllowlist` | none | policy strings present in Helium binary, live behaviour to verify |
| 3b | Browser window and tab | AppleScript (Automation permission) via the browser's scripting dictionary | Automation (one prompt per browser) | Helium and Chrome both ship `scripting.sdef` |
| 3c | URLs, precise | Browser extension with declarativeNetRequest allowlist + native messaging | install per browser | standard, more work |
| 3d | Domains everywhere | NetworkExtension `NEFilterDataProvider` system extension | Network Extension entitlement, Developer ID, user approval | macOS 10.15+, overkill for v1 |

## Dead end: Apple's Screen Time API

FamilyControls, ManagedSettings and DeviceActivity are the official "shield this app"
API. In the macOS 26 SDK every declaration in all three frameworks is annotated
`@available(macOS, unavailable)` with zero positive macOS availability. They exist in
the SDK only for Mac Catalyst (`System/iOSSupport`). A Catalyst app would also need the
Family Controls entitlement, which needs a paid team and Apple approval for
distribution, and Catalyst is a poor fit for a menu bar utility. Not pursued.

## Layer 1: app lock

Observe `NSWorkspace.didActivateApplicationNotification` and
`didLaunchApplicationNotification`. For any app not on the task's allowlist:

- Dark: `NSRunningApplication.hide()`. The app stays running, drops out of view.
- Closed: `NSRunningApplication.terminate()` on launch or activation.
- Frozen: `hide()` then `kill(pid, SIGSTOP)`; `SIGCONT` at session end.

None of these need a TCC permission. `hide()` and `terminate()` work from the
process manager without Accessibility or Automation.

Caveats:

- Roughly one frame of flicker: the disallowed app appears, then is hidden.
- SIGSTOP freezes the process completely. Network sessions may drop, the Dock shows
  the app as not responding, and if the timer app dies the victims stay frozen. Keep a
  frozen-pid list on disk and thaw on next launch. Recommend hide-and-close as the
  default and freeze as opt-in.
- SIGSTOP on other processes needs a non-sandboxed app. Fine for a personal tool.
- The "dark" look can be pushed further with a black translucent NSWindow ordered
  directly below the allowed app's windows. `NSWindow.order(.below, relativeTo:)`
  accepts a window number from another app. This is how HazeOver dims. Verify at
  runtime in a spike.

## Layer 2: one window inside an app

Accessibility API on the target process:

- `AXUIElementCreateApplication(pid)` then read `kAXWindowsAttribute`.
- Set `kAXMinimizedAttribute` on every window except the allowed one, or raise the
  allowed one with `kAXRaiseAction`.
- `AXObserver` on `kAXWindowCreatedNotification` and
  `kAXFocusedWindowChangedNotification` to react instead of polling.
- Identify the allowed window across restarts by title, or by CGWindowID through the
  private `_AXUIElementGetWindow` (present in the SDK's HIServices.tbd, used by
  yabai, AltTab and Rectangle).

Needs the Accessibility permission, which macOS ties to a stable bundle identifier and
code signature. The app therefore has to ship as a signed `.app` bundle, ad-hoc
signing is enough for personal use.

## Layer 3: URLs

Browsers on this Mac: Helium 0.15.1 (default https handler, `net.imput.helium`),
Google Chrome 152, Brave (`com.brave.Browser`), Firefox, Safari.

### 3a. Chromium policy (recommended first)

Chromium reads managed preferences from the app's own preference domain. Writing
these two keys turns the browser into allowlist mode with a native "blocked" page:

```sh
defaults write net.imput.helium URLBlocklist -array '*'
defaults write net.imput.helium URLAllowlist -array 'docs.google.com' 'github.com/org/repo'
```

Remove both keys at session end. Same for `com.google.Chrome` and `com.brave.Browser`.
Firefox has the equivalent through `org.mozilla.firefox` with `EnterprisePoliciesEnabled`
and `WebsiteFilter`.

Verified: the Helium framework binary still contains the `URLBlocklist`,
`URLAllowlist`, `ExtensionInstallForcelist` and `chrome://policy` strings, so the
policy machinery was not stripped by the ungoogled base.

To verify live: that Helium honours user-level (not just `/Library/Managed
Preferences`) values, and how quickly it reloads after a change. Chrome picks up Mac
policy changes without a restart; measure the lag on Helium. Side effect while
active: a "Managed by your organization" badge in the menu.

### 3b. AppleScript for window and tab control

Helium's `scripting.sdef` matches Chrome's: windows expose `id`, `index`,
`minimized`, `active tab`, `close`; tabs expose `URL` (read and write), `loading`,
`go back`, `reload`, `execute` (JavaScript). This gives "only this one browser
window": minimize every window whose id is not the allowed one, and steer the active
tab back when its URL leaves the allowlist. Polling at 500 ms is cheap. Needs the
Automation permission, one prompt per browser.

### 3c. Browser extension

Chromium `declarativeNetRequest` with a low-priority block-all rule and higher
priority allow rules blocks navigations before they load, per tab, with no policy
badge. The extension gets the allowlist from the menu bar app over native messaging
or a localhost endpoint. Safari gets a bundled content blocker extension instead.
More moving parts: must be installed in each browser. Worth it only if 3a's reload
lag or the badge is unacceptable.

### 3d. Network filter

`NEFilterDataProvider` (macOS 10.15+, `remoteHostname` from macOS 11) blocks domains
for every process on the machine, including embedded web views. Costs the Network
Extension entitlement, Developer ID signing and a system extension approval dialog.
Domain level only; a single URL path cannot be distinguished without TLS interception.
Not needed for v1.

## Proposed build order

1. Menu bar app (SwiftUI `MenuBarExtra`, macOS 14+ target), timer, task list with
   per-task allowlist. Non-sandboxed, `LSUIElement` so it has no Dock icon.
2. Layer 1 enforcer with dark / closed / frozen modes and a crash-safe thaw file.
3. Layer 3a Chromium policy writer for Helium, Chrome, Brave.
4. Layer 2 Accessibility window lock, plus 3b AppleScript for browser windows.
5. Optional: dim overlay, Safari content blocker, extension.

## Spikes before committing

1. Helium policy live test: write the two keys, open a blocked site, time the reload,
   remove the keys. About 20 minutes, no code.
2. Minimize a background Helium window through AX from a signed test bundle. Confirms
   the permission flow and the window identification strategy.
3. Cross-app `order(.below, relativeTo:)` for the dim overlay.

## Open items

- Code signing identities could not be listed in this session. Ad-hoc signing works
  for personal use. A Developer ID is only needed for 3d.
- A hard mode (timer cannot be quit early) needs a launchd agent that relaunches the
  app, and a rule in the app that refuses to stop before the timer ends. Design
  decision, not a feasibility question.

## Picking apps and windows (added 2026-09-02)

Goal: choosing what a task allows should feel like Mission Control. Click windows to
include or exclude, done.

The real Mission Control is closed. It renders inside the Dock process, has no public
API, no overlay hook, and a click on a window always switches to it. Three ways to get
the same feel:

| Option | UI | Permission | Fit |
| --- | --- | --- | --- |
| A. Own exposé overlay | Full-screen grid of live window thumbnails grouped by app, click toggles a badge | Screen Recording for thumbnails, falls back to icon + title tiles without it | best, recommended |
| B. System picker `SCContentSharingPicker` | Apple's window/app picker with thumbnails, multi-select | none expected for the picker itself, verify | zero UI code, wording is about "sharing" |
| C. Real Mission Control round trip | Launch `com.apple.exposelauncher`, record the window the user clicks, reopen, repeat until Esc | none | clunky, no feedback inside Mission Control |

### A. Own exposé overlay

- Enumerate on-screen windows with `SCShareableContent` (window id, title, frame,
  owning app) or, without Screen Recording, with the Accessibility API which we need
  anyway for Layer 2.
- Thumbnails per window through `SCScreenshotManager.captureImage` with an
  `SCContentFilter(desktopIndependentWindow:)`. macOS 14+. One capture pass when the
  overlay opens, no live stream.
- Borderless window per display at a level above normal windows, dimmed background,
  tiles laid out in a packed grid like Mission Control. Click a tile to include the
  window, click the app header to include the whole app, click again to exclude, Esc
  or Done to close.
- Cost of thumbnails: the Screen Recording prompt, plus the macOS 15+ periodic
  "has accessed your screen" re-approval nag. Ship the icon + title fallback first,
  add thumbnails behind a toggle.

### B. System picker

`SCContentSharingPicker` presents Apple's own picker in window or application mode.
From macOS 15.2 the resulting `SCContentFilter` exposes `includedWindows` and
`includedApplications`, each with window id, title and owning app, so the selection
is readable. Limits: one mode per presentation, no include versus exclude badge, the
button says Share. Good enough for a first cut if we want to skip building the grid.
Verify whether presenting it triggers the Screen Recording prompt.

### What a click stores

Window ids die with the window, so a pick is turned into a rule:

```
Rule { bundleID, scope: .app | .window(titlePattern) | .url(pattern), effect: .allow | .deny }
```

The picker proposes the title pattern from the clicked window and lets the user
generalise it to the whole app. Browser windows get a URL pattern from the
AppleScript tab URL instead of the title. Deny rules only matter for "whole app except
this window".

### Quick adjustments during a session

Two small additions make upfront configuration mostly unnecessary:

- Hotkey pick: while a lock runs, press a hotkey and click any window to allow it for
  this session. `AXUIElementCopyElementAtPosition` under the cursor gives the window.
- Blocked-app prompt: when the enforcer hides or closes an app, the menu bar item
  offers "allow for this session" and "add to preset". Allowlists grow from real use.

## Presets

- A preset is a named list of rules plus a default mode (dark, closed, frozen) and an
  optional set of URLs to open when the task starts.
- Built-ins to ship: Coding (editor, terminal, browser limited to docs and the repo),
  Writing (Obsidian only), Comms (Slack, Mail), Reading (browser, one URL).
- Tasks reference a preset and may override rules. A new task inherits the last used
  preset so the common path is one click.
- "Save current as preset" snapshots the picker state. Presets live as a JSON file in
  Application Support so they can be edited or versioned by hand.

## Layers 2 and 3 as built (2026-09-03)

Layer 2 (`WindowEnforcer`): an app allowed only through window rules keeps the
windows whose title matched a rule; every other standard window in it is minimised
through `kAXMinimizedAttribute` and brought back at session end. A window that matched
once stays allowed for the session by CGWindowID (via `_AXUIElementGetWindow`), so an
editor switching files does not lose its window; new windows are judged by title. An
`AXObserver` per app (window created, focused, deminiaturised, retitled) triggers a
sweep, with a one-second sweep as the safety net. Untitled windows get 1.5 s of grace
before they count as non-matching. Dialogs, sheets and palettes are ignored. Without
the Accessibility permission the layer is inert and a window rule allows the whole app.

Layer 3: option 3a (Chromium policy through `defaults write`) was not built. From
Chromium's `policy_loader_mac` source (recalled, not re-read in this session), the Mac
loader only watches `/Library/Managed Preferences/<user>/<bundle>.plist` and otherwise
reloads on a 15-minute timer, so a user-level write would not be seen at session start,
and Firefox reads policies only at launch. The spike is still worth 20 minutes if the
badge-free extension route ever matters.

Built 3b instead (`BrowserEnforcer`): once a second, each managed browser that is
running and has site rules is asked over its scripting dictionary for every window's
id, title, minimised state, active tab and tab URLs. A window whose active tab is a web
page off the allowlist is steered: to another tab of the same window that is allowed,
else back to the page it last showed while allowed, else to the first site rule as a
URL. Non-web pages (`chrome://newtab`, `about:blank`) never count. Site rules are
`host[/path]` patterns matching the host and its subdomains and the path at a segment
boundary; the picker offers "this page" or "whole site" per browser window. Safari and
the Chromium family are supported; Firefox is not scriptable and its site rules allow
the whole app. Settings lists the installed browsers with a switch each. A browser that
declines Automation is left alone. Nothing is persisted, so a crash leaves the browser
as it is.

## Control socket and MCP (2026-09-03)

Tunnel Vision listens on `~/Library/Application Support/TunnelVision/control.sock` (mode 0600,
newline-delimited JSON, `{"id","method","params"}` in, `{"id","result"|"error"}` out)
while it runs. `ControlAPI` maps the methods onto the model: `state.get`,
`tasks.list|add|update|delete|reorder|set_done`, `presets.list|create|update|delete`,
`session.start|pause|resume|stop|done|skip_break|extend`, `apps.list`. Rules are
`{bundle_id|app, scope, pattern}`; an app name resolves through running apps and
/Applications.

`tunnelvision-mcp` (Sources/TunnelVisionMCP, bundled at `TunnelVision.app/Contents/Helpers/tunnelvision-mcp`)
is a stdio MCP server exposing those methods as `tunnelvision_*` tools and forwarding each
call over the socket; if the socket is missing it launches Tunnel Vision with `open -b` and
waits for it. Register with `make mcp-register` (runs `claude mcp add --scope user
tunnelvision -- …/tunnelvision-mcp`). The wire format, the blocking client, the JSON-RPC handling
and the tool schemas live in the `TunnelVisionControlKit` library so both executables and
the tests share them. Editing `data.json` directly while the app runs would be
clobbered by the app's next persist, which is why the socket exists.
