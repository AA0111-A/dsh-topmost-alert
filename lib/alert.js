/**
 * Process plumbing for the topmost alert.
 *
 * Each notification is one short-lived PowerShell process that paints a
 * borderless, always-on-top card. The payload travels through a UTF-8 JSON file
 * so Chinese text never has to survive command-line quoting or the console code
 * page, and Windows PowerShell 5.1 (ANSI script reader) never sees non-ASCII
 * script bytes.
 */
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdir, unlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const PACKAGE_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SCRIPT_PATH = join(PACKAGE_ROOT, 'popup', 'alert.ps1')
const TEMP_DIR = join(tmpdir(), 'dsh-topmost-alert')
const SYSTEM_ROOT = process.env.SystemRoot || process.env.windir || 'C:\\Windows'
const MAX_VISIBLE = 4
const WINDOWS_POWERSHELL = join(SYSTEM_ROOT, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')

let cachedShell

/**
 * Resolve a PowerShell host once. pwsh 7 starts faster and reads UTF-8
 * natively, so it wins when present; inbox Windows PowerShell always exists as
 * the fallback.
 */
export function resolveShell() {
  if (cachedShell !== undefined) return cachedShell
  const candidates = [
    process.env.DSH_TOPMOST_ALERT_SHELL,
    'C:\\Program Files\\PowerShell\\7\\pwsh.exe',
    'C:\\Program Files\\PowerShell\\7-preview\\pwsh.exe',
    WINDOWS_POWERSHELL,
  ]
  cachedShell = candidates.find((candidate) => typeof candidate === 'string'
    && candidate.length > 0
    && existsSync(candidate)) ?? 'powershell.exe'
  return cachedShell
}

export function alertScriptPath() {
  return SCRIPT_PATH
}

export function alertAvailable() {
  return existsSync(SCRIPT_PATH)
}

function shellArguments(file) {
  return [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    SCRIPT_PATH,
    '-PayloadFile',
    file,
  ]
}

async function writePayload(payload) {
  await mkdir(TEMP_DIR, { recursive: true })
  const file = join(TEMP_DIR, `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}.json`)
  await writeFile(file, JSON.stringify(payload), 'utf8')
  return file
}

async function removeFile(file) {
  if (file === undefined) return
  try {
    await unlink(file)
  } catch {
    // The temp sweep is best effort; a leftover file is harmless.
  }
}

/**
 * Alerter: spawns one window per notification, keeps at most MAX_VISIBLE
 * stacked, and lets the caller close a window early (an answered approval no
 * longer deserves screen space).
 */
export function createAlerter() {
  const live = new Set()
  let visible = 0

  const release = (record, file) => {
    if (!live.delete(record)) return
    visible = Math.max(0, visible - 1)
    record.child = undefined
    void removeFile(file)
  }

  const show = (payload) => {
    if (!existsSync(SCRIPT_PATH)) return undefined
    if (visible >= MAX_VISIBLE) return undefined

    const record = {
      child: undefined,
      cancelled: false,
      close() {
        // The card may not have a process yet: the request can be answered (or
        // auto-denied by policy) before PowerShell has started. Remember the
        // cancellation so the spawn below never shows an orphan window.
        record.cancelled = true
        try {
          record.child?.kill()
        } catch {
          // Killing an already-exited window is expected.
        }
      },
    }
    let file
    visible += 1
    live.add(record)

    void (async () => {
      try {
        file = await writePayload({ ...payload, index: visible - 1 })
        if (record.cancelled || !live.has(record)) {
          // Closed (or disposed) while the payload was still being written.
          await removeFile(file)
          release(record, file)
          return
        }
        const child = spawn(resolveShell(), shellArguments(file), {
          cwd: TEMP_DIR,
          windowsHide: true,
          stdio: 'ignore',
        })
        record.child = child
        child.once('error', () => { release(record, file) })
        child.once('exit', () => { release(record, file) })
        if (record.cancelled) {
          try {
            child.kill()
          } catch {
            // Already gone.
          }
        }
      } catch {
        release(record, file)
      }
    })()

    return record
  }

  const dispose = () => {
    for (const record of live) {
      record.cancelled = true
      try {
        record.child?.kill()
      } catch {
        // Killing an already-exited window is expected.
      }
    }
    live.clear()
    visible = 0
  }

  return { show, dispose }
}
