import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { linuxSandboxArgv } from './linux-sandbox'
import { prepareSandboxExecution, SANDBOX_PROFILES } from './sandbox'

const host = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'tensorfold-install-host-')))
let scratch: string | undefined
try {
  const manifest = '{"name":"install-fixture","version":"1.0.0"}\n'
  writeFileSync(path.join(host, 'package.json'), manifest)
  writeFileSync(path.join(host, 'private-source.txt'), 'host-only input')
  const execution = prepareSandboxExecution(host, 'package-install')
  scratch = execution.cwd
  assert.notEqual(scratch, host)
  assert.equal(readFileSync(path.join(scratch, 'package.json'), 'utf8'), manifest)
  assert.equal(existsSync(path.join(scratch, 'private-source.txt')), false)
  assert.equal(SANDBOX_PROFILES['package-install'].allowCwdWrite, false)
  const argv = linuxSandboxArgv(scratch, { ...execution.linuxOptions, allowNetwork: false })
  const binds = (mode: string, cwd: string) => argv.some((arg, index) => arg === mode && argv[index + 2] === cwd)
  assert.ok(binds('--bind', scratch), 'sandbox-owned package scratch is writable without requiring a Git repository')
  assert.ok(!binds('--bind', host), 'the original project is not granted a writable workspace mount')
  assert.ok(!argv.includes('--share-net'), 'scratch writes do not change network policy')
  const readOnly = prepareSandboxExecution(host, 'read-only')
  assert.equal(readOnly.cwd, host)
  const readOnlyArgv = linuxSandboxArgv(host, { ...readOnly.linuxOptions, allowNetwork: false })
  assert.ok(readOnlyArgv.some((arg, index) => arg === '--ro-bind' && readOnlyArgv[index + 2] === host))
  console.log('package install scratch mount policy passed (mount plan, not Linux confinement qualification)')
} finally {
  if (scratch) rmSync(scratch, { recursive: true, force: true })
  rmSync(host, { recursive: true, force: true })
}
