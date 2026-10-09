import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { CheckIn, Priority, Snapshot, Task, TVState } from '../types'
import {
  HAND_OFF_AFTER_MS,
  NOT_RUNNING,
  SOCKET,
  addParams,
  checkInChoices,
  clock,
  contextGoal,
  describe,
  focusSection,
  groupByGoal,
  isSessionRunning,
  matchTask,
  nextCheckIn,
  nextUpOrder,
  openTasks,
  sortedTasks,
  parseResponse,
  remaining,
  requestLine,
  sessionsDone,
  skillPrompt,
  statusText,
  transitionText,
} from './tv'
import type { Request } from './tv'

const PANE = 'tunnel-vision'
const POLL_EVERY = 5 // ticks of one second
const SECTION_ID = 'tunnel-vision:focus'

const EMPTY: Snapshot = { state: null, tasks: [], fetchedAt: 0, error: null }
const snapshot = atom({ plugin: 'tunnelvision-mod', key: 'snapshot' } as const, EMPTY)
const checkIn = atom({ plugin: 'tunnelvision-mod', key: 'checkIn' } as const, null as CheckIn | null)

const USAGE = [
  '/tv                 status, and open the task pane',
  '/tv close           close the task pane (or Esc in it)',
  '/tv status          status only',
  '/tv start [task]    start a task by title fragment (next up when left out)',
  '/tv pause | resume  pause or resume the running session',
  '/tv done            check the running task off and take the break',
  '/tv stop            end the session early, no credit',
  '/tv extend [min]    add minutes to the session (5 when left out)',
  '/tv skip            skip the break',
  '/tv later <title>   add a low-priority task, in the current task’s goal',
  '/tv next <title>    add a task in the current task’s goal and make it next up',
  '/tv bg [note]       hand this conversation’s work to this agent as a background task',
  '/tv task [note]     turn this conversation’s work into a focus task for you',
  '/tv plan | review | eod | breakdown | suggest   run that Tunnel Vision skill',
].join('\n')

type Outcome = { ok: boolean; text: string }

// Read by `prompt.compose`, which runs before every request: a module
// variable keeps that path free of host calls.
let latest: TVState | null = null
let ticks = 0

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** One request over Tunnel Vision's control socket. The engine has no socket noun, so it is one `nc -U` run. */
async function call(
  $: EngineInterface,
  method: string,
  params: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const home = await $.env.get('HOME')
  if (!home) throw new Error('HOME is not set')
  const ran = await $.process.run(['/usr/bin/nc', '-U', `${home}/${SOCKET}`], {
    stdin: requestLine(method, params),
    timeoutMs: 5000,
  })
  if (ran.exitCode !== 0 || ran.stdout.trim() === '') {
    // nc's own words tell a missing app from a refused socket (a sandbox).
    const why = ran.stderr.trim().slice(0, 160)
    throw new Error(`${NOT_RUNNING} (nc exited ${ran.exitCode}${why ? `: ${why}` : ''})`)
  }
  return parseResponse(ran.stdout)
}

/**
 * Polls state and tasks, stores them, toasts a phase change and keeps the
 * check-in. `checkedOff` is a poll right after `/tv done`, which already
 * says how the session went, so it starts no check-in.
 */
async function refresh($: EngineInterface, checkedOff = false): Promise<Snapshot> {
  const before = latest
  let next: Snapshot
  try {
    const { state } = await call($, 'state.get')
    const { tasks } = await call($, 'tasks.list')
    next = { state: state as TVState, tasks: tasks as Task[], fetchedAt: await $.clock.now(), error: null }
  } catch (error) {
    next = { ...EMPTY, fetchedAt: await $.clock.now(), error: message(error) }
  }
  latest = next.state
  await update($, snapshot, () => next)
  if (before && next.state) {
    const found = nextCheckIn(before, next.state)
    const kept = checkedOff && found ? null : found
    if (kept !== undefined) await update($, checkIn, () => kept)
    const said = transitionText(before, next.state)
    if (said && kept) $.ui.toast(`${said} · How did “${kept.title}” go? /tv to check in`)
    else if (said) $.ui.toast(said)
  }
  return next
}

