import { describe, expect, mock, test } from 'claude-code/testing'

import type { Task, TVState } from '../types'
import {
  addParams,
  checkInChoices,
  contextGoal,
  focusSection,
  groupByGoal,
  matchTask,
  nextCheckIn,
  nextUpOrder,
  remaining,
  sortedTasks,
  statusText,
  transitionText,
} from '../hooks/tv'

function task(id: string, title: string, extra: Partial<Task> = {}): Task {
  return { id, title, duration_minutes: 25, done: false, active: false, repeat_daily: false, preset: null, ...extra }
}

const docs = task('A1', 'Write docs')
const review = task('B2', 'Review draft for workbook')
const reviewPr = task('C3', 'Review PR')
const shipped = task('D4', 'Write release notes', { done: true })
const TASKS = [docs, review, reviewPr, shipped]

function working(on: Task, extra: Partial<TVState> = {}): TVState {
  return { phase: 'work', today: '2026-10-06', sessions_today: 1, remaining_seconds: 600, active_task: { ...on, active: true }, ...extra }
}
const IDLE: TVState = { phase: 'idle', today: '2026-10-06', sessions_today: 1 }

describe('matchTask', () => {
  test('a unique title fragment picks that task', () => {
    expect(matchTask(TASKS, 'docs')).toEqual({ task: docs })
  })
  test('an ambiguous fragment lists the candidates and starts nothing', () => {
    const found = matchTask(TASKS, 'review')
    expect('error' in found && found.error).toContain('matches 2 tasks')
  })
  test('done tasks are not candidates', () => {
    expect(matchTask(TASKS, 'release')).toEqual({ error: 'No open task matches “release”.' })
  })
  test('a task the app marks not open is not a candidate, even when not done today', () => {
    const old = task('E5', 'Write changelog', { open: false })
    expect(matchTask([...TASKS, old], 'changelog')).toEqual({ error: 'No open task matches “changelog”.' })
  })
  test('a repeating task done today stays a candidate when the app marks it open', () => {
    const daily = task('F6', 'Standup notes', { done: true, repeat_daily: true, open: true })
    expect(matchTask([...TASKS, daily], 'standup')).toEqual({ task: daily })
  })
  test('an empty query is next up', () => {
    expect(matchTask(TASKS, '  ', review)).toEqual({ task: review })
  })
  test('an exact title wins over a longer one that contains it', () => {
    expect(matchTask(TASKS, 'review pr')).toEqual({ task: reviewPr })
  })
})

describe('transitionText', () => {
  test('starting work names the task', () => {
    expect(transitionText(IDLE, working(docs))).toBe('Focus: Write docs started')
  })
  test('pause and resume stay quiet', () => {
    const paused = working(docs, { phase: 'paused' })
    expect(transitionText(working(docs), paused)).toBeUndefined()
    expect(transitionText(paused, working(docs))).toBeUndefined()
  })
  test('a break and its end are said', () => {
    const rest: TVState = { ...IDLE, phase: 'break', long_break: true, remaining_seconds: 900 }
    expect(transitionText(working(docs), rest)).toBe('Long break started')
    expect(transitionText(rest, IDLE)).toBe('Break over')
  })
  test('no change says nothing', () => {
    expect(transitionText(working(docs), working(docs, { remaining_seconds: 10 }))).toBeUndefined()
  })
})

describe('statusText and remaining', () => {
  test('work counts down from the poll', () => {
    const state = working(docs, { remaining_seconds: 600 })
    expect(statusText(state, remaining(state, 0, 30_000))).toBe('◉ Write docs · 9:30')
  })
  test('a paused session does not count down', () => {
    const state = working(docs, { phase: 'paused', remaining_seconds: 600 })
    expect(remaining(state, 0, 30_000)).toBe(600)
  })
  test('idle and a missing app clear the status line', () => {
    expect(statusText(IDLE, undefined)).toBeUndefined()
    expect(statusText(null, undefined)).toBeUndefined()
  })
})

