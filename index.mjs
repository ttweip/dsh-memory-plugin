/**
 * dsh-memory — dsh 文件式记忆库插件（记忆方案 v1.1）
 *
 * 能力：
 *  1. 会话引导：会话首次工具调用（promotion）后，注入一次"记忆库存在"提示，
 *     指引模型读 PROTOCOL.md / MEMORY.md、按索引式落盘、结束写 checkpoint。
 *     （与 preset 的 instruction-hint 同一模式：只提示存在性，不注入内容。）
 *  2. memory_search：按关键词检索记忆库（调 dsh-memory/scripts/memory_search.sh）。
 *  3. memory_sync：git 提交并推送备份（merge 不 force-push，调 memory_sync.sh）。
 *
 * 记忆库定位（v1.1 动态化，不再固化挂载点）：
 *     config.memoryDir > 环境变量 DSH_MEMORY_DIR > 从会话 cwd 向上查找
 *     dsh-memory/（含 MEMORY.md 即命中）> 兜底 /mnt/smb/dsh-memory
 *
 * 依赖：记忆数据仓库 dsh-memory（含 scripts/）。
 * 任何异常只降级为工具报错/跳过提示，绝不破坏会话。
 */
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

const run = promisify(execFile)

/** Cordis 插件名（loader 诊断用）。 */
export const name = 'dsh-memory'

/** 需要 tools 服务先就绪。 */
export const inject = ['tools']

/** 兜底位置（本机 fstab 固定挂载点；仅当动态发现全部失败时使用）。 */
const DEFAULT_DIR = '/mnt/smb/dsh-memory'

/**
 * 解析记忆库目录：config.memoryDir > DSH_MEMORY_DIR > cwd 向上动态发现 > 兜底。
 * @param {string} [base] 动态发现的起点（会话 cwd）
 * @param {object} [config] 插件配置
 * @param {object} [env] 环境变量（默认 process.env）
 * @returns {string} 记忆库绝对路径
 */
export function resolveMemoryDir(base, config = {}, env = process.env) {
  if (config.memoryDir) return resolve(config.memoryDir)
  if (env.DSH_MEMORY_DIR) return resolve(env.DSH_MEMORY_DIR)
  if (base) {
    let cur = resolve(base)
    for (;;) {
      const candidate = join(cur, 'dsh-memory')
      if (existsSync(join(candidate, 'MEMORY.md'))) return candidate
      const parent = dirname(cur)
      if (parent === cur) break
      cur = parent
    }
  }
  return resolve(DEFAULT_DIR)
}

/** 最小 JSON Schema 编译器（零依赖，同 skill-search 模式）。 */
function toJsonSchema(spec) {
  const properties = {}
  const required = []
  for (const [key, meta] of Object.entries(spec || {})) {
    const prop = { type: meta.type }
    if (meta.description) prop.description = meta.description
    properties[key] = prop
    if (meta.required) required.push(key)
  }
  return { type: 'object', properties, required, additionalProperties: false }
}

/** 统一工具输出结构。 */
function textOutput() {
  return {
    schema: { type: 'object', additionalProperties: false, properties: { text: { type: 'string' } }, required: ['text'] },
    render: (_a, v) => [{ type: 'text', text: v.text }],
  }
}

