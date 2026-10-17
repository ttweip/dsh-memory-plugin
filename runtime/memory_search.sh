#!/usr/bin/env bash
# dsh 记忆检索 v1.8：默认只搜本地知识层，多关键词按“词义组 AND”（每组含同义词），
# 输出硬预算（3 文件 / 每文件 3 行 / 全局 20 行）；reference/128 需显式 --scope；
# 默认不返回 MEMORY.md / PROTOCOL.md / scripts/ 命中；Archived 仍由 --all 展开。
# 放宽：--any 回退为 OR；范围：--scope local|reference|all。
# checkpoint 区仅在本地范围且关键词命中 sessions/ 时列出；0 命中给出收窄提示。
# 用法: memory_search.sh [--scope local|reference|all] [--any] [--all] [--include-scripts] <关键词...>
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

MEM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYN_FILE="$MEM_DIR/scripts/synonyms.tsv"

# 默认输出预算：足够定位主题，但不把整篇记忆灌进上下文。
MAX_FILES="${MEMORY_SEARCH_MAX_FILES:-3}"       # 最多列出多少个文件
MAX_PER_FILE="${MEMORY_SEARCH_MAX_PER_FILE:-3}" # 每文件最多显示行数（含上下文）
MAX_LINES="${MEMORY_SEARCH_MAX_LINES:-20}"      # 全局最多显示行数
LINE_WIDTH="${MEMORY_SEARCH_LINE_WIDTH:-280}"   # 单行显示宽度（超长条目截断）

# ── 参数解析：只解析关键词之前的选项；关键词以 -- 开头时先传 -- ─────────
OPT_INCLUDE_SCRIPTS=0
OPT_ALL=0
OPT_ANY=0
OPT_SCOPE=local
usage() {
  echo "用法: $0 [--scope local|reference|all] [--any] [--all] [--include-scripts] <关键词...>" >&2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --include-scripts) OPT_INCLUDE_SCRIPTS=1; shift ;;
    --all)             OPT_ALL=1; shift ;;
    --any)             OPT_ANY=1; shift ;;
    --scope)
      [ "$#" -ge 2 ] || { echo "❌ --scope 缺少取值（local|reference|all）" >&2; usage; exit 2; }
      OPT_SCOPE="$2"; shift 2 ;;
    --scope=*)
      OPT_SCOPE="${1#*=}"; shift ;;
    --) shift; break ;;
    -*) echo "❌ 未知选项：$1" >&2; usage; exit 2 ;;
    *) break ;;
  esac
done
case "$OPT_SCOPE" in
  local|reference|all) ;;
  *) echo "❌ --scope 仅支持 local|reference|all，收到：$OPT_SCOPE" >&2; usage; exit 2 ;;
esac
keywords=("$@")
if [ "${#keywords[@]}" -eq 0 ]; then
  usage
  exit 1
fi

# ── 可移植性：bash 3.2（macOS 自带）+ GNU/BSD 双兼容 ──────────────────
# 关联数组（declare -A）需 bash 4+，mapfile 需 bash 4+，stat -c/date -d 仅 GNU。
# 以下用「分隔符字符串表 + case 查表」实现等价语义，兼容 bash 3.2 且不引入 eval。
_SYN_MAP=""   # 格式: $'\x1f词\x1f扩展\x1e' 重复拼接（\x1f 作字段分隔，\x1e 作记录分隔）
seen_has() { case "$_SEEN_MAP" in *$'\x1f'"$1"$'\x1f'*) return 0 ;; *) return 1 ;; esac; }
seen_add() { _SEEN_MAP="$_SEEN_MAP"$'\x1f'"$1"$'\x1f'; }
seen_reset() { _SEEN_MAP=""; }
# 文件 mtime（epoch 秒）：GNU stat -c → BSD stat -f → python3 兜底
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null \
    || python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$1" 2>/dev/null \
    || echo 0
}
# epoch → YYYY-MM-DD：GNU date -d → BSD date -r → python3 兜底
fmt_date() {
  date -d @"$1" +%Y-%m-%d 2>/dev/null || date -r "$1" +%Y-%m-%d 2>/dev/null \
    || python3 -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).strftime("%Y-%m-%d"))' "$1" 2>/dev/null \
    || echo '?'
}

