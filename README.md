# dsh-memory-plugin

dsh（DeepSeek Harness）的文件式记忆库插件 —— 给 dsh 补上跨会话记忆的**入口**与**工具**。

```
┌─ dsh 会话 ───────────────────────────────────────────────┐
│ 首次工具调用后 → 注入一次轻量提示：                         │
│   "记忆库存在；只在需要既往结论/环境事实时检索；静默操作"     │
│ 不要求每会话预读 PROTOCOL / MEMORY.md 正文                  │
│ memory_search 默认本地层、严格匹配、条目化输出 + 字节预算；   │
│ 命中后用 memory_get 精准读取；reference 层需显式 scope        │
└──────────────────────────────────────────────────────────┘
```

## 能力

| 功能 | 说明 |
|---|---|
| 会话引导提示（v1.8 起惰性） | 每会话一次（promotion 后），只提示"记忆库存在 + 按需检索 + 静默原则"，**不要求预读 PROTOCOL/MEMORY 正文**，不注入记忆内容 |
| 静默原则（v1.0.3） | 提示中声明：记忆操作（检索/落盘/备份）一律静默进行，不向用户播报；仅用户主动问起或涉及影响行为的新规则时才一句话带过 |
| `memory_add`（v1.2.0，v1.6.1 起带域） | **落盘推荐写入口**：topic 必须带域（`<域>/<主题>` → `topics/<域>/MEMORY-<主题>.md`，域固定 dsh / idc-ops / projects / knowledge），MEMORY.md 的 See 行自动插进对应域小节、计数自动维护（真实条目数重算，可校正历史漂移）；同主题同标题自动拒绝防重复 |
| `memory_search`（v1.9 单进程） | 默认**仅本地知识层**、多词**严格 AND**（同义词按词扩展）；`scope=reference/all` 才查参考层，`any=true` 才放宽为 OR；按条目输出，默认 3 文件 / 每文件 3 条 / 约 2KB 总预算；`all=true` 只控制归档主题 |
| `memory_get`（v1.9） | memory_search 命中后的**精准二段式读取**：只允许 `MEMORY-*.md`，支持 `section` / `offset` / `limit` / 字节预算，默认 60 行、约 6KB，避免整篇加载 |
| `memory_suggest`（v1.6.0） | 查看最近 checkpoint 的候选区（Discovered candidates），半自动提取待确认知识（只读不写入） |
| `memory_sync` | git commit + push 到 GitLab 备份仓库（merge 不 force-push）；sessions/ 不备份 |
| `memory_init`（v1.6.2） | 新环境初始化记忆库：建空库（骨架 + 脚本 + git + 防泄漏钩子）或 `--from` 克隆已有库；已存在则不覆盖 |
| 容错 | 任何异常只降级为工具报错/跳过提示，绝不破坏会话 |

## 依赖

- **记忆数据仓库** `dsh-memory`（默认位于工作区根目录下的 `.dsh-memory/`）：含 PROTOCOL.md、MEMORY.md、`topics/<域>/MEMORY-<主题>.md`、sessions/、scripts/memory_search.sh + scripts/memory_search.py、scripts/memory_get.py、scripts/memory_add.py、scripts/memory_sync.sh、scripts/audit_secrets.sh（域分组自 v1.3；按需检索与 scope 隔离自协议 v1.4；单进程检索与 memory_get 自 v1.9）
- **插件自带 `runtime/`（v1.6.2）**：记忆库脚本 + PROTOCOL.md + MEMORY.md 模板的随包副本，供 `init` 在新环境落地使用；发版前用 `bash install.sh sync-runtime [记忆库路径]` 从记忆库刷新
- **路径不固化（v1.1）**：记忆库定位优先级 = `config.memoryDir` > 环境变量 `DSH_MEMORY_DIR` > **从会话 cwd 向上动态发现 `.dsh-memory/`**（含 MEMORY.md 即命中）> 兜底 `/mnt/smb/.dsh-memory`。记忆库可整体搬迁（内部脚本均相对定位）

### 运行环境（v1.7.0 起）

| 组件 | 要求 |
|---|---|
| Node | ≥ 20（插件本体 `index.mjs` 零依赖） |
| bash | ≥ 3.2（wrapper 兼容旧调用；检索核心已转 Python） |
| Python | ≥ 3.9（`memory_search.py` / `memory_get.py` 必需） |
| 工具链 | GNU 或 BSD 均可（git / grep 等常规工具） |

