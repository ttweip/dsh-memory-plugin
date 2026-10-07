# 发布后人工验收清单（release checklist）

> 每次发布新版本后，按本清单逐项验收；`[ ]` 前打勾确认。自动化测试过不代表真机行为正确。

> ⚠️ 已知偶发：`npm test` 约 2% 概率出现 1 例失败（约 110 次运行中复现 2 次，未能稳定复现；v1.6.2 与 v1.7.0 均观察到）。`release.sh` 用 `npm test >/dev/null` 吞掉了输出，失败时看不到是哪个用例——遇到中止请**先单独重跑 `npm test` 确认**，若通过则重试发布，不要盲目改代码。

## 发布侧（自动化已覆盖）
- [ ] **`bash install.sh sync-runtime <记忆库路径>` 已跑**（把记忆库最新 scripts/ 与 PROTOCOL.md 拉进插件 `runtime/`，否则新环境 init 出的是旧脚本）
- [ ] `node --check index.mjs` 通过
- [ ] `npm test` 全绿（当前 ≥22 用例；注意上面的偶发说明）
- [ ] 记忆库 `bash scripts/selfcheck.sh` 全绿（当前 61 用例；建议 **C locale 与 UTF-8 locale 各跑一次**：`env -u LANG LC_ALL=C bash scripts/selfcheck.sh`，v1.7.0 起两者均应全绿）
- [ ] GitLab release 已建、GitHub release 已建（两端 tag 对齐）
- [ ] 记忆库两端 commit 一致（GitLab deploy/dsh-memory == GitHub ttweip/dsh-memory）

## 真机验收（dsh-tui 新会话，自动化覆盖不到）
- [ ] 新会话收到 dsh-memory-hint 引导提示（版本相关文案正确）
- [ ] `memory_add` 工具真实调用一次：落盘成功 + 索引计数自动更新
- [ ] `memory_search` 工具真实调用一次：结构化输出、同义词扩展标注正常
- [ ] `memory_suggest` 工具调用：返回候选/无候选提示（不发散）
- [ ] `memory_sync` 工具调用：commit + push 成功（观察输出无异常）

## 安装链路
- [ ] `bash install.sh update` 实测（拉最新 tag 覆盖本地 + 配置幂等）
- [ ] `bash install.sh uninstall` + `install.sh all` 恢复（假 HOME 测试过，真机按需）
- [ ] **`bash install.sh init <临时目录>` 实测**（脚手架产物齐全、git 与钩子在位、二次运行拒绝覆盖）

## 跨平台（v1.7.0 起，macOS/BSD 必验）
- [ ] **C locale 下检索不静默失效**：`env -u LANG LC_ALL=C bash <库>/scripts/memory_search.sh <关键词>` —— 应有正常命中输出（不是"无命中"），退出码 0，stderr 无 `declare`/`unbound variable` 报错
- [ ] **环境守卫兜底生效**：上述环境下 locale 被自动切到 UTF-8（可加 `bash -x` 观察，或确认未出现多字节变量名报错）
- [ ] `DSH_SKIP_ENV_CHECK=1` 时守卫被跳过且脚本仍可运行
- [ ] macOS 无 `flock` 时 selfcheck 的 SY3 显示"跳过"而非失败；`memory_sync.sh` 降级为不锁

## 安全
- [ ] `bash scripts/audit_secrets.sh --test` 自测通过
- [ ] 发布说明 / commit message / 代码中无真实凭据（ghp_/glpat- 明文）
- [ ] 记忆库 pre-commit hook 在位（新 clone 需重跑 --install）

## 用户侧待办
- [ ] dsh-web 常驻服务已重启（`systemctl restart dsh-web`）
- [ ] （若启用）injectRecentCheckpoint 配置按工作区确认
