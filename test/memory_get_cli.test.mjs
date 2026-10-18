import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const PLUGIN_DIR = dirname(dirname(fileURLToPath(import.meta.url)))
const GET_SRC = join(PLUGIN_DIR, 'runtime', 'memory_get.py')

function makeLibrary() {
  const root = mkdtempSync(join(tmpdir(), 'dsh-memory-get-'))
  const lib = join(root, '.dsh-memory')
  mkdirSync(join(lib, 'scripts'), { recursive: true })
  mkdirSync(join(lib, 'topics', 'dsh'), { recursive: true })
  writeFileSync(join(lib, 'scripts', 'memory_get.py'), readFileSync(GET_SRC))
  writeFileSync(join(lib, 'MEMORY.md'), '# index\n')
  writeFileSync(join(lib, 'topics', 'dsh', 'MEMORY-sample.md'), [
    '# MEMORY-sample.md',
    '- **第一条**：alpha',
    '## Section One',
    'line one',
    'line two',
    '## Section Two',
    'line three',
    'line four',
    '',
  ].join('\n'))
  return { root, lib }
}

function run(lib, args) {
  const r = spawnSync('python3', [join(lib, 'scripts', 'memory_get.py'), ...args], {
    encoding: 'utf8',
    timeout: 10000,
  })
  return { code: r.status, stdout: r.stdout, stderr: r.stderr }
}

test('memory_get CLI：小节限定与 line 号输出', () => {
  const { root, lib } = makeLibrary()
  try {
    const r = run(lib, ['--path', 'topics/dsh/MEMORY-sample.md', '--section', 'Section One'])
    assert.equal(r.code, 0, r.stderr)
    assert.match(r.stdout, /Section One/)
    assert.match(r.stdout, /line one/)
    assert.match(r.stdout, /line two/)
    assert.doesNotMatch(r.stdout, /Section Two/)
    assert.doesNotMatch(r.stdout, /line three/)
    assert.match(r.stdout, /L3-L5 \/ 8 行/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('memory_get CLI：offset/limit 与未显示提示', () => {
  const { root, lib } = makeLibrary()
  try {
    const r = run(lib, ['--path', 'topics/dsh/MEMORY-sample.md', '--offset', '7', '--limit', '1'])
    assert.equal(r.code, 0, r.stderr)
    assert.match(r.stdout, /L7-L7/)
    assert.match(r.stdout, /line three/)
    assert.match(r.stdout, /还有 1 行未显示/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('memory_get CLI：字节预算上限', () => {
  const { root, lib } = makeLibrary()
  try {
    const long = 'x'.repeat(2000)
    writeFileSync(join(lib, 'topics', 'dsh', 'MEMORY-long.md'), `# long\n## Big\n${long}\n${long}\n`)
    const r = run(lib, [
      '--path', 'topics/dsh/MEMORY-long.md', '--section', 'Big', '--limit', '20', '--max-bytes', '800',
    ])
    assert.equal(r.code, 0, r.stderr)
    assert.ok(Buffer.byteLength(r.stdout, 'utf8') <= 800, `output=${Buffer.byteLength(r.stdout, 'utf8')}`)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('memory_get CLI：拒绝越界/非主题文件/不存在小节', () => {
  const { root, lib } = makeLibrary()
  try {
    const traversal = run(lib, ['--path', '../MEMORY.md'])
    assert.equal(traversal.code, 1)
    assert.match(traversal.stderr, /相对路径|越出/)
    const meta = run(lib, ['--path', 'MEMORY.md'])
    assert.equal(meta.code, 1)
    const script = run(lib, ['--path', 'scripts/memory_get.py'])
    assert.equal(script.code, 1)
    const missing = run(lib, ['--path', 'topics/dsh/MEMORY-sample.md', '--section', 'No Such Section'])
    assert.equal(missing.code, 1)
    assert.match(missing.stderr, /未找到小节/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('memory_get CLI：--version', () => {
  const { root, lib } = makeLibrary()
  try {
    const r = run(lib, ['--version'])
    assert.equal(r.code, 0)
    assert.match(r.stdout, /1\.9\.0/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
