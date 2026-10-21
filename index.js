/**
 * Topmost Alert — Host half.
 *
 * Pops a borderless, always-on-top card on the Windows desktop when this DSH
 * instance stops needing the model: the turn finished, an approval or a
 * structured question is waiting for the user, or a turn errored. The window is
 * painted by `popup/alert.ps1`; this half only decides *when* to show one and
 * what it says.
 *
 * The plugin never claims a waterfall decision. Approval and user-question
 * listeners notify first and then always delegate with `next()`.
 */
import { basename } from 'node:path'
import { alertAvailable, alertScriptPath, createAlerter } from './lib/alert.js'

export const name = 'topmost-alert'

export const DEFAULTS = Object.freeze({
  enabled: true,
  notifyOnDone: true,
  notifyOnNeedsUser: true,
  notifyOnError: true,
  durationSeconds: 20,
  minTurnSeconds: 5,
  sound: true,
  position: 'bottom-right',
  dismissWhenClientFocused: true,
})

const POSITIONS = new Set(['bottom-right', 'top-right', 'bottom-left'])
const SUBAGENT_ORIGIN = 'subagent'

/** Boards of resumed sessions announce `idle` right after load; stay quiet then. */
const BOOT_GRACE_MS = 15_000
/** An errored turn ends right after its error; do not stack two cards for it. */
const ERROR_QUIET_MS = 3_000
/** Collapse identical cards (retries, re-entrant asks) instead of fanning out. */
const REPEAT_QUIET_MS = 3_000
const SUBTITLE_LIMIT = 90
const BODY_LIMIT = 220

function resolveValue(raw, fallback) {
  const value = raw !== null && typeof raw === 'object' && typeof raw.get === 'function' ? raw.get() : raw
  return value === undefined || value === null ? fallback : value
}

function asNumber(raw, fallback) {
  const value = Number(resolveValue(raw, fallback))
  return Number.isFinite(value) ? value : fallback
}

function asFlag(raw, fallback) {
  const value = resolveValue(raw, fallback)
  if (typeof value === 'string') return !['false', '0', 'off', 'no'].includes(value.trim().toLowerCase())
  return Boolean(value)
}

function clampText(value, limit) {
  const text = String(value ?? '').replace(/\s+/g, ' ').trim()
  if (text.length <= limit) return text
  return `${text.slice(0, Math.max(0, limit - 1)).trimEnd()}…`
}

function formatDuration(ms) {
  const totalSeconds = Math.max(1, Math.round(ms / 1000))
  if (totalSeconds < 60) return `${totalSeconds} 秒`
  const minutes = Math.floor(totalSeconds / 60)
  const seconds = totalSeconds % 60
  return seconds === 0 ? `${minutes} 分钟` : `${minutes} 分 ${seconds} 秒`
}

function describeError(error) {
  if (error instanceof Error) return error.message || error.name
  if (typeof error === 'string') return error
  try {
    return JSON.stringify(error)
  } catch {
    return String(error)
  }
}

function pickReason(displayReason, fallback) {
  if (displayReason !== null && typeof displayReason === 'object') {
    for (const locale of ['zh-CN', 'zh', 'en']) {
      const candidate = displayReason[locale]
      if (typeof candidate === 'string' && candidate.trim() !== '') return candidate
    }
  }
  return typeof fallback === 'string' ? fallback : undefined
}

