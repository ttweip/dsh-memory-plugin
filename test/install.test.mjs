import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, rmSync, statSync, cpSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const PLUGIN_DIR = dirname(dirname(fileURLToPath(import.meta.url)))
const INSTALL_SH = join(PLUGIN_DIR, 'install.sh')
const git = (args, cwd) => execFileSync('git', args, { cwd, encoding: 'utf8' })
const sh = (args) => execFileSync('bash', [INSTALL_SH, ...args], { encoding: 'utf8' })

function copyPluginFiles(dest) {
  mkdirSync(dest, { recursive: true })
  for (const f of ['index.mjs', 'package.json', 'install.sh', 'README.md', 'CHANGELOG.md']) {
    cpSync(join(PLUGIN_DIR, f), join(dest, f))
  }
  for (const d of ['runtime', 'scripts', 'test']) {
    cpSync(join(PLUGIN_DIR, d), join(dest, d), { recursive: true })
  }
}

test('install.sh：文件可执行且 update 用 bash 重新执行（防 Permission denied 回归）', () => {
  const mode = statSync(INSTALL_SH).mode
  assert.ok((mode & 0o111) !== 0, 'install.sh 应带执行位：旧版 update 末尾会直接 exec 本文件')
  const src = readFileSync(INSTALL_SH, 'utf8')
  assert.match(src, /chmod \+x "\$PLUGIN_DIR\/install\.sh"/)
  assert.match(src, /exec bash "\$SELF" install/)
})

test('install.sh init：空库脚手架（模板/脚本/git/防泄漏钩子）+ 幂等拒绝', () => {
  const ws = mkdtempSync(join(tmpdir(), 'dsh-init-'))
  try {
    const out = sh(['init', ws])
    assert.ok(out.includes('记忆库就绪'), out)
    const mem = join(ws, '.dsh-memory')
    for (const f of ['MEMORY.md', 'PROTOCOL.md', '.gitignore',
      'scripts/memory_add.py', 'scripts/memory_search.sh', 'scripts/memory_search.py',
      'scripts/memory_get.py', 'scripts/memory_sync.sh',
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

test('install.sh sync-memory：升级已有记忆库脚本，不动 MEMORY/topics/sessions', () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-sync-mem-'))
  try {
    const mem = join(root, '.dsh-memory')
    mkdirSync(join(mem, 'scripts'), { recursive: true })
    mkdirSync(join(mem, 'topics'), { recursive: true })
    mkdirSync(join(mem, 'sessions'), { recursive: true })
    const memoryText = '# my index\nKEEP-ME\n'
    writeFileSync(join(mem, 'MEMORY.md'), memoryText)
    writeFileSync(join(mem, 'PROTOCOL.md'), '# old protocol\n')
    writeFileSync(join(mem, 'scripts', 'custom.sh'), 'echo custom\n')
    writeFileSync(join(mem, 'topics', 'MEMORY-keep.md'), 'keep-topic\n')
    writeFileSync(join(mem, 'sessions', 'keep.md'), 'keep-session\n')

    const out = sh(['sync-memory', mem])
    assert.ok(out.includes('记忆库脚本已同步'), out)
    for (const f of ['memory_search.sh', 'memory_search.py', 'memory_get.py', 'selfcheck.sh']) {
      assert.ok(existsSync(join(mem, 'scripts', f)), `缺 ${f}`)
    }
    assert.equal(readFileSync(join(mem, 'MEMORY.md'), 'utf8'), memoryText)
    assert.equal(readFileSync(join(mem, 'topics', 'MEMORY-keep.md'), 'utf8'), 'keep-topic\n')
    assert.equal(readFileSync(join(mem, 'sessions', 'keep.md'), 'utf8'), 'keep-session\n')
    assert.ok(existsSync(join(mem, 'scripts', 'custom.sh')), 'sync-memory 不应删除本地额外脚本')
    assert.match(readFileSync(join(mem, 'PROTOCOL.md'), 'utf8'), /v1\.5/)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('install.sh sync-memory：scripts/PROTOCOL 脏改动默认中止，--force 可继续', () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-sync-mem-dirty-'))
  try {
    const mem = join(root, '.dsh-memory')
    mkdirSync(join(mem, 'scripts'), { recursive: true })
    writeFileSync(join(mem, 'MEMORY.md'), '# index\n')
    writeFileSync(join(mem, 'PROTOCOL.md'), '# old\n')
    git(['init', '-q'], mem)
    git(['add', '-A'], mem)
    git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'init'], mem)
    writeFileSync(join(mem, 'PROTOCOL.md'), '# dirty\n')
    assert.throws(() => sh(['sync-memory', mem]))
    const out = sh(['sync-memory', '--force', mem])
    assert.ok(out.includes('记忆库脚本已同步'), out)
  } finally { rmSync(root, { recursive: true, force: true }) }
})

test('install.sh update：本地远端全流程（旧档更新→重装 profile，防 exec/install 解析回归）', () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-update-'))
  try {
    const home = join(root, 'home')
    mkdirSync(join(home, '.dsh', 'profiles', 'web'), { recursive: true })
    mkdirSync(join(home, '.dsh', 'profiles', 'dsh-tui'), { recursive: true })
    writeFileSync(join(home, '.dsh', 'profiles', 'web', 'cordis.patch.yml'), '# web\n')
    writeFileSync(join(home, '.dsh', 'profiles', 'dsh-tui', 'cordis.patch.yml'), '# tui\n')

    // 构造一个本地“远端”：tag v9.9.9 的包版本改为 9.9.9，便于确认文件真的被更新。
    const seed = join(root, 'seed')
    copyPluginFiles(seed)
    const seedPkg = JSON.parse(readFileSync(join(seed, 'package.json'), 'utf8'))
    seedPkg.version = '9.9.9'
    writeFileSync(join(seed, 'package.json'), JSON.stringify(seedPkg, null, 2) + '\n')
    git(['init', '-q'], seed)
    git(['add', '-A'], seed)
    git(['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'seed v9.9.9'], seed)
    git(['tag', 'v9.9.9'], seed)
    const bare = join(root, 'remote.git')
    execFileSync('git', ['clone', '-q', '--bare', seed, bare])

    // 初始安装目录是当前版本；通过 update 拉到本地 remote 的 v9.9.9。
    const plug = join(root, 'plugin')
    copyPluginFiles(plug)
    const out = execFileSync('bash', [join(plug, 'install.sh'), 'update'], {
      cwd: plug,
      encoding: 'utf8',
      env: {
        ...process.env,
        HOME: home,
        DSH_MEMORY_PLUGIN_REMOTE: bare,
        DSH_MEMORY_PLUGIN_FALLBACK_REMOTE: bare,
      },
    })
    assert.ok(out.includes('已更新插件文件到 v9.9.9'), out)
    assert.ok(out.includes('已安装：web'), out)
    assert.ok(out.includes('已安装：dsh-tui'), out)
    const pkg = JSON.parse(readFileSync(join(plug, 'package.json'), 'utf8'))
    assert.equal(pkg.version, '9.9.9')
    assert.ok(readFileSync(join(home, '.dsh', 'profiles', 'web', 'cordis.patch.yml'), 'utf8')
      .includes('dsh-memory 记忆插件'))
    assert.ok(readFileSync(join(home, '.dsh', 'profiles', 'dsh-tui', 'cordis.patch.yml'), 'utf8')
      .includes('dsh-memory 记忆插件'))
  } finally { rmSync(root, { recursive: true, force: true }) }
})