- **macOS 可用**：macOS 自带 bash 3.2 与 BSD 工具链，v1.7.0 起开箱可用（v1.6.2 及更早版本会静默失效，见 CHANGELOG）。
- **环境守卫**：脚本启动时校验 bash 版本；`LC_ALL`/`LC_CTYPE`/`LANG` 为 `C`/`POSIX` 时自动选用可用的 UTF-8 locale（`en_US.UTF-8` → `zh_CN.UTF-8` → `C.UTF-8`）。设 `DSH_SKIP_ENV_CHECK=1` 可跳过。
- **无 `flock` 的平台**（macOS）：`memory_sync.sh` 降级为不锁，多会话并发 sync 无互斥保护。

## 初始化（新环境）★ v1.6.2

新机器/新工作区里没有任何记忆库时，一条命令建好（也可由会话内的 `memory_init` 工具完成）：

```bash
bash install.sh init /path/to/workspace          # 建空库：MEMORY.md 骨架 + PROTOCOL.md + scripts/ + sessions/
bash install.sh init /path --from <git-url>      # 或从已有记忆库仓库克隆（含数据与脚本）
bash install.sh init /path --remote <git-url>    # 同时设置备份 remote
bash install.sh init /path --no-git              # 不建 git 仓库（也不装钩子）
bash install.sh init /path --force               # 已存在时也继续（覆盖脚本/模板，不动主题文件）
```

`init` 做的事：建 `.dsh-memory/`（MEMORY.md 四域骨架、PROTOCOL.md、scripts/ 下 9 个文件、sessions/、topics/、.gitignore）→ `git init` + 初始 commit → 从库内 `scripts/audit_secrets.sh --install` 装 pre-commit 防泄漏钩子 → 打印下一步。**已存在记忆库时默认拒绝覆盖**。

工作区内没有记忆库时，插件会在会话首次工具调用后注入一条"如何初始化"的提示（`config.initHint=false` 可关）。

## 安装（本地 profile）

编辑 `~/.dsh/profiles/<web|dsh-tui>/cordis.patch.yml`，追加：

```yaml
- insert:
    - id: dsh-memory
      name: '/绝对/路径/dsh-memory-plugin/index.mjs'
      config:
        injectHint: true
        # memoryDir 可选：默认动态发现（cwd 向上找 .dsh-memory/），或设 DSH_MEMORY_DIR
```

或直接运行：

```bash
bash install.sh all        # web + dsh-tui 两个 profile（幂等）
bash install.sh web        # 只装 web
DSH_MEMORY_DIR=/自定义/路径 bash install.sh all   # 显式指定记忆库

bash install.sh update     # 更新：拉 GitLab/GitHub 最新 tag 覆盖插件目录并重装配置
bash install.sh sync-memory ~/.dsh-memory  # 已有记忆库：同步新脚本（不动 MEMORY/topics/sessions）
bash install.sh uninstall  # 卸载：从 patch.yml 精确摘除本插件块
```

> 从 v1.8.0 及更早版本首次升级时，如遇 `Permission denied`，先执行 `chmod +x <插件目录>/install.sh` 再重试；或更新后直接执行 `bash install.sh all` 重装配置（文件已更新）。v1.8.2 起支持完整的 `update → install` 重执行链路。

装完重启 dsh（`systemctl restart dsh-web` 或重开会话）生效。

### 配置项

| 键 | 默认 | 说明 |
|---|---|---|
| `memoryDir` | 动态发现 | 记忆数据仓库路径（显式指定后不再动态发现；也可用环境变量 `DSH_MEMORY_DIR`） |
| `injectHint` | `true` | 是否注入会话引导提示 |
| `initHint` | `true` | 工作区没有记忆库时，是否注入"如何初始化"提示（v1.6.2） |
| `injectRecentCheckpoint` | `false` | 引导提示是否附带最近 checkpoint 摘要（护栏：仅 Active intent/Next action 两节、200 字上限，按工作区显式开启） |
| `searchTimeoutMs` | `30000` | memory_search 脚本执行超时（毫秒）；超时会保留已输出的部分结果 |
| `getTimeoutMs` | `15000` | memory_get 脚本执行超时（毫秒，v1.9） |
| `getMaxBytes` | `6000` | memory_get 单次输出字节上限（v1.9） |
| `addTimeoutMs` | `15000` | memory_add 脚本执行超时（毫秒） |
| `syncTimeoutMs` | `120000` | memory_sync 脚本执行超时（毫秒） |
| `initTimeoutMs` | `60000` | memory_init 初始化超时（毫秒，v1.6.2） |

