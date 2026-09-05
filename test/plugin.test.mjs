import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { apply } from '../index.mjs'

/** 最小 fake cordis ctx：on 收集 handler、tools.register 收集工具 */
function fakeCtx() {
  const handlers = {}
  const tools = {}
  const ctx = {
    on: (ev, h) => { handlers[ev] = h },
    tools: { register: (t) => { tools[t.name] = t } },
  }
  ctx._handlers = handlers
  ctx._tools = tools
  return ctx
}

function fakeSession(cwd, events = []) {
  return { id: 'ses-1', header: { cwd }, events }
}

/** 造最小记忆库（无 scripts） */
function makeMem() {
  const root = mkdtempSync(join(tmpdir(), 'dsh-plugin-test-'))
  const mem = join(root, '.dsh-memory')
  mkdirSync(mem, { recursive: true })
  writeFileSync(join(mem, 'MEMORY.md'), '# mem\n')
  return { root, mem }
}

async function runPreStep(ctx, session) {
  return ctx._handlers['agent/pre-step'](
    { agent: { session }, signal: {} },
    async () => ({ messages: [] }),
  )
}

function emitToolCall(ctx, session) {
  ctx._handlers['session/event'](session, { type: 'tool/call' })
}

test('工具注册：memory_search / memory_add / memory_suggest / memory_sync 齐全', () => {
  const ctx = fakeCtx()
  apply(ctx, {})
  for (const name of ['memory_search', 'memory_add', 'memory_suggest', 'memory_sync']) {
    assert.ok(ctx._tools[name], `缺工具 ${name}`)
  }
})

test('hint：首次 tool/call 后注入一次；无 tool/call 不注入', async () => {
  const { root } = makeMem()
  try {
    const ctx = fakeCtx()
    apply(ctx, {})
    const session = fakeSession(root)
    // 无 tool/call → 不注入
    let d = await runPreStep(ctx, session)
    assert.equal(d.messages.length, 0)
    // 有 tool/call → 注入
    emitToolCall(ctx, session)
    d = await runPreStep(ctx, session)
    assert.equal(d.messages.length, 1)
    assert.ok(d.messages[0].content[0].text.includes('dsh 记忆库存在'))
    // 同会话第二次 → 不重复
    d = await runPreStep(ctx, session)
    assert.equal(d.messages.length, 0)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('hint：resume 历史已有插件提示则不重复', async () => {
  const { root } = makeMem()
  try {
    const ctx = fakeCtx()
    apply(ctx, {})
    const session = fakeSession(root, [{
      type: 'user/message',
      data: { source: { kind: 'dsh-memory-hint', form: 'hint' } },
    }])
    emitToolCall(ctx, session)
    const d = await runPreStep(ctx, session)
    assert.equal(d.messages.length, 0)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('hint：injectHint=false 关闭注入；记忆库缺失跳过', async () => {
  const { root } = makeMem()
  try {
    const ctx = fakeCtx()
    apply(ctx, { injectHint: false })
    const session = fakeSession(root)
    emitToolCall(ctx, session)
    let d = await runPreStep(ctx, session)
    assert.equal(d.messages.length, 0)

    // 记忆库缺失（cwd 无 .dsh-memory 且 config.memoryDir 指向空目录）
    const empty = mkdtempSync(join(tmpdir(), 'dsh-empty-'))
    const ctx2 = fakeCtx()
    apply(ctx2, { memoryDir: empty })
    const s2 = fakeSession(empty)
    emitToolCall(ctx2, s2)
    d = await runPreStep(ctx2, s2)
    assert.equal(d.messages.length, 0)
    rmSync(empty, { recursive: true, force: true })
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('checkpoint 注入：默认不含摘要；开启且存在 checkpoint 时按护栏注入', async () => {
  const { root, mem } = makeMem()
  try {
    mkdirSync(join(mem, 'sessions'))
    writeFileSync(join(mem, 'sessions', '2026-09-05-1000-测试.md'),
      '# cp\n## Active intent\n修复检索\n## Next action\n发布 v1.6.0\n## Current work\n不该注入的详情\n')

    // 默认关闭：不含 checkpoint 摘要
    const ctx = fakeCtx()
    apply(ctx, {})
    const s = fakeSession(root)
    emitToolCall(ctx, s)
    let d = await runPreStep(ctx, s)
    const text0 = d.messages[0].content[0].text
    assert.ok(!text0.includes('上次会话 checkpoint'))

    // 开启：含两节摘要、不含 Current work
    const ctx2 = fakeCtx()
    apply(ctx2, { injectRecentCheckpoint: true })
    const s2 = fakeSession(root)
    emitToolCall(ctx2, s2)
    d = await runPreStep(ctx2, s2)
    const text1 = d.messages[0].content[0].text
    assert.ok(text1.includes('上次会话 checkpoint'))
    assert.ok(text1.includes('Active intent: 修复检索'))
    assert.ok(text1.includes('Next action: 发布 v1.6.0'))
    assert.ok(!text1.includes('不该注入的详情'))
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('memory_search：空关键词提示；脚本缺失报错', async () => {
  const { root, mem } = makeMem()
  try {
    const ctx = fakeCtx()
    apply(ctx, {})
    const exec = { agent: { session: fakeSession(root) } }
    const r1 = await ctx._tools.memory_search.execute({ keyword: '  ' }, exec)
    assert.ok(r1.text.includes('缺少关键词'))
    const r2 = await ctx._tools.memory_search.execute({ keyword: 'x' }, exec)
    assert.ok(r2.text.includes('脚本不存在'))
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('memory_add / memory_suggest / memory_sync：参数校验与脚本缺失报错', async () => {
  const { root } = makeMem()
  try {
    const ctx = fakeCtx()
    apply(ctx, {})
    const exec = { agent: { session: fakeSession(root) } }
    const r1 = await ctx._tools.memory_add.execute({ topic: 't', title: '', body: '' }, exec)
    assert.ok(r1.text.includes('均不能为空'))
    const r2 = await ctx._tools.memory_add.execute({ topic: 't', title: 'x', body: 'y' }, exec)
    assert.ok(r2.text.includes('脚本不存在'))
    const r3 = await ctx._tools.memory_suggest.execute({}, exec)
    assert.ok(r3.text.includes('脚本不存在'))
    const r4 = await ctx._tools.memory_sync.execute({}, exec)
    assert.ok(r4.text.includes('脚本不存在'))
  } finally { rmSync(root, { recursive: true, force: true }) }
})
