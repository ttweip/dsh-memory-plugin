import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const PLUGIN_DIR = dirname(dirname(fileURLToPath(import.meta.url)))
const INSTALL_SH = join(PLUGIN_DIR, 'install.sh')
const git = (args, cwd) => execFileSync('git', args, { cwd, encoding: 'utf8' })
const sh = (args) => execFileSync('bash', [INSTALL_SH, ...args], { encoding: 'utf8' })

test('install.sh init：空库脚手架（模板/脚本/git/防泄漏钩子）+ 幂等拒绝', () => {
  const ws = mkdtempSync(join(tmpdir(), 'dsh-init-'))
  try {
    const out = sh(['init', ws])
    assert.ok(out.includes('记忆库就绪'), out)
    const mem = join(ws, '.dsh-memory')
    for (const f of ['MEMORY.md', 'PROTOCOL.md', '.gitignore',
      'scripts/memory_add.py', 'scripts/memory_search.sh', 'scripts/memory_sync.sh',
      'scripts/memory_suggest.py', 'scripts/audit_secrets.sh', 'scripts/selfcheck.sh',
      'scripts/synonyms.tsv', '.git/hooks/pre-commit']) {
      assert.ok(existsSync(join(mem, f)), `缺 ${f}`)
    }
    // 骨架索引含 4 个域小节（memory_add 域感知插入依赖）
    const idx = execFileSync('cat', [join(mem, 'MEMORY.md')], { encoding: 'utf8' })
    for (const d of ['### dsh', '### idc-ops', '### projects', '### knowledge']) {
      assert.ok(idx.includes(d), `索引缺域小节 ${d}`)
    }
    // 初始 commit 已生成
    assert.equal(git(['rev-list', '--count', 'HEAD'], mem).trim(), '1')
    // 幂等：不加 --force 时拒绝
    assert.ok(sh(['init', ws]).includes('已存在记忆库'))
  } finally { rmSync(ws, { recursive: true, force: true }) }
})

test('install.sh init --from：从已有仓库克隆（数据+脚本），并设置 remote 与钩子', () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-init-from-'))
  try {
    const seed = join(root, 'seed')
    mkdirSync(join(seed, 'scripts'), { recursive: true })
    writeFileSync(join(seed, 'MEMORY.md'), '# Project memory — seed\n')
    writeFileSync(join(seed, 'PROTOCOL.md'), '# seed protocol\n')
    // 真脚本（--install 会写 .git/hooks/pre-commit），用记忆库的审计脚本
    execFileSync('cp', [join(PLUGIN_DIR, 'runtime', 'audit_secrets.sh'), join(seed, 'scripts', 'audit_secrets.sh')])
    git(['init', '-q'], seed)
    git(['add', '-A'], seed)
    git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'init'], seed)
    const bare = join(root, 'origin.git')
    execFileSync('git', ['clone', '-q', '--bare', seed, bare])

    const ws = join(root, 'ws')
    const out = sh(['init', ws, '--from', bare, '--remote', bare])
    assert.ok(out.includes('克隆记忆库'), out)
    const mem = join(ws, '.dsh-memory')
    assert.ok(existsSync(join(mem, 'MEMORY.md')))
    assert.ok(existsSync(join(mem, 'scripts', 'audit_secrets.sh')))
    assert.equal(git(['remote', 'get-url', 'origin'], mem).trim(), bare)
    assert.ok(existsSync(join(mem, '.git', 'hooks', 'pre-commit')), '克隆后应补装防泄漏钩子')
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('install.sh init --no-git：不建仓库；sync-runtime 可从记忆库刷新 runtime/', () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-init-nogit-'))
  try {
    const ws = join(root, 'ws')
    sh(['init', ws, '--no-git'])
    const mem = join(ws, '.dsh-memory')
    assert.ok(existsSync(join(mem, 'MEMORY.md')))
    assert.ok(!existsSync(join(mem, '.git')), '--no-git 不应建 .git')

    // sync-runtime：把库内 scripts 同步进插件 runtime/（不改变文件集合）
    const before = execFileSync('ls', [join(PLUGIN_DIR, 'runtime')], { encoding: 'utf8' }).trim().split('\n').length
    const out2 = sh(['sync-runtime', mem])
    assert.ok(out2.includes('runtime/ 已同步'), out2)
    const after = execFileSync('ls', [join(PLUGIN_DIR, 'runtime')], { encoding: 'utf8' }).trim().split('\n').length
    assert.equal(after, before)
  } finally { rmSync(root, { recursive: true, force: true }) }
})
