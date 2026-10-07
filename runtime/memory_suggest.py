#!/usr/bin/env python3
# dsh 记忆候选提示（v1.6）：扫描最近会话 checkpoint 的候选区，列出待确认落盘的知识。
# 半自动提取：不自动写入，只列候选，由模型挑选后用 memory_add 落盘（符合 §7 护栏）。
# 用法: memory_suggest.py [份数]     默认读最近 1 份 checkpoint
import re
import sys
from pathlib import Path

MEM_DIR = Path(__file__).resolve().parent.parent
SESS_DIR = MEM_DIR / 'sessions'


def candidates_of(text: str):
    """提取 checkpoint 中「Discovered candidates」节的行（- 开头）。"""
    m = re.search(r'##\s+Discovered candidates[^\n]*\n([\s\S]*?)(?=\n##\s|$)', text)
    if not m:
        return []
    out = []
    for line in m.group(1).splitlines():
        s = line.strip()
        if s.startswith('- '):
            out.append(s[2:].strip())
        elif s and not s.startswith('#'):
            out.append(s)
    return [c for c in out if c and c not in ('(none)', '(无)')]


def main() -> None:
    if not SESS_DIR.exists():
        print('（无 sessions/ 目录，还没有 checkpoint）')
        return
    n = 1
    if len(sys.argv) >= 2 and sys.argv[1].isdigit():
        n = int(sys.argv[1])
    files = sorted(SESS_DIR.glob('*.md'), key=lambda p: p.stat().st_mtime, reverse=True)[:n]
    if not files:
        print('（无 checkpoint）')
        return
    total = 0
    for f in files:
        cands = candidates_of(f.read_text(encoding='utf-8', errors='replace'))
        if not cands:
            continue
        print(f'== {f.name} ==')
        for i, c in enumerate(cands, 1):
            total += 1
            print(f'{total}. {c}')
        print()
    if total == 0:
        print('最近 checkpoint 无候选条目（Discovered candidates 为空）。')
        print('提示：会话中有「已验证的结论/新规则」时，建议直接 memory_add 落盘，不必等候选区。')
    else:
        print(f'共 {total} 条候选。挑选确认后逐条 memory_add（topic/title/body），其余可忽略。')


if __name__ == '__main__':
    main()