async function paint($: EngineInterface): Promise<void> {
  const snap = await read($, snapshot)
  const left = snap.state ? remaining(snap.state, snap.fetchedAt, await $.clock.now()) : undefined
  $.ui.status(statusText(snap.state, left))
}

async function tick($: EngineInterface): Promise<void> {
  ticks += 1
  if (ticks % POLL_EVERY === 0) await refresh($)
  await paint($)
}

/** Runs one session method, refreshes, and says what happened. */
async function act($: EngineInterface, method: string, params: Record<string, unknown> = {}): Promise<Outcome> {
  try {
    await call($, method, params)
  } catch (error) {
    return { ok: false, text: message(error) }
  }
  const snap = await refresh($, method === 'session.done')
  await paint($)
  const left = snap.state ? remaining(snap.state, snap.fetchedAt, snap.fetchedAt) : undefined
  return { ok: true, text: describe(snap.state, left) }
}

async function start($: EngineInterface, query: string): Promise<Outcome> {
  const snap = await refresh($)
  if (!snap.state) return { ok: false, text: describe(null, undefined) }
  const found = matchTask(snap.tasks, query, snap.state.next_up)
  if ('error' in found) return { ok: false, text: found.error }
  return act($, 'session.start', { id: found.task.id })
}

/**
 * `/tv later` (low) and `/tv next` (medium): adds the task in the current
 * goal, and for next moves it up to follow the running task.
 */
async function addTask($: EngineInterface, title: string, priority: Priority): Promise<Outcome> {
  const verb = priority === 'low' ? 'later' : 'next'
  if (title.trim() === '') return { ok: false, text: `Give it a title: /tv ${verb} <title>.` }
  const snap = await refresh($)
  if (!snap.state) return { ok: false, text: describe(null, undefined) }
  const goal = contextGoal(snap.state, snap.tasks, await read($, checkIn))
  let added: Task
  try {
    added = (await call($, 'tasks.add', addParams(title, priority, goal))).task as Task
  } catch (error) {
    return { ok: false, text: message(error) }
  }
  const where = goal ? ` to “${goal.title}”` : ''
  let text = `Added “${added.title}”${where} for later.`
  if (priority === 'medium') {
    const running = isSessionRunning(snap.state.phase) ? snap.state.active_task?.id : undefined
    try {
      await call($, 'tasks.reorder', { ids: nextUpOrder(added.id, running) })
      text = `Added “${added.title}”${where} as next up.`
      const sort = snap.state.task_sort
      if (sort && sort !== 'manual') text += ` The panel sorts by ${sort}; set it to manual to see this order.`
    } catch (error) {
      text = `Added “${added.title}”${where}, though moving it up failed: ${message(error)}`
    }
  }
  await refresh($)
  await paint($)
  return { ok: true, text }
}

/** A pane button's press: only a failure needs saying, the pane redraws itself. */
async function press($: EngineInterface, method: string, params: Record<string, unknown> = {}): Promise<void> {
  const done = await act($, method, params)
  if (!done.ok) $.ui.toast(done.text)
}

/** A check-in answer: runs its requests in order, then ends the check-in. */
async function answer($: EngineInterface, requests: Request[]): Promise<void> {
  try {
    for (const request of requests) await call($, request.method, request.params)
  } catch (error) {
    $.ui.toast(message(error))
  }
  await update($, checkIn, () => null)
  await refresh($)
  await paint($)
}

async function nextStep($: EngineInterface, title: string): Promise<void> {
  const added = await addTask($, title, 'medium')
  if (added.ok) await update($, checkIn, () => null)
  $.ui.toast(added.text)
}

async function closePane($: EngineInterface): Promise<void> {
  await $.ui.close({ id: PANE })
}

async function status($: EngineInterface): Promise<string> {
  const snap = await refresh($)
  const left = snap.state ? remaining(snap.state, snap.fetchedAt, snap.fetchedAt) : undefined
  return describe(snap.state, left)
}

