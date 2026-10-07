#!/usr/bin/env bash
# dsh-memory-plugin 本地安装/更新/卸载/初始化
# 用法:
#   install.sh [web|dsh-tui|all]               # 安装插件（默认 all；幂等）
#   install.sh update [web|dsh-tui|all]        # 更新：拉远端最新 tag 覆盖插件目录，再重装配置
#   install.sh uninstall [web|dsh-tui|all]     # 卸载：从 cordis.patch.yml 摘除本插件块
#   install.sh init [目录] [选项]               # ★ 新环境初始化记忆库（.dsh-memory/）
#         --from <git-url>   从已有记忆库仓库克隆（含数据与脚本），而非建空库
#         --remote <git-url> 设置 git remote origin（备份用）
#         --no-git           不执行 git init（也不装 pre-commit 防泄漏钩子）
#         --force            目标已有记忆库时也继续（覆盖脚本/模板，不动已有主题文件）
#   install.sh sync-runtime [记忆库路径]        # 把记忆库 scripts/ 同步进插件 runtime/（发版前用）
#
# 记忆库定位（v1.1）：默认不写 memoryDir（插件从会话 cwd 动态向上发现 .dsh-memory/），
# 仅当设置 DSH_MEMORY_DIR 环境变量时才显式写入配置。
# 远端来源：GitLab deploy/dsh-memory-plugin（主）→ GitHub ttweip/dsh-memory-plugin（备）。
# 凭据：remote 不内嵌 token，走 ~/.git-credentials 或环境变量注入。
set -euo pipefail

# ── 环境守卫（可移植性）───────────────────────────────────────────────
# 依赖：bash ≥3.2 + 常见 POSIX 工具；脚本本身已避免 bash 4+ 特性
# （declare -A / mapfile / local -n）与 GNU 专有参数（stat -c / date -d）。
# 设 DSH_SKIP_ENV_CHECK=1 可跳过本段检查。
# locale 兜底：LC_CTYPE 为 C/POSIX 时，bash 3.2 会把「变量名紧跟多字节字符」
# 误解析为变量名的一部分（多字节首字节被并入变量名 → unbound variable），
# 故显式选用一个可用的 UTF-8 locale；找不到时至少不再假装成功。
# 注：脚本内所有「变量紧跟多字节字符」处一律写 ${var} 花括号形式。
if [ "${DSH_SKIP_ENV_CHECK:-0}" != "1" ]; then
  if [ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]}" -lt 3 ]; then
    echo "❌ 需要 bash ≥3.2，当前 ${BASH_VERSION:-未知}。macOS 自带 bash 3.2 可用；" >&2
    echo "   若报语法错误请安装新版：brew install bash" >&2
    exit 1
  fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    C|POSIX)
      for _loc in en_US.UTF-8 zh_CN.UTF-8 C.UTF-8; do
        if locale -a 2>/dev/null | grep -qx "$_loc"; then
          LC_ALL="$_loc"; LC_CTYPE="$_loc"; export LC_ALL LC_CTYPE; break
        fi
      done
      ;;
  esac
fi


PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$PLUGIN_DIR/runtime"
REMOTE_PRIMARY="http://192.168.0.145/deploy/dsh-memory-plugin.git"
REMOTE_FALLBACK="https://github.com/ttweip/dsh-memory-plugin.git"
MARKER='# ── dsh-memory 记忆插件'
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

action=install
case "${1:-all}" in
  update|uninstall) action="$1"; shift || true ;;
  init|sync-runtime) action="$1"; shift || true ;;
esac

targets=()
if [ "$action" = install ] || [ "$action" = update ] || [ "$action" = uninstall ]; then
  case "${1:-all}" in
    all)     targets=(web dsh-tui) ;;
    web)     targets=(web) ;;
    dsh-tui) targets=(dsh-tui) ;;
    *) echo "用法: $0 [update|uninstall|init|sync-runtime] [web|dsh-tui|all]" >&2; exit 1 ;;
  esac
