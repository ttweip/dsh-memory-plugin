#!/usr/bin/env bash
# dsh-memory-plugin 一键发布：本地校验 → 推 GitLab → 建 Release → 同步 GitHub 镜像
# 用法: bash scripts/release.sh <vX.Y.Z> [message]
# 凭据: 环境变量 DSH_GITLAB_PAT（必填）与 DSH_GH_PAT（必填，GitHub 镜像）
# 发布描述: 自动从 CHANGELOG.md 提取「## vX.Y.Z」段落
set -euo pipefail

[ $# -ge 1 ] || { echo "用法: $0 <vX.Y.Z> [message]" >&2; exit 1; }
VERSION="$1"
VERSION_NOV="${VERSION#v}"   # package.json 内无 v 前缀
MESSAGE="${2:-release $VERSION}"
PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PLUGIN_DIR"

GL_PAT="${DSH_GITLAB_PAT:-}"
GH_PAT="${DSH_GH_PAT:-}"
[ -n "$GL_PAT" ] || { echo "❌ 缺 DSH_GITLAB_PAT（GitLab 推送凭据）" >&2; exit 1; }
[ -n "$GH_PAT" ] || { echo "❌ 缺 DSH_GH_PAT（GitHub 镜像凭据）" >&2; exit 1; }
GL_HTTP="192.168.0.145"
GH_HTTP="https://api.github.com"

# ── 1) 本地校验 ───────────────────────────────────────────────────────
echo "== 1) 本地校验 =="
node --check index.mjs
npm test >/dev/null 2>&1 || { echo "❌ npm test 未通过" >&2; exit 1; }
bash -n install.sh
grep -q "\"version\": \"$VERSION_NOV\"" package.json || { echo "❌ package.json 版本不是 $VERSION_NOV" >&2; exit 1; }
echo "✓ 校验通过（npm test 全绿）"

# ── 2) 从 CHANGELOG 提取发布描述 ───────────────────────────────────────
DESC="$(python3 - "$VERSION" <<'PYEOF'
import re, sys
v = sys.argv[1]
text = open('CHANGELOG.md', encoding='utf-8').read()
m = re.search(rf'##\s+{re.escape(v)}[^\n]*\n(.*?)(?=\n##\s|\Z)', text, re.S)
if not m:
    print(f'❌ CHANGELOG.md 无 {v} 段', file=sys.stderr); sys.exit(1)
print(m.group(1).strip())
PYEOF
)"

# ── 3) 推 GitLab（main + tag + release）───────────────────────────────
echo "== 3) GitLab =="
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
GIT_TERMINAL_PROMPT=0 git clone -q "http://deploy:$GL_PAT@$GL_HTTP/deploy/dsh-memory-plugin.git" "$tmp/repo"
cd "$tmp/repo"
cp "$PLUGIN_DIR"/index.mjs "$PLUGIN_DIR"/package.json "$PLUGIN_DIR"/README.md \
   "$PLUGIN_DIR"/install.sh "$PLUGIN_DIR"/CHANGELOG.md .
[ -d "$PLUGIN_DIR/test" ] && { rm -rf test; cp -r "$PLUGIN_DIR/test" test; }
[ -d "$PLUGIN_DIR/scripts" ] && { rm -rf scripts; cp -r "$PLUGIN_DIR/scripts" scripts; }
git add -A
git -c user.name="dsh-memory" -c user.email="memory@dsh.local" commit -q -m "$MESSAGE"
git push -q "http://deploy:$GL_PAT@$GL_HTTP/deploy/dsh-memory-plugin.git" main
git tag "$VERSION"
git push -q "http://deploy:$GL_PAT@$GL_HTTP/deploy/dsh-memory-plugin.git" "$VERSION"
python3 - "$VERSION" "$DESC" <<'PYEOF' > "$tmp/body.json"
import json, sys
print(json.dumps({"name": sys.argv[1], "tag_name": sys.argv[1], "description": sys.argv[2]}))
PYEOF
curl -s -m 20 -X POST -H "PRIVATE-TOKEN: $GL_PAT" -H "Content-Type: application/json" \
  --data @"$tmp/body.json" "$GL_HTTP/api/v4/projects/deploy%2Fdsh-memory-plugin/releases" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('✓ GitLab release:', r.get('tag_name')) if 'tag_name' in r else (print('FAIL:', r), sys.exit(1))"

# ── 4) 同步 GitHub 镜像（main + tag + release）─────────────────────────
echo "== 4) GitHub =="
GH_URL="https://oauth2:$GH_PAT@github.com/ttweip/dsh-memory-plugin.git"
git push -q "$GH_URL" main
git push -q "$GH_URL" "$VERSION"
curl -s -m 20 -X POST -H "Authorization: Bearer $GH_PAT" -H "Accept: application/vnd.github+json" \
  --data @"$tmp/body.json" "https://api.github.com/repos/ttweip/dsh-memory-plugin/releases" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print('✓ GitHub release:', r.get('tag_name'), r.get('html_url','')) if 'tag_name' in r else (print('FAIL:', r), sys.exit(1))"

# ── 5) 待办提示 ────────────────────────────────────────────────────────
echo "== 5) 收尾待办 =="
echo "  · 记忆库配套改动 commit + memory_sync + 补推 GitHub 镜像 ttweip/dsh-memory"
echo "  · 落盘 $VERSION 记录（memory_add）"
echo "  · 按 scripts/release_checklist.md 完成发布后人工验收"
echo "  · 提醒用户 dsh-web 需重启生效"
echo "✓ $VERSION 双端发布完成"