describe('focusSection', () => {
  test('names the task while a session runs, and nothing that ticks', () => {
    const early = focusSection(working(docs, { remaining_seconds: 600 }))
    const late = focusSection(working(docs, { remaining_seconds: 5 }))
    expect(early).toContain('“Write docs”')
    expect(early).toBe(late)
    expect(focusSection(working(docs, { phase: 'paused' }))).toBe(early)
  })
  test('is absent when idle, on a break or with no app', () => {
    expect(focusSection(IDLE)).toBeUndefined()
    expect(focusSection({ ...IDLE, phase: 'break' })).toBeUndefined()
    expect(focusSection(null)).toBeUndefined()
  })
  test('a plain task gets no outcome, goal or session lines', () => {
    const text = focusSection(working(task('A1', 'Write docs', { done_when: '', sessions: 1, sessions_done: 0, goal: null })))
    expect(text).not.toContain('done when')
    expect(text).not.toContain('goal')
    expect(text).not.toContain('session 1')
    expect(text).not.toContain('/tv done')
    expect(text).toContain('Keep the work on that task.')
    // An app that predates the fields says the same.
    expect(focusSection(working(docs))).toBe(text)
  })
  test('names the outcome, the goal and the session in progress, and offers /tv done', () => {
    const planned = task('G1', 'Draft the parser', {
      done_when: '  parser passes the fixtures ',
      goal: { id: 'g', title: 'Ship 1.0' },
      sessions: 3,
      sessions_done: 1,
    })
    const text = focusSection(working(planned)) ?? ''
    expect(text).toContain('The task is done when: parser passes the fixtures')
    expect(text).toContain('goal “Ship 1.0”')
    expect(text).toContain('session 2/3')
    expect(text).toContain('offer to check the task off with `/tv done`')
    expect(text).toContain('Keep the work on that task.')
    expect(focusSection(working(planned, { remaining_seconds: 3 }))).toBe(text)
  })
  test('the session count stays within the plan after one more was added', () => {
    const over = task('G2', 'Polish', { sessions: 2, sessions_done: 2 })
    expect(focusSection(working(over))).toContain('session 2/2')
  })
})

describe('end-of-session check-in', () => {
  const breakTime: TVState = { ...IDLE, phase: 'break', remaining_seconds: 300 }

  test('work running into a break remembers the task that ended', () => {
    expect(nextCheckIn(working(docs), breakTime)).toEqual({ taskId: 'A1', title: 'Write docs' })
  })
  test('a new session clears it; a break ending or a pause keeps it', () => {
    expect(nextCheckIn(breakTime, working(review))).toBeNull()
    expect(nextCheckIn(IDLE, working(review))).toBeNull()
    expect(nextCheckIn(breakTime, IDLE)).toBeUndefined()
    expect(nextCheckIn(working(docs), working(docs, { phase: 'paused' }))).toBeUndefined()
    expect(nextCheckIn(working(docs), IDLE)).toBeUndefined()
  })
  test('a task still open offers Done', () => {
    const left = task('A1', 'Write docs', { sessions: 1, sessions_done: 0, open: true })
    expect(checkInChoices(left)).toEqual({
      done: { method: 'tasks.set_done', params: { id: 'A1', done: true } },
      sessionsLeft: undefined,
      goal: undefined,
    })
  })
  test('a task open with sessions left offers Done and shows its count in place of One more', () => {
    const goal = { id: 'g', title: 'Ship 1.0' }
    const choices = checkInChoices(task('A1', 'Write docs', { sessions: 3, sessions_done: 1, open: true, goal }))
    expect(choices.done).toEqual({ method: 'tasks.set_done', params: { id: 'A1', done: true } })
    expect(choices.oneMore).toBeUndefined()
    expect(choices.sessionsLeft).toBe('1/3 sessions')
    expect(choices.goal).toEqual(goal)
  })
  test('a checked-off task offers One more: a copy of it in its series', () => {
    const choices = checkInChoices(task('A1', 'Write docs', { done: true, open: false, sessions: 2, sessions_done: 2 }))
    expect(choices.done).toBeUndefined()
    expect(choices.oneMore).toEqual([
      { method: 'tasks.duplicate', params: { id: 'A1' } },
    ])
  })
  test('an app without task series only reopens the task', () => {
    expect(checkInChoices(task('A1', 'Write docs', { done: true })).oneMore).toEqual([
      { method: 'tasks.set_done', params: { id: 'A1', done: false } },
    ])
  })
  test('a task gone from the list offers nothing', () => {
    expect(checkInChoices(undefined)).toEqual({})
  })
})