fi

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
  echo "已安装：${profile}（重启 dsh 生效）"
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
  if [ -d "$tmp/src/runtime" ]; then
    rm -rf "$PLUGIN_DIR/runtime"
    cp -r "$tmp/src/runtime" "$PLUGIN_DIR/"
    chmod +x "$PLUGIN_DIR"/runtime/*.sh "$PLUGIN_DIR"/runtime/*.py 2>/dev/null || true
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

init_usage() {
  cat >&2 <<EOF
用法: $0 init [目录] [选项]
  在 <目录>（默认当前目录）下创建记忆库 .dsh-memory/
选项:
  --from <git-url>    从已有记忆库仓库克隆（含数据与脚本），而非创建空库
  --remote <git-url>  初始化后设置 git remote origin（备份用）
  --no-git            不执行 git init（也不装 pre-commit 防泄漏钩子）
  --force             目标已有记忆库时也继续（覆盖脚本/模板，不动已有主题文件）
EOF
}

init_library() {
  local dir="$PWD" from="" remote="" do_git=1 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)   from="${2:-}";   shift 2 ;;
      --remote) remote="${2:-}"; shift 2 ;;
      --no-git) do_git=0; shift ;;
      --force)  force=1; shift ;;
      -h|--help) init_usage; return 0 ;;
      -*) echo "未知选项：$1" >&2; init_usage; return 1 ;;
      *)  dir="$1"; shift ;;
    esac
  done
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" || { echo "❌ 无法创建目录：$dir" >&2; return 1; }
    echo "已创建工作区目录：$dir"
  fi
  dir="$(cd "$dir" && pwd)"
  local lib="$dir/.dsh-memory"

  if [ -f "$lib/MEMORY.md" ] && [ "$force" -ne 1 ]; then
    echo "已存在记忆库：${lib}（如需重建请加 --force）"
    return 0
  fi

  if [ -n "$from" ]; then
    if [ -d "$lib/.git" ]; then
      echo "已存在仓库，跳过克隆：$lib"
    else
      echo "从 $from 克隆记忆库 → $lib"
      GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 "$from" "$lib" \
        || { echo "❌ 克隆失败：$from" >&2; return 1; }
    fi
  else
    echo "创建空记忆库 → $lib"
    mkdir -p "$lib/sessions" "$lib/scripts" "$lib/topics"
    cp "$RUNTIME_DIR"/memory_search.sh "$RUNTIME_DIR"/memory_sync.sh \
       "$RUNTIME_DIR"/audit_secrets.sh "$RUNTIME_DIR"/selfcheck.sh \
       "$RUNTIME_DIR"/memory_add.py "$RUNTIME_DIR"/memory_suggest.py \
       "$RUNTIME_DIR"/synonyms.tsv "$lib/scripts/"
    chmod +x "$lib/scripts"/*.sh "$lib/scripts"/*.py
    [ -f "$lib/PROTOCOL.md" ] || cp "$RUNTIME_DIR/PROTOCOL.md" "$lib/PROTOCOL.md"
    [ -f "$lib/MEMORY.md" ]   || cp "$RUNTIME_DIR/MEMORY.md.template" "$lib/MEMORY.md"
    [ -f "$lib/.gitignore" ]  || printf 'sessions/\n*.tmp\n.DS_Store\n' > "$lib/.gitignore"
  fi

  if [ "$do_git" -eq 1 ]; then
    if [ ! -d "$lib/.git" ]; then
      git -C "$lib" init -q
      git -C "$lib" add -A
      git -C "$lib" -c user.name="dsh-memory" -c user.email="memory@dsh.local" \
        commit -q -m "chore: 初始化 dsh 记忆库（install.sh init）" || true
    fi
    if [ -n "$remote" ]; then
      git -C "$lib" remote remove origin >/dev/null 2>&1 || true
      git -C "$lib" remote add origin "$remote"
      echo "  ✓ remote origin = $remote"
    fi
    if [ -x "$lib/scripts/audit_secrets.sh" ]; then
      if ( cd "$lib" && bash scripts/audit_secrets.sh --install >/dev/null 2>&1 ); then
        echo "  ✓ pre-commit 防泄漏钩子已安装"
      else
        echo "  ⚠ 钩子安装失败（可手动：cd $lib && bash scripts/audit_secrets.sh --install）"
      fi
    fi
  fi

  echo "✅ 记忆库就绪：$lib"
  echo "  下一步："
  echo "    · 会话里立即可用（插件按 cwd 向上发现 .dsh-memory/；已运行中的 dsh 进程需重启才加载插件）"
  echo "    · 自检：bash $lib/scripts/selfcheck.sh"
  [ -n "$remote" ] || echo "    · 备份：git -C $lib remote add origin <url> 后跑 bash $lib/scripts/memory_sync.sh"
}

sync_runtime() {
  local src="${1:-${DSH_MEMORY_DIR:-$PWD/.dsh-memory}}"
  [ -d "$src" ] || { echo "❌ 记忆库目录不存在：$src" >&2; return 1; }
  src="$(cd "$src" && pwd)"
  local sdir="$src/scripts"
  [ -f "$sdir/memory_search.sh" ] || { echo "❌ 不是记忆库（缺 scripts/memory_search.sh）：$src" >&2; return 1; }
  mkdir -p "$RUNTIME_DIR"
  cp "$sdir"/memory_search.sh "$sdir"/memory_sync.sh "$sdir"/audit_secrets.sh "$sdir"/selfcheck.sh \
     "$sdir"/memory_add.py "$sdir"/memory_suggest.py "$sdir"/synonyms.tsv "$RUNTIME_DIR/"
  [ -f "$src/PROTOCOL.md" ] && cp "$src/PROTOCOL.md" "$RUNTIME_DIR/PROTOCOL.md"
  chmod +x "$RUNTIME_DIR"/*.sh "$RUNTIME_DIR"/*.py
  echo "✅ runtime/ 已同步（源：${src}，$(ls -1 "$RUNTIME_DIR" | wc -l) 个文件）"
  echo "   注意：MEMORY.md.template 不随同步改动（手工维护）"
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
  init)
    init_library "$@"
    ;;
  sync-runtime)
    sync_runtime "$@"
    ;;
esac
