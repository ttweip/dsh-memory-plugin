#!/usr/bin/env bash
# dsh 记忆检索 v1.9 兼容入口：实际检索由同目录 memory_search.py 单进程完成。
# 保留 --scope / --any / --all / --include-scripts 参数与旧调用方式。
# 标记 OPT_SCOPE 供插件检测新版能力；--version 输出 1.9.0。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${SCRIPT_DIR}/memory_search.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ memory_search: 缺少 python3（v1.9 检索内核需要 Python 3.9+）" >&2
  exit 1
fi
if [ ! -f "$PY" ]; then
  echo "❌ memory_search: 缺少检索内核 ${PY}（请同步记忆库 scripts/ 或重新 init）" >&2
  exit 1
fi

# C/POSIX locale 下避免 Python 输出中文时报编码错误。
export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"
exec python3 "$PY" "$@"
