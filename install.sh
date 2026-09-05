#!/usr/bin/env bash
# dsh-memory-plugin 本地安装/更新/卸载
# 用法:
#   install.sh [web|dsh-tui|all]               # 安装（默认 all；幂等）
#   install.sh update [web|dsh-tui|all]        # 更新：拉远端最新 tag 覆盖插件目录，再重装配置
#   install.sh uninstall [web|dsh-tui|all]     # 卸载：从 cordis.patch.yml 摘除本插件块
#
# 记忆库定位（v1.1）：默认不写 memoryDir（插件从会话 cwd 动态向上发现 .dsh-memory/），
# 仅当设置 DSH_MEMORY_DIR 环境变量时才显式写入配置。
# 远端来源：GitLab deploy/dsh-memory-plugin（主）→ GitHub ttweip/dsh-memory-plugin（备）。
# 凭据：remote 不内嵌 token，走 ~/.git-credentials 或环境变量注入。
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_PRIMARY="http://192.168.0.145/deploy/dsh-memory-plugin.git"
REMOTE_FALLBACK="https://github.com/ttweip/dsh-memory-plugin.git"
MARKER='# ── dsh-memory 记忆插件'
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

action=install
case "${1:-all}" in
  update|uninstall) action="$1"; shift || true ;;
esac

targets=()
case "${1:-all}" in
  all)     targets=(web dsh-tui) ;;
  web)     targets=(web) ;;
  dsh-tui) targets=(dsh-tui) ;;
  *) echo "用法: $0 [update|uninstall] [web|dsh-tui|all]" >&2; exit 1 ;;
esac

patch_for() { echo "$HOME/.dsh/profiles/$1/cordis.patch.yml"; }

install_to() {
  local profile="$1" patch
  patch="$(patch_for "$profile")"
  if [ ! -f "$patch" ]; then
    echo "跳过：$patch 不存在"
    return 0
  fi
  if grep -qF "$MARKER" "$patch"; then
    echo "已安装（幂等跳过）：$profile"
    return 0
  fi
  if [ -n "${DSH_MEMORY_DIR:-}" ]; then
    config_block="        memoryDir: '$DSH_MEMORY_DIR'"
  else
    config_block="        # memoryDir 不写死：插件按 cwd 向上动态发现 .dsh-memory/（或设 DSH_MEMORY_DIR）"
  fi
  cat >> "$patch" <<EOF

$MARKER ────────────────────────────────────
- insert:
    - id: dsh-memory
      name: '$PLUGIN_DIR/index.mjs'
      config:
$config_block
        injectHint: true
EOF
  echo "已安装：$profile（重启 dsh 生效）"
}

update_files() {
  # 取远端最新 tag（GitLab 优先，失败切 GitHub）
  local tag=""
  tag="$(git ls-remote --tags --refs "$REMOTE_PRIMARY" 2>/dev/null \
    | sed 's#.*refs/tags/##' | sort -V | tail -1 || true)"
  if [ -z "${tag:-}" ]; then
    echo "GitLab 不可达，尝试 GitHub 镜像…"
    tag="$(git ls-remote --tags --refs "$REMOTE_FALLBACK" 2>/dev/null \
      | sed 's#.*refs/tags/##' | sort -V | tail -1 || true)"
  fi
  [ -n "${tag:-}" ] || tag=main

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  echo "拉取 $tag …"
  if ! GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --branch "$tag" \
      "$REMOTE_PRIMARY" "$tmp/src" 2>/dev/null; then
    if ! GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --branch "$tag" \
        "$REMOTE_FALLBACK" "$tmp/src" 2>/dev/null; then
      echo "❌ GitLab/GitHub 拉取均失败，更新中止" >&2
      exit 1
    fi
  fi
  [ -f "$tmp/src/index.mjs" ] || { echo "❌ 拉取内容异常（缺 index.mjs）" >&2; exit 1; }

  cp "$tmp/src/index.mjs" "$tmp/src/package.json" "$tmp/src/install.sh" "$PLUGIN_DIR/"
  [ -f "$tmp/src/README.md" ] && cp "$tmp/src/README.md" "$PLUGIN_DIR/"
  [ -f "$tmp/src/CHANGELOG.md" ] && cp "$tmp/src/CHANGELOG.md" "$PLUGIN_DIR/"
  if [ -d "$tmp/src/test" ]; then
    rm -rf "$PLUGIN_DIR/test"
    cp -r "$tmp/src/test" "$PLUGIN_DIR/"
  fi
  echo "已更新插件文件到 $tag"
}

uninstall_from() {
  local profile="$1" patch
  patch="$(patch_for "$profile")"
  if [ ! -f "$patch" ]; then
    echo "跳过：$patch 不存在"
    return 0
  fi
  if ! grep -qF "$MARKER" "$patch"; then
    echo "未安装（跳过）：$profile"
    return 0
  fi
  python3 - "$patch" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    lines = f.readlines()

marker = None
for i, l in enumerate(lines):
    if l.startswith('# ── dsh-memory 记忆插件'):
        marker = i
        break
if marker is None:
    print('未找到插件块，跳过')
    sys.exit(0)

# 起点：marker 行，向前吞掉追加时空行
start = marker
while start > 0 and not lines[start - 1].strip():
    start -= 1

# 块主体 = marker 注释 + 随后的一个 YAML 列表项（- insert: 子树，全部缩进）
i0 = None
for j in range(marker + 1, len(lines)):
    if lines[j].startswith('- '):
        i0 = j
        break
if i0 is None:
    i0 = marker + 1  # 异常块：只有注释行

# 终点：i0 之后第一条非空且顶格（非缩进）的行，即下一段内容；无则到文件尾
end = len(lines)
for j in range(i0 + 1, len(lines)):
    l = lines[j]
    if l.strip() and l[0] not in (' ', '\t'):
        end = j
        break

del lines[start:end]
# 收敛切口处空行（至多保留一个）
while start < len(lines) and not lines[start].strip():
    del lines[start]
if start > 0 and not lines[start - 1].strip():
    del lines[start - 1]

with open(path, 'w', encoding='utf-8') as f:
    f.writelines(lines)
print('已卸载：' + path)
PYEOF
}

case "$action" in
  install)
    for p in "${targets[@]}"; do install_to "$p"; done
    echo "安装完成（dsh-tui 新会话生效；dsh-web 需 systemctl restart dsh-web）"
    ;;
  update)
    update_files
    # L2 修复：install.sh 已被更新内容覆盖，exec 新脚本执行 install（避免旧 fd 继续读被覆盖文件）
    exec "$SELF" install "${targets[@]}"
    ;;
  uninstall)
    for p in "${targets[@]}"; do uninstall_from "$p"; done
    echo "卸载完成（重启 dsh 后插件不再加载）"
    ;;
esac
