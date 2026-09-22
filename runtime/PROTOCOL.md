# dsh 记忆协议 v1.3（PROTOCOL）

> 本文件是 dsh（DeepSeek Harness）会话的**记忆读写规范**。
> 任何 dsh 会话开始工作前，先读本协议 + `MEMORY.md` 索引；结束前按协议落盘。
> v1.3（2026-09-22）：主题**按域分组**——`topics/<域>/MEMORY-<主题>.md`，域固定 `dsh` / `idc-ops` / `projects` / `knowledge`；`memory_add` 域感知（See 行自动插进 MEMORY.md 对应 `### <域>` 小节）；存量 34 个主题已迁移，根目录平铺写法仅作历史兼容。
> v1.2（2026-09-05）：主题文件支持 `topics/<域>/` 子目录；新增 `memory_suggest` 候选提示；发布流程脚本化（scripts/release.sh + release_checklist.md）。
> v1.1（2026-09-02）：新增推荐写入口 `memory_add`（自动维护索引计数）；新增防泄漏 pre-commit hook。

## 0. 记忆库位置

```
<工作区根>/dsh-memory/             ← 路径不固化：记忆库跟随工作区目录
├── MEMORY.md                     # 主索引：只放 See 索引行，按域分 `### <域>` 小节
├── topics/<域>/MEMORY-<主题>.md   # 主题记忆（详情都在这；一域一子目录）
├── sessions/                     # 会话 checkpoint（不备份，gitignore）
├── PROTOCOL.md                   # 本文件
└── scripts/                      # 检索/同步工具（相对自身定位，可整体搬迁）
```

**域（固定 4 个，2026-09-22 起；新知识一律带域落盘）**：

| 域 | 放什么 | 例 |
|---|---|---|
| `dsh` | dsh 自身机制：插件 / TUI / 会话 / 部署 / 记忆系统 | `dsh/dsh-memory-plugin` |
| `idc-ops` | 机房网络运维与运维平台（设备、割接、巡检、MCP 平台） | `idc-ops/idc-network-gigamon` |
| `projects` | 外部项目交付知识（各自的代码/部署/踩坑） | `projects/doc-tool` |
| `knowledge` | 通用技术知识（与 dsh、与具体项目都无关） | `knowledge/linux-sysctl` |

> 边界判断：知识属于"这台工作区里运行的 agent 自身"→ dsh；"机房/网络/运维"→ idc-ops；"某个交付项目"→ projects；"换个场景也成立的技术常识"→ knowledge。
> 兼容：根目录 `MEMORY-<topic>.md` 平铺写法仍可读可检索，但**新落盘请勿再用**（memory_add 会提示）。

**新环境建库**（插件 v1.6.2）：`bash <插件目录>/install.sh init <工作区目录>` —— 建空库脚手架（本文件 + MEMORY.md 四域骨架 + `scripts/` + `sessions/` + git init + 防泄漏钩子），加 `--from <git-url>` 可改为克隆已有记忆库；会话内也可直接调 `memory_init` 工具。已存在记忆库时默认拒绝覆盖（`--force` 才继续）。

定位方式（插件 v1.1）：`config.memoryDir` > 环境变量 `DSH_MEMORY_DIR` > 从会话 cwd 向上查找 `.dsh-memory/`（含 MEMORY.md 即命中）> 兜底 `/mnt/smb/.dsh-memory`。所有脚本用 `dirname $0` 相对定位，记忆库整体搬迁无需改任何路径。

## 1. 会话开始（读）

1. 读 `PROTOCOL.md`（本文件）
2. 读 `MEMORY.md` 索引（按域分小节），浏览有哪些主题
3. 任务涉及的主题 → 读对应 `topics/<域>/MEMORY-<主题>.md`

## 2. 会话中（写）

**何时写**：出现以下情况就落盘，不要等会话结束：
- 用户下了新规则 / 明确偏好（记 Rules）
- 某个决策定稿（记 Architecture decisions）
- 经验证可复用的知识（记 Discovered durable knowledge）
- 已证伪的路径（记 Dead ends）

**怎么写（索引式，借鉴 mimocode 2026-08-26 定稿规范）**：
1. **推荐写入口：`memory_add` 工具**（topic/title/body 三参数）——自动完成以下 1-3 步并校验格式、查重、维护索引计数（v1.1，脚本 `scripts/memory_add.py`）
2. 手写等效：详情写入 `topics/<域>/MEMORY-<主题>.md`（主题文件，不存在就新建），格式见下；topic **必须带域**（如 `dsh/dsh-memory-plugin` → `topics/dsh/MEMORY-dsh-memory-plugin.md`，域见 §0）
3. `MEMORY.md` 只加一行索引：`See topics/<域>/MEMORY-<主题>.md (N entries) — 摘要`，且要落在对应 `### <域>` 小节内（memory_add 自动插入并重算 N，可校正历史漂移；`--resync` 可批量校正）
4. **禁止**把全文塞进 MEMORY.md 正文