export function apply(ctx, config = {}) {
  const hintEnabled = config.injectHint !== false

  /* 每会话解析一次记忆库路径（动态发现，见 resolveMemoryDir） */
  const dirCache = new Map()
  const memoryDirFor = (session) => {
    if (session === undefined) return resolveMemoryDir(undefined, config)
    let dir = dirCache.get(session.id)
    if (dir === undefined) {
      dir = resolveMemoryDir(session.header?.cwd, config)
      dirCache.set(session.id, dir)
    }
    return dir
  }

  /* ── 1) 会话引导提示（promotion 后每会话一次，resume 安全） ─────────── */

  const toolUsed = new Set() // 出现过 tool/call 的会话
  const hinted = new Set()   // 已发过提示的会话（进程内去重）

  ctx.on('session/event', (session, event) => {
    if (event?.type === 'tool/call') toolUsed.add(session.id)
  })

  ctx.on('agent/pre-step', async ({ agent, signal }, next) => {
    const decision = await next()
    try {
      const session = agent?.session
      if (session === undefined || !hintEnabled) return decision
      if (hinted.has(session.id) || !toolUsed.has(session.id)) return decision
      // resume 安全：历史里已有本插件提示则不重复注入
      if (session.events.some((ev) => ev.type === 'user/message' && ev.data?.source?.kind === 'dsh-memory-hint')) {
        hinted.add(session.id)
        return decision
      }
      hinted.add(session.id)
      const memoryDir = memoryDirFor(session)
      if (!existsSync(join(memoryDir, 'MEMORY.md'))) return decision

      const text = [
        `dsh 记忆库存在：${memoryDir}（dsh-memory 插件）。`,
        '涉及本工作区的任务，先读 PROTOCOL.md（协议）和 MEMORY.md（索引），需要时读对应 MEMORY-<topic>.md；',
        '会话中产生可复用知识按索引式落盘（详情进主题文件，索引只加一行 See）；',
        '会话结束写 sessions/ 下 checkpoint（Active intent / Next action / Discovered candidates / Errors / Live resources）。',
        '可用工具：memory_search（检索既往知识）、memory_sync（git 备份）。',
      ].join(' ')

      return {
        ...decision,
        messages: [...decision.messages, {
          id: `dsh-memory-hint-${session.id}`,
          role: 'user',
          content: [{ type: 'text', text }],
          source: { kind: 'dsh-memory-hint', form: 'hint' },
        }],
      }
    } catch {
      return decision // 提示失败绝不影响会话
    }
  }, { prepend: true })

  /* ── 2) memory_search 工具 ──────────────────────────────────────────── */

  ctx.tools.register({
    name: 'memory_search',
    description: '在 dsh 记忆库中按关键词检索已落盘知识（排除会话日志）。需要确认既往结论、规则、环境事实时先调用；结果含文件路径，可再读原文。',
    parameters: toJsonSchema({
      keyword: { type: 'string', required: true, description: '搜索关键词（多个词用空格分隔，按或匹配）' },
    }),
    output: textOutput(),
    async execute(args, exec) {
      const memoryDir = memoryDirFor(exec?.agent?.session)
      const script = join(memoryDir, 'scripts', 'memory_search.sh')
      if (!existsSync(script)) {
        return { text: `memory_search: 脚本不存在 ${script}（记忆库未部署 scripts/，可用 config.memoryDir 或 DSH_MEMORY_DIR 指定）` }
      }
      try {
        const { stdout } = await run('bash', [script, args.keyword], { timeout: 15000 })
        return { text: stdout || '无命中。' }
      } catch (error) {
        return { text: `memory_search 失败：${String((error && error.message) || error)}` }
      }
    },
  })

  /* ── 3) memory_sync 工具 ────────────────────────────────────────────── */

  ctx.tools.register({
    name: 'memory_sync',
    description: '把 dsh 记忆库的变更 commit 并推送到 GitLab 备份仓库（merge 不 force-push）。落盘新知识或会话结束前调用。',
    parameters: toJsonSchema({
      message: { type: 'string', description: '提交说明（可选，默认自动生成时间戳）' },
    }),
    output: textOutput(),
    async execute(args, exec) {
      const memoryDir = memoryDirFor(exec?.agent?.session)
      const script = join(memoryDir, 'scripts', 'memory_sync.sh')
      if (!existsSync(script)) {
        return { text: `memory_sync: 脚本不存在 ${script}（记忆库未部署 scripts/）` }
      }
      try {
        const { stdout } = await run('bash', [script, args.message ?? ''], { timeout: 60000 })
        return { text: stdout }
      } catch (error) {
        return { text: `memory_sync 失败：${String((error && error.message) || error)}` }
      }
    },
  })
}
