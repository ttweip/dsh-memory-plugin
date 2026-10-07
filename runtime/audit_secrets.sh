#!/usr/bin/env bash
# dsh 记忆防泄漏审计（v1.2.0）：拦截 token/私钥/URL 内嵌密码进入 git
#
# 用法:
#   audit_secrets.sh              # 扫描当前 git 仓库 staged 内容（pre-commit 场景）
#   audit_secrets.sh <路径>       # 递归扫描指定文件/目录（文本文件）
#   audit_secrets.sh --install    # 安装为当前 git 仓库的 pre-commit hook（.git/hooks/ 不随仓库备份，clone/搬迁后需重装）
#   audit_secrets.sh --test       # 自测：构造模拟泄漏验证拦截
#
# 退出码: 0=干净  1=发现泄漏
# 豁免: 占位符（<PAT> ${VAR} *** ChangeMe_* 等）不算泄漏；
#       确需提交请 git commit --no-verify（并人工确认无害）
set -u

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

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

PY_SCAN='
import re, sys

source = sys.argv[1] if len(sys.argv) > 1 else "<stdin>"
pats = [
    ("GitLab PAT",   re.compile(r"glpat-[A-Za-z0-9_.-]{8,}")),
    ("GitHub PAT",   re.compile(r"ghp_[A-Za-z0-9]{20,}")),
    ("GitHub 细粒度", re.compile(r"github_pat_[A-Za-z0-9_]{20,}")),
    ("私钥",         re.compile(r"BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY")),
    ("URL 内嵌密码", re.compile(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^/@\s:]+:[^@\s]+@")),
]

def mask(s):
    return s[:6] + "***" if len(s) > 6 else "***"

found = False
try:
    data = sys.stdin.buffer.read()
except Exception:
    data = b""
if b"\x00" in data[:4096]:
    sys.exit(0)  # 二进制，跳过
for no, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
    for name, pat in pats:
        for m in pat.finditer(line):
            hit = m.group(0)
            if name == "URL 内嵌密码":
                pw = hit.split(":", 1)[1].rsplit("@", 1)[0] if ":" in hit else ""
                # 豁免占位符/示例值
                if re.search(r"[<$\*{}]", pw) or pw.startswith("ChangeMe_") or pw in ("PAT", "TOKEN", "xxx", "password"):
                    continue
            print("%s:%d: [%s] %s" % (source, no, name, mask(hit)))
            found = True
sys.exit(1 if found else 0)
'

scan_stdin() {
  python3 -c "$PY_SCAN" "$1" || return $?
}

scan_staged() {
  local root files f rc=0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "❌ 不在 git 仓库内" >&2; return 1; }
  files="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)"
  [ -n "$files" ] || { echo "✅ staged 无内容变更"; return 0; }
  echo "== 防泄漏审计（staged）=="
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # 从 index 取 staged 内容扫描（不含未 add 的本地改动）
    if ! git show ":$f" 2>/dev/null | python3 -c "$PY_SCAN" "$f"; then
      rc=1
    fi
  done <<< "$files"
  if [ "$rc" -eq 0 ]; then echo "✅ 干净，未发现凭据特征"; fi
  return $rc
}

scan_path() {
  local target="$1" rc=0
  echo "== 防泄漏审计（${target}）=="
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! python3 -c "$PY_SCAN" "$f" < "$f"; then
      rc=1
    fi
  done < <(find "$target" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.py' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' -o -name '*.txt' -o -name '*.cfg' \) 2>/dev/null)
  if [ "$rc" -eq 0 ]; then echo "✅ 干净，未发现凭据特征"; fi
  return $rc
}

install_hook() {
  local root hook
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "❌ 需在记忆库 git 仓库内运行 --install" >&2; return 1; }
  hook="$root/.git/hooks/pre-commit"
  if [ -f "$hook" ]; then
    cp "$hook" "$hook.bak-$(date +%Y%m%d%H%M%S)"   # L4: 覆盖前备份旧 hook
    echo "已备份旧 hook：$hook.bak-*"
  fi
  cat > "$hook" <<EOF
#!/usr/bin/env bash
# dsh 防泄漏审计（由 scripts/audit_secrets.sh --install 生成；重装：\$(git rev-parse --show-toplevel)/scripts/audit_secrets.sh --install）
root="\$(git rev-parse --show-toplevel)"
exec "\$root/scripts/audit_secrets.sh"
EOF
  chmod +x "$hook"
  echo "✅ pre-commit hook 已安装：$hook"
  echo "   （.git/hooks 不随仓库备份；记忆库 clone/搬迁后请重跑 --install）"
}

self_test() {
  local d
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' RETURN
  # 子 shell 整体退出码即测试结果（M3 修复：不再依赖外层变量传回）
  ( cd "$d" || exit 1
    git init -q
    echo "测试1: 真实 token 应被拦截"
    fake="glpat-""abcdef1234567890"   # 运行时拼接，避免模拟样例字面出现在本脚本
    printf 'key = %s\n' "$fake" > bad.txt
    git add bad.txt
    if "$SELF" > "$d/out1" 2>&1; then echo "  ❌ 未拦截（应 exit 1）"; exit 1
    else echo "  ✅ 已拦截"; grep -v '^==' "$d/out1" | head -2; fi
    git reset -q
    echo "测试2: 占位符不应误报"
    printf 'url = http://deploy:<PAT>@192.168.0.145/x.git\nurl2 = http://oauth2:${DSH_GITLAB_PAT}@h/x.git\n' > ok.txt
    git add ok.txt
    if "$SELF" > "$d/out2" 2>&1; then echo "  ✅ 占位符未误报"
    else echo "  ❌ 占位符被误报"; cat "$d/out2"; exit 1; fi
    echo "✅ 自测全部通过"
  )
}

case "${1:-}" in
  --install) install_hook ;;
  --test)    self_test ;;
  "")
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      scan_staged
    else
      echo "用法: $0 [--install|--test|<路径>]" >&2
      exit 1
    fi
    ;;
  *) scan_path "$1" ;;
esac
