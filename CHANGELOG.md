# Changelog

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