### memory_search 检索策略（v1.9）

| 需求 | 参数 |
|---|---|
| 普通本地检索 | `memory_search {keyword: "关键词1 关键词2"}`（默认 strict AND + scope=local） |
| 读取命中片段 | `memory_get {path, section?, offset?, limit?}`（path/offset 可直接用搜索输出的 `L行号`） |
| 放宽多词匹配 | `any: true`（OR；同义词仍参与） |
| 查他机参考层 | `scope: "reference"`；本地+参考一起查用 `scope: "all"` |
| 查归档主题 | `all: true`（与 scope 独立） |

- 默认只检索 `MEMORY-*.md` 主题文件，不返回 `MEMORY.md`、`PROTOCOL.md`、`README.md`、`scripts/` 命中；脚本检索需直接调用脚本并加 `--include-scripts`。
- 插件会自动检测记忆库检索脚本版本：旧版脚本仍可跑默认查询并提示同步，显式使用 `scope`/`any` 时会明确拒绝，避免静默跑错范围。
- 输出预算可用脚本环境变量调整：`MEMORY_SEARCH_MAX_FILES` / `MEMORY_SEARCH_MAX_PER_FILE` / `MEMORY_SEARCH_MAX_LINES` / `MEMORY_SEARCH_MAX_BYTES` / `MEMORY_SEARCH_ENTRY_WIDTH`。
- v1.9 检索内核为 `memory_search.py` 单进程实现；本机实测 22 个本地主题约 0.4s、94 个全量主题约 0.4s（旧 bash 版约 4–17s）。

## CI

- **GitHub Actions**：`.github/workflows/ci.yml` 自动运行 npm 单测 + 新库 selfcheck（UTF-8/C locale）。
- **GitLab CI**：`.gitlab-ci.yml` 已配置，但当前 GitLab 没有注册 runner。为避免产生 `stuck_pending_no_matching_runners` 红流水线，默认**不创建自动 pipeline**；注册 runner 后在 GitLab UI 手动 Run pipeline 并设置 `RUN_GITLAB_CI=1` 即可启用。

## 使用

- 产生可复用知识（新规则/定稿决策/已验证经验）→ `memory_add {topic, title, body}`（落盘推荐写入口，索引自动维护；topic 支持「域/主题」如 `dsh/dsh-memory-plugin`）
- 会话收尾 → `memory_suggest` 查看 checkpoint 候选区，挑选确认后逐条落盘
- 会话中需要回忆既往知识 → `memory_search keyword`（只在需要时用，不预读整库）
- 命中后需要看原文 → `memory_get {path, section?, offset?, limit?}`（不要直接整篇读主题）
- 落盘新知识后/会话结束 → `memory_sync "docs: ..."`（静默执行，不向用户播报）
- 引导提示会指示模型：按需检索、用 memory_add 索引式落盘、结束按需写 checkpoint；**记忆操作不向用户播报（静默原则）**

## 仓库结构

```
dsh-memory-plugin/
├── index.mjs        # Cordis 插件本体（name/apply，零依赖）
├── package.json
├── install.sh       # 安装/更新/卸载脚本（幂等）
├── CHANGELOG.md     # 版本变更记录
├── scripts/         # release.sh 发布脚本 + release_checklist.md 验收清单
├── test/            # node:test 单测（npm test）
├── .gitlab-ci.yml   # GitLab CI（单测 + selfcheck + update 链路）
├── .github/workflows/ci.yml  # GitHub Actions 镜像
└── README.md
```

记忆数据（PROTOCOL/MEMORY/checkpoint）在独立仓库 **deploy/dsh-memory**，本插件不携带数据。

## 工作原理（dsh 插件机制）

- `ctx.on('session/event')` 观察 `tool/call` 判定 promotion；`ctx.on('agent/pre-step')` 注入提示（`prepend: true`，source.kind=`dsh-memory-hint`，resume 安全：历史已有则不重复）
- 工具经 `ctx.tools.register()` 注册，schema 用零依赖 JSON Schema 编译
- 插件名解析：dsh-agent-presets 的 EntryTree 支持**绝对路径**（`pathToFileURL`），故可直接引用本地文件
