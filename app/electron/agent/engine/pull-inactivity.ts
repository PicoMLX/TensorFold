export type PullTimeout = (callback: () => void, ms: number) => () => void

type PullActivity = { phase: 'download' } | { phase: 'verify'; completed: number; total: number }

export function parsePullActivity(line: string): PullActivity | null {
  const prefix = '[tensorfold-pull] '
  if (!line.startsWith(prefix)) return null
  try {
    const value = JSON.parse(line.slice(prefix.length))
    if (value?.phase === 'download') return { phase: 'download' }
    if (value?.phase === 'verify' && Number.isSafeInteger(value.completed) && Number.isSafeInteger(value.total)
      && value.completed >= 0 && value.total >= value.completed) {
      return { phase: 'verify', completed: value.completed, total: value.total }
    }
  } catch { /* ordinary diagnostics are not activity records */ }
  return null
}

const scheduleTimeout: PullTimeout = (callback, ms) => {
  const timer = setTimeout(callback, ms)
  timer.unref?.()
  return () => clearTimeout(timer)
}

// Only advancing transfer or verification bytes reset the deadline; ordinary console output does not.
export class PullInactivity {
  private bytes = 0
  private cancelTimer: (() => void) | null = null

  constructor(private readonly expired: () => void, private readonly schedule: PullTimeout = scheduleTimeout) {}

  start(bytes: number): void {
    this.stop()
    this.bytes = bytes
    this.cancelTimer = this.schedule(this.expired, 60_000)
  }

  sample(bytes: number): void {
    if (this.cancelTimer && bytes > this.bytes) this.start(bytes)
    else this.bytes = bytes
  }

  stop(): void {
    this.cancelTimer?.()
    this.cancelTimer = null
  }
}
