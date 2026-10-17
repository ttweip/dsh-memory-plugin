import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const runAsync = promisify(execFile)
const PLUGIN_DIR = dirname(dirname(fileURLToPath(import.meta.url)))
const SEARCH_SRC = join(PLUGIN_DIR, 'runtime', 'memory_search.sh')
const SYN_SRC = join(PLUGIN_DIR, 'runtime', 'synonyms.tsv')

/** 建一个最小记忆库，并复制实际检索脚本。 */
function makeLibrary() {
  const root = mkdtempSync(join(tmpdir(), 'dsh-search-cli-'))
  const lib = join(root, '.dsh-memory')
  mkdirSync(join(lib, 'scripts'), { recursive: true })
  mkdirSync(join(lib, 'topics', 'dsh'), { recursive: true })
  writeFileSync(join(lib, 'scripts', 'memory_search.sh'), readFileSync(SEARCH_SRC))
  writeFileSync(join(lib, 'scripts', 'synonyms.tsv'), readFileSync(SYN_SRC))
  writeFileSync(join(lib, 'MEMORY.md'), '# index\n索元文件独有\n')
  writeFileSync(join(lib, 'PROTOCOL.md'), '# protocol\n协议元文件独有\n')
  return { root, lib, script: join(lib, 'scripts', 'memory_search.sh') }
}

function writeTopic(lib, rel, body) {
  const path = join(lib, ...rel.split('/'))
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, body)
}

function run(lib, args, extraEnv = {}) {
  return new Promise((resolve) => {
    execFile('bash', [join(lib, 'scripts', 'memory_search.sh'), ...args], {
      encoding: 'utf8',
      env: { ...process.env, DSH_SKIP_ENV_CHECK: '1', ...extraEnv },
      timeout: 30000,
    }, (error, stdout, stderr) => {
      resolve({ code: error?.code ?? 0, stdout, stderr, error })
    })
  })
}

