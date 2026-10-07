# Changelog

## v1.7.3（2026-10-07，memory_sync 私有仓库凭据修复）

### 修复（会导致同步完全不可用）
- **`memory_sync.sh` 凭据 URL 丢失仓库路径**：原实现取 host 后直接拼 `scheme://oauth2:PAT@host`，丢掉仓库路径，认证必然失败。改为按 URL 结构替换 userinfo、保留完整路径（兼容宿主子路径部署）。
- **`ls-remote` 未带凭据**：私有仓库匿名访问失败 → 被误判为「远端不可达」，进而走错分支。现在 ls-remote / pull / push 统一使用认证 URL。
- **弃用无效的 `-c remote.origin.url=<auth>` 覆盖**：实测 git 2.39.2 下该覆盖**不参与凭据查找**，仍回落真实 remote URL 并要求交互输入用户名；改为直接传 URL 位置参数（唯一可靠方式）。

### 影响
v1.7.2 及更早：对**私有** GitLab 仓库 `memory_sync` 无法推送（公开仓库不受影响，因无需认证）。

### 已知问题（未修，待办）
- `audit_secrets.sh` 的「URL 内嵌密码」规则提取密码位有 bug：`hit.split(":", 1)[1]` 对 `http://user:pw@` 会先切到 `http` 的冒号，得到 `//user` 而非 `pw`，导致占位符豁免（`<PAT>`/`${VAR}`/`TOKEN` 等）**全部失效**，只要出现 `scheme://x:y@` 形式的文本（哪怕注释示例）就误报。需改用 `urlsplit`/`rsplit('@')` 正确取 userinfo。

## v1.7.2（2026-10-07，修复 runtime 未随包发布）

### 修复（重要）
- **`scripts/release.sh` 漏拷 `runtime/`，导致 v1.7.0 / v1.7.1 的 tag 里 runtime 仍是旧脚本**。
  `runtime/` 是 `memory_init` / `install.sh init` 在新环境建库时落地的脚本副本，漏拷意味着
  **新环境 init 出来的仍是未修复版**——macOS 上依然会静默失效，v1.7.0 的可移植性修复实际没有随包发出。
  - release.sh 增加 `runtime/` 拷贝
  - 增加**逐文件校验**（8 个关键文件存在性 + 与插件目录 `cmp` 逐字节一致），不一致即中止发布
  - `runtime/` 目录缺失时直接报错退出（而非静默跳过）

### 验证
- v1.7.2 tag 内 `runtime/memory_search.sh` 含环境守卫与 bash 3.2 可移植实现（对比：v1.7.0/v1.7.1 均无）
- 记忆库 `selfcheck.sh`：61 通过 / 0 失败（C locale 与 UTF-8 均全绿）

## v1.7.1（2026-10-07，发布流程修复）

### 修复
- **`scripts/release.sh`：GitHub release 描述长期为空**。GitLab Releases API 用 `description` 字段，GitHub Releases API 用 `body` 字段；原脚本把同一份 JSON 同时喂给两端，GitHub 端因字段名不被识别而**静默忽略**描述。影响范围：v1.2.0 起的**所有** GitHub release（经核对 body 均为 0 字符）。
  - 改为两端各生成对应字段的 JSON（`gl-body.json` / `gh-body.json`）
  - GitHub 步骤增加**描述非空校验**：创建成功但 `body` 为空即判失败退出，避免同类静默问题再次发生

### 说明
- v1.7.0 的 GitHub release 描述已通过 PATCH 补填（与 GitLab 端一致，1520 字符）
- 历史 release（v1.2.0 / v1.4.1 / v1.6.0）的 GitHub 描述仍为空，可按需用其 CHANGELOG 段落回填

## v1.7.0（2026-10-07，macOS / BSD 可移植性）

> 背景：在 macOS（自带 bash 3.2 + BSD 工具链）上部署时发现记忆检索**静默失效**——脚本崩溃但退出码为 0，插件据此显示「无命中」，用户会误判记忆库为空。本次修复可移植性并加入环境守卫。

### 修复（可移植性）
- **`memory_search.sh` 去掉 bash 4+ 依赖**（macOS 自带 bash 3.2 直接报错，且失败后继续执行、最终 exit 0 导致静默失效）：
  - `declare -A`（关联数组，需 bash 4.0）→ 分隔符字符串表 + `case` 查表（`_SYN_MAP` / `_SEEN_MAP`，不引入 `eval`）
  - `mapfile`（需 bash 4.0）→ `while IFS= read -r` 循环（无子 shell，保留全局状态）
  - `local -n`（nameref，需 bash 4.3）→ 固定全局数组 `G_ENTRIES` + 调用方拷贝
  - 空数组在 `set -u` 下展开报 unbound（bash 3.2 行为）→ `${arr[@]+"${arr[@]}"}` 惯用法
