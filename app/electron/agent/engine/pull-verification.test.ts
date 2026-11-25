import assert from 'node:assert/strict'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { startPull, type PullHandle } from './pull'
import { makeHarness, waitFor } from './test-fixtures/harness'
import { PullClock } from './test-fixtures/pull-clock'

async function main() {
  const h = await makeHarness()
  const owned: PullHandle[] = []
  const source = path.join(h.root, 'cached-file')
  const stage = path.join(h.root, 'verification-stage')
  await fs.writeFile(source, Buffer.alloc(8192, 1))
  const script = `
    const fs = require('node:fs')
    const file = fs.openSync(process.env.VERIFY_SOURCE, 'r')
    let step = 0
    console.log('[tensorfold-pull] {"phase":"verify","completed":0,"total":8192}')
    console.log('Verification started')
    setInterval(() => {
      let next
      try { next = Number(fs.readFileSync(process.env.VERIFY_STAGE, 'utf8')) } catch { return }
      if (next <= step) return
      fs.readSync(file, Buffer.alloc(4096), 0, 4096, step * 4096)
      step = next
      console.log('[tensorfold-pull] ' + JSON.stringify({phase: 'verify', completed: step * 4096, total: 8192}))
      if (step === 2) console.log('[tensorfold-pull] {"phase":"download"}')
      console.log(step === 2 ? 'Network phase resumed' : 'Verified first block')
    }, 10)
  `
  const options = (clock: PullClock) => ({
    binary: { command: process.execPath, args: ['-e', script, '--'] },
    env: { ...h.env, VERIFY_SOURCE: source, VERIFY_STAGE: stage }, hub: h.hub,
    steps: [{ repo: 'Org/Verified', revision: null }], totalBytes: 8192,
    inactivityTimer: clock.schedule, pollMs: 20, killGraceMs: 30, onUpdate: () => {},
  })
  try {
    const clock = new PullClock()
    const healthy = startPull(options(clock))
    owned.push(healthy)
    await waitFor(() => healthy.progress().lastLine === 'Verification started')
    clock.advance(59_999)
    await fs.writeFile(stage, '1')
    await waitFor(() => healthy.progress().lastLine === 'Verified first block')
    clock.advance(59_999)
    assert.equal(healthy.progress().message, null, 'advancing verification does not fire the inactivity deadline')
    assert.equal(healthy.progress().state, 'running', 'advancing verification survives over a minute without cache growth')
    assert.equal(healthy.progress().receivedBytes, 0)
    assert.equal(healthy.progress().bytesPerSecond, null)
    await fs.writeFile(stage, '2')
    await waitFor(() => healthy.progress().lastLine === 'Network phase resumed')
    clock.advance(59_999)
    assert.equal(healthy.progress().state, 'running')
    clock.advance(1)
    assert.match((await healthy.done).message ?? '', /timed out.*Hugging Face Hub/)
    assert.equal(clock.pending, 0, 'finishing verification restores the bounded network guard')

    await fs.rm(stage)
    const stoppedClock = new PullClock()
    const stopped = startPull(options(stoppedClock))
    owned.push(stopped)
    await waitFor(() => stopped.progress().lastLine === 'Verification started')
    stoppedClock.advance(60_000)
    const failure = await stopped.done
    assert.equal(failure.state, 'failed')
    assert.match(failure.message ?? '', /verification made no progress for 60 seconds/)
    assert.equal(stoppedClock.pending, 0)
    console.log('Verification progress extends the existing deadline; stalled verification and network remain bounded')
  } finally {
    for (const handle of owned) handle.cancel()
    await Promise.all(owned.map((handle) => handle.done))
    await h.cleanup()
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1 })
