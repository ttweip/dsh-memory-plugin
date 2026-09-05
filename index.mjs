/**
 * dsh-memory — dsh 文件式记忆库插件（记忆方案 v1.2）
 *
 * 能力：
 *  1. 会话引导：会话首次工具调用（promotion）后，注入一次"记忆库存在"提示，
 *     指引模型读 PROTOCOL.md / MEMORY.md、按索引式落盘、结束写 checkpoint，
 *     并声明静默原则：记忆操作（检索/落盘/备份）不向用户播报。
 *     （与 preset 的 instruction-hint 同一模式：只提示存在性，不注入内容。）
 *  2. memory_search：按关键词检索记忆库（调 .dsh-memory/scripts/memory_search.sh）。
 *     多关键词以空白分隔、按或（OR）匹配（v1.0.4 修复：此前整串字面匹配）。
 *  3. memory_add（v1.2.0）：索引式落盘推荐写入口——条目进 MEMORY-<topic>.md，
 *     MEMORY.md 的 See 索引计数自动维护（调 scripts/memory_add.py）。
 *  4. memory_sync：git 提交并推送备份（merge 不 force-push，调 memory_sync.sh）。
 *
 * 配置项（config）：memoryDir / injectHint / searchTimeoutMs（默认 15000）/
 *     addTimeoutMs（默认 15000）/ syncTimeoutMs（默认 120000）
 *
 * 记忆库定位（v1.2 隐藏目录规范）：
 *     config.memoryDir > 环境变量 DSH_MEMORY_DIR > 从会话 cwd 向上查找
 *     .dsh-memory/（隐藏目录，含 MEMORY.md 即命中；兼容旧名 dsh-memory/）
 *     > 兜底 /mnt/smb/.dsh-memory
 *
 * 依赖：记忆数据仓库 .dsh-memory（含 scripts/）。
 * 任何异常只降级为工具报错/跳过提示，绝不破坏会话。
 */
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'

const run = promisify(execFile)

/** Cordis 插件名（loader 诊断用）。 */
export const name = 'dsh-memory'

/** 需要 tools 服务先就绪。 */
export const inject = ['tools']

/** 兜底位置（本机 fstab 固定挂载点；仅当动态发现全部失败时使用）。 */
const DEFAULT_DIR = '/mnt/smb/.dsh-memory'

/** 向上查找的候选目录名：规范 .dsh-memory（隐藏），兼容 dsh-memory（旧名）。 */
const CANDIDATE_NAMES = ['.dsh-memory', 'dsh-memory']

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
      for (const candidate of CANDIDATE_NAMES) {
        const dir = join(cur, candidate)
        if (existsSync(join(dir, 'MEMORY.md'))) return dir
      }
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

/**
 * 把 memory_search 关键词串拆成多个词（空白分隔，按或匹配）。
 * 纯函数，便于单测。
 * @param {string} keyword
 * @returns {string[]}
 */
export function parseKeywords(keyword) {
  return String(keyword ?? '').trim().split(/\s+/).filter(Boolean)
}

/**
 * 从 checkpoint 文本提取 Active intent / Next action 摘要。
 * 护栏（PROTOCOL §7）：只取这两节、总长 200 字上限、不取 Current work 等详情。
 * 纯函数，便于单测。
 * @param {string} text checkpoint 文件内容
 * @returns {string} 摘要（无则空串）
 */
export function extractCheckpointSummary(text) {
  const parts = []
  for (const name of ['Active intent', 'Next action']) {
    const re = new RegExp(`##\\s+${name}[^\\n]*\\n([\\s\\S]*?)(?=\\n##\\s|$)`)
    const m = String(text ?? '').match(re)
    if (!m) continue
    const body = m[1].split('\n')
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith('#'))
      .join(' ')
    if (body) parts.push(`${name}: ${body}`)
  }
  const joined = parts.join(' ｜ ')
  return joined.length > 200 ? `${joined.slice(0, 200)}…` : joined
}