describe('groupByGoal', () => {
  const ship = { id: 'g1', title: 'Ship 1.0' }
  const hire = { id: 'g2', title: 'Hire' }

  test('a list with no goals is one group without a title', () => {
    expect(groupByGoal([docs, review])).toEqual([{ id: null, title: null, tasks: [docs, review] }])
    expect(groupByGoal([])).toEqual([])
  })
  test('tasks go under their goal in list order, the rest under Other last', () => {
    const a = task('1', 'a', { goal: ship })
    const b = task('2', 'b', { goal: hire })
    const c = task('3', 'c', { goal: ship })
    expect(groupByGoal([docs, a, b, c])).toEqual([
      { id: 'g1', title: 'Ship 1.0', tasks: [a, c] },
      { id: 'g2', title: 'Hire', tasks: [b] },
      { id: null, title: 'Other', tasks: [docs] },
    ])
  })
})

describe('/tv later and /tv next parameters', () => {
  const ship = { id: 'g1', title: 'Ship 1.0' }
  const inGoal = task('A1', 'Write docs', { goal: ship })
  const breakTime: TVState = { ...IDLE, phase: 'break' }

  test('a task joins the goal by id, with its priority and a trimmed title', () => {
    expect(addParams('  Fix typo ', 'low', ship)).toEqual({ title: 'Fix typo', priority: 'low', goal: 'g1' })
    expect(addParams('Fix typo', 'medium', undefined)).toEqual({ title: 'Fix typo', priority: 'medium' })
  })
  test('the goal is the running task’s, else the one that just ended', () => {
    expect(contextGoal(working(inGoal), [inGoal], null)).toEqual(ship)
    expect(contextGoal(breakTime, [inGoal], { taskId: 'A1', title: 'Write docs' })).toEqual(ship)
    expect(contextGoal(breakTime, [inGoal], null)).toBeUndefined()
    expect(contextGoal(working(review), [review, inGoal], { taskId: 'A1', title: 'Write docs' })).toBeUndefined()
  })
  test('next up follows the running task, or leads the list', () => {
    expect(nextUpOrder('N', 'R')).toEqual(['R', 'N'])
    expect(nextUpOrder('N', undefined)).toEqual(['N'])
  })
})

// `/tv` as typed at the prompt.
const TYPED = {
  command: 'tv',
  origin: { kind: 'composer' as const },
  presentation: { isFullscreen: false, columns: 120 },
}

// A fake Tunnel Vision answering the plugin's `nc -U` runs beneath it.
function fakeApp(state: () => TVState, sent: { method: string; params: Record<string, unknown> }[]) {
  return (argv: readonly string[], stdin: string | undefined) => {
    expect(argv[0]).toBe('/usr/bin/nc')
    expect(argv[2]).toContain('TunnelVision/control.sock')
    const request = JSON.parse(stdin ?? '{}') as { method: string; params: Record<string, unknown> }
    sent.push(request)
    const result =
      request.method === 'tasks.list' ? { day: '2026-10-06', tasks: TASKS } : { state: state() }
    const stdout = JSON.stringify({ id: 1, result }) + '\n'
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  }
}

test('/tv start <fragment> starts the matching task over the socket', async ($, on) => {
  const sent: { method: string; params: Record<string, unknown> }[] = []
  const answer = fakeApp(() => IDLE, sent)
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  on('process.run', ($, e) => answer(e.argv, e.init?.stdin))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))

  const { text } = await $.command.run({ ...TYPED, args:'start docs' })

  expect(sent.find(r => r.method === 'session.start')?.params).toEqual({ id: 'A1' })
  expect(text).toContain('Idle')
})

test('/tv start with an ambiguous fragment sends no start', async ($, on) => {
  const sent: { method: string; params: Record<string, unknown> }[] = []
  const answer = fakeApp(() => IDLE, sent)
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  on('process.run', ($, e) => answer(e.argv, e.init?.stdin))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))

  const { text } = await $.command.run({ ...TYPED, args:'start review' })

  expect(sent.some(r => r.method === 'session.start')).toBe(false)
  expect(text).toContain('matches 2 tasks')
})

test('a running session adds the focus section to the system prompt; idle adds none', async ($, on) => {
  let state: TVState = working(docs)
  const answer = fakeApp(() => state, [])
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  on('process.run', ($, e) => answer(e.argv, e.init?.stdin))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('prompt.compose', () => ({ sections: [{ id: 'base', text: 'base', scope: 'shared' as const }] }))

  const request = { model: 'claude-opus-5-5', promptModel: 'claude-opus-5-5', surfaces: [], tools: [], outputStyle: null, traits: [] }
  await $.command.run({ ...TYPED, args:'status' })
  const during = await $.prompt.compose(request)
  expect(during.sections.map(s => s.id)).toEqual(['base', 'tunnel-vision:focus'])
  expect(during.sections[1]?.text).toContain('“Write docs”')

  state = IDLE
  await $.command.run({ ...TYPED, args:'status' })
  const after = await $.prompt.compose(request)
  expect(after.sections.map(s => s.id)).toEqual(['base'])
})