# ── 同义词表（scripts/synonyms.tsv，格式: 词<TAB>扩展词1 扩展词2）────
if [ -f "$SYN_FILE" ]; then
  while IFS=$'\t' read -r k rest; do
    [ -n "$k" ] || continue
    case "$k" in \#*) continue ;; esac
    _SYN_MAP="$_SYN_MAP"$'\x1f'"$k"$'\x1f'"$rest"$'\x1e'
  done < "$SYN_FILE"
fi
syn_lookup() {  # $1=词 → 打印其扩展词（未命中则无输出）
  case "$_SYN_MAP" in
    *$'\x1f'"$1"$'\x1f'*)
      _rest="${_SYN_MAP#*$'\x1f'"$1"$'\x1f'}"
      printf '%s' "${_rest%%$'\x1e'*}"
      ;;
  esac
}

orig=("${keywords[@]}")
expanded_notes=()
search_terms=("${keywords[@]}")
for kw in "${keywords[@]}"; do
  ext="$(syn_lookup "$kw")"
  if [ -n "$ext" ]; then
    expanded_notes+=("${kw}→${ext// /|}")
    for w in $ext; do search_terms+=("$w"); done
  fi
done
# 去重（保持顺序）
seen_reset
uniq=()
for kw in "${search_terms[@]}"; do
  if ! seen_has "$kw"; then seen_add "$kw"; uniq+=("$kw"); fi
done
search_terms=("${uniq[@]}")

# grep 输出用：所有原始词 + 同义词，按 OR 匹配行
args=()
for kw in "${search_terms[@]}"; do args+=(-e "$kw"); done

# 严格模式：每个原始关键词为一个“词义组”，组内可用同义词替代，组间必须全部命中。
file_matches_strict() {
  local f="$1" kw ext w
  local group_args
  for kw in "${orig[@]}"; do
    group_args=(-e "$kw")
    ext="$(syn_lookup "$kw")"
    if [ -n "$ext" ]; then
      for w in $ext; do
        [ "$w" = "$kw" ] || group_args+=(-e "$w")
      done
    fi
    if ! grep -Fq "${group_args[@]}" "$f" 2>/dev/null; then
      return 1
    fi
  done
  return 0
}
file_matches_any() { grep -Fq "${args[@]}" "$1" 2>/dev/null; }
file_matches() {
  if [ "$OPT_ANY" -eq 1 ]; then file_matches_any "$1"; else file_matches_strict "$1"; fi
}