**条目格式**：
```
- **标题（日期 + 用户原话引用，如有）**：正文……（溯源：会话 ID / 文件路径）
```

**禁忌**：
- ❌ token / 密码 / 私钥明文（如 bitwarden Bearer、GitLab PAT）——一律只记"从哪取"
- ❌ 大段日志/输出原文——记结论和路径
- ❌ 未经验证的猜测——放 checkpoint 的候选区，验证后再进 MEMORY

## 3. 会话结束（checkpoint）

写 `sessions/YYYY-MM-DD-HHMM-<简述>.md`（HHMM 防同日多份覆盖，v1.1），结构：

收尾时可用 `memory_suggest` 查看最近 checkpoint 的候选区（Discovered candidates），挑选确认后逐条 `memory_add` 落盘（半自动提取，不自动写入）

```markdown
# Session checkpoint YYYY-MM-DD
## Active intent      # 用户最近请求（逐字引用）
## Next action        # 下一步具体动作
## Current work       # 本次做了什么（路径/结论）
## Discovered candidates  # 可能提升到 MEMORY 的知识（待验证）
## Errors and fixes   # 踩坑记录
## Live resources     # 易变状态（进程/服务/临时文件）
```

新会话续接时：读最近一份 checkpoint 的 Active intent / Next action。

## 4. 备份（可选，建议）

插件发布流程：插件仓库 `scripts/release.sh <vX.Y.Z>`（需 DSH_GITLAB_PAT/DSH_GH_PAT 环境变量）；发布后按 `scripts/release_checklist.md` 人工验收。

```bash
/mnt/smb/.dsh-memory/scripts/memory_sync.sh   # git add+commit+push（merge 不 force-push）
```

- commit 身份：`-c user.name="dsh-memory" -c user.email="memory@dsh.local"`
- remote 未配置时只做本地 commit
- sessions/ 不备份（gitignore）

## 5. 与 mimocode 记忆的关系

- mimocode 的记忆在 `/mnt/smb/mimocode-memory/`（它自己的 git 仓库 + GitLab 备份）
- **dsh 只读写 `.dsh-memory/`，不碰 mimocode 的记忆**（除非用户明确要求）
- 两份记忆可以互相引用（如 dsh 记了 mimocode 记忆体系的索引），但互不覆盖

## 6. 防泄漏审计（v1.1）

- 脚本 `scripts/audit_secrets.sh`：拦截 GitLab/GitHub PAT、私钥、URL 内嵌密码（占位符 `<PAT>` `${VAR}` `***` `ChangeMe_*` 豁免）
- 安装：在记忆库内运行 `bash scripts/audit_secrets.sh --install`（写 `.git/hooks/pre-commit`，每次 commit 自动审计 staged 内容）
- ⚠️ `.git/hooks/` 不随仓库备份：记忆库 clone/搬迁后须重跑 `--install`
- 确需提交被拦内容：`git commit --no-verify`（人工确认无害后）
- 自测：`bash scripts/audit_secrets.sh --test`

## 7. 上下文注入护栏（v1.2+）

**总原则：记忆库内容不自动进会话上下文，除非模型按需检索。**

1. **会话引导提示**：每会话仅注入一次「存在性提示」（记忆库路径 + 协议要点 + 工具清单，约 230 字）。**不注入** MEMORY.md 正文、主题条目、checkpoint 内容
2. **注入时机**：首次工具调用后注入一次；纯闲聊会话（无工具调用）不注入；resume 时历史已有该提示则不重复
3. **记忆内容进入上下文的唯一方式**：模型主动调用 `memory_search` 按需检索
4. **未来若支持「checkpoint 摘要注入」**（v1.4 计划，默认关闭 `config.injectRecentCheckpoint=false`，按工作区显式开启）必须满足：
   - 只注入最近一份 checkpoint 的 Active intent / Next action **两行**
   - 硬上限 200 字，超出截断；不注入 Current work 等详情
5. **提示去重**：协议细节归插件提示，AGENTS.md / instruction-hint 只留指针，避免每会话双份注入
6. **登记制**：任何新增的自动注入类功能，必须在本节登记（注入什么 / 何时 / 上限），未登记按「不注入」处理
