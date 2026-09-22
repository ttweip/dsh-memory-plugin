#!/usr/bin/env bash
# dsh 记忆检索 v1.4：结构化输出——按文件聚合排序（命中行数+文件名加权 desc、同分 mtime 新优先）、
# 每文件带行号+上下文、截断透明；同义词自动扩展（scripts/synonyms.tsv）；
# 分层：知识文件优先，工具脚本命中降级末段；Archived 主题默认排除（--all 才显示）；
# checkpoint 区仅在关键词命中 sessions/ 时列出；0 命中给出换词提示。
# 用法: memory_search.sh [--include-scripts|--all] <关键词...>   （多关键词按或匹配）
set -u
MEM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYN_FILE="$MEM_DIR/scripts/synonyms.tsv"

MAX_FILES="${MEMORY_SEARCH_MAX_FILES:-5}"       # 最多列出多少个文件
MAX_PER_FILE="${MEMORY_SEARCH_MAX_PER_FILE:-8}" # 每文件最多显示行数（含上下文）
MAX_LINES="${MEMORY_SEARCH_MAX_LINES:-60}"      # 全局最多显示行数
LINE_WIDTH="${MEMORY_SEARCH_LINE_WIDTH:-280}"   # 单行显示宽度（超长条目截断）

# ── 参数解析：选项只认第一个参数（其余一律按关键词字面搜索）─────────
OPT_INCLUDE_SCRIPTS=0
OPT_ALL=0
case "${1:-}" in
  --include-scripts) OPT_INCLUDE_SCRIPTS=1; shift ;;
  --all) OPT_INCLUDE_SCRIPTS=1; OPT_ALL=1; shift ;;
esac
keywords=("$@")
if [ "${#keywords[@]}" -eq 0 ]; then
  echo "用法: $0 [--include-scripts|--all] <关键词...>" >&2
  exit 1
fi

# ── 同义词扩展（scripts/synonyms.tsv，格式: 词<TAB>扩展词1 扩展词2）────
declare -A syn_map
if [ -f "$SYN_FILE" ]; then
  while IFS=$'\t' read -r k rest; do
    [ -n "$k" ] || continue
    case "$k" in \#*) continue ;; esac
    syn_map["$k"]="$rest"
  done < "$SYN_FILE"
fi
orig=("${keywords[@]}")
expanded_notes=()
for kw in "${keywords[@]}"; do
  ext="${syn_map["$kw"]:-}"
  if [ -n "$ext" ]; then
    expanded_notes+=("$kw→${ext// /|}")
    for w in $ext; do keywords+=("$w"); done
  fi
done
# 去重（保持顺序）
declare -A seen
uniq=()
for kw in "${keywords[@]}"; do
  [ -n "${seen[$kw]:-}" ] || { seen[$kw]=1; uniq+=("$kw"); }
done
keywords=("${uniq[@]}")

# 多关键词 → grep -F 多个 -e（字面匹配，OR）
args=()
for kw in "${keywords[@]}"; do args+=(-e "$kw"); done

