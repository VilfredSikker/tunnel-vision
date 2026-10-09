/** A task as Tunnel Vision's control socket returns it (the fields this mod reads). */
export type Task = {
  id: string
  title: string
  duration_minutes: number
  done: boolean
  active: boolean
  repeat_daily: boolean
  /** On today's open list as the app's panel shows it. Absent from apps that predate it. */
  open?: boolean
  preset: { id: string; name: string } | null
  // The fields below are absent from apps that predate goals and task series.
  goal?: { id: string; title: string } | null
  priority?: Priority
  /** ISO 8601; absent for tasks from before the app recorded it. */
  created_at?: string
  /** What finished looks like; "" when unset. */
  done_when?: string
  /** Tasks in this task's series (the task plus its copies), at least 1. Every task in the series reports the same number. */
  sessions?: number
  /** How many tasks in the series are checked off (per day for a repeat_daily task). */
  sessions_done?: number
}

export type Priority = 'high' | 'medium' | 'low'

export type Phase = 'idle' | 'work' | 'paused' | 'break'

/** `state.get`'s `state`. */
export type TVState = {
  phase: Phase
  today: string
  sessions_today: number
  task_sort?: 'manual' | 'created' | 'priority'
  remaining_seconds?: number
  long_break?: boolean
  active_task?: Task
  next_up?: Task
}

/** The last poll: the app's state and today's tasks, or why there are none. */
export type Snapshot = {
  state: TVState | null
  tasks: Task[]
  /** Epoch ms of the poll, to count `remaining_seconds` down between polls. */
  fetchedAt: number
  error: string | null
}

/** The task whose work session just ran out into a break, kept until it is acted on or a new session starts. */
export type CheckIn = {
  taskId: string
  title: string
}

declare module 'claude-code' {
  interface PluginState {
    'tunnelvision-mod': { snapshot: Snapshot; checkIn: CheckIn | null }
  }
}
