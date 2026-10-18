/**
 * dsh-memory — dsh 文件式记忆库插件（记忆方案 v1.2）
 *
 * 能力：
 *  1. 会话引导：会话首次工具调用（promotion）后，注入一次"记忆库存在"提示。
 *     提示采用惰性加载：不要求每会话预读 PROTOCOL/MEMORY，只在需要既往
 *     结论、规则或环境事实时检索；并声明记忆操作静默原则。
 *  2. memory_search：按关键词检索记忆库（调 .dsh-memory/scripts/memory_search.sh）。
 *     默认仅本地知识层、多词严格 AND（同义词按词扩展）；reference 参考层需
 *     scope=reference/all；any=true 才放宽为 OR。默认输出有硬预算。
 *     memory_get：按 path/section/offset 精准读取主题片段，避免整篇加载。
 *  3. memory_add（v1.2.0）：索引式落盘推荐写入口——条目进 MEMORY-<topic>.md，
 *     MEMORY.md 的 See 索引计数自动维护（调 scripts/memory_add.py）。
 *  4. memory_sync：git 提交并推送备份（merge 不 force-push，调 memory_sync.sh）。
 *  5. memory_init（v1.6.2）：新环境初始化记忆库（install.sh init）——无库时建空库
 *     （MEMORY.md/PROTOCOL.md/scripts/sessions + git init + 防泄漏钩子），
 *     或 --from <git-url> 克隆已有记忆库；已有库则不覆盖。
 *     库里没有 scripts/ 时，工具报错会指向本工具（此前只能人工 cd 折腾）。
 *
 * 配置项（config）：memoryDir / injectHint（默认 true）/ initHint（默认 true，
 *     无记忆库时提示如何初始化）/ searchTimeoutMs（默认 30000）/
 *     addTimeoutMs（默认 15000）/ getTimeoutMs（默认 15000）/ getMaxBytes（默认 6000）/
 *     syncTimeoutMs（默认 120000）/ initTimeoutMs（默认 60000）
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
import { fileURLToPath } from 'node:url'

const run = promisify(execFile)

/** 插件自身目录（install.sh / runtime/ 与 index.mjs 同级）。 */
const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))

/** 记忆库/插件缺件时的统一指引。 */
const MISSING_SCRIPTS_HINT = '（记忆库未部署 scripts/：可用 memory_init 初始化，或用 config.memoryDir / DSH_MEMORY_DIR 指向已有库）'

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
    if (Array.isArray(meta.enum)) prop.enum = [...meta.enum]
    if (meta.default !== undefined) prop.default = meta.default
    properties[key] = prop
    if (meta.required) required.push(key)
  }
  return { type: 'object', properties, required, additionalProperties: false }
}

/**
 * 把 memory_search 关键词串拆成多个词（空白分隔）。
 * 默认按词义组 AND；脚本 --any 时才放宽为 OR。
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
 * 逐行解析（L1 修复：空节不吞下一节；CRLF 兼容）。
 * 纯函数，便于单测。
 * @param {string} text checkpoint 文件内容
 * @returns {string} 摘要（无则空串）
 */
