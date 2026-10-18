#!/usr/bin/env python3
"""dsh 记忆检索 v1.9（单进程实现）。

默认：scope=local，只搜本地 MEMORY-*.md；多词按词义组严格 AND；
输出按条目聚合，并有文件/条目/字节硬预算。reference 层需显式 scope。
"""
from __future__ import annotations

import datetime as _dt
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

VERSION = "1.9.0"
SCRIPT_DIR = Path(__file__).resolve().parent
MEM_DIR = SCRIPT_DIR.parent
SYN_FILE = SCRIPT_DIR / "synonyms.tsv"

try:
    sys.stdout.reconfigure(encoding="utf-8")
except (AttributeError, ValueError):
    pass


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default


MAX_FILES = max(1, _env_int("MEMORY_SEARCH_MAX_FILES", 3))
MAX_ENTRIES_PER_FILE = max(1, _env_int("MEMORY_SEARCH_MAX_PER_FILE", 3))
MAX_ENTRIES = max(1, _env_int("MEMORY_SEARCH_MAX_LINES", 20))
MAX_BYTES = max(256, _env_int("MEMORY_SEARCH_MAX_BYTES", 2000))
# 兼容旧变量 MEMORY_SEARCH_LINE_WIDTH；新变量优先。
ENTRY_WIDTH = max(
    40,
    _env_int(
        "MEMORY_SEARCH_ENTRY_WIDTH",
        _env_int("MEMORY_SEARCH_LINE_WIDTH", 420),
    ),
)

USAGE = (
    "用法: memory_search.sh [--scope local|reference|all] [--any] "
    "[--all] [--include-scripts] <关键词...>"
)

