# dsh-memory-plugin

dsh（DeepSeek Harness）的文件式记忆库插件 —— 给 dsh 补上跨会话记忆的**入口**与**工具**。

```
┌─ dsh 会话 ───────────────────────────────────────────────┐
│ 首次工具调用后 → 插件注入一次提示：                         │
│   "dsh 记忆库存在：/mnt/smb/dsh-memory，先读 PROTOCOL +    │
│    MEMORY.md 索引；会话结束写 checkpoint"                  │
│ 模型按提示读写记忆文件（索引式落盘）                         │
│ memory_search（检索）/ memory_sync（git 备份）两个工具       │
└──────────────────────────────────────────────────────────┘
```

## 能力

| 功能 | 说明 |
|---|---|
| 会话引导提示 | 每会话一次（promotion 后），只提示"记忆库存在 + 协议要点"，不注入内容（同 instruction-hint 模式，省 token） |
| `memory_search` | 按关键词检索记忆库（排除 sessions/ 会话日志与 .git） |
| `memory_sync` | git commit + push 到 GitLab 备份仓库（merge 不 force-push） |
| 容错 | 任何异常只降级为工具报错/跳过提示，绝不破坏会话 |

## 依赖

- **记忆数据仓库** `dsh-memory`（默认 `/mnt/smb/dsh-memory`）：含 PROTOCOL.md、MEMORY.md、MEMORY-<topic>.md、sessions/、scripts/memory_search.sh、scripts/memory_sync.sh
- 目录可经 `config.memoryDir` 覆盖

## 安装（本地 profile）

编辑 `~/.dsh/profiles/<web|dsh-tui>/cordis.patch.yml`，追加：

```yaml
- insert:
    - id: dsh-memory
      name: '/mnt/smb/dsh-memory-plugin/index.mjs'
      config:
        memoryDir: '/mnt/smb/dsh-memory'
        injectHint: true
```

或直接运行：

```bash
bash install.sh all        # web + dsh-tui 两个 profile（幂等）
bash install.sh web        # 只装 web
bash install.sh dsh-tui    # 只装 dsh-tui
```

装完重启 dsh（`systemctl restart dsh-web` 或重开会话）生效。

### 配置项

| 键 | 默认 | 说明 |
|---|---|---|
| `memoryDir` | `/mnt/smb/dsh-memory` | 记忆数据仓库路径 |
| `injectHint` | `true` | 是否注入会话引导提示 |

## 使用

- 会话中需要回忆既往知识 → `memory_search keyword`
- 落盘新知识后/会话结束 → `memory_sync "docs: ..."`
- 引导提示会指示模型：先读 PROTOCOL.md 与 MEMORY.md 索引；按索引式落盘；结束写 checkpoint

## 仓库结构

```
dsh-memory-plugin/
├── index.mjs        # Cordis 插件本体（name/apply，零依赖）
├── package.json
├── install.sh       # 本地安装脚本（幂等）
└── README.md
```

记忆数据（PROTOCOL/MEMORY/checkpoint）在独立仓库 **deploy/dsh-memory**，本插件不携带数据。

## 工作原理（dsh 插件机制）

- `ctx.on('session/event')` 观察 `tool/call` 判定 promotion；`ctx.on('agent/pre-step')` 注入提示（`prepend: true`，source.kind=`dsh-memory-hint`，resume 安全：历史已有则不重复）
- 工具经 `ctx.tools.register()` 注册，schema 用零依赖 JSON Schema 编译
- 插件名解析：dsh-agent-presets 的 EntryTree 支持**绝对路径**（`pathToFileURL`），故可直接引用本地文件