- **GNU/BSD 命令双兼容**：`stat -c %Y`（GNU）→ `stat -f %m`（BSD）；`date -d @ts`（GNU）→ `date -r ts`（BSD）；封装为 `file_mtime()` / `fmt_date()`，先试 GNU 再回退 BSD，最后 `python3` 兜底
- **修 11 处「变量紧跟多字节字符」导致的崩溃**：`LC_CTYPE=C/POSIX` 时 bash 3.2 会把多字节字符首字节并入变量名（如变量名后紧跟箭头字符时，解析出的变量名多出一个字节 → unbound variable，脚本 rc=1）。涉及 `memory_search.sh`(2) / `memory_sync.sh`(3) / `audit_secrets.sh`(1) / `selfcheck.sh`(2) / `install.sh`(3)，一律改为 `${var}` 花括号形式

### 新增
- **环境守卫**（4 个 runtime 脚本 + `install.sh`）：启动时校验 bash 版本；`LC_ALL`/`LC_CTYPE`/`LANG` 为 `C`/`POSIX` 时自动选用可用的 UTF-8 locale 兜底（`en_US.UTF-8` → `zh_CN.UTF-8` → `C.UTF-8`）。设 `DSH_SKIP_ENV_CHECK=1` 可跳过
- **`selfcheck.sh` 在无 `flock` 的环境（macOS）跳过 SY3 并发用例**并说明原因，不再误判为失败（`memory_sync.sh` 本就有 `command -v flock` 守卫，会降级为不锁）

### 测试
- `selfcheck.sh`：**61 通过 / 0 失败**（C locale 与 UTF-8 locale 下均全绿）；修复前在 macOS 为 47 通过 / 14 失败
- `npm test` 22/22 通过

### 已知限制
- macOS 无 `flock`，多会话并发 `memory_sync` 无互斥保护（降级为不锁）
- 记忆库默认兜底路径 `/mnt/smb/.dsh-memory` 为 Linux 习惯；macOS 建议用 `config.memoryDir` 或把库放在会话 cwd 的上级目录

## v1.6.2（2026-09-22，新环境初始化）

### 新增
- **`install.sh init`（新环境一条命令建库）**：`init [目录] [--from <git-url>] [--remote <git-url>] [--no-git] [--force]`
  - 空库脚手架：`MEMORY.md`（四域骨架）+ `PROTOCOL.md` + `scripts/`（7 个脚本）+ `sessions/` + `topics/` + `.gitignore`
  - `git init` + 初始 commit；从库内 `scripts/audit_secrets.sh --install` 装 pre-commit 防泄漏钩子；可选设置 `remote origin`
  - `--from` 走克隆路径（含数据与脚本），克隆后同样补装钩子；已存在记忆库默认拒绝覆盖（`--force` 才继续）
- **`memory_init` 工具**：会话内直接初始化（薄封装 `install.sh init`，参数 `dir` / `from` / `remote`）；用于"新环境里 memory_* 工具报脚本不存在"的场景
- **缺库提示**：工作区没有 `.dsh-memory/MEMORY.md` 时不再静默跳过，改为注入一条"如何初始化"提示（`config.initHint=false` 可关；与存在性提示共用每会话一次的去重）
- **插件自带 `runtime/`**：记忆库脚本 + `PROTOCOL.md` + `MEMORY.md.template` 随包，`init` 落地用；`install.sh sync-runtime [记忆库路径]` 从记忆库刷新（`update` 会一并覆盖 `runtime/`）

### 变更
- 四个工具脚本缺失时的报错统一追加指引：可用 `memory_init` 初始化，或用 `config.memoryDir` / `DSH_MEMORY_DIR` 指向已有库

### 测试
- 新增 `test/install.test.mjs`（3 例）：脚手架产物 + 幂等拒绝 / `--from` 克隆 + remote + 钩子 / `--no-git` + `sync-runtime`
- `test/plugin.test.mjs` 扩到 12 例：工具注册含 `memory_init`、init 提示三态（注入/不重复/可关）、`memory_init` 端到端脚手架 + 幂等
- `npm test` 22/22 通过（v1.6.1 时为 17）

## v1.6.1（2026-09-22，按域分组配套）

### 记忆体系（协议 v1.3）
- **主题按域分组**：`topics/<域>/MEMORY-<主题>.md`，域固定 `dsh` / `idc-ops` / `projects` / `knowledge`；存量 34 个主题从记忆库根目录迁移（`git mv` 保留历史），MEMORY.md 索引改为按域分 `### <域>` 小节
- **memory_add 域感知插入**：新主题的 See 行自动插进对应域小节（不再一律"最后一个 See 行之后"）；域小节不存在时自动新建（落在 `### Discovered` 之前）；无域落盘追加域提示
- **selfcheck 扩至 61 用例**：新增 5 个域感知用例（插入位置 / 不串域 / 新域建节 / 新域 See 行位置 / 无域提示）

