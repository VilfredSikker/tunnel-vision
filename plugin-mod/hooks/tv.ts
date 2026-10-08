import type { CheckIn, Phase, Priority, Task, TVState } from '../types'

// Pure helpers; the hooks module does the talking.
export const SOCKET = 'Library/Application Support/TunnelVision/control.sock'
export const NOT_RUNNING = 'Tunnel Vision is not running'

export function requestLine(method: string, params: Record<string, unknown> = {}): string {
  return JSON.stringify({ id: 1, method, params }) + '\n'
}

export function parseResponse(line: string): Record<string, unknown> {
  const reply = JSON.parse(line) as {
    result?: Record<string, unknown>
    error?: { message?: string }
  }
  if (reply.error) throw new Error(reply.error.message ?? 'unknown error')
  return reply.result ?? {}
}

export function clock(seconds: number): string {
  const s = Math.max(0, Math.round(seconds))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

/** Seconds left now, counting down from the last poll while the timer runs. */
export function remaining(state: TVState, fetchedAt: number, now: number): number | undefined {
  if (state.remaining_seconds === undefined) return undefined
  const isRunning = state.phase === 'work' || state.phase === 'break'
  const elapsed = isRunning ? (now - fetchedAt) / 1000 : 0
  return Math.max(0, state.remaining_seconds - elapsed)
}

function short(title: string, room = 32): string {
  return title.length > room ? `${title.slice(0, room - 1)}…` : title
}

/** The status line text, or undefined to clear it (idle, or the app is gone). */
export function statusText(state: TVState | null, left: number | undefined): string | undefined {
  if (!state) return undefined
  const time = left === undefined ? '' : ` · ${clock(left)}`
  const title = state.active_task ? short(state.active_task.title) : 'focus'
  switch (state.phase) {
    case 'work':
      return `◉ ${title}${time}`
    case 'paused':
      return `‖ ${title} · paused${time}`
    case 'break':
      return `${state.long_break ? 'Long break' : 'Break'}${time}`
    case 'idle':
      return undefined
  }
}

/** What to say when the phase or the running task changes; undefined for nothing. */
export function transitionText(before: TVState, after: TVState): string | undefined {
  const was = before.phase
  const is = after.phase
  const sameTask = before.active_task?.id === after.active_task?.id
  if (was === is && sameTask) return undefined
  if (is === 'work' && was !== 'paused') {
    return `Focus: ${after.active_task?.title ?? 'session'} started`
  }
  if (is === 'break') return `${after.long_break ? 'Long break' : 'Break'} started`
  if (is === 'idle' && was === 'break') return 'Break over'
  if (is === 'idle') return 'Focus session ended'
  return undefined
}

export function isSessionRunning(phase: Phase): boolean {
  return phase === 'work' || phase === 'paused'
}

/** Tasks still due today, in list order: the ones a session can start. */
export function openTasks(tasks: Task[]): Task[] {
  return tasks.filter(task => task.open ?? !task.done)
}

const RANK: Record<Priority, number> = { high: 1, medium: 2, low: 3 }

/**
 * Tasks in the order the app's panel shows them for its sort. Ties keep list
 * order, as the app's do; a task without a creation date sorts first, as the
 * app dates it to the distant past.
 */
export function sortedTasks(tasks: Task[], sort: TVState['task_sort']): Task[] {
  if (sort !== 'priority' && sort !== 'created') return tasks
  const key = (task: Task): number | string =>
    sort === 'priority' ? RANK[task.priority ?? 'medium'] : (task.created_at ?? '')
  return tasks
    .map((task, index) => ({ task, index }))
    .sort((a, b) => {
      const ka = key(a.task)
      const kb = key(b.task)
      return ka < kb ? -1 : ka > kb ? 1 : a.index - b.index
    })
    .map(entry => entry.task)
}

/**
 * The task a `/tv start` query names: an exact id, else one open task whose
 * title contains the query (case-insensitive). An empty query is next up.
 */
export function matchTask(
  tasks: Task[],
  query: string,
  nextUp?: Task,
): { task: Task } | { error: string } {
  const q = query.trim().toLowerCase()
  if (q === '') {
    return nextUp ? { task: nextUp } : { error: 'Nothing is left on today’s list.' }
  }
  const byId = tasks.find(task => task.id.toLowerCase() === q)
  if (byId) return { task: byId }
  const hits = openTasks(tasks).filter(task => task.title.toLowerCase().includes(q))
  const [only] = hits
  if (only && hits.length === 1) return { task: only }
  if (!only) return { error: `No open task matches “${query.trim()}”.` }
  const exact = hits.find(task => task.title.toLowerCase() === q)
  if (exact) return { task: exact }
  return {
    error: `“${query.trim()}” matches ${hits.length} tasks: ${hits.map(t => t.title).join(', ')}.`,
  }
}

/** Planned sessions, or undefined for a one-session task (and apps that predate the field). */
function planned(task: Task): number | undefined {
  return task.sessions !== undefined && task.sessions > 1 ? task.sessions : undefined
}

/** `N/M` for the session in progress, N counting it; undefined for a one-session task. */
export function sessionOfPlanned(task: Task): string | undefined {
  const of = planned(task)
  if (of === undefined) return undefined
  return `${Math.min((task.sessions_done ?? 0) + 1, of)}/${of}`
}

/** `N/M sessions` done of planned, for a list row; undefined for a one-session task. */
export function sessionsDone(task: Task): string | undefined {
  const of = planned(task)
  return of === undefined ? undefined : `${task.sessions_done ?? 0}/${of} sessions`
}

/**
 * The system-prompt section while a session runs. It names the task, its
 * outcome, goal and session count, and nothing that ticks, so it only
 * changes (and costs a prompt-cache miss) when a session starts, ends or
 * switches task.
 */
export function focusSection(state: TVState | null): string | undefined {
  if (!state || !isSessionRunning(state.phase) || !state.active_task) return undefined
  const task = state.active_task
  const doneWhen = task.done_when?.trim()
  const session = sessionOfPlanned(task)
  return [
    '# Focus session',
    `The user is in a Tunnel Vision focus session on the task “${task.title}”.`,
    ...(task.goal ? [`It is a step toward the goal “${task.goal.title}”.`] : []),
    ...(doneWhen ? [`The task is done when: ${doneWhen}`] : []),
    ...(session ? [`This is session ${session} planned for it.`] : []),
    'Keep the work on that task. If a request looks unrelated to it, say so in one short line ' +
      'before doing it, and offer to note it as a separate task for later. Do not refuse the request.',
    ...(doneWhen
      ? ['When that outcome looks met, say so and offer to check the task off with `/tv done`.']
      : []),
  ].join('\n')
}

/**
 * The check-in a poll leaves: a new one when work ran into a break, null
 * when a new session started, undefined to keep what there is.
 */
export function nextCheckIn(before: TVState, after: TVState): CheckIn | null | undefined {
  if (after.phase === 'work') return null
  if (before.phase === 'work' && after.phase === 'break' && before.active_task) {
    return { taskId: before.active_task.id, title: before.active_task.title }
  }
  return undefined
}

/** One control request: a method and its params. */
export type Request = { method: string; params: Record<string, unknown> }

/** What the check-in offers for the task that just ended, judged from its fresh state. */
export type CheckInChoices = {
  /** Check it off: it is still open. */
  done?: Request
  /** Open it again for one more session: it got checked off. */
  oneMore?: Request[]
  /** It stays on the list with sessions left: `N/M sessions`. */
  sessionsLeft?: string
  /** A next step can go into this goal. */
  goal?: { id: string; title: string }
}

export function checkInChoices(task: Task | undefined): CheckInChoices {
  if (!task) return {}
  const open = task.open ?? !task.done
  const goal = task.goal ?? undefined
  const of = planned(task)
  if (!open) {
    // One more session is a copy of the task in its series; apps that
    // predate task series only take the check-off back.
    const more: Request[] = task.sessions_done !== undefined
      ? [{ method: 'tasks.duplicate', params: { id: task.id } }]
      : [{ method: 'tasks.set_done', params: { id: task.id, done: false } }]
    return { oneMore: more, goal }
  }
  const left = of !== undefined && (task.sessions_done ?? 0) < of ? sessionsDone(task) : undefined
  return {
    done: { method: 'tasks.set_done', params: { id: task.id, done: true } },
    sessionsLeft: left,
    goal,
  }
}

/** The goal new tasks join: the running task's, else the one that just ended. */
export function contextGoal(
  state: TVState | null,
  tasks: Task[],
  checkIn: CheckIn | null,
): { id: string; title: string } | undefined {
  const id =
    state && isSessionRunning(state.phase) && state.active_task ? state.active_task.id : checkIn?.taskId
  if (!id) return undefined
  const task = tasks.find(t => t.id === id) ?? (state?.active_task?.id === id ? state.active_task : undefined)
  return task?.goal ?? undefined
}

/** `tasks.add` params for `/tv later` (low) and `/tv next` (medium). */
export function addParams(
  title: string,
  priority: Priority,
  goal: { id: string; title: string } | undefined,
): Record<string, unknown> {
  return { title: title.trim(), priority, ...(goal ? { goal: goal.id } : {}) }
}

/** `tasks.reorder` ids that make a new task next up: after the running task, when there is one. */
export function nextUpOrder(newId: string, runningId: string | undefined): string[] {
  return runningId && runningId !== newId ? [runningId, newId] : [newId]
}

/** Open tasks under their goal, in list order; a list with no goals is one group without a title. */
export type TaskGroup = { id: string | null; title: string | null; tasks: Task[] }

export function groupByGoal(tasks: Task[]): TaskGroup[] {
  const groups = new Map<string, TaskGroup>()
  const loose: Task[] = []
  for (const task of tasks) {
    if (!task.goal) {
      loose.push(task)
      continue
    }
    const group = groups.get(task.goal.id) ?? { id: task.goal.id, title: task.goal.title, tasks: [] }
    group.tasks.push(task)
    groups.set(task.goal.id, group)
  }
  if (groups.size === 0) return loose.length === 0 ? [] : [{ id: null, title: null, tasks: loose }]
  return [...groups.values(), ...(loose.length === 0 ? [] : [{ id: null, title: 'Other', tasks: loose }])]
}

export function describe(state: TVState | null, left: number | undefined): string {
  if (!state) return NOT_RUNNING + '.'
  const time = left === undefined ? '' : `, ${clock(left)} left`
  const next = state.next_up ? ` Next up: ${state.next_up.title}.` : ''
  const count = `${state.sessions_today} session${state.sessions_today === 1 ? '' : 's'} today.`
  switch (state.phase) {
    case 'work':
      return `Working on ${state.active_task?.title ?? 'a task'}${time}. ${count}${next}`
    case 'paused':
      return `Paused on ${state.active_task?.title ?? 'a task'}${time}. ${count}${next}`
    case 'break':
      return `On a ${state.long_break ? 'long ' : ''}break${time}. ${count}${next}`
    case 'idle':
      return `Idle. ${count}${next}`
  }
}