// A fake Tunnel Vision that also answers tasks.add and tasks.reorder.
function fakeTasksApp(state: () => TVState, tasks: () => Task[], sent: { method: string; params: Record<string, unknown> }[]) {
  return (argv: readonly string[], stdin: string | undefined) => {
    const request = JSON.parse(stdin ?? '{}') as { method: string; params: Record<string, unknown> }
    sent.push(request)
    const result =
      request.method === 'tasks.list'
        ? { day: '2026-10-06', tasks: tasks() }
        : request.method === 'tasks.add'
          ? { task: task('NEW', String(request.params.title)) }
          : request.method === 'tasks.reorder'
            ? { tasks: tasks() }
            : { state: state() }
    const stdout = JSON.stringify({ id: 1, result }) + '\n'
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  }
}

const SHIP = { id: 'g1', title: 'Ship 1.0' }
const parser = task('P1', 'Draft the parser', { goal: SHIP })

test('/tv later adds a low-priority task in the running task’s goal', async ($, on) => {
  const sent: { method: string; params: Record<string, unknown> }[] = []
  const answer = fakeTasksApp(() => working(parser), () => [parser], sent)
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  on('process.run', ($, e) => answer(e.argv, e.init?.stdin))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))

  const { text } = await $.command.run({ ...TYPED, args: 'later Fix the README' })

  expect(sent.find(r => r.method === 'tasks.add')?.params).toEqual({ title: 'Fix the README', priority: 'low', goal: 'g1' })
  expect(sent.some(r => r.method === 'tasks.reorder')).toBe(false)
  expect(text).toBe('Added “Fix the README” to “Ship 1.0” for later.')
})

test('/tv next adds a medium-priority task and moves it after the running task', async ($, on) => {
  const sent: { method: string; params: Record<string, unknown> }[] = []
  const answer = fakeTasksApp(() => working(parser), () => [parser], sent)
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  on('process.run', ($, e) => answer(e.argv, e.init?.stdin))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))

  const { text } = await $.command.run({ ...TYPED, args: 'next Write the tests' })

  expect(sent.find(r => r.method === 'tasks.add')?.params).toEqual({ title: 'Write the tests', priority: 'medium', goal: 'g1' })
  expect(sent.find(r => r.method === 'tasks.reorder')?.params).toEqual({ ids: ['P1', 'NEW'] })
  expect(text).toBe('Added “Write the tests” to “Ship 1.0” as next up.')
})

test('/tv later with no title adds nothing', async ($, on) => {
  const sent: { method: string; params: Record<string, unknown> }[] = []
  const answer = fakeTasksApp(() => IDLE, () => [], sent)
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  on('process.run', ($, e) => answer(e.argv, e.init?.stdin))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))

  const { text } = await $.command.run({ ...TYPED, args: 'later' })

  expect(sent.length).toBe(0)
  expect(text).toBe('Give it a title: /tv later <title>.')
})

test('work running into a break toasts a check-in, and /tv next then joins that task’s goal', async ($, on) => {
  const sent: { method: string; params: Record<string, unknown> }[] = []
  const toasts: string[] = []
  let state: TVState = working(parser)
  const answer = fakeTasksApp(() => state, () => [parser], sent)
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  on('process.run', ($, e) => answer(e.argv, e.init?.stdin))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })

  await $.command.run({ ...TYPED, args: 'status' })
  state = { ...IDLE, phase: 'break', remaining_seconds: 300 }
  await $.command.run({ ...TYPED, args: 'status' })

  expect(toasts).toEqual(['Break started · How did “Draft the parser” go? /tv to check in'])

  await $.command.run({ ...TYPED, args: 'next Write the tests' })
  expect(sent.find(r => r.method === 'tasks.add')?.params).toEqual({ title: 'Write the tests', priority: 'medium', goal: 'g1' })
  expect(sent.find(r => r.method === 'tasks.reorder')?.params).toEqual({ ids: ['NEW'] })
})

const PANE_PROPS = {
  title: 'Tunnel Vision',
  isFocused: true,
  bodyColumns: 100,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
}