test('search CLI：默认 local，隔离 reference / 元文件 / scripts', async () => {
  const { root, lib } = makeLibrary()
  try {
    writeTopic(lib, 'topics/dsh/MEMORY-local.md', '# local\n- **本地**：localonly 本地层独有\n')
    writeTopic(lib, 'reference/128/topics/MEMORY-ref.md', '# ref\n- **参考**：refonly 参考层独有\n')
    writeFileSync(join(lib, 'scripts', 'extra.sh'), '- **脚本**：scriptonly 脚本独有\n')

    const local = await run(lib, ['localonly'])
    assert.equal(local.code, 0, local.stderr)
    assert.match(local.stdout, /topics\/dsh\/MEMORY-local\.md/)
    assert.doesNotMatch(local.stdout, /reference\/128/)
    assert.doesNotMatch(local.stdout, /MEMORY\.md/)
    assert.doesNotMatch(local.stdout, /PROTOCOL\.md/)

    const meta1 = await run(lib, ['索元文件独有'])
    assert.doesNotMatch(meta1.stdout, /MEMORY\.md/)
    const meta2 = await run(lib, ['协议元文件独有'])
    assert.doesNotMatch(meta2.stdout, /PROTOCOL\.md/)
    const script = await run(lib, ['scriptonly'])
    assert.doesNotMatch(script.stdout, /scripts\/extra\.sh/)

    const included = await run(lib, ['--include-scripts', 'scriptonly'])
    assert.match(included.stdout, /scripts\/extra\.sh/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('search CLI：scope=reference/all 显式隔离与合并', async () => {
  const { root, lib } = makeLibrary()
  try {
    writeTopic(lib, 'topics/dsh/MEMORY-local.md', '# local\n- **本地**：sharedterm 本地\n')
    writeTopic(lib, 'reference/128/topics/MEMORY-ref.md', '# ref\n- **参考**：sharedterm 参考\n')
    writeFileSync(join(lib, 'reference', '128', 'README.md'), '# meta\nreadmeonly\n')

    const def = await run(lib, ['sharedterm'])
    assert.match(def.stdout, /MEMORY-local\.md/)
    assert.doesNotMatch(def.stdout, /reference\/128/)

    const ref = await run(lib, ['--scope', 'reference', 'sharedterm'])
    assert.match(ref.stdout, /reference\/128\/topics\/MEMORY-ref\.md/)
    assert.doesNotMatch(ref.stdout, /MEMORY-local\.md/)

    const all = await run(lib, ['--scope', 'all', 'sharedterm'])
    assert.match(all.stdout, /MEMORY-local\.md/)
    assert.match(all.stdout, /reference\/128\/topics\/MEMORY-ref\.md/)

    const readme = await run(lib, ['--scope', 'all', 'readmeonly'])
    assert.doesNotMatch(readme.stdout, /README\.md/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('search CLI：默认严格 AND，--any 才 OR', async () => {
  const { root, lib } = makeLibrary()
  try {
    writeTopic(lib, 'topics/dsh/MEMORY-combo.md', '# combo\n- **组合**：alpha beta 同时出现\n')
    writeTopic(lib, 'topics/dsh/MEMORY-alpha.md', '# alpha\n- **单 alpha**：alpha 单独\n')
    writeTopic(lib, 'topics/dsh/MEMORY-beta.md', '# beta\n- **单 beta**：beta 单独\n')

    const strict = await run(lib, ['alpha', 'beta'])
    assert.match(strict.stdout, /MEMORY-combo\.md/)
    assert.doesNotMatch(strict.stdout, /MEMORY-alpha\.md/)
    assert.doesNotMatch(strict.stdout, /MEMORY-beta\.md/)

    const any = await run(lib, ['--any', 'alpha', 'beta'])
    assert.match(any.stdout, /MEMORY-combo\.md/)
    assert.match(any.stdout, /MEMORY-alpha\.md/)
    assert.match(any.stdout, /MEMORY-beta\.md/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('search CLI：默认文件/行预算与可调预算', async () => {
  const { root, lib } = makeLibrary()
  try {
    for (let i = 1; i <= 5; i += 1) {
      writeTopic(lib, `topics/dsh/MEMORY-budget${i}.md`, `# b${i}\n- **预算**：budgetterm\n`)
    }
    const budget = await run(lib, ['budgetterm'])
    const headers = budget.stdout.match(/^\[\d+\/\d+\] /gm) || []
    assert.ok(headers.length <= 3, budget.stdout)
    assert.match(budget.stdout, /还有 2 个文件未列出/)

    const many = Array.from({ length: 8 }, (_, i) => `- **多行${i}**：manyterm`).join('\n')
    writeTopic(lib, 'topics/dsh/MEMORY-many.md', `# many\n${many}\n`)
    const lines = await run(lib, ['manyterm'])
    assert.match(lines.stdout, /该文件还有/)

    const capped = await run(lib, ['budgetterm'], {
      MEMORY_SEARCH_MAX_FILES: '5',
      MEMORY_SEARCH_MAX_PER_FILE: '1',
      MEMORY_SEARCH_MAX_LINES: '4',
    })
    assert.ok((capped.stdout.match(/^\[\d+\/\d+\] /gm) || []).length <= 4, capped.stdout)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('search CLI：选项边界、空关键词、非法 scope、-- 终止符', async () => {
  const { root, lib } = makeLibrary()
  try {
    const noKw = await run(lib, [])
    assert.equal(noKw.code, 1)
    assert.match(noKw.stderr, /用法/)

    const missing = await run(lib, ['--scope'])
    assert.equal(missing.code, 2)

    const bad = await run(lib, ['--scope', 'bad', 'x'])
    assert.equal(bad.code, 2)
    assert.match(bad.stderr, /仅支持 local\|reference\|all/)

    const unknown = await run(lib, ['--nope', 'x'])
    assert.equal(unknown.code, 2)

    const literal = await run(lib, ['--', '--all'])
    assert.equal(literal.code, 0)
    assert.match(literal.stdout, /--all/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('search CLI：空库、无 reference 目录、文件名含空格', async () => {
  const { root, lib } = makeLibrary()
  try {
    const empty = await run(lib, ['anything'])
    assert.equal(empty.code, 0)
    assert.match(empty.stdout, /无命中/)

    const ref = await run(lib, ['--scope', 'reference', 'anything'])
    assert.equal(ref.code, 0)
    assert.match(ref.stdout, /无命中/)

    writeTopic(lib, 'topics/dsh/MEMORY-space name.md', '# space\n- **空格文件名**：spacedterm\n')
    const spaced = await run(lib, ['spacedterm'])
    assert.match(spaced.stdout, /MEMORY-space name\.md/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('search CLI：并发调用输出一致', async () => {
  const { root, lib } = makeLibrary()
  try {
    writeTopic(lib, 'topics/dsh/MEMORY-concurrent.md', '# c\n- **并发**：concurrentterm\n')
    const runs = await Promise.all(Array.from({ length: 8 }, () => run(lib, ['concurrentterm'])))
    for (const r of runs) {
      assert.equal(r.code, 0, r.stderr)
      assert.equal(r.stdout, runs[0].stdout)
    }
  } finally { rmSync(root, { recursive: true, force: true }) }
})