export function extractCheckpointSummary(text) {
  const wanted = { 'Active intent': [], 'Next action': [] }
  let cur = null
  for (const raw of String(text ?? '').split(/\r?\n/)) {
    const head = raw.match(/^##\s+(\S.*)$/)
    if (head) {
      cur = Object.prototype.hasOwnProperty.call(wanted, head[1]) ? head[1] : null
      continue
    }
    const line = raw.trim()
    if (cur && line && !line.startsWith('#')) wanted[cur].push(line)
  }
  const parts = []
  for (const name of ['Active intent', 'Next action']) {
    if (wanted[name].length) parts.push(`${name}: ${wanted[name].join(' ')}`)
  }
  const joined = parts.join(' ｜ ')
  return joined.length > 200 ? `${joined.slice(0, 200)}…` : joined
}

/** 记忆库检索脚本是否支持 v1.8 的 scope/any 选项。 */
function supportsScopedSearch(script) {
  try {
    return readFileSync(script, 'utf-8').includes('OPT_SCOPE')
  } catch {
    return false
  }
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
      // resume 安全：历史里已有本插件提示（存在性或初始化提示）则不重复注入
      if (session.events.some((ev) => ev.type === 'user/message'
        && (ev.data?.source?.kind === 'dsh-memory-hint' || ev.data?.source?.kind === 'dsh-memory-init-hint'))) {
        hinted.add(session.id)
        return decision
      }
      hinted.add(session.id)
      const memoryDir = memoryDirFor(session)
      if (!existsSync(join(memoryDir, 'MEMORY.md'))) {
        // v1.6.2：新环境没有记忆库时不再静默跳过——提示如何初始化（config.initHint=false 可关）
        if (config.initHint === false) return decision
        return {
          ...decision,
          messages: [...decision.messages, {
            id: `dsh-memory-init-hint-${session.id}`,
            role: 'user',
            content: [{ type: 'text', text: `本工作区还没有 dsh 记忆库（预期位置 ${memoryDir}）。`
              + `如需跨会话记忆，用 memory_init 工具初始化（等价于 bash ${join(PLUGIN_DIR, 'install.sh')} init <工作区目录>），`
              + `或把已有记忆库放到该位置 / 用 DSH_MEMORY_DIR 指定。未初始化前 memory_* 工具不可用。` }],
            source: { kind: 'dsh-memory-init-hint', form: 'hint' },
          }],
        }
      }

      const text = [
        `dsh 记忆库存在：${memoryDir}（dsh-memory 插件）。`,
        '按需使用：仅在任务需要复用既往结论、规则或环境事实时调 memory_search；不要为普通任务预读 MEMORY.md 或 PROTOCOL.md。',
        'memory_search 默认只查本地知识层、多词严格匹配；命中后用 memory_get 读取指定段落/行号，不要整篇读；他机参考层用 scope=reference/all，放宽用 any=true。',
        '产生可复用知识用 memory_add 落盘，topic 必须带域：dsh / idc-ops / projects / knowledge；会话收尾可写 checkpoint 或用 memory_suggest 查看候选。',
        '静默原则：记忆操作（检索/落盘/备份）一律静默进行，不向用户播报；仅当用户主动问起，或落盘的是影响后续行为的新规则时，才一句话带过。',
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
    description: '在 dsh 记忆库中检索已落盘知识（排除会话日志）。默认只查本地知识层、多词严格 AND，并按条目限制输出量；结果含相对路径和行号，命中后用 memory_get 精准读取。需要他机参考层时 scope=reference/all；需要放宽多词为 OR 时 any=true；归档主题默认隐藏，需要时 all=true。',
    parameters: toJsonSchema({
      keyword: { type: 'string', required: true, description: '搜索关键词（多个词用空格分隔；默认每个词都必须命中，同义词按词扩展）' },
      scope: {
        type: 'string',
        enum: ['local', 'reference', 'all'],
        default: 'local',
        description: '检索范围：local 仅本地主题（默认）；reference 仅他机参考层；all 两者都查',
      },
      any: { type: 'boolean', default: false, description: '多关键词是否放宽为 OR（默认 false，严格 AND）' },
      all: { type: 'boolean', default: false, description: '是否包含归档主题（默认 false；查已了结故障、历史结论时打开）' },
    }),
    output: textOutput(),
    async execute(args, exec) {
      const keywords = parseKeywords(args.keyword)
      if (keywords.length === 0) {
        return { text: 'memory_search: 缺少关键词。用法：memory_search "关键词1 关键词2"（默认多词严格匹配）' }
      }
      if (args.scope !== undefined && !['local', 'reference', 'all'].includes(args.scope)) {
        return { text: 'memory_search: scope 仅支持 local / reference / all。' }
      }
      const memoryDir = memoryDirFor(exec?.agent?.session)
      const script = join(memoryDir, 'scripts', 'memory_search.sh')
      if (!existsSync(script)) {
        return { text: `memory_search: 脚本不存在 ${script}${MISSING_SCRIPTS_HINT}` }
      }
      const scoped = supportsScopedSearch(script)
      if (!scoped && (args.scope !== undefined || args.any === true)) {
        return { text: `memory_search: 记忆库检索脚本为旧版，不支持 scope/any：${script}。`
          + '请先把记忆库 scripts/memory_search.sh 同步到 v1.8（插件 runtime/ 已带新版）。' }
      }
      try {
        // 选项必须位于关键词之前。旧版脚本不支持 scope/any，因此只在检测到新版时透传。
        const extra = []
        if (scoped) extra.push('--scope', args.scope ?? 'local')
        if (scoped && args.any === true) extra.push('--any')
        if (args.all === true) extra.push('--all')
        const { stdout } = await run('bash', [script, ...extra, ...keywords], { timeout: config.searchTimeoutMs ?? 30000 })
        let text = stdout || '无命中。'
        if (!scoped) {
          text += '\n（⚠ 记忆库检索脚本为旧版：默认 local / 严格匹配 / 输出预算未生效；请同步 scripts/memory_search.sh）'
        }
        return { text }
      } catch (error) {
        const stdout = String(error?.stdout ?? '').trim()
        const timedOut = error?.killed === true || error?.signal === 'SIGTERM'
        const detail = String(error?.stderr || error?.message || error).trim()
        if (stdout) {
          // 超时也可能已有完整结果；保留结果并明确说明，不再笼统标成“失败”。
          return { text: `${timedOut ? 'memory_search 超时，已保留部分结果：' : 'memory_search 失败：'}${stdout}${detail ? `\n${detail}` : ''}` }
        }
        return { text: `memory_search ${timedOut ? '超时' : '失败'}：${detail}` }
      }
    },
  })

  /* ── 2.5) memory_get：命中后的精准读取（v1.9.0）────────────────────── */

  ctx.tools.register({
    name: 'memory_get',
    description: '读取 memory_search 命中的 MEMORY-*.md 主题片段（精准二段式读取）：只允许记忆库内主题文件，按 section/offset/limit 和字节预算返回，避免整篇加载。',
    parameters: toJsonSchema({
      path: { type: 'string', required: true, description: '相对记忆库根的路径，来自 memory_search 输出，如 topics/dsh/MEMORY-x.md' },
      section: { type: 'string', description: '可选小节标题（子串匹配），限定在该小节内读取' },
      offset: { type: 'number', description: '绝对起始行号（1 基，可用 memory_search 输出里的 L 行号）' },
      limit: { type: 'number', default: 60, description: '最多读取行数（默认 60，最大 200）' },
    }),
    output: textOutput(),
    async execute(args, exec) {
      const pathArg = String(args.path ?? '').trim()
      if (!pathArg) {
        return { text: 'memory_get: 缺少 path。用法：memory_get {path, section?, offset?, limit?}' }
      }
      const memoryDir = memoryDirFor(exec?.agent?.session)
      const script = join(memoryDir, 'scripts', 'memory_get.py')
      if (!existsSync(script)) {
        return { text: `memory_get: 脚本不存在 ${script}${MISSING_SCRIPTS_HINT}` }
      }
      const argv = [script, '--path', pathArg]
      if (args.section) argv.push('--section', String(args.section))
      if (Number.isInteger(args.offset) && args.offset > 0) argv.push('--offset', String(args.offset))
      if (Number.isInteger(args.limit) && args.limit > 0) argv.push('--limit', String(Math.min(args.limit, 200)))
      const maxBytes = Number.isInteger(config.getMaxBytes) && config.getMaxBytes > 0
        ? Math.min(config.getMaxBytes, 20000)
        : 6000
      argv.push('--max-bytes', String(maxBytes))
      try {
        const { stdout } = await run('python3', argv, { timeout: config.getTimeoutMs ?? 15000 })
        return { text: stdout || 'memory_get: 无内容。' }
      } catch (error) {
        const detail = error && (error.stdout || error.stderr || error.message)
        return { text: `memory_get 失败：${String(detail || error).trim()}` }
      }
    },
  })

  /* ── 3) memory_add 工具（v1.2.0 推荐写入口）────────────────────────── */

  ctx.tools.register({
    name: 'memory_add',
    description: '把一条知识按索引式规范落盘到 dsh 记忆库（推荐写入口）：详情条目自动追加到 topics/<域>/MEMORY-<主题>.md（不存在则新建），MEMORY.md 的 See 索引行自动插进对应域小节、计数自动维护；同主题同标题会拒绝以防重复。产生可复用知识（新规则/定稿决策/已验证经验）时使用。',
    parameters: toJsonSchema({
      topic: { type: 'string', required: true, description: '主题名，必须带域：<域>/<主题>（域固定 dsh / idc-ops / projects / knowledge，如 dsh/dsh-memory-plugin、idc-ops/idc-ops-environment）→ 落 topics/<域>/MEMORY-<主题>.md；不存在则自动新建' },
      title: { type: 'string', required: true, description: '条目标题（简短，日期自动附加，如 v1.2.0 交付记录）' },
      body: { type: 'string', required: true, description: '条目正文（结论/路径/溯源；token/密码/私钥明文禁止入记忆，只记获取渠道）' },
    }),
    output: textOutput(),
    async execute(args, exec) {
      const topic = String(args.topic ?? '').trim()
      const title = String(args.title ?? '').trim()
      const body = String(args.body ?? '').trim()
      if (!topic || !title || !body) {
        return { text: 'memory_add: topic / title / body 均不能为空。用法：memory_add {topic, title, body}' }
      }
      const memoryDir = memoryDirFor(exec?.agent?.session)
      const script = join(memoryDir, 'scripts', 'memory_add.py')
      if (!existsSync(script)) {
        return { text: `memory_add: 脚本不存在 ${script}${MISSING_SCRIPTS_HINT}` }
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

  /* ── 4) memory_suggest 工具（v1.6.0 候选提示，半自动提取）──────────── */

  ctx.tools.register({
    name: 'memory_suggest',
    description: '查看最近会话 checkpoint 的 Discovered candidates 候选区，列出待确认落盘的知识条目（只读不写入；确认后逐条用 memory_add 落盘）。会话收尾时调用，避免漏记。',
    parameters: toJsonSchema({
      count: { type: 'number', description: '读取最近几份 checkpoint（默认 1）' },
    }),
    output: textOutput(),
    async execute(args, exec) {
      const memoryDir = memoryDirFor(exec?.agent?.session)
      const script = join(memoryDir, 'scripts', 'memory_suggest.py')
      if (!existsSync(script)) {
        return { text: `memory_suggest: 脚本不存在 ${script}${MISSING_SCRIPTS_HINT}` }
      }
      try {
        const argv = [script]
        if (Number.isInteger(args.count) && args.count > 0) argv.push(String(args.count))
        const { stdout } = await run('python3', argv, { timeout: config.addTimeoutMs ?? 15000 })
        return { text: stdout }
      } catch (error) {
        const detail = error && (error.stdout || error.stderr || error.message)
        return { text: `memory_suggest 失败：${String(detail || error).trim()}` }
      }
    },
  })

  /* ── 5) memory_sync 工具 ────────────────────────────────────────────── */

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
        return { text: `memory_sync: 脚本不存在 ${script}${MISSING_SCRIPTS_HINT}` }
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

  /* ── 6) memory_init 工具（v1.6.2，新环境初始化）──────────────────────── */

  ctx.tools.register({
    name: 'memory_init',
    description: '为当前工作区初始化 dsh 记忆库（.dsh-memory/）：建 MEMORY.md 骨架（按域分小节）/PROTOCOL.md/scripts/sessions + git init + 防泄漏钩子；已存在记忆库时不覆盖。用于"新环境里 memory_* 工具报脚本不存在"的场景。',
    parameters: toJsonSchema({
      dir: { type: 'string', description: '工作区目录（默认会话 cwd；不存在会自动创建）' },
      from: { type: 'string', description: '从已有记忆库 git 仓库克隆（含数据与脚本），而非建空库' },
      remote: { type: 'string', description: '初始化后设置 git remote origin（备份地址）' },
    }),
    output: textOutput(),
    async execute(args, exec) {
      const installSh = join(PLUGIN_DIR, 'install.sh')
      if (!existsSync(installSh)) {
        return { text: `memory_init: 找不到 ${installSh}（插件目录不完整，无法初始化）` }
      }
      const dir = String(args.dir ?? '').trim() || exec?.agent?.session?.header?.cwd || process.cwd()
      const argv = [installSh, 'init', dir]
      if (args.from) argv.push('--from', String(args.from))
      if (args.remote) argv.push('--remote', String(args.remote))
      try {
        const { stdout, stderr } = await run('bash', argv, { timeout: config.initTimeoutMs ?? 60000 })
        return { text: `${stdout}${stderr ? `\n${stderr}` : ''}`.trim() || 'memory_init 完成。' }
      } catch (error) {
        const detail = error && (error.stdout || error.stderr || error.message)
        return { text: `memory_init 失败：${String(detail || error).trim()}` }
      }
    },
  })
}