/** sessions/ 下最新一份 checkpoint 的绝对路径；无则 null。 */
function latestCheckpoint(memoryDir) {
  try {
    const dir = join(memoryDir, 'sessions')
    if (!existsSync(dir)) return null
    const files = readdirSync(dir).filter((f) => f.endsWith('.md'))
    if (files.length === 0) return null
    files.sort((a, b) => statSync(join(dir, b)).mtimeMs - statSync(join(dir, a)).mtimeMs)
    return join(dir, files[0])
  } catch {
    return null
  }
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
        '涉及本工作区的任务，先读 PROTOCOL.md 与 MEMORY.md，需要时读对应 MEMORY-<topic>.md；',
        '可复用知识用 memory_add 索引式落盘（详情自动进 MEMORY-<topic>.md，See 索引自动维护）；',
        '会话结束按需写 sessions/ 下 checkpoint（Active intent / Next action / Discovered candidates / Errors / Live resources）。',
        '静默原则：记忆操作（检索/落盘/备份）一律静默进行，不向用户播报；仅当用户主动问起，或落盘的是影响后续行为的新规则时，才一句话带过。',
        '可用工具：memory_add（落盘，推荐写入口）、memory_search（检索）、memory_sync（git 备份）。',
      ].join(' ')

      // 护栏（PROTOCOL §7）：checkpoint 摘要注入默认关闭，开启后只带两节、200 字上限
      let fullText = text
      if (config.injectRecentCheckpoint === true) {
        const cp = latestCheckpoint(memoryDir)
        if (cp) {
          const summary = extractCheckpointSummary(readFileSync(cp, 'utf-8'))
          if (summary) fullText += `【上次会话 checkpoint：${basename(cp)}】${summary}`
        }
      }

      return {
        ...decision,
        messages: [...decision.messages, {
          id: `dsh-memory-hint-${session.id}`,
          role: 'user',
          content: [{ type: 'text', text: fullText }],
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
      const keywords = parseKeywords(args.keyword)
      if (keywords.length === 0) {
        return { text: 'memory_search: 缺少关键词。用法：memory_search "关键词1 关键词2"（多词按或匹配）' }
      }
      try {
        const { stdout } = await run('bash', [script, ...keywords], { timeout: config.searchTimeoutMs ?? 15000 })
        return { text: stdout || '无命中。' }
      } catch (error) {
        const detail = error && (error.stdout || error.stderr || error.message)
        return { text: `memory_search 失败：${String(detail || error).trim()}` }
      }
    },
  })

  /* ── 3) memory_add 工具（v1.2.0 推荐写入口）────────────────────────── */

  ctx.tools.register({
    name: 'memory_add',
    description: '把一条知识按索引式规范落盘到 dsh 记忆库（推荐写入口）：详情条目自动追加到 MEMORY-<topic>.md（不存在则新建），MEMORY.md 的 See 索引计数自动维护；同主题同标题会拒绝以防重复。产生可复用知识（新规则/定稿决策/已验证经验）时使用。',
    parameters: toJsonSchema({
      topic: { type: 'string', required: true, description: '主题名（对应 MEMORY-<topic>.md，如 dsh-memory-plugin / idc-ops-environment；不存在则自动新建）' },
      title: { type: 'string', required: true, description: '条目标题（简短，日期自动附加，如 v1.2.0 交付记录）' },
      body: { type: 'string', required: true, description: '条目正文（结论/路径/溯源；token/密码/私钥明文禁止入记忆，只记获取渠道）' },
    }),
    output: textOutput(),
    async execute(args, exec) {
      const memoryDir = memoryDirFor(exec?.agent?.session)
      const script = join(memoryDir, 'scripts', 'memory_add.py')
      if (!existsSync(script)) {
        return { text: `memory_add: 脚本不存在 ${script}（记忆库未部署 scripts/，可用 config.memoryDir 或 DSH_MEMORY_DIR 指定）` }
      }
      const topic = String(args.topic ?? '').trim()
      const title = String(args.title ?? '').trim()
      const body = String(args.body ?? '').trim()
      if (!topic || !title || !body) {
        return { text: 'memory_add: topic / title / body 均不能为空。用法：memory_add {topic, title, body}' }
      }
      try {
        const { stdout } = await run('python3', [script, topic, title, body], { timeout: config.addTimeoutMs ?? 15000 })
        return { text: stdout }
      } catch (error) {
        const detail = error && (error.stdout || error.stderr || error.message)
        return { text: `memory_add 失败：${String(detail || error).trim()}` }
      }
    },
  })

  /* ── 4) memory_sync 工具 ────────────────────────────────────────────── */

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
        const { stdout } = await run('bash', [script, args.message ?? ''], { timeout: config.syncTimeoutMs ?? 120000 })
        return { text: stdout }
      } catch (error) {
        const detail = error && (error.stdout || error.stderr || error.message)
        return { text: `memory_sync 失败：${String(detail || error).trim()}` }
      }
    },
  })
}