# ── 候选文件分类：知识(活跃/归档) vs 工具脚本 ──────────────────────────
is_archived() { head -5 "$1" 2>/dev/null | grep -qE '^状态：Archived|^_状态：Archived'; }
is_script() { case "$1" in "$MEM_DIR"/scripts/*) return 0 ;; *) return 1 ;; esac }

while IFS= read -r f; do files_all+=("$f"); done < <(
  find "$MEM_DIR" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.py' \) \
    -not -path '*/sessions/*' -not -path '*/.git/*' 2>/dev/null
)

know_files=(); arch_files=(); scr_files=()   # bash 5.2：用空数组赋值而非 declare（declare 空数组在 set -u 下报未绑定）
for f in "${files_all[@]}"; do
  if is_script "$f"; then scr_files+=("$f")
  elif is_archived "$f"; then arch_files+=("$f")
  else know_files+=("$f"); fi
done
# --include-scripts：脚本与知识同等排序（不单独降级）
if [ "$OPT_INCLUDE_SCRIPTS" -eq 1 ]; then
  know_files+=("${scr_files[@]}")
  scr_files=()
fi

# ── 统计与排序（归一化命中率 + 文件名加权，mtime 兜底）────────────────
scan_group() { # $1=输出数组名  $2..=文件（结果数组直接写入调用者；总命中行数写全局 G_TOTAL）
  local -n out="$1"; shift
  local stats=() f c mtime rel name_hit entries score
  G_TOTAL=0
  for f in "$@"; do
    c="$(grep -Fc "${args[@]}" "$f" 2>/dev/null || true)"
    [ "${c:-0}" -gt 0 ] || continue
    name_hit=0
    for kw in "${orig[@]}"; do
      case "$(basename "$f")" in *"$kw"*) name_hit=100; break ;; esac
    done
    # 归一化：命中行数 / 条目数（大文件不霸榜、小文件不虚高，下限 4）；文件名命中重加权
    entries="$(grep -c '^- \*\*' "$f" 2>/dev/null || true)"
    [ "${entries:-0}" -gt 4 ] || entries=4
    score=$((c * 100 / entries + name_hit))
    mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    stats+=("$score	$mtime	${f#"$MEM_DIR"/}	$c	$name_hit")
    G_TOTAL=$((G_TOTAL + c))
  done
  if [ "${#stats[@]}" -gt 0 ]; then
    mapfile -t out < <(printf '%s\n' "${stats[@]}" | sort -t$'\t' -k1,1nr -k2,2nr)
  else
    out=()
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
    date_s="$(date -d @"$mtime" +%Y-%m-%d 2>/dev/null || echo '?')"
    echo ""
    echo "[$shown_files/$GROUP_TOTAL] $rel — 命中 ${cnt} 行（更新 $date_s）"
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
know_entries=(); arch_entries=(); scr_entries=()   # 空数组赋值（bash 5.2 兼容，见上）
total_know=0; total_arch=0; total_scr=0
if [ "${#know_files[@]}" -gt 0 ]; then scan_group know_entries "${know_files[@]}"; total_know=$G_TOTAL; fi
# 归档组总是扫描（拿提示用），仅 --all 才显示明细
if [ "${#arch_files[@]}" -gt 0 ]; then scan_group arch_entries "${arch_files[@]}"; total_arch=$G_TOTAL; fi
if [ "${#scr_files[@]}" -gt 0 ]; then scan_group scr_entries "${scr_files[@]}"; total_scr=$G_TOTAL; fi

if [ "${#know_entries[@]}" -eq 0 ] && [ "${#arch_entries[@]}" -eq 0 ] && [ "${#scr_entries[@]}" -eq 0 ]; then
  echo "== dsh-memory 无命中（${orig[*]}）=="
  echo "建议：换近义词/英文（如 warranty↔维保、防火墙↔USG）；或直接读 MEMORY.md 索引浏览主题。"
  exit 0
fi

GLOBAL_SHOWN=0
echo "== dsh-memory 命中（${orig[*]}）==${expanded_notes:+  [同义词扩展: ${expanded_notes[*]}]}"
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
  GLOBAL_SHOWN=0   # 归档组独立额度，避免被知识组挤空（M2 修复）
  print_group "归档" "${arch_entries[@]}"
fi
if [ "${#scr_entries[@]}" -gt 0 ]; then
  echo ""
  echo "── 工具脚本命中（非知识，仅参考；--include-scripts 可并入排序）──"
  GROUP_TOTAL="${#scr_entries[@]}"
  print_group "脚本" "${scr_entries[@]}" 
fi
echo ""
echo "（知识 ${total_know} 行 / 归档 ${total_arch} 行 / 脚本 ${total_scr} 行；加更具体关键词可细化）"
if [ "${#arch_entries[@]}" -gt 0 ] && [ "$OPT_ALL" -ne 1 ]; then
  echo "ℹ ${#arch_entries[@]} 个归档主题有命中（${total_arch} 行，已了结故障），加 --all 查看"
fi

# ── checkpoint 区：仅当关键词命中 sessions/ 时列出 ─────────────────
sess_hits="$(grep -lF "${args[@]}" "$MEM_DIR"/sessions/*.md 2>/dev/null || true)"
if [ -n "$sess_hits" ]; then
  echo ""
  echo "== 会话 checkpoint 命中（仅参考，非正文知识）=="
  printf '%s\n' "$sess_hits" | sed "s|$MEM_DIR/||" | head -5
fi

exit 0