### 修复
- **memory_search 工具新增 `all` 参数**（默认 false）：透传 `--all` 到脚本（选项置于关键词之前），修「归档主题经插件工具永远检索不到」——此前工具只传关键词，而脚本的"加 --all 查看"提示在工具层无法执行

### 配套
- 会话引导提示、memory_add / memory_search 工具描述改为域约定（topic 必须带域）
- 记忆库 PROTOCOL v1.3、工作区 AGENTS.md 同步更新

## v1.6.0（2026-09-05，1.5 测试地基 + 1.6 功能合并版）

### 测试地基（原 v1.5 范围）
- **selfcheck 扩至 56 用例**：memory_sync 假仓库全流程（init/首次推送空远端/flock 抢占/rebase 冲突态/非冲突失败）、audit 全模式（ghp_/细粒度/私钥/ChangeMe_/二进制）、search 补充（0 命中/checkpoint 区/MAX_FILES/LINE_WIDTH 截断）、memory_add 报错路径（空 topic/非法日期/缺小节）
- **插件 fake ctx 单测**（17/17）：hint 注入判定（promotion/去重/resume/injectHint/记忆库缺失）、checkpoint 摘要护栏、三工具全分支
- 修复测试暴露的真 bug：① memory_sync 空远端首次推送被 pull 失败卡死；② bash 5.2 `declare -a` 空数组在 set -u 下报未绑定（改空数组赋值）；③ 截断提示在 v1.4 重写时丢失（SE3 抓回）

### 功能（原 v1.6 范围）
- **主题分组目录**：memory_add 的 topic 支持「域/主题」（如 `dsh/dsh-memory-plugin` → `topics/dsh/MEMORY-*.md`）；MEMORY.md 索引行带路径；--resync 扫子目录
- **memory_suggest 工具**：扫描最近 checkpoint 的 Discovered candidates 候选区，半自动提取待确认知识（只读，确认后逐条 memory_add；符合 §7 护栏不自动注入）
- **scripts/release.sh 一键发布**（CHANGELOG 自动提取描述 → GitLab → GitHub）+ **scripts/release_checklist.md** 发布后人工验收清单
- 引导提示更新（子目录说明 + memory_suggest + 收尾提示）；PROTOCOL v1.2

## v1.4.1（2026-09-05，独立代码审查修复版）

- **H1** memory_sync：remote 剥离只处理 `user:pass@`（`ssh://user@host` 不再被误剥坏配置）；分支动态取（不硬编码 main）
- **H2** memory_search：`grep -c` 无匹配双行输出 bug（报告体文件不再每次检索刷 stderr）
- **M1** 选项只解析首个参数，`--all` 等出现在第二参数时按字面关键词搜索
- **M2** `--all` 归档组独立输出额度，不再被知识组挤空
- **M3** audit 自测退出码真实传回（此前恒绿）
- **M4** memory_add：title 换行清洗 + 尾部自带日期不重复附加 + **查重改逐行精确匹配**（修复「条1」误杀「条10」→ 并发丢条真凶）；锁文件改 `a` 模式（`w` 截断导致 flock 互斥失效）
- **L1** checkpoint 摘要改逐行解析（空节不吞下一节，CRLF 兼容）
- **L2** install.sh update 覆盖后 exec 重执行
- **L4** audit --install 覆盖前备份旧 hook
- **L5** 归档判定收紧（只认头部 `状态：Archived` 标记）
- **L6** `--include-scripts` 真实生效（并入主排序）
- **新增** 记忆库 `scripts/selfcheck.sh` 自检套件（31 用例全绿）+ 插件单测 10/10

## v1.4.0（2026-09-05，合并原 v1.3 检索增强 + v1.4 续接体验）