test('the pane groups tasks by goal and its check-in Done checks the ended task off', async ($, on) => {
  const sent: { method: string; params: Record<string, unknown> }[] = []
  let state: TVState = working(parser)
  const listed = () => [{ ...parser, done_when: 'parses the fixtures', sessions: 1, sessions_done: 0, open: true }, docs]
  const answer = fakeTasksApp(() => state, listed, sent)
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  on('process.run', ($, e) => answer(e.argv, e.init?.stdin))
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))

  for (const surface of ['terminal', 'desktop'] as const) {
    sent.length = 0
    state = working(parser)
    await $.command.run({ ...TYPED, args: 'status' })
    state = { ...IDLE, phase: 'break', remaining_seconds: 300 }
    await $.command.run({ ...TYPED, args: 'status' })

    const ui = await $.ui.mount({ plugin: 'tunnelvision-mod', surface, component: 'Pane', requestId: 'tunnel-vision', props: PANE_PROPS })
    expect(await ui.find({ type: 'Text', text: /^Ship 1\.0$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^Other$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Done when: parses the fixtures/ })).toBeDefined()
    expect(await ui.find({ key: 'checkin-more' })).toBeUndefined()
    expect(await ui.find({ key: 'checkin-next' })).toBeDefined()

    await ui.press({ key: 'checkin-done' })
    expect(sent.find(r => r.method === 'tasks.set_done')?.params).toEqual({ id: 'P1', done: true })
    expect(await ui.find({ key: 'checkin-done' })).toBeUndefined()
    await ui.unmount()
  }

  // The mobile app draws no text field, so the check-in names the command.
  state = working(parser)
  await $.command.run({ ...TYPED, args: 'status' })
  state = { ...IDLE, phase: 'break', remaining_seconds: 300 }
  await $.command.run({ ...TYPED, args: 'status' })
  const mobile = await $.ui.mount({ plugin: 'tunnelvision-mod', surface: 'mobile', component: 'Pane', requestId: 'tunnel-vision', props: PANE_PROPS })
  expect(await mobile.find({ key: 'checkin-next' })).toBeUndefined()
  expect(await mobile.find({ type: 'Text', text: /Add a next step to “Ship 1\.0” with \/tv next <title>/ })).toBeDefined()
  await mobile.unmount()
})

test('/tv done takes the break without pointing to a check-in', async ($, on) => {
  const sent: { method: string; params: Record<string, unknown> }[] = []
  const toasts: string[] = []
  let state: TVState = working(parser)
  const answer = fakeTasksApp(() => state, () => [parser], sent)
  mock.env(on, { HOME: '/Users/test' })
  mock.clock(on)
  on('process.run', ($, e) => {
    if (e.init?.stdin?.includes('"session.done"')) state = { ...IDLE, phase: 'break', remaining_seconds: 300 }
    return answer(e.argv, e.init?.stdin)
  })
  on('ui.status', () => ({ value: undefined }))
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })

  await $.command.run({ ...TYPED, args: 'status' })
  await $.command.run({ ...TYPED, args: 'done' })

  expect(toasts).toEqual(['Break started'])
  const ui = await $.ui.mount({ plugin: 'tunnelvision-mod', surface: 'terminal', component: 'Pane', requestId: 'tunnel-vision', props: PANE_PROPS })
  expect(await ui.find({ key: 'checkin-dismiss' })).toBeUndefined()
  await ui.unmount()
})

describe('sortedTasks', () => {
  const medium = task('M1', 'Medium', { priority: 'medium', created_at: '2026-10-02T09:00:00Z' })
  const high = task('H1', 'High', { priority: 'high', created_at: '2026-10-03T09:00:00Z' })
  const low = task('L1', 'Low', { priority: 'low', created_at: '2026-10-01T09:00:00Z' })
  const high2 = task('H2', 'Second high', { priority: 'high' })
  const list = [medium, high, low, high2]

  test('manual keeps list order', () => {
    expect(sortedTasks(list, 'manual').map(t => t.id)).toEqual(['M1', 'H1', 'L1', 'H2'])
    expect(sortedTasks(list, undefined).map(t => t.id)).toEqual(['M1', 'H1', 'L1', 'H2'])
  })

  test('priority puts high first and keeps list order within a priority, as the app does', () => {
    expect(sortedTasks(list, 'priority').map(t => t.id)).toEqual(['H1', 'H2', 'M1', 'L1'])
  })

  test('created puts the oldest first, undated tasks before dated ones', () => {
    expect(sortedTasks(list, 'created').map(t => t.id)).toEqual(['H2', 'L1', 'M1', 'H1'])
  })
})
