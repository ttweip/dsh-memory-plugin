#!/usr/bin/env bash
# dsh 记忆备份：本地 git commit；配置了 remote 则 rebase 后推送（绝不 force-push）
# 用法: memory_sync.sh ["提交说明"]
#
# v1.0.4 健壮性：
#   - remote URL 若内嵌明文凭据 → 自动剥离（防 token 落盘 .git/config）
#   - pull --rebase 冲突 → 中止并提示人工处理，绝不带中间态 push
#   - flock 互斥：多会话并发 sync 时后者直接退出，不互相打架
#   - git HTTP 低速超时（GIT_HTTP_LOW_SPEED_*），避免网络挂死
# 凭据来源（不写进 remote）：~/.git-credentials（credential.helper）或环境变量
#   DSH_GITLAB_PAT（临时注入，仅进程内使用）
set -euo pipefail

MEM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MEM_DIR"

MSG="${1:-$(date +'docs: 记忆同步 %Y-%m-%d %H:%M')}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git init -b main
fi

# ── 并发互斥（flock 不存在时降级为不锁）──────────────────────────────
LOCK="$MEM_DIR/.git/memory-sync.lock"
exec 9>"$LOCK"
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    echo "❌ 另一 memory_sync 正在进行（$LOCK），本次退出。稍后再试。"
    exit 1
  fi
fi

# ── 剥离 remote 内嵌凭据（一次性自愈，之后不再落盘 token）────────────
# 只剥 user:pass@ 形态；user@host（如 ssh://git@host）无密码，不动
url="$(git remote get-url origin 2>/dev/null || true)"
case "$url" in
  *://*@*)
    clean="$(printf '%s' "$url" | sed -E 's#(^[a-zA-Z][a-zA-Z0-9+.-]*://)[^@/]*:[^@/]*@#\1#')"
    if [ "$clean" != "$url" ]; then
      git remote set-url origin "$clean"
      echo "⚠️ 已剥离 remote URL 中的内嵌凭据：$clean"
    fi
    ;;
esac

# 当前分支动态取（不硬编码 main，兼容任意主分支名）
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"

# ── git 低速超时（30s 无进展即中止）─────────────────────────────────
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=30

# ── 凭据注入：优先环境变量 DSH_GITLAB_PAT（进程内，不落盘）────────────
if [ -n "${DSH_GITLAB_PAT:-}" ]; then
  host="$(git remote get-url origin 2>/dev/null | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+)/.*#\1#')"
  scheme="$(git remote get-url origin 2>/dev/null | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://).*#\1#')"
  AUTH_URL="${scheme}oauth2:${DSH_GITLAB_PAT}@${host#*://}"
fi

git add -A
if git diff --cached --quiet; then
  echo "无变更，跳过 commit"
else
  git -c user.name="dsh-memory" -c user.email="memory@dsh.local" commit -m "$MSG"
  echo "已提交: $MSG"
fi

if git remote | grep -q origin; then
  # 远端尚无该分支（空仓库首次推送）→ 跳过 pull 直接 push；
  # 注意与「远端不可达」区分：ls-remote --heads 成功（空输出也 exit 0）且无该分支才算首次推送
  heads="$(git ls-remote --heads origin "$BRANCH" 2>/dev/null || true)"
  if git ls-remote --heads origin "$BRANCH" >/dev/null 2>&1 && [ -z "$heads" ]; then
    echo "远端尚无 $BRANCH（首次推送），跳过 pull"
    if [ -n "${AUTH_URL:-}" ]; then
      git -c credential.helper= -c "remote.origin.url=$AUTH_URL" push origin "$BRANCH" 2>&1
    else
      git push origin "$BRANCH" 2>&1
    fi
  elif [ -n "${AUTH_URL:-}" ]; then
    if ! git -c credential.helper= -c "remote.origin.url=$AUTH_URL" pull --rebase origin "$BRANCH" 2>&1; then
      if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
        echo "❌ rebase 冲突：$MEM_DIR 需人工处理（git status 查看；解决后 git rebase --continue，或 git rebase --abort）。未推送。"
        exit 1
      fi
      echo "❌ pull --rebase 失败（非冲突原因），未推送。"
      exit 1
    fi
    git -c credential.helper= -c "remote.origin.url=$AUTH_URL" push origin "$BRANCH" 2>&1
  else
    if ! git pull --rebase origin "$BRANCH" 2>&1; then
      if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
        echo "❌ rebase 冲突：$MEM_DIR 需人工处理（git status 查看；解决后 git rebase --continue，或 git rebase --abort）。未推送。"
        exit 1
      fi
      echo "❌ pull --rebase 失败（非冲突原因），未推送。"
      exit 1
    fi
    git push origin "$BRANCH" 2>&1
  fi
  echo "已推送 origin/$BRANCH（rebase 不 force-push）"
else
  echo "未配置 remote，仅本地 commit。备份仓库创建后：git remote add origin http://<gitlab-host>/deploy/dsh-memory.git（勿内嵌 token，凭据走 ~/.git-credentials 或 DSH_GITLAB_PAT）"
fi
