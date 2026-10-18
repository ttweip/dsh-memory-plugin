#!/usr/bin/env python3
"""dsh 记忆精准读取 v1.9。

只允许读取记忆库内的 `MEMORY-*.md` 主题文件；支持按小节、绝对行号 offset、
行数 limit 与字节预算 max-bytes。用于 memory_search 命中后的二段式读取。
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import List, Optional, Tuple

VERSION = "1.9.0"
SCRIPT_DIR = Path(__file__).resolve().parent
MEM_DIR = SCRIPT_DIR.parent
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")

try:
    sys.stdout.reconfigure(encoding="utf-8")
except (AttributeError, ValueError):
    pass


def _positive_int(value: str) -> int:
    try:
        n = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"需要整数：{value}") from exc
    if n < 1:
        raise argparse.ArgumentTypeError("必须 ≥1")
    return n


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="memory_get.py",
        description="读取 dsh 记忆库中的 MEMORY-*.md 主题片段",
    )
    parser.add_argument("--path", "-p", required=True, help="相对记忆库根的路径，如 topics/dsh/MEMORY-x.md")
    parser.add_argument("--section", "-s", default="", help="小节标题（子串匹配，限定读取范围）")
    parser.add_argument("--offset", "-o", type=_positive_int, default=None, help="绝对起始行号，1 基（默认 1 或小节起始）")
    parser.add_argument("--limit", "-l", type=_positive_int, default=60, help="最多读取行数（默认 60，最大 200）")
    parser.add_argument("--max-bytes", type=_positive_int, default=6000, help="输出字节预算（默认 6000）")
    parser.add_argument("--version", action="version", version=f"memory_get {VERSION}")
    return parser


def resolve_topic(path_arg: str) -> Tuple[Path, str]:
    raw = Path(path_arg)
    if raw.is_absolute() or ".." in raw.parts:
        raise ValueError("path 必须是记忆库内的相对路径，且不能包含 ..")
    if raw.suffix.lower() != ".md" or not raw.name.startswith("MEMORY-"):
        raise ValueError("只允许读取 MEMORY-*.md 主题文件")
    root = MEM_DIR.resolve()
    full = (MEM_DIR / raw).resolve()
    try:
        if os.path.commonpath([str(root), str(full)]) != str(root):
            raise ValueError("path 越出记忆库范围")
    except ValueError:
        raise ValueError("path 越出记忆库范围")
    if not full.is_file():
        raise ValueError(f"文件不存在：{raw}")
    return full, str(raw)


def find_section(lines: List[str], section: str) -> Optional[Tuple[int, int, str]]:
    """返回 (start_idx, end_idx, heading)，索引 0 基，end 不含。"""
    if not section:
        return None
    needle = section.casefold()
    headings = []
    for idx, line in enumerate(lines):
        m = HEADING_RE.match(line)
        if m:
            headings.append((idx, len(m.group(1)), m.group(2).strip()))
    for pos, (idx, level, title) in enumerate(headings):
        if needle not in title.casefold():
            continue
        end = len(lines)
        for next_idx, next_level, _ in headings[pos + 1:]:
            if next_level <= level:
                end = next_idx
                break
        return idx, end, title
    return None


def read_slice(
    path: Path,
    rel: str,
    section: str,
    offset: Optional[int],
    limit: int,
    max_bytes: int,
) -> str:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    total = len(lines)
    sec = find_section(lines, section)
    if section and sec is None:
        titles = [m.group(2).strip() for m in (HEADING_RE.match(x) for x in lines) if m]
        preview = " / ".join(titles[:8])
        raise ValueError(f"未找到小节：{section}" + (f"（可用：{preview}）" if preview else ""))

    if sec:
        sec_start, sec_end, sec_title = sec
        low = sec_start + 1
        high = sec_end
    else:
        sec_start, sec_end, sec_title = 0, total, ""
        low = 1
        high = total

    start = max(low, min(offset or low, high)) if high >= low else low
    limit = max(1, min(limit, 200))
    # 预算：表头 + 行 + 尾部提示都要放得下。
    header = f"[{rel} L{start}-? / {total} 行"
    if sec_title:
        header += f"｜section={sec_title}"
    header += "]"
    budget = max(512, min(max_bytes, 20000))
    body: List[str] = []
    used = len((header + "\n").encode("utf-8"))
    end = start - 1
    stop = min(high, total, start + limit - 1)
    for lineno in range(start, stop + 1):
        line = f"{lineno:>5}: {lines[lineno - 1]}"
        cost = len((line + "\n").encode("utf-8"))
        if body and used + cost > budget:
            break
        if not body and used + cost > budget:
            # 极端窄预算：只截该行，保证不空返回。
            room = max(0, budget - used - 1)
            line = line[:room]
            cost = len((line + "\n").encode("utf-8"))
        body.append(line)
        used += cost
        end = lineno
    if not body:
        body.append(f"{start:>5}: （无内容）")
        end = start

    remaining = max(0, high - end)
    header = f"[{rel} L{start}-L{end} / {total} 行"
    if sec_title:
        header += f"｜section={sec_title}"
    header += "]"
    footer = ""
    if remaining:
        where = "本节" if sec_title else ""
        footer = f"\n（{where}还有 {remaining} 行未显示；继续读取时把 offset 设为 {end + 1}）"
    out = header + "\n" + "\n".join(body)
    if footer:
        out += footer
    # 硬预算兜底（极长单行/极小预算）
    raw = out.encode("utf-8")
    if len(raw) > budget:
        marker = "\n…（输出超过字节预算，已截断）"
        room = max(0, budget - len(marker.encode("utf-8")))
        cut = raw[:room].decode("utf-8", "ignore")
        if "\n" in cut:
            cut = cut.rsplit("\n", 1)[0]
        out = cut + marker
    return out


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        full, rel = resolve_topic(args.path)
        text = read_slice(full, rel, args.section, args.offset, args.limit, args.max_bytes)
    except (ValueError, OSError) as exc:
        print(f"❌ memory_get: {exc}", file=sys.stderr)
        return 1
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
