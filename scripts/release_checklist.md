# 发布后人工验收清单（release checklist）

> 每次发布新版本后，按本清单逐项验收；`[ ]` 前打勾确认。自动化测试过不代表真机行为正确。

> ⚠️ 已知偶发：`npm test` 约 2% 概率出现 1 例失败（约 110 次运行中复现 2 次，未能稳定复现；v1.6.2 与 v1.7.0 均观察到）。`release.sh` 用 `npm test >/dev/null` 吞掉了输出，失败时看不到是哪个用例——遇到中止请**先单独重跑 `npm test` 确认**，若通过则重试发布，不要盲目改代码。

## 发布侧（自动化已覆盖）
- [ ] **`bash install.sh sync-runtime <记忆库路径>` 已跑**（把记忆库最新 scripts/ 与 PROTOCOL.md 拉进插件 `runtime/`，否则新环境 init 出的是旧脚本）
- [ ] `node --check index.mjs` 通过
- [ ] `npm test` 全绿（当前 ≥43 用例；注意上面的偶发说明）
- [ ] 记忆库 `bash scripts/selfcheck.sh` 全绿（当前 ≥85 用例；建议 **C locale 与 UTF-8 locale 各跑一次**：`env -u LANG LC_ALL=C bash scripts/selfcheck.sh`，v1.7.0 起两者均应全绿）
- [ ] `npm test` 跨轮次重复 ≥3 次，确认无偶发失败
- [ ] GitLab release 已建、GitHub release 已建（两端 tag 对齐）
- [ ] **release 描述两端非空且一致**（v1.7.1 前 GitHub 端因字段名错误长期为空；v1.7.1 起 release.sh 有校验）
- [ ] **「发布产物内容」校验——不要只看 release 页面是否 200**（v1.7.2 教训：release.sh 漏拷 `runtime/`，发布了 3 个版本但 `runtime/` 一直是旧脚本，而流水线全绿）：
      ```bash
      rm -rf /tmp/vt && git clone -q --depth 1 --branch <tag> <repo-url> /tmp/vt
      test -f /tmp/vt/runtime/memory_search.py                    # v1.9+ 单进程内核
      test -f /tmp/vt/runtime/memory_get.py                       # v1.9+ 精准读取
      grep -q 'VERSION = "1.9' /tmp/vt/runtime/memory_search.py    # v1.9+
      grep -q 'OPT_SCOPE' /tmp/vt/runtime/memory_search.sh        # 兼容层能力标记
      bash -n /tmp/vt/runtime/memory_search.sh
      python3 -m py_compile /tmp/vt/runtime/memory_search.py /tmp/vt/runtime/memory_get.py
      diff -rq /tmp/vt/runtime <插件目录>/runtime             # 应无差异
      ```
- [ ] 记忆库两端 commit 一致（GitLab deploy/dsh-memory == GitHub ttweip/dsh-memory）

## 真机验收（dsh-tui 新会话，自动化覆盖不到）
- [ ] 新会话收到 dsh-memory-hint 引导提示（版本相关文案正确）
- [ ] `memory_add` 工具真实调用一次：落盘成功 + 索引计数自动更新
- [ ] `memory_search` 工具真实调用一次：默认 scope=local、严格 AND、条目化输出、≤2KB；`scope=reference` 与 `any=true` 不串范围
- [ ] `memory_get` 工具真实调用一次：按 path + section/offset/limit 读取，路径穿越与非主题文件被拒绝
- [ ] 会话引导提示不再要求预读 PROTOCOL/MEMORY 正文
- [ ] `memory_suggest` 工具调用：返回候选/无候选提示（不发散）
- [ ] `memory_sync` 工具调用：commit + push 成功（观察输出无异常）

## 安装链路
- [ ] `bash install.sh update` 实测（拉最新 tag 覆盖本地 + 配置幂等）
- [ ] `bash install.sh sync-memory <已有记忆库>` 实测（脚本升级，MEMORY/topics/sessions 不变）
- [ ] scripts/PROTOCOL 有未提交改动时 sync-memory 默认中止，`--force` 可继续
- [ ] `bash install.sh uninstall` + `install.sh all` 恢复（假 HOME 测试过，真机按需）
- [ ] **`bash install.sh init <临时目录>` 实测**（脚手架产物齐全、git 与钩子在位、二次运行拒绝覆盖）

## 跨平台（v1.7.0 起，macOS/BSD 必验）
- [ ] **C locale 下检索不静默失效**：`env -u LANG LC_ALL=C bash <库>/scripts/memory_search.sh <关键词>` —— 应有正常命中输出（不是"无命中"），退出码 0，stderr 无 `declare`/`unbound variable` 报错
- [ ] **Python 输出在 C/POSIX locale 下仍正常**：`env -u LANG LC_ALL=C bash <库>/scripts/memory_search.sh <关键词>` 应有中文命中且无 UnicodeEncodeError
- [ ] `DSH_SKIP_ENV_CHECK=1` 时守卫被跳过且脚本仍可运行
- [ ] macOS 无 `flock` 时 selfcheck 的 SY3 显示"跳过"而非失败；`memory_sync.sh` 降级为不锁

## 安全
- [ ] `bash scripts/audit_secrets.sh --test` 自测通过
- [ ] GitHub Actions CI 已成功跑过 npm + selfcheck
- [ ] GitLab CI 默认不自动建 pipeline；注册 runner 后以 `RUN_GITLAB_CI=1` 手动跑通
- [ ] 发布说明 / commit message / 代码中无真实凭据（ghp_/glpat- 明文）
- [ ] 记忆库 pre-commit hook 在位（新 clone 需重跑 --install）

## 用户侧待办
- [ ] dsh-web 常驻服务已重启（`systemctl restart dsh-web`）
- [ ] （若启用）injectRecentCheckpoint 配置按工作区确认
