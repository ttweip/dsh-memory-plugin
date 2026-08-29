#!/usr/bin/env bash
# dsh-memory-plugin 本地安装：把插件 insert 追加到目标 profile 的 cordis.patch.yml
# 用法: install.sh [web|dsh-tui|all]   默认 all；幂等（已存在则跳过）
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_MEM_DIR="${DSH_MEMORY_DIR:-/mnt/smb/dsh-memory}"

targets=()
case "${1:-all}" in
  all)     targets=(web dsh-tui) ;;
  web)     targets=(web) ;;
  dsh-tui) targets=(dsh-tui) ;;
  *) echo "用法: $0 [web|dsh-tui|all]" >&2; exit 1 ;;
esac

for profile in "${targets[@]}"; do
  patch="$HOME/.dsh/profiles/$profile/cordis.patch.yml"
  if [ ! -f "$patch" ]; then
    echo "跳过：$patch 不存在"
    continue
  fi
  if grep -q "id: dsh-memory" "$patch"; then
    echo "已安装（幂等跳过）：$profile"
    continue
  fi
  cat >> "$patch" <<EOF

# ── dsh-memory 记忆插件 ────────────────────────────────────
- insert:
    - id: dsh-memory
      name: '$PLUGIN_DIR/index.mjs'
      config:
        memoryDir: '$DEFAULT_MEM_DIR'
        injectHint: true
EOF
  echo "已安装：$profile（重启 dsh 生效）"
done