### 检索增强（配套记忆库 scripts/memory_search.sh + synonyms.tsv）
- **同义词表** `scripts/synonyms.tsv`：检索时自动扩展关键词（warranty→维保、防火墙→USG、卡住→卡死…），输出标注扩展来源
- **工具脚本命中降级**：scripts/*.sh|py 命中放末段「非知识，仅参考」，不再污染知识排序（查「PAT 获取」不再 Top1=audit_secrets.sh）
- **归一化排序 + 文件名加权**：命中行数/条目数（下限 4），大文件不霸榜、小文件不虚高；文件名含关键词 +100 分
- **冷热归档**：主题文件头部 `状态：Archived` 即归档，默认排除、`--all` 显示，并在默认输出提示「N 个归档主题有命中」
- 修复空 stats 导致 mapfile 空条目 bug
- 回归评测 8 场景：原 4 个失败案例（PAT/warranty/防火墙/卡住）全部修正，候选集均含正确主题

### checkpoint 摘要注入（按 PROTOCOL §7 护栏）
- 新配置 `injectRecentCheckpoint`（默认 **false**）：开启后引导提示附带最近一份 checkpoint 的摘要
- 护栏：只取 Active intent / Next action 两节、硬上限 200 字截断、不注入 Current work 等详情
- 提取逻辑抽为导出纯函数 extractCheckpointSummary，单测覆盖（8/8 全绿）

### 协议配套（记忆库 PROTOCOL §7）
- 上下文注入护栏写入协议：登记制、默认不注入、正文零注入

## v1.2.0（2026-09-02）

### 写入口规范化：memory_add（配套记忆库 deploy/dsh-memory 的 scripts/memory_add.py）
- 新工具 `memory_add {topic, title, body}`：落盘推荐写入口
  - 条目自动追加到 `MEMORY-<topic>.md`（不存在则自动新建，带头部）
  - **MEMORY.md 的 See 索引计数自动维护**——按真实条目数重算，可校正历史漂移（此前索引与内容脱节是主要乱源）
  - 同主题同标题自动拒绝，防重复落盘
  - topic 清洗防路径穿越；body 换行压缩为单行（与既有条目格式一致）；日期自动附加
- 会话引导提示更新：memory_add 列为推荐写入口
- 新增 `addTimeoutMs` 配置（默认 15000）

### 防泄漏审计（配套记忆库 scripts/audit_secrets.sh）
- 拦截 GitLab/GitHub PAT、私钥、URL 内嵌密码进入 git；占位符（`<PAT>` `${VAR}` `***` `ChangeMe_*`）豁免
- `audit_secrets.sh --install` 安装 pre-commit hook（.git/hooks 不随仓库备份，clone/搬迁后重装）
- 自测 `--test` 内置；记忆库已装 hook 并实测 commit 通过

### 协议配套（记忆库 deploy/dsh-memory，PROTOCOL v1.1）
- memory_add 为推荐写入口；新增防泄漏审计章节

## v1.1.0（2026-09-02）

### 检索体验（memory_search；配套记忆库 deploy/dsh-memory 的 scripts/memory_search.sh）
- 输出结构化：按文件聚合排序（命中行数 desc，同分按文件更新时间新优先），保留行号
- 命中带 1 行下文上下文；单行超长（>280 字符）自动截断（MEMORY_SEARCH_LINE_WIDTH 可调）
- 截断透明：默认最多 5 个文件 / 每文件 8 行 / 全局 60 行（MEMORY_SEARCH_MAX_* 可调），并提示剩余未列出
- checkpoint 区仅在关键词命中 sessions/ 时列出（消除此前固定刷 3 条的假命中噪音）
- 0 命中给出换词 / 看索引提示
- 匹配改 grep -F 字面（多关键词 OR），消除正则转义边界问题（此前 `]` `-` 等字符未转义）

### 工程化
- node:test 单测（test/memory.test.mjs：resolveMemoryDir 优先级矩阵、parseKeywords），`npm test` 全绿
- 关键词拆词逻辑抽为导出纯函数 parseKeywords（v1.0.4 修复的回归由单测兜底）
- install.sh 新增 `update`（GitLab → GitHub 拉最新 tag 覆盖本地目录并重装配置）与 `uninstall`（精确摘除 patch 块，支持块位于文件中间）；幂等检测改块标记精确匹配

### 协议配套（记忆库 deploy/dsh-memory）
- checkpoint 命名建议加 HHMM：`YYYY-MM-DD-HHMM-<简述>.md`（防同日覆盖）

## v1.0.4（2026-09-02）
- memory_search 多词 OR 拆词生效（此前整串字面匹配）；空关键词给出用法提示
- memory_sync 超时 60s → 120s（config.syncTimeoutMs 可调），新增 searchTimeoutMs
- 工具错误详情透出 stdout/stderr，便于排障
- 配套 memory_sync.sh 重写：remote URL 内嵌凭据自动剥离（防 token 落盘）、pull --rebase 冲突检测中止、flock 并发互斥、git HTTP 低速超时

## v1.0.3（2026-08-29）
- 静默原则：会话引导提示声明记忆操作（检索/落盘/备份）不向用户播报

## v1.0.2（2026-08-29）
- 记忆库改隐藏目录 `.dsh-memory/`，插件目录同步 `.dsh-memory-plugin/`；动态发现优先新名、兼容旧名

## v1.0.1（2026-08-29）
- 路径去固化：`config.memoryDir > DSH_MEMORY_DIR > 会话 cwd 向上发现 > 兜底`

## v1.0.0（2026-08-29）
- 首个版本：会话引导提示（promotion 后每会话一次）+ memory_search / memory_sync 工具 + install.sh 幂等安装