ENTRY_HEAD_RE = re.compile(r"^-\s+\*\*(.+?)\*\*\s*[：:]\s*(.*)$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
DATE_FMT = "%Y-%m-%d"


@dataclass
class SearchOptions:
    scope: str = "local"
    any_mode: bool = False
    include_archived: bool = False
    include_scripts: bool = False
    keywords: List[str] = field(default_factory=list)


@dataclass
class Entry:
    line: int
    text: str
    title: str = ""
    section: str = ""
    groups_hit: Tuple[int, ...] = ()


@dataclass
class FileHit:
    path: Path
    rel: str
    mtime: float
    entries: List[Entry]
    file_groups: Tuple[int, ...]
    hit_entries: int
    score: int
    archived: bool = False
    script: bool = False


def parse_args(argv: Sequence[str]) -> Optional[SearchOptions]:
    opts = SearchOptions()
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--version":
            print(f"memory_search {VERSION}")
            return None
        if arg in ("-h", "--help"):
            print(USAGE)
            return None
        if arg == "--include-scripts":
            opts.include_scripts = True
            i += 1
            continue
        if arg == "--all":
            opts.include_archived = True
            i += 1
            continue
        if arg == "--any":
            opts.any_mode = True
            i += 1
            continue
        if arg == "--scope":
            if i + 1 >= len(argv):
                print("❌ --scope 缺少取值（local|reference|all）", file=sys.stderr)
                print(USAGE, file=sys.stderr)
                raise SystemExit(2)
            opts.scope = argv[i + 1]
            i += 2
            continue
        if arg.startswith("--scope="):
            opts.scope = arg.split("=", 1)[1]
            i += 1
            continue
        if arg == "--":
            i += 1
            break
        if arg.startswith("-"):
            print(f"❌ 未知选项：{arg}", file=sys.stderr)
            print(USAGE, file=sys.stderr)
            raise SystemExit(2)
        break
    opts.keywords = [str(x) for x in argv[i:]]
    if opts.scope not in ("local", "reference", "all"):
        print(
            f"❌ --scope 仅支持 local|reference|all，收到：{opts.scope}",
            file=sys.stderr,
        )
        print(USAGE, file=sys.stderr)
        raise SystemExit(2)
    if not opts.keywords:
        print(USAGE, file=sys.stderr)
        raise SystemExit(1)
    return opts


def load_synonyms() -> Dict[str, List[str]]:
    mapping: Dict[str, List[str]] = {}
    if not SYN_FILE.is_file():
        return mapping
    try:
        lines = SYN_FILE.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return mapping
    for line in lines:
        if not line or line.startswith("#") or "\t" not in line:
            continue
        key, rest = line.split("\t", 1)
        key = key.strip()
        words = [w for w in rest.split() if w]
        if key:
            mapping[key] = words
    return mapping


def term_groups(keywords: Sequence[str], synonyms: Dict[str, List[str]]) -> List[List[str]]:
    groups: List[List[str]] = []
    for kw in keywords:
        group = [kw]
        for word in synonyms.get(kw, []):
            if word not in group:
                group.append(word)
        groups.append(group)
    return groups


def iter_files(scope: str, include_scripts: bool) -> Iterable[Path]:
    if scope == "reference":
        root = MEM_DIR / "reference"
        if root.is_dir():
            yield from _walk_topics(root)
    elif scope == "all":
        yield from _walk_topics(MEM_DIR)
    else:
        yield from _walk_topics(MEM_DIR, skip_reference=True)

    if include_scripts and scope != "reference":
        scripts = MEM_DIR / "scripts"
        if scripts.is_dir():
            for path in sorted(scripts.iterdir()):
                if path.is_file() and path.suffix in (".sh", ".py"):
                    yield path


def _walk_topics(root: Path, skip_reference: bool = False) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        # 目录级剪枝，避免无谓地进入 sessions/.git/reference
        dirnames[:] = [
            d
            for d in dirnames
            if d not in (".git", "sessions")
            and not (skip_reference and d == "reference")
        ]
        for name in sorted(filenames):
            if name.startswith("MEMORY-") and name.endswith(".md"):
                yield Path(dirpath) / name


def is_archived(text: str) -> bool:
    for line in text.splitlines()[:5]:
        if line.startswith("状态：Archived") or line.startswith("_状态：Archived"):
            return True
    return False


def extract_entries(text: str) -> List[Entry]:
    """按 `- **标题**：正文` 聚合条目；续行合并到当前条目。"""
    entries: List[Entry] = []
    current: Optional[Entry] = None
    section = ""
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        heading = HEADING_RE.match(line)
        if heading:
            section = heading.group(2).strip()
            if current is not None:
                entries.append(current)
                current = None
            continue
        m = ENTRY_HEAD_RE.match(line)
        if m:
            if current is not None:
                entries.append(current)
            current = Entry(
                line=lineno,
                text=f"- **{m.group(1).strip()}**：{m.group(2).strip()}",
                title=m.group(1).strip(),
                section=section,
            )
            continue
        if current is not None:
            stripped = line.strip()
            if stripped and not stripped.startswith("- "):
                current.text += " " + stripped
    if current is not None:
        entries.append(current)
    # 报告体/非条目文件：退化为逐行伪条目
    if not entries:
        for lineno, raw in enumerate(text.splitlines(), 1):
            if raw.strip():
                entries.append(Entry(line=lineno, text=raw.strip()))
    return entries


def _collapse(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _display(text: str, width: int) -> str:
    text = _collapse(text)
    if len(text) > width:
        return text[:width] + "…"
    return text


def _groups_in_text(text: str, groups: Sequence[Sequence[str]]) -> Tuple[int, ...]:
    return tuple(i for i, group in enumerate(groups) if any(term in text for term in group))


def _format_date(ts: float) -> str:
    try:
        return _dt.datetime.fromtimestamp(ts).strftime(DATE_FMT)
    except (OverflowError, OSError, ValueError):
        return "?"


def scan(
    opts: SearchOptions,
    groups: Sequence[Sequence[str]],
    search_terms: Sequence[str],
) -> List[FileHit]:
    hits: List[FileHit] = []
    for path in iter_files(opts.scope, opts.include_scripts):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
            mtime = path.stat().st_mtime
        except OSError:
            continue
        file_groups = _groups_in_text(text, groups)
        if opts.any_mode:
            if not file_groups:
                continue
        elif len(file_groups) != len(groups):
            continue

        entries = extract_entries(text)
        matched: List[Entry] = []
        for entry in entries:
            entry_groups = _groups_in_text(entry.text, groups)
            if not entry_groups:
                continue
            entry.groups_hit = entry_groups
            matched.append(entry)
        if not matched:
            # 关键词只出现在头部/索引行时，保留文件但不要凭空编条目。
            pseudo = []
            for lineno, raw in enumerate(text.splitlines(), 1):
                if any(term in raw for term in search_terms):
                    pseudo.append(Entry(line=lineno, text=raw.strip()))
            matched = pseudo
        if not matched:
            continue

        matched.sort(key=lambda e: (-len(e.groups_hit), e.line))
        max_entry_groups = max((len(e.groups_hit) for e in matched), default=0)
        entries_count = max(len(entries), 4)
        name_hit = 100 if any(k in path.name for k in opts.keywords) else 0
        score = (
            len(file_groups) * 10000
            + max_entry_groups * 1000
            + min(len(matched) * 100 // entries_count, 99)
            + name_hit
        )
        hits.append(
            FileHit(
                path=path,
                rel=str(path.relative_to(MEM_DIR)),
                mtime=mtime,
                entries=matched,
                file_groups=file_groups,
                hit_entries=len(matched),
                score=score,
                archived=is_archived(text),
                script=path.parent == SCRIPT_DIR,
            )
        )
    hits.sort(key=lambda h: (-h.score, -h.mtime, h.rel))
    return hits


def render(
    opts: SearchOptions,
    groups: Sequence[Sequence[str]],
    search_terms: Sequence[str],
    synonyms: Dict[str, List[str]],
    active: Sequence[FileHit],
    archived: Sequence[FileHit],
) -> str:
    mode = "宽松 OR" if opts.any_mode else "严格 AND"
    expanded = []
    for kw in opts.keywords:
        words = synonyms.get(kw, [])
        if words:
            expanded.append(f"{kw}→{'|'.join(words)}")
    header = f"== dsh-memory 命中（{' '.join(opts.keywords)}｜scope={opts.scope}｜{mode}）=="
    if expanded:
        header += f"  [同义词扩展: {' '.join(expanded)}]"

    parts: List[str] = [header]
    shown_files = 0
    shown_entries = 0

    def add_group(title: str, hits: Sequence[FileHit]) -> None:
        nonlocal shown_files, shown_entries
        group_shown_files = 0
        group_shown_entries = 0
        if not hits:
            return
        if title:
            parts.append("")
            parts.append(title)
        for hit in hits:
            if group_shown_files >= MAX_FILES:
                break
            if group_shown_entries >= MAX_ENTRIES:
                break
            header_line = (
                f"[{group_shown_files + 1}/{len(hits)}] {hit.rel} — "
                f"{hit.hit_entries} 条命中（更新 {_format_date(hit.mtime)}）"
            )
            # 先检查文件头是否还放得下；预算由最后统一字节截断，这里只控制条目数。
            parts.append("")
            parts.append(header_line)
            group_shown_files += 1
            shown_files += 1
            remaining = MAX_ENTRIES - group_shown_entries
            per_file = min(MAX_ENTRIES_PER_FILE, remaining)
            displayed = 0
            for entry in hit.entries[:per_file]:
                suffix = ""
                if len(entry.groups_hit) > 1:
                    suffix = f" [命中 {len(entry.groups_hit)} 组]"
                parts.append(
                    f"  L{entry.line}: {_display(entry.text, ENTRY_WIDTH)}{suffix}"
                )
                displayed += 1
                group_shown_entries += 1
                shown_entries += 1
            more_entries = len(hit.entries) - displayed
            if more_entries > 0:
                parts.append(f"  …（该文件还有 {more_entries} 条未显示）")
        rest_files = max(0, len(hits) - group_shown_files)
        if rest_files:
            parts.append(f"…还有 {rest_files} 个文件未列出（命中较少或较旧）。加更具体关键词可细化。")

    add_group("", active)
    if opts.include_archived and archived:
        add_group("── 归档记忆（Archived，默认隐藏；本组不计入常规排序）──", archived)

    if not active and not (opts.include_archived and archived):
        msg = (
            f"== dsh-memory 无命中（{' '.join(opts.keywords)}｜scope={opts.scope}｜{mode}）==\n"
            "建议：换更具体关键词；或加 --any 放宽为 OR、--scope all 查参考层、--all 看归档。"
        )
        if archived:
            msg += f"\nℹ {len(archived)} 个归档主题有命中，加 --all 查看"
        return msg

    if archived and not opts.include_archived:
        parts.append(
            f"ℹ {len(archived)} 个归档主题有命中（已了结故障），加 --all 查看"
        )

    # checkpoint 只作路径提示，不注入正文；reference 范围不看 sessions。
    if opts.scope != "reference":
        sess_files: List[str] = []
        sessions = MEM_DIR / "sessions"
        if sessions.is_dir():
            for path in sorted(sessions.glob("*.md")):
                try:
                    data = path.read_text(encoding="utf-8", errors="ignore")
                except OSError:
                    continue
                if any(term in data for term in search_terms):
                    sess_files.append(str(path.relative_to(MEM_DIR)))
                    if len(sess_files) >= 5:
                        break
        if sess_files:
            parts.append("")
            parts.append("== 会话 checkpoint 命中（仅参考，非正文知识）==")
            parts.extend(sess_files)

    parts.append("")
    parts.append(
        f"（知识文件 {len(active)} 个 / 归档 {len(archived)} 个；"
        f"scope={opts.scope}；{mode}；输出上限≈{MAX_BYTES}B）"
    )
    return "\n".join(parts)


def truncate_utf8(text: str, limit: int) -> str:
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return text
    marker = f"\n…（输出超过 {limit}B 预算，已截断）"
    room = max(0, limit - len(marker.encode("utf-8")))
    cut = raw[:room].decode("utf-8", "ignore")
    if "\n" in cut:
        cut = cut.rsplit("\n", 1)[0]
    return cut + marker


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    opts = parse_args(argv)
    if opts is None:
        return 0
    synonyms = load_synonyms()
    groups = term_groups(opts.keywords, synonyms)
    search_terms: List[str] = []
    for group in groups:
        for term in group:
            if term not in search_terms:
                search_terms.append(term)
    hits = scan(opts, groups, search_terms)
    active = [h for h in hits if not h.archived]
    archived = [h for h in hits if h.archived]
    text = render(opts, groups, search_terms, synonyms, active, archived)
    if len(text.encode("utf-8")) > MAX_BYTES:
        text = truncate_utf8(text, MAX_BYTES)
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
