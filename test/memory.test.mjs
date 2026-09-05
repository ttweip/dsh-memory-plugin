import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { resolveMemoryDir, parseKeywords, extractCheckpointSummary } from '../index.mjs'

/** 造一个含 MEMORY.md 的记忆库目录 */
function makeRepo(root, name) {
  const dir = join(root, name)
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'MEMORY.md'), '# mem\n')
  return dir
}

function tmpRoot() {
  return mkdtempSync(join(tmpdir(), 'dsh-mem-test-'))
}

test('parseKeywords：空白拆词、去空、容错', () => {
  assert.deepEqual(parseKeywords('静默 GitLab'), ['静默', 'GitLab'])
  assert.deepEqual(parseKeywords('  a   b  '), ['a', 'b'])
  assert.deepEqual(parseKeywords('单'), ['单'])
  assert.deepEqual(parseKeywords(''), [])
  assert.deepEqual(parseKeywords('   '), [])
  assert.deepEqual(parseKeywords(undefined), [])
  assert.deepEqual(parseKeywords(null), [])
})

test('resolveMemoryDir：config.memoryDir 最高优先（压过 env 与发现）', () => {
  const root = tmpRoot()
  try {
    const a = makeRepo(root, '.dsh-memory')
    const b = makeRepo(root, 'other')
    assert.equal(resolveMemoryDir(root, { memoryDir: b }), b)
    assert.equal(resolveMemoryDir(root, { memoryDir: b }, { DSH_MEMORY_DIR: a }), b)
    assert.equal(resolveMemoryDir(undefined, { memoryDir: b }), b)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('resolveMemoryDir：DSH_MEMORY_DIR 次之', () => {
  const root = tmpRoot()
  try {
    const a = makeRepo(root, '.dsh-memory')
    assert.equal(resolveMemoryDir('/unrelated', {}, { DSH_MEMORY_DIR: a }), a)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('resolveMemoryDir：cwd 向上动态发现（就近命中、新名优先旧名）', () => {
  const root = tmpRoot()
  try {
    const hidden = makeRepo(root, '.dsh-memory')              // 顶层：规范隐藏名
    const legacy = makeRepo(join(root, 'sub'), 'dsh-memory')  // 深层：旧名
    mkdirSync(join(root, 'sub', 'deep'), { recursive: true })

    // 从 deep 逐级向上：在 sub 层命中旧名（就近原则）
    assert.equal(resolveMemoryDir(join(root, 'sub', 'deep')), legacy)
    // 从 root 层：命中顶层 .dsh-memory
    assert.equal(resolveMemoryDir(root), hidden)
    // 同一层同时存在新旧名 → 规范名优先
    const both = tmpRoot()
    try {
      const h2 = makeRepo(both, '.dsh-memory')
      makeRepo(both, 'dsh-memory')
      assert.equal(resolveMemoryDir(both), h2)
    } finally { rmSync(both, { recursive: true, force: true }) }
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('resolveMemoryDir：无命中时走兜底', () => {
  const root = tmpRoot()
  try {
    const empty = join(root, 'nothing-here')
    mkdirSync(empty, { recursive: true })
    assert.equal(resolveMemoryDir(empty), resolveMemoryDir()) // 与默认兜底一致
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('extractCheckpointSummary：只取 Active intent / Next action 两节', () => {
  const cp = `# Session checkpoint 2026-09-02
## Active intent
修复 dsh-memory 检索排序
## Next action
发布 v1.4.0 双端
## Current work
一大堆不该注入的详情……
## Errors and fixes
踩坑记录`
  const s = extractCheckpointSummary(cp)
  assert.ok(s.includes('Active intent: 修复 dsh-memory 检索排序'))
  assert.ok(s.includes('Next action: 发布 v1.4.0 双端'))
  assert.ok(!s.includes('Current work'))
  assert.ok(!s.includes('一大堆不该注入的详情'))
})

test('extractCheckpointSummary：200 字硬上限截断', () => {
  const long = `# c
## Active intent
${'长'.repeat(300)}
## Next action
x`
  const s = extractCheckpointSummary(long)
  assert.ok(s.length <= 203) // 200 + 省略号
  assert.ok(s.endsWith('…'))
})

test('extractCheckpointSummary：缺节/空文本返回空串', () => {
  assert.equal(extractCheckpointSummary('# c\n## Other\nx'), '')
  assert.equal(extractCheckpointSummary(''), '')
  assert.equal(extractCheckpointSummary(undefined), '')
})

test('extractCheckpointSummary：空节不吞下一节（L1 回归）', () => {
  const cp = `# c
## Active intent
## Next action
做 x
## Current work
y`
  const s = extractCheckpointSummary(cp)
  assert.ok(s.includes('Next action: 做 x'))
  assert.ok(!s.includes('Active intent'))
  assert.ok(!s.includes('Current work'))
})

test('extractCheckpointSummary：CRLF 与多行正文', () => {
  const cp = '# c\r\n## Active intent\r\n第一行\r\n第二行\r\n## Next action\r\n下一\r\n'
  const s = extractCheckpointSummary(cp)
  assert.ok(s.includes('Active intent: 第一行 第二行'))
  assert.ok(s.includes('Next action: 下一'))
})
