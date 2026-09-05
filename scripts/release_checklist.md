# 发布后人工验收清单（release checklist）

> 每次发布新版本后，按本清单逐项验收；`[ ]` 前打勾确认。自动化测试过不代表真机行为正确。

## 发布侧（自动化已覆盖）
- [ ] `node --check index.mjs` 通过
- [ ] `npm test` 全绿（当前 ≥20 用例）
- [ ] 记忆库 `bash scripts/selfcheck.sh` 全绿（当前 56 用例）
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

## 安全
- [ ] `bash scripts/audit_secrets.sh --test` 自测通过
- [ ] 发布说明 / commit message / 代码中无真实凭据（ghp_/glpat- 明文）
- [ ] 记忆库 pre-commit hook 在位（新 clone 需重跑 --install）

## 用户侧待办
- [ ] dsh-web 常驻服务已重启（`systemctl restart dsh-web`）
- [ ] （若启用）injectRecentCheckpoint 配置按工作区确认
