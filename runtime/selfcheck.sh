#!/usr/bin/env bash
# dsh 记忆系统自检套件（v1.4.1 起）：把各脚本的边界/回归用例固化，防再犯。
# 用法: bash scripts/selfcheck.sh   退出码 0=全过 1=有失败
# 覆盖: memory_search(H2/M1/M2/L5/L6/同义词/转义) / memory_add(M4/A8/查重/resync)
#       audit(M3/L3) / memory_sync(H1 剥离正则) / 各脚本语法
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
cd "$MEM_DIR"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
assert() { # assert <描述> <命令...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
assert_not() { # 命令应失败
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}

echo "═══════ 0. 语法 ═══════"
for s in memory_search.sh memory_sync.sh audit_secrets.sh; do
  assert "bash -n scripts/$s" bash -n "scripts/$s"
done
assert "python 语法 scripts/memory_add.py" python3 -c "import ast; ast.parse(open('scripts/memory_add.py').read())"

echo "═══════ 1. memory_search.sh（假库）═══════"
FM="$(mktemp -d)"; trap 'rm -rf "$FM"' RETURN
mkdir -p "$FM/scripts"
cp scripts/memory_search.sh "$FM/scripts/"
cp scripts/synonyms.tsv "$FM/scripts/"
cat > "$FM/MEMORY.md" <<'EOF'
# Project memory
## Discovered durable knowledge
- See MEMORY-网络故障.md (3 entries) — 网络故障主题
- See MEMORY-活跃主题.md (2 entries) — 活跃主题
### Discovered
EOF
cat > "$FM/MEMORY-网络故障.md" <<'EOF'
# MEMORY-网络故障.md
_状态：Archived（已了结故障，检索默认隐藏，--all 可见）_
- **崩溃根因（2026-08-01）**：交换机 watchdog 崩溃
- **修复（2026-08-02）**：升级补丁
- **复验（2026-08-03）**：无复发
EOF
cat > "$FM/MEMORY-活跃主题.md" <<'EOF'
# MEMORY-活跃主题.md
_活跃_
- **防火墙策略（2026-08-04）**：正文提到 Archived 概念但本主题活跃
- **卡死排查（2026-08-05）**：任务卡死处理
EOF
# H2 场景：报告体例文件（无 - ** 条目）应不报错不刷 stderr
cat > "$FM/MEMORY-报告体.md" <<'EOF'
# MEMORY-报告体.md
## 1. 现象
卡死相关内容
## 2. 结论
完毕
EOF
printf '# MEMORY-报告体.md (2 entries)' >> "$FM/MEMORY.md" 2>/dev/null || true
S() { bash "$FM/scripts/memory_search.sh" "$@"; }

stderr_empty=$(S 卡死 2>&1 >/dev/null)
[ -z "$stderr_empty" ] && ok "H2: 报告体文件无条目不刷 stderr" || bad "H2: stderr 有输出: $stderr_empty"

out=$(S 卡死 2>/dev/null)
echo "$out" | grep -q "同义词扩展" && ok "同义词扩展标注" || bad "同义词扩展标注缺失"
echo "$out" | grep -q "MEMORY-活跃主题.md" && ok "同义词命中活跃主题" || bad "同义词未命中"
out=$(S 崩溃 2>/dev/null)
echo "$out" | grep -q "归档主题有命中" && ok "归档命中提示（崩溃→归档主题）" || bad "归档提示缺失"

out=$(S --all 崩溃 2>/dev/null)
echo "$out" | grep -q "归档记忆" && ok "M2: --all 显示归档段" || bad "M2: 归档段缺失"
n=$(echo "$out" | grep -c '^  [0-9]')
[ "$n" -gt 0 ] && ok "M2: 归档段有明细（$n 行）" || bad "M2: 归档段被挤空"

out=$(S 防火墙 --all 2>/dev/null)
echo "$out" | grep -q "MEMORY-活跃主题" && ok "M1: 第二参数 --all 按字面关键词搜索" || bad "M1: --all 被误吞"

out=$(S --include-scripts 卡死 2>/dev/null)
if echo "$out" | grep -q "工具脚本命中"; then bad "L6: --include-scripts 未生效（仍降级段）"
else ok "L6: --include-scripts 并入主排序"; fi

# L5: 活跃文件正文含 Archived 字样不被误归档（默认检索应命中活跃主题的 Archived 字样行）
out=$(S Archived 2>/dev/null)
echo "$out" | grep -q "MEMORY-活跃主题.md" && ok "L5: 正文 Archived 不误判归档" || bad "L5: 活跃主题被误归档"

out=$(S '[.*' 2>/dev/null)
[ -n "$out" ] && ok "正则元字符关键词不崩溃" || bad "元字符关键词输出异常"

echo "═══════ 2. memory_add.py（假库）═══════"
AM="$(mktemp -d)"; mkdir -p "$AM/scripts"
cp scripts/memory_add.py "$AM/scripts/"
printf '# Project memory\n## Discovered durable knowledge\n\n### Discovered\n(none)\n' > "$AM/MEMORY.md"
A() { python3 "$AM/scripts/memory_add.py" "$@"; }
A 新主题 "首条" "正文内容" >/dev/null 2>&1 && ok "新建主题+索引" || bad "新建失败"
[ -f "$AM/MEMORY-新主题.md" ] && ok "主题文件已建" || bad "主题文件缺失"
grep -q "MEMORY-新主题.md (1 entries)" "$AM/MEMORY.md" && ok "索引行已建" || bad "索引行缺失"
A 新主题 "二条" "内容二" >/dev/null 2>&1
grep -q "(2 entries)" "$AM/MEMORY.md" && ok "计数重算 1→2" || bad "计数未重算"
assert_not "M4/查重: 同标题拒绝" A 新主题 "首条" "重复"
out=$(A 新主题 "带日期标题（2026-08-10）" "内容三" 2>/dev/null)
if echo "$out" | grep -q "已落盘" && grep -qF "**带日期标题（2026-08-10）**：" "$AM/MEMORY-新主题.md" \
  && ! grep -qF "（2026-08-10）（" "$AM/MEMORY-新主题.md"; then
  ok "M4: 自带日期不重复附加"
else
  bad "M4: 日期防呆失败"
fi
out=$(A 新主题 "$(printf '多\n行\n标\n题')" "内容四" 2>/dev/null)
lines=$(grep -c '^- \*\*' "$AM/MEMORY-新主题.md")
[ "$lines" -eq 4 ] && ok "M4: title 换行清洗为单行条目（条目数 ${lines}）" || bad "M4: title 换行破坏条目（条目数 ${lines}）"
# L8: 并发落盘不丢（20 个并发进程不同标题；xargs 并发，避开 bash for+& 循环变量坑）
seq 1 20 | xargs -P 20 -I{} python3 "$AM/scripts/memory_add.py" 并发 "并发条{}" "内容{}" >/dev/null 2>&1
n=$(grep -c '^- \*\*' "$AM/MEMORY-并发.md" 2>/dev/null || echo 0)
[ "$n" -eq 20 ] && ok "L8: 20 并发落盘全保留（$n 条）" || bad "L8: 并发丢条目（$n/20）"
# 前缀标题不误杀（条1 vs 条10-19）
printf '# m\n## Discovered durable knowledge\n\n### Discovered\n(none)\n' > "$AM/MEMORY.md"
rm -f "$AM/MEMORY-前缀.md"
python3 "$AM/scripts/memory_add.py" 前缀 "条1" "c" >/dev/null 2>&1
python3 "$AM/scripts/memory_add.py" 前缀 "条10" "c" >/dev/null 2>&1
n=$(grep -c '^- \*\*' "$AM/MEMORY-前缀.md")
[ "$n" -eq 2 ] && ok "查重精确匹配：条1 不误杀 条10（$n 条）" || bad "查重前缀误杀（$n/2）"
python3 "$AM/scripts/memory_add.py" 前缀 "条1" "c" >/dev/null 2>&1 && bad "重复条1 未被拒绝" || ok "重复条1 仍被拒绝"
# v1.6: 子目录 topic（域/主题）落盘 + 索引路径 + resync 扫子目录
python3 "$AM/scripts/memory_add.py" dsh/新主题 "子目录条目" "c" >/dev/null 2>&1
[ -f "$AM/topics/dsh/MEMORY-新主题.md" ] && ok "v1.6: topics/<域>/ 文件创建" || bad "v1.6: 子目录文件缺失"
grep -q "See topics/dsh/MEMORY-新主题.md (1 entries)" "$AM/MEMORY.md" && ok "v1.6: 索引行含子目录路径" || bad "v1.6: 索引行路径错误"
python3 "$AM/scripts/memory_add.py" --resync >/dev/null 2>&1
grep -q "See topics/dsh/MEMORY-新主题.md (1 entries)" "$AM/MEMORY.md" && ok "v1.6: resync 覆盖子目录" || bad "v1.6: resync 丢失子目录"
# v1.3: 域感知索引插入——See 行进对应 ### <域> 小节；新域自动建小节；无域给提示
printf '# Project memory\n## Discovered durable knowledge\n\n### dsh — dsh 自身机制（topics/dsh/）\n- See topics/dsh/MEMORY-甲.md (1 entries) — 甲\n\n### knowledge — 通用技术知识（topics/knowledge/）\n- See topics/knowledge/MEMORY-丙.md (1 entries) — 丙\n\n### Discovered\n(none)\n' > "$AM/MEMORY.md"
rm -rf "$AM/topics"
mkdir -p "$AM/topics/dsh" "$AM/topics/knowledge"
printf '# MEMORY-甲.md\n- **甲（2026-01-01）**：x\n' > "$AM/topics/dsh/MEMORY-甲.md"
printf '# MEMORY-丙.md\n- **丙（2026-01-01）**：x\n' > "$AM/topics/knowledge/MEMORY-丙.md"
A dsh/乙 "乙条" "c" >/dev/null 2>&1
awk '/^### dsh/{d=1} /^### knowledge/{d=0} d&&/See topics\/dsh\/MEMORY-乙.md/{f=1} END{exit !f}' "$AM/MEMORY.md" \
  && ok "v1.3: 域主题 See 行插入对应域小节" || bad "v1.3: See 行未进对应域小节"
awk '/^### knowledge/{k=1} k&&/See topics\/dsh\/MEMORY-乙.md/{f=1} END{exit !f}' "$AM/MEMORY.md" \
  && bad "v1.3: See 行串到其它域小节" || ok "v1.3: 未串到其它域小节"
A projects/新项目 "新域条" "c" >/dev/null 2>&1
grep -q '^### projects' "$AM/MEMORY.md" && ok "v1.3: 新域自动建小节" || bad "v1.3: 新域小节未创建"
awk '/^### projects/{p=1} /^### Discovered/{p=0} p&&/See topics\/projects\/MEMORY-新项目.md/{f=1} END{exit !f}' "$AM/MEMORY.md" \
  && ok "v1.3: 新域 See 行落在新小节内" || bad "v1.3: 新域 See 行位置错误"
out=$(A 无域主题 "无域条" "c" 2>/dev/null)
echo "$out" | grep -q "未指定域" && ok "v1.3: 无域落盘给出域提示" || bad "v1.3: 无域无提示"
# resync 单数校正
printf '# m\n## Discovered durable knowledge\n- See MEMORY-旧.md (1 entry) — 旧\n### Discovered\n' > "$AM/MEMORY.md"
printf '# MEMORY-旧.md\n- **a（2026-01-01）**：x\n' > "$AM/MEMORY-旧.md"
python3 "$AM/scripts/memory_add.py" --resync >/dev/null 2>&1
grep -q "MEMORY-旧.md (1 entries)" "$AM/MEMORY.md" && ok "--resync 单数(1 entry)→(1 entries)" || bad "--resync 单数校正失败"

echo "═══════ 3. audit_secrets.sh ═══════"
assert "audit --test 正常退出 0" bash scripts/audit_secrets.sh --test
# M3: 故意失败场景退出码应传回
tmp_s="$(mktemp)"; sed 's|^SELF=.*|SELF=/bin/true|' scripts/audit_secrets.sh > "$tmp_s"
assert_not "M3: 拦截失效时 --test 应退出非 0" bash "$tmp_s" --test
sed 's|^SELF=.*|SELF=/bin/false|' scripts/audit_secrets.sh > "$tmp_s"
assert_not "M3: 占位符误报时 --test 应退出非 0" bash "$tmp_s" --test
rm -f "$tmp_s"

echo "═══════ 4. memory_sync.sh H1 剥离正则 ═══════"
strip() { printf '%s' "$1" | sed -E 's#(^[a-zA-Z][a-zA-Z0-9+.-]*://)[^@/]*:[^@/]*@#\1#'; }
r=$(strip "ssh://git@example.com/repo.git"); [ "$r" = "ssh://git@example.com/repo.git" ] && ok "H1: ssh user@host 不动" || bad "H1: ssh 被破坏→$r"
fake_pw="glpat-""abcdef1234"   # 运行时拼接，避免假样例字面连续出现
fake_cred_url="http://deploy:${fake_pw}@192.168.0.145/x.git"
r=$(strip "$fake_cred_url"); [ "$r" = "http://192.168.0.145/x.git" ] && ok "H1: user:pass@ 剥离" || bad "H1: 剥离失败→$r"
r=$(strip "http://192.168.0.145/x.git"); [ "$r" = "http://192.168.0.145/x.git" ] && ok "H1: 无凭据不变" || bad "H1: 无凭据被改→$r"

echo "═══════ 5. memory_sync.sh 假仓库全流程 ═══════"
SY="$(mktemp -d)"; BAREDIR="$(mktemp -d)"; mkdir -p "$SY/scripts"
cp scripts/memory_sync.sh "$SY/scripts/"
git init -q --bare -b main "$BAREDIR/remote.git"
git --git-dir="$BAREDIR/remote.git" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
SYNC() { bash "$SY/scripts/memory_sync.sh" "$@" 2>&1; }
# SY1: 非 git 目录自动 init + 本地 bare remote 真推（bare 仓库放记忆库之外）
printf '# 记忆\n- **x（2026-01-01）**：y\n' > "$SY/MEMORY.md"
git -C "$SY" init -q -b main 2>/dev/null || true
git -C "$SY" remote add origin "$BAREDIR/remote.git" 2>/dev/null || true
SYNC "初始同步" | grep -q "已推送" && ok "SY1: init+commit+push 全流程" || bad "SY1: 推送流程失败"
git -C "$BAREDIR/remote.git" rev-parse main >/dev/null 2>&1 && ok "SY1: bare 仓库收到 main" || bad "SY1: bare 仓库无 main"
# SY2: 无变更跳过 commit（不产生空提交）
before=$(git -C "$SY" rev-parse HEAD)
SYNC "无变更" | grep -q "无变更" && ok "SY2: 无变更跳过 commit" || bad "SY2: 未跳过"
# SY3: flock 抢占——后台持有锁，sync 应立即退出
# macOS 无 flock（memory_sync.sh 会降级为不锁），此时跳过本用例而非判失败
if command -v flock >/dev/null 2>&1; then
  ( exec 9>"$SY/.git/memory-sync.lock"; flock -n 9; sleep 5 ) &
  holder=$!
  sleep 0.5
  SYNC "并发抢锁" | grep -q "另一 memory_sync 正在进行" && ok "SY3: flock 互斥生效" || bad "SY3: flock 未生效"
  kill $holder 2>/dev/null; wait $holder 2>/dev/null || true
else
  ok "SY3: 跳过（本机无 flock，memory_sync.sh 已降级为不锁）"
fi
# SY4: rebase 冲突态 + pull 失败 → 提示冲突退出 1
mkdir -p "$SY/.git/rebase-merge"
git -C "$SY" remote set-url origin "/nonexistent/path.git"
out=$(SYNC "冲突模拟" || true)
echo "$out" | grep -q "rebase 冲突" && ok "SY4: rebase 冲突态中止提示" || bad "SY4: 冲突提示缺失→$out"
rm -rf "$SY/.git/rebase-merge"
git -C "$SY" remote set-url origin "$BAREDIR/remote.git"
# SY5: pull 失败（无冲突态）→ 非冲突提示
git -C "$SY" remote set-url origin "/nonexistent/path.git"
out=$(SYNC "拉取失败" || true)
echo "$out" | grep -q "非冲突原因" && ok "SY5: 非冲突失败提示" || bad "SY5: 提示缺失→$out"
rm -rf "$SY" "$BAREDIR"

echo "═══════ 6. audit_secrets.sh 全模式 ═══════"
AU="$(mktemp -d)"; printf '' > "$AU/t.md"
ghp_sample="ghp_""abcdefghijklmnopqrstuvwxyz1234"          # 运行时拼接，防假样例字面进文件
printf 'x %s y\n' "$ghp_sample" > "$AU/t.md"
bash scripts/audit_secrets.sh "$AU" 2>&1 | grep -q "GitHub PAT" && ok "AU1: ghp_ 拦截" || bad "AU1: ghp_ 未拦"
gp_sample="github_pat_""abcdefghijklmnopqrstuvwxyz1234"
printf 'x %s y\n' "$gp_sample" > "$AU/t.md"
bash scripts/audit_secrets.sh "$AU" 2>&1 | grep -q "GitHub 细粒度" && ok "AU2: 细粒度 PAT 拦截" || bad "AU2: 未拦"
rsa_sample="-----BEGIN ""RSA PRIVATE KEY-----"
printf '%s\nabc\n-----END RSA PRIVATE KEY-----\n' "$rsa_sample" > "$AU/t.md"
bash scripts/audit_secrets.sh "$AU" 2>&1 | grep -q "私钥" && ok "AU3: 私钥拦截" || bad "AU3: 未拦"
printf 'pass = ChangeMe_12345\n' > "$AU/t.md"
bash scripts/audit_secrets.sh "$AU" 2>&1 | grep -q "干净" && ok "AU4: ChangeMe_ 豁免" || bad "AU4: 误报"
printf 'bin\x00ary content\n' > "$AU/b.md"
bash scripts/audit_secrets.sh "$AU" 2>&1 | grep -q "干净" && ok "AU5: 二进制跳过不误报" || bad "AU5: 二进制误报"
rm -rf "$AU"

echo "═══════ 7. memory_search.sh 补充边界 ═══════"
out=$(S qwertyzzz 2>/dev/null)
echo "$out" | grep -q "无命中" && ok "SE1: 0 命中文案" || bad "SE1: 缺失"
mkdir -p "$FM/sessions"; printf '# cp\n## Active intent\n查 卡死 的问题\n' > "$FM/sessions/x.md"
out=$(S 卡死 2>/dev/null)
echo "$out" | grep -q "checkpoint 命中" && ok "SE2: sessions 命中时列 checkpoint 区" || bad "SE2: 缺失"
rm -f "$FM/sessions/x.md"
out=$(S 卡死 2>/dev/null)
echo "$out" | grep -q "checkpoint 命中" && bad "SE2b: 未命中仍列 checkpoint" || ok "SE2b: 未命中不列 checkpoint"
out=$(MEMORY_SEARCH_MAX_FILES=1 bash "$FM/scripts/memory_search.sh" 卡死 2>/dev/null)
echo "$out" | grep -q "还有.*文件未列出" && ok "SE3: MAX_FILES 截断提示" || bad "SE3: 缺失"
out=$(MEMORY_SEARCH_LINE_WIDTH=20 bash "$FM/scripts/memory_search.sh" 防火墙 2>/dev/null)
echo "$out" | grep -q "…" && ok "SE4: LINE_WIDTH 截断生效" || bad "SE4: 未截断"

echo "═══════ 8. memory_add.py 报错路径 ═══════"
assert_not "AD1: 空 topic 拒绝" python3 "$AM/scripts/memory_add.py" "" "t" "b"
assert_not "AD2: 非法日期拒绝" python3 "$AM/scripts/memory_add.py" t2 "t" "b" "2026-13-99"
printf '# m\n## Rules\n- r\n' > "$AM/MEMORY.md"   # 缺 Discovered durable knowledge 小节
out=$(python3 "$AM/scripts/memory_add.py" t3 "t" "b" 2>&1 || true)
echo "$out" | grep -q "Discovered durable knowledge" && ok "AD3: 缺小节报错" || bad "AD3: 未报错→$out"

echo "═══════ 9. memory_suggest.py ═══════"
SG="$(mktemp -d)"; mkdir -p "$SG/scripts" "$SG/sessions"
cp scripts/memory_suggest.py "$SG/scripts/"
printf '# cp\n## Discovered candidates\n- 候选甲\n- 候选乙\n## Errors\n- err\n' > "$SG/sessions/x.md"
out=$(python3 "$SG/scripts/memory_suggest.py" 2>&1)
echo "$out" | grep -q "候选甲" && echo "$out" | grep -q "候选乙" && ok "SG1: 候选区提取" || bad "SG1: 提取失败→$out"
echo "$out" | grep -q "err" && bad "SG2: 误提 Errors 节" || ok "SG2: 不提取 Errors"
printf '# cp\n## Next action\nx\n' > "$SG/sessions/y.md"
out=$(python3 "$SG/scripts/memory_suggest.py" 2>&1)
echo "$out" | grep -q "无候选" && ok "SG3: 无候选提示" || bad "SG3: 缺失→$out"
rm -rf "$SG"

echo
echo "═══════ 结果：通过 $PASS / 失败 $FAIL ═══════"
[ "$FAIL" -eq 0 ]