/**
 * Hands a skill prompt to Claude as the person's own, once the command's
 * answer has printed. The engine refuses a submit made inside a `command.run`
 * hook (it would wait on the turn the hook holds), so a timer submits after
 * the hook has returned; a refusal is said in a toast, never swallowed.
 */
function handOff($: EngineInterface, prompt: string): void {
  $.clock.after(HAND_OFF_AFTER_MS, () => {
    void $.prompt.submit({ text: prompt, asUser: true }).catch(error => {
      $.ui.toast(`Could not hand it to Claude: ${message(error)}`)
    })
  })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'tv',
      description: 'Tunnel Vision: status, start/pause/done/stop a focus session, add tasks, open the task pane',
      argumentHint:
        '[close | status | start <task> | pause | resume | done | stop | extend <min> | skip | later <title> | next <title> | bg [note] | task [note] | plan | review | eod | breakdown | suggest | help]',
      immediate: true,
    })
    await refresh($)
    await paint($)
    $.clock.every(1000, () => tick($))
    return next(e)
  })

  on('command.run', { command: 'tv' }, async ($, e) => {
    const [verb = '', ...rest] = e.args.trim().split(/\s+/)
    const arg = rest.join(' ')
    switch (verb.toLowerCase()) {
      case '': {
        await $.ui.open({ id: PANE, title: 'Tunnel Vision', closeOnEscape: true })
        const text = await status($)
        const pending = await read($, checkIn)
        return { text: pending ? `${text} Check in on “${pending.title}” in the pane.` : text }
      }
      case 'close':
        await closePane($)
        return { text: 'Task pane closed.' }
      case 'status':
        return { text: await status($) }
      case 'start':
        return { text: (await start($, arg)).text }
      case 'pause':
        return { text: (await act($, 'session.pause')).text }
      case 'resume':
        return { text: (await act($, 'session.resume')).text }
      case 'done':
        return { text: (await act($, 'session.done')).text }
      case 'stop':
        return { text: (await act($, 'session.stop')).text }
      case 'skip':
        return { text: (await act($, 'session.skip_break')).text }
      case 'extend': {
        const minutes = arg === '' ? 5 : Number.parseInt(arg, 10)
        if (!Number.isFinite(minutes) || minutes <= 0) return { text: 'extend takes a number of minutes.' }
        return { text: (await act($, 'session.extend', { minutes })).text }
      }
      case 'later':
        return { text: (await addTask($, arg, 'low')).text }
      case 'next': {
        const added = await addTask($, arg, 'medium')
        if (added.ok) await update($, checkIn, () => null)
        return { text: added.text }
      }
      default: {
        // Skill verbs need Claude to read the conversation: the prompt runs
        // as the person's own turn once the session is idle.
        const prompt = skillPrompt(verb, arg)
        if (!prompt) return { text: USAGE }
        handOff($, prompt)
        return { text: `Handing it to Claude: ${prompt}` }
      }
    }
  })

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    const text = focusSection(latest)
    if (!text) return composed
    return {
      sections: [
        ...composed.sections.filter(section => section.id !== SECTION_ID),
        { id: SECTION_ID, text, scope: 'session' as const },
      ],
    }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const elements = $.ui.resolve(e)
    const { Box, Button, Text } = elements
    // The mobile app draws no text field; there the check-in names the command instead.
    const Input = e.surface !== 'mobile' && 'Input' in elements ? elements.Input : undefined
    const snap = await read($, snapshot)
    const pending = await read($, checkIn)
    const { state } = snap

    if (!state) {
      return (
        <Box flexDirection="column">
          <Text dimColor>{snap.error ?? 'Loading…'}</Text>
          <Button key="retry" label="Retry" onPress={() => refresh($)} />
        </Box>
      )
    }

    const left = remaining(state, snap.fetchedAt, await $.clock.now())
    const running = isSessionRunning(state.phase)
    const open = sortedTasks(openTasks(snap.tasks), state.task_sort)
    const finished = snap.tasks.filter(task => task.done)
    const ended = pending ? snap.tasks.find(task => task.id === pending.taskId) : undefined
    const choices = checkInChoices(ended)

    return (
      <Box flexDirection="column">
        <Text bold>{describe(state, left)}</Text>
        <Box flexDirection="row" gap={1}>
          {state.phase === 'work' && (
            <Button key="pause" label="Pause" hotkey="p" onPress={() => press($, 'session.pause')} />
          )}
          {state.phase === 'paused' && (
            <Button key="resume" label="Resume" hotkey="r" onPress={() => press($, 'session.resume')} />
          )}
          {running && (
            <Button key="done" label="Done" hotkey="d" variant="primary" onPress={() => press($, 'session.done')} />
          )}
          {running && (
            <Button key="extend" label="+5 min" hotkey="e" onPress={() => press($, 'session.extend', { minutes: 5 })} />
          )}
          {state.phase === 'break' && (
            <Button key="skip" label="Skip break" hotkey="s" onPress={() => press($, 'session.skip_break')} />
          )}
          <Button key="close" label="Close" hotkey="x" dimColor onPress={() => closePane($)} />
        </Box>
        {pending && (
          <Box key="checkin" flexDirection="column">
            <Text> </Text>
            <Text bold>Session over: {pending.title}</Text>
            {choices.sessionsLeft && <Text dimColor>{choices.sessionsLeft}, so it stays on the list.</Text>}
            <Box flexDirection="row" gap={1}>
              {choices.done && (
                <Button
                  key="checkin-done"
                  label="Done"
                  hotkey="c"
                  variant="primary"
                  onPress={() => answer($, choices.done ? [choices.done] : [])}
                />
              )}
              {choices.oneMore && (
                <Button
                  key="checkin-more"
                  label="One more session"
                  hotkey="o"
                  onPress={() => answer($, choices.oneMore ?? [])}
                />
              )}
              <Button key="checkin-dismiss" label="Dismiss" dimColor onPress={() => answer($, [])} />
            </Box>
            {choices.goal && Input && (
              <Input
                key="checkin-next"
                label="Next step"
                placeholder={`in ${choices.goal.title}; Enter makes it next up`}
                submitLabel="add"
                onSubmit={value => nextStep($, value)}
              />
            )}
            {choices.goal && (
              <Text dimColor>
                {Input ? 'Or type' : `Add a next step to “${choices.goal.title}” with`} /tv next {'<title>'}
              </Text>
            )}
          </Box>
        )}
        <Text> </Text>
        <Text dimColor>Today</Text>
        {open.length === 0 && <Text dimColor>Nothing left on the list.</Text>}
        {finished.length > 0 && <Text dimColor>Done · {finished.length}</Text>}
        {groupByGoal(open).map(group => (
          <Box key={`goal-${group.id ?? 'none'}`} flexDirection="column">
            {group.title !== null && <Text bold>{group.title}</Text>}
            {group.tasks.map(task => (
              <Box key={`row-${task.id}`} flexDirection="column">
                <Box flexDirection="row" gap={1}>
                  <Text bold={task.active}>
                    {group.title !== null ? '  ' : ''}
                    {task.active ? '◉' : '○'} {task.title} · {clock(task.duration_minutes * 60)}
                    {task.preset ? ` · ${task.preset.name}` : ''}
                    {sessionsDone(task) ? ` · ${sessionsDone(task)}` : ''}
                  </Text>
                  {!running && (
                    <Button key={`start-${task.id}`} label="Start" dimColor onPress={() => press($, 'session.start', { id: task.id })} />
                  )}
                </Box>
                {task.done_when?.trim() && (
                  <Text dimColor>
                    {group.title !== null ? '    ' : '  '}
                    Done when: {task.done_when.trim()}
                  </Text>
                )}
              </Box>
            ))}
          </Box>
        ))}
        {finished.map(task => (
          <Text dimColor>✓ {task.title}</Text>
        ))}
      </Box>
    )
  })
}