# ── 候选文件：本地知识层 vs reference 参考层；元文件/脚本默认不参与 ─────
is_archived() { head -5 "$1" 2>/dev/null | grep -qE '^状态：Archived|^_状态：Archived'; }
is_script() { case "$1" in "$MEM_DIR"/scripts/*) return 0 ;; *) return 1 ;; esac }
is_meta() {
  case "$(basename "$1")" in
    MEMORY.md|PROTOCOL.md|README.md) return 0 ;;
    *) return 1 ;;
  esac
}

files_all=()
case "$OPT_SCOPE" in
  local)
    while IFS= read -r f; do files_all+=("$f"); done < <(
      find "$MEM_DIR" -type f -name 'MEMORY-*.md' \
        -not -path '*/sessions/*' -not -path '*/.git/*' -not -path '*/reference/*' 2>/dev/null
    )
    ;;
  reference)
    if [ -d "$MEM_DIR/reference" ]; then
      while IFS= read -r f; do files_all+=("$f"); done < <(
        find "$MEM_DIR/reference" -type f -name 'MEMORY-*.md' -not -path '*/.git/*' 2>/dev/null
      )
    fi
    ;;
  all)
    while IFS= read -r f; do files_all+=("$f"); done < <(
      find "$MEM_DIR" -type f -name 'MEMORY-*.md' -not -path '*/sessions/*' -not -path '*/.git/*' 2>/dev/null
    )
    ;;
esac
if [ "$OPT_INCLUDE_SCRIPTS" -eq 1 ] && [ "$OPT_SCOPE" != "reference" ]; then
  while IFS= read -r f; do files_all+=("$f"); done < <(
    find "$MEM_DIR/scripts" -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null
  )
fi

know_files=(); arch_files=(); scr_files=()   # bash 5.2：用空数组赋值而非 declare
for f in ${files_all[@]+"${files_all[@]}"}; do
  if is_meta "$f"; then continue
  elif is_script "$f"; then scr_files+=("$f")
  elif is_archived "$f"; then arch_files+=("$f")
  else know_files+=("$f"); fi
done
# --include-scripts：脚本并入主排序；默认完全不输出脚本命中
if [ "$OPT_INCLUDE_SCRIPTS" -eq 1 ]; then
  know_files+=(${scr_files[@]+"${scr_files[@]}"})
  scr_files=()
fi

# ── 统计与排序（归一化命中率 + 文件名加权，mtime 兜底）────────────────
# bash 3.2 无 nameref，结果写入固定全局数组 G_ENTRIES，由调用方立即拷走。
scan_group() { # $1..=文件；结果写入全局 G_ENTRIES，总命中行数写入 G_TOTAL
  local stats=() f c mtime rel name_hit entries score
  G_TOTAL=0
  G_ENTRIES=()
  for f in "$@"; do
    file_matches "$f" || continue
    c="$(grep -Fc "${args[@]}" "$f" 2>/dev/null || true)"
    [ "${c:-0}" -gt 0 ] || continue
    name_hit=0
    for kw in "${orig[@]}"; do
      case "$(basename "$f")" in *"$kw"*) name_hit=100; break ;; esac
    done
    entries="$(grep -c '^- \*\*' "$f" 2>/dev/null || true)"
    [ "${entries:-0}" -gt 4 ] || entries=4
    score=$((c * 100 / entries + name_hit))
    mtime="$(file_mtime "$f")"
    stats+=("$score	$mtime	${f#"$MEM_DIR"/}	$c	$name_hit")
    G_TOTAL=$((G_TOTAL + c))
  done
  G_ENTRIES=()
  if [ "${#stats[@]}" -gt 0 ]; then
    while IFS= read -r _line; do G_ENTRIES+=("$_line"); done < <(
      printf '%s\n' "${stats[@]}" | sort -t$'\t' -k1,1nr -k2,2nr
    )
  fi
}

print_group() { # $1=组标题 $2..=entries（实际列出的文件数写全局 G_SHOWN_FILES）
  local title="$1"; shift
  local shown_files=0
  for entry in "$@"; do
    [ "$shown_files" -lt "$MAX_FILES" ] || break
    [ "$GLOBAL_SHOWN" -lt "$MAX_LINES" ] || break
    IFS=$'\t' read -r sortk mtime rel cnt name_hit <<<"$entry"
    shown_files=$((shown_files + 1))
    local date_s
    date_s="$(fmt_date "$mtime")"
    echo ""
    echo "[$shown_files/$GROUP_TOTAL] $rel — 命中 ${cnt} 行（更新 ${date_s}）"
    local remaining per_file out n_shown
    remaining=$((MAX_LINES - GLOBAL_SHOWN))
    per_file=$((MAX_PER_FILE < remaining ? MAX_PER_FILE : remaining))
    out="$(grep -nF -A1 "${args[@]}" "$MEM_DIR/$rel" 2>/dev/null \
      | python3 -c 'import sys
w = int(sys.argv[1])
for l in sys.stdin:
    s = l.rstrip("\n")
    print(s[:w] + ("…" if len(s) > w else ""))' "$LINE_WIDTH" || true)"
    printf '%s\n' "$out" | head -n "$per_file" | sed 's/^/  /'
    n_shown="$(printf '%s\n' "$out" | wc -l)"
    if [ "$n_shown" -gt "$per_file" ]; then
      echo "  …（该文件还有 $((n_shown - per_file)) 行未显示）"
    fi
    GLOBAL_SHOWN=$((GLOBAL_SHOWN + (n_shown < per_file ? n_shown : per_file)))
  done
  G_SHOWN_FILES=$shown_files
}

# ── 主流程 ───────────────────────────────────────────────────────────
know_entries=(); arch_entries=(); scr_entries=()
total_know=0; total_arch=0; total_scr=0
# G_ENTRIES 是 scan_group 的全局出口，每次调用后须立即拷走。
# bash 3.2 在 set -u 下对空数组展开会报错，统一用 ${arr[@]+"${arr[@]}"}。
if [ "${#know_files[@]}" -gt 0 ]; then scan_group "${know_files[@]}"; know_entries=(${G_ENTRIES[@]+"${G_ENTRIES[@]}"}); total_know=$G_TOTAL; fi
if [ "${#arch_files[@]}" -gt 0 ]; then scan_group "${arch_files[@]}"; arch_entries=(${G_ENTRIES[@]+"${G_ENTRIES[@]}"}); total_arch=$G_TOTAL; fi
if [ "${#scr_files[@]}" -gt 0 ]; then scan_group "${scr_files[@]}"; scr_entries=(${G_ENTRIES[@]+"${G_ENTRIES[@]}"}); total_scr=$G_TOTAL; fi

MODE_LABEL="严格 AND"
[ "$OPT_ANY" -eq 1 ] && MODE_LABEL="宽松 OR"
expanded_note=""
if [ "${expanded_notes[@]+x}" ]; then
  expanded_note="  [同义词扩展: ${expanded_notes[*]}]"
fi

if [ "${#know_entries[@]}" -eq 0 ] && [ "${#arch_entries[@]}" -eq 0 ] && [ "${#scr_entries[@]}" -eq 0 ]; then
  echo "== dsh-memory 无命中（${orig[*]}｜scope=${OPT_SCOPE}｜${MODE_LABEL}）=="
  echo "建议：换更具体关键词；或加 --any 放宽为 OR、--scope all 查参考层、--all 看归档。"
  exit 0
fi

GLOBAL_SHOWN=0
echo "== dsh-memory 命中（${orig[*]}｜scope=${OPT_SCOPE}｜${MODE_LABEL}）==${expanded_note}"
if [ "${#know_entries[@]}" -gt 0 ]; then
  GROUP_TOTAL="${#know_entries[@]}"
  print_group "知识" "${know_entries[@]}"
  if [ "$G_SHOWN_FILES" -lt "${#know_entries[@]}" ]; then
    rest=$(( ${#know_entries[@]} - G_SHOWN_FILES ))
    echo "…还有 $rest 个文件未列出（命中较少或较旧）。加更具体关键词可细化。"
  fi
fi
if [ "$OPT_ALL" -eq 1 ] && [ "${#arch_entries[@]}" -gt 0 ]; then
  echo ""
  echo "── 归档记忆（Archived，默认隐藏；本组不计入常规排序）──"
  GROUP_TOTAL="${#arch_entries[@]}"
  GLOBAL_SHOWN=0   # 归档组独立额度，避免被知识组挤空
  print_group "归档" "${arch_entries[@]}"
fi
if [ "${#scr_entries[@]}" -gt 0 ]; then
  echo ""
  echo "── 工具脚本命中（非知识，仅参考；--include-scripts 可并入排序）──"
  GROUP_TOTAL="${#scr_entries[@]}"
  print_group "脚本" "${scr_entries[@]}"
fi
echo ""
echo "（知识 ${total_know} 行 / 归档 ${total_arch} 行 / 脚本 ${total_scr} 行；scope=${OPT_SCOPE}；${MODE_LABEL}）"
if [ "${#arch_entries[@]}" -gt 0 ] && [ "$OPT_ALL" -ne 1 ]; then
  echo "ℹ ${#arch_entries[@]} 个归档主题有命中（${total_arch} 行，已了结故障），加 --all 查看"
fi

# ── checkpoint 区：仅本地范围且关键词命中 sessions/ 时列出 ─────────────
if [ "$OPT_SCOPE" != "reference" ]; then
  sess_hits="$(grep -lF "${args[@]}" "$MEM_DIR"/sessions/*.md 2>/dev/null || true)"
  if [ -n "$sess_hits" ]; then
    echo ""
    echo "== 会话 checkpoint 命中（仅参考，非正文知识）=="
    printf '%s\n' "$sess_hits" | sed "s|$MEM_DIR/||" | head -5
  fi
fi

exit 0