export function apply(ctx, config) {
  const logger = ctx.logger(name)
  const alerter = createAlerter()
  const startedAt = new Map()
  const erroredAt = new Map()
  const recent = new Map()
  const loadedAt = Date.now()

  const option = (key) => resolveValue(config?.[key], DEFAULTS[key])

  const sessionOf = (agent) => {
    const session = agent?.session
    return session !== null && typeof session === 'object' ? session : undefined
  }

  const isSubagent = (agent) => sessionOf(agent)?.header?.origin === SUBAGENT_ORIGIN

  const sessionLabel = (agent) => {
    const session = sessionOf(agent)
    if (session === undefined) return ''
    try {
      const title = ctx.get('sessionTitle')?.get?.(session)?.title
      if (typeof title === 'string' && title.trim() !== '') return clampText(title, SUBTITLE_LIMIT)
    } catch {
      // Title projection is optional; the working directory is a fine fallback.
    }
    try {
      const cwd = ctx.get('workingDirectory')?.get?.(session)
      if (typeof cwd === 'string' && cwd !== '') return clampText(basename(cwd), SUBTITLE_LIMIT)
    } catch {
      // No working directory yet.
    }
    return ''
  }

  const position = () => {
    const value = String(option('position')).trim()
    return POSITIONS.has(value) ? value : DEFAULTS.position
  }

  const cardSeconds = () => Math.max(3, asNumber(option('durationSeconds'), DEFAULTS.durationSeconds))

  const fire = (card) => {
    if (!asFlag(option('enabled'), DEFAULTS.enabled)) return undefined
    if (!alertAvailable()) {
      logger.debug('popup script missing at %s; skipped', alertScriptPath())
      return undefined
    }
    const signature = `${card.kind}|${card.title}|${card.body}`
    const now = Date.now()
    if (now - (recent.get(signature) ?? 0) < REPEAT_QUIET_MS) return undefined
    recent.set(signature, now)
    for (const [key, stamp] of recent) {
      if (now - stamp > 30_000) recent.delete(key)
    }
    try {
      return alerter.show({
        title: card.title,
        subtitle: card.subtitle,
        body: card.body,
        kind: card.kind,
        durationMs: card.durationMs,
        sound: asFlag(option('sound'), DEFAULTS.sound),
        position: position(),
        clientPid: process.pid,
        dismissOnClientFocus: asFlag(option('dismissWhenClientFocused'), DEFAULTS.dismissWhenClientFocused),
      })
    } catch (error) {
      logger.warn('could not show alert: %s', describeError(error))
      return undefined
    }
  }

  // --- finished turn -------------------------------------------------------
  ctx.on('agent/status', ({ agent, status }) => {
    if (status === 'running') {
      if (!startedAt.has(agent.id)) startedAt.set(agent.id, Date.now())
      return
    }
    if (status !== 'idle') return

    const began = startedAt.get(agent.id)
    startedAt.delete(agent.id)
    if (isSubagent(agent)) return
    if (!asFlag(option('notifyOnDone'), DEFAULTS.notifyOnDone)) return

    const now = Date.now()
    // Ignore the idle announcement a resumed session makes while the profile loads.
    if (now - loadedAt < BOOT_GRACE_MS) return
    if (now - (erroredAt.get(agent.id) ?? 0) < ERROR_QUIET_MS) return

    const elapsed = began === undefined ? 0 : now - began
    const minMs = Math.max(0, asNumber(option('minTurnSeconds'), DEFAULTS.minTurnSeconds)) * 1000
    if (elapsed > 0 && elapsed < minMs) return

    const label = sessionLabel(agent)
    logger.debug('turn finished in %dms for %s', elapsed, agent.id)
    fire({
      kind: 'done',
      title: '任务完成',
      subtitle: label,
      body: elapsed > 0
        ? `本轮工作已结束，用时 ${formatDuration(elapsed)}。回到 DSH 查看结果或继续下达指令。`
        : '本轮工作已结束。回到 DSH 查看结果或继续下达指令。',
      durationMs: cardSeconds() * 1000,
    })
  })

  // --- waiting for an approval --------------------------------------------
  ctx.on('approval/request', async (request, next) => {
    let card
    if (asFlag(option('notifyOnNeedsUser'), DEFAULTS.notifyOnNeedsUser)) {
      const agent = request?.agent
      const tool = typeof request?.toolName === 'string' && request.toolName !== ''
        ? `工具「${request.toolName}」`
        : '一个操作'
      const reason = pickReason(request?.displayReason, request?.reason)
      card = fire({
        kind: 'need',
        title: '需要你确认',
        subtitle: sessionLabel(agent),
        body: `${tool}正在等待你的授权${reason === undefined ? '。' : `：${clampText(reason, BODY_LIMIT - 24)}`}`,
        durationMs: 0,
      })
    }
    try {
      if (typeof next !== 'function') return undefined
      return await next()
    } finally {
      card?.close()
    }
  })

  // --- waiting for an answer ----------------------------------------------
  ctx.on('user-questions/request', async (request, next) => {
    let card
    if (asFlag(option('notifyOnNeedsUser'), DEFAULTS.notifyOnNeedsUser)) {
      const questions = Array.isArray(request?.questions) ? request.questions : []
      const first = questions[0]
      const question = typeof first?.question === 'string' ? clampText(first.question, BODY_LIMIT - 40) : ''
      const extra = questions.length > 1 ? `（另有 ${questions.length - 1} 个问题）` : ''
      card = fire({
        kind: 'need',
        title: '需要你回答',
        subtitle: sessionLabel(request?.agent),
        body: question === '' ? `有 ${questions.length} 个问题等你选择。` : `${question}${extra}`,
        durationMs: 0,
      })
    }
    try {
      if (typeof next !== 'function') return undefined
      return await next()
    } finally {
      card?.close()
    }
  })

  // --- failed turn ---------------------------------------------------------
  ctx.on('agent/error', ({ agent, error }) => {
    if (isSubagent(agent)) return
    if (!asFlag(option('notifyOnError'), DEFAULTS.notifyOnError)) return
    erroredAt.set(agent.id, Date.now())
    fire({
      kind: 'error',
      title: '出错了',
      subtitle: sessionLabel(agent),
      body: clampText(describeError(error), BODY_LIMIT),
      durationMs: cardSeconds() * 1000,
    })
  })

  ctx.on('agent/disposed', ({ agent }) => {
    startedAt.delete(agent.id)
    erroredAt.delete(agent.id)
  })

  ctx.effect(() => () => {
    alerter.dispose()
    startedAt.clear()
    erroredAt.clear()
    recent.clear()
  }, 'topmost-alert: popups')

  logger.debug('ready (script %s)', alertScriptPath())
}
