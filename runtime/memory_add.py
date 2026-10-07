#!/usr/bin/env python3
# dsh 记忆落盘工具（推荐写入口，协议 v1.3 / 插件 v1.6.1）
#
# 把一条知识按索引式规范写入记忆库：
#   1. 详情条目追加到 MEMORY-<topic>.md（不存在则新建，带头部）
#   2. MEMORY.md 的 See 索引行自动维护（计数按真实条目数重算，顺带校正历史漂移）
#   3. 标题查重：同一主题内标题重复则拒绝（防重复落盘）
#   4. v1.3：域主题 topic「域/主题」→ topics/<域>/MEMORY-<主题>.md，
#      See 行自动插进 MEMORY.md 对应 `### <域>` 小节（域约定 dsh/idc-ops/projects/knowledge）
#
# 用法: memory_add.py <topic> <title> <body> [YYYY-MM-DD]
#   记忆库定位：脚本自身父目录的上级（scripts/ 与记忆库整体搬迁不受影响）
#   与手写等效：条目格式 `- **<title>（<date>）**：<body>`（body 内换行压缩为空格）
import os
import re
import sys
import datetime
from pathlib import Path

MEM_DIR = Path(__file__).resolve().parent.parent
INDEX_FILE = MEM_DIR / 'MEMORY.md'
DATE_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')


def clean_segment(s: str) -> str:
    """清洗 topic 的单个片段（域名或主题名）：留中文/字母数字/._-，≤40 字符。"""
    t = s.strip().strip('/\\').replace('\\', '-')
    t = re.sub(r'[^\w\u4e00-\u9fff.\-]+', '-', t)
    t = re.sub(r'-{2,}', '-', t).strip('-.')
    if not t or len(t) > 40:
        raise SystemExit('❌ topic 片段无效（非空、≤40 字符，仅中文/字母/数字/._-）')
    return t


def split_topic(topic: str):
    """topic 支持「域/主题」（v1.6）：无 / → (None, name)；单层 / → (domain, name)。"""
    parts = [p for p in topic.split('/') if p]
    if len(parts) == 0:
        raise SystemExit('❌ topic 无效（非空）')
    if len(parts) == 1:
        return None, clean_segment(parts[0])
    if len(parts) == 2:
        return clean_segment(parts[0]), clean_segment(parts[1])
    raise SystemExit('❌ topic 最多一层「域/主题」（如 dsh/dsh-memory-plugin）')


def topic_rel_path(topic: str) -> str:
    """主题文件相对记忆库根路径（v1.6：域主题在 topics/<域>/ 下，无域在根）。"""
    domain, name = split_topic(topic)
    if domain:
        return f'topics/{domain}/MEMORY-{name}.md'
    return f'MEMORY-{name}.md'


def count_entries(topic_file: Path) -> int:
    if not topic_file.exists():
        return 0
    n = 0
    for line in topic_file.read_text(encoding='utf-8').splitlines():
        if line.startswith('- **'):
            n += 1
    return n


DOMAIN_HEAD_RE = re.compile(r'^###\s+(\S+)')


def _domain_block(lines, domain: str):
    """定位 `### <域>` 小节的 (标题行号, 小节结束行号)；找不到返回 None。"""
    for i, ln in enumerate(lines):
        m = DOMAIN_HEAD_RE.match(ln)
        if m and m.group(1) == domain:
            end = len(lines)
            for j in range(i + 1, len(lines)):
                if lines[j].startswith('### ') or lines[j].startswith('## '):
                    end = j
                    break
            return i, end
    return None


def _insert_domain_line(lines, domain: str, new_line: str) -> None:
    """把 See 行插到 `### <域>` 小节末尾；该域小节不存在则在尾部结构前新建一个。"""
    blk = _domain_block(lines, domain)
    if blk:
        head, end = blk
        insert_at = head + 1
        for i in range(head + 1, end):
            if lines[i].startswith('- See '):
                insert_at = i + 1
        lines.insert(insert_at, new_line)
        return
    # 新域：在 ### Discovered / ### Dead ends 之前建小节，保持尾部结构不变
    at = len(lines)
    for i, ln in enumerate(lines):
        if ln.startswith('### Discovered') or ln.startswith('### Dead ends'):
            at = i
            break
    block = []
    if at > 0 and lines[at - 1].strip() != '':
        block.append('\n')
    block += [f'### {domain}\n', new_line]
    if at < len(lines) and lines[at].strip() != '':
        block.append('\n')
    lines[at:at] = block


def upsert_index(rel_path: str, title: str, count: int) -> str:
    """更新 MEMORY.md 的 See 索引行（rel_path 为相对记忆库根的路径）；返回更新说明。"""
    text = INDEX_FILE.read_text(encoding='utf-8')
    see_re = re.compile(rf'(?m)^- See {re.escape(rel_path)} \(\d+ entr(?:y|ies)\)')

    if see_re.search(text):
        # 计数按真实条目数重算（校正历史漂移），摘要保留人工维护的原文
        new_text = see_re.sub(
            lambda m: re.sub(r'\(\d+ entr(?:y|ies)\)', f'({count} entries)', m.group(0)),
            text)
        INDEX_FILE.write_text(new_text, encoding='utf-8')
        return f'索引计数已更新为 {count} entries（摘要沿用原文）'

    summary = title if len(title) <= 60 else title[:60] + '…'
    new_line = f'- See {rel_path} ({count} entries) — {summary}\n'
    lines = text.splitlines(keepends=True)

    # 域主题（topics/<域>/…）→ 插进对应域小节（v1.3 域感知插入）
    if rel_path.startswith('topics/'):
        domain = rel_path.split('/')[1]
        _insert_domain_line(lines, domain, new_line)
        INDEX_FILE.write_text(''.join(lines), encoding='utf-8')
        return f'索引已新增（域 {domain}）：See {rel_path} ({count} entries) — {summary}'

    # 无域主题（历史平铺写法）→ 在 "## Discovered durable knowledge" 小节内追加一行
    sec_start = None
    sec_end = len(lines)
    for i, ln in enumerate(lines):
        if ln.startswith('## '):
            if sec_start is not None and sec_end == len(lines):
                sec_end = i
            if ln.startswith('## Discovered durable knowledge'):
                sec_start = i
                sec_end = len(lines)
        if sec_start is not None and ln.startswith('### ') and i > sec_start:
            sec_end = i
            break
    if sec_start is None:
        raise SystemExit('❌ MEMORY.md 缺少 "## Discovered durable knowledge" 小节，请人工检查')
    # 小节内最后一个 See 行之后插入；无 See 行则插在小节标题下一行
    insert_at = sec_start + 1
    for i in range(sec_start + 1, sec_end):
        if lines[i].startswith('- See '):
            insert_at = i + 1
    lines.insert(insert_at, new_line)
    INDEX_FILE.write_text(''.join(lines), encoding='utf-8')
    return f'索引已新增：See {rel_path} ({count} entries) — {summary}'


def resync_all() -> int:
    """批量校正：按真实条目数重算 MEMORY.md 全部 See 行计数（含 topics/ 子目录）。"""
    text = INDEX_FILE.read_text(encoding='utf-8')
    changed = 0
    for tf in sorted(MEM_DIR.glob('**/MEMORY-*.md')):
        rel = str(tf.relative_to(MEM_DIR))
        n = count_entries(tf)
        see_re = re.compile(rf'(?m)^- See {re.escape(rel)} \(\d+ entr(?:y|ies)\)')
        new_text, subs = see_re.subn(
            lambda m: re.sub(r'\(\d+ entr(?:y|ies)\)', f'({n} entries)', m.group(0)), text)
        if subs:
            text = new_text
            changed += 1
    INDEX_FILE.write_text(text, encoding='utf-8')
    return changed


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] == '--resync':
        if not INDEX_FILE.exists():
            print(f'❌ 记忆库索引缺失：{INDEX_FILE}', file=sys.stderr)
            sys.exit(1)
        n = resync_all()
        print(f'✅ 索引计数已批量校正（更新 {n} 个 See 行）')
        return
    if len(sys.argv) < 4:
        print('用法: memory_add.py <topic> <title> <body> [YYYY-MM-DD]', file=sys.stderr)
        print('      memory_add.py --resync   # 批量校正 MEMORY.md 全部 See 计数', file=sys.stderr)
        sys.exit(1)
    topic_arg = sys.argv[1]
    split_topic(topic_arg)   # 校验格式（无域或单层域/主题）
    rel_path = topic_rel_path(topic_arg)
    title = re.sub(r'\s+', ' ', sys.argv[2]).strip()  # M4: title 清洗（防换行破坏条目/索引格式）
    body = re.sub(r'\s+', ' ', sys.argv[3]).strip()  # 换行/多余空白压缩为单空格
    if not title or not body:
        print('❌ title 与 body 不能为空', file=sys.stderr)
        sys.exit(1)
    if len(sys.argv) >= 5 and sys.argv[4]:
        if not DATE_RE.match(sys.argv[4]):
            print('❌ 日期须为 YYYY-MM-DD', file=sys.stderr)
            sys.exit(1)
        try:
            datetime.datetime.strptime(sys.argv[4], '%Y-%m-%d')  # 严格校验（拒绝 13 月 99 日）
        except ValueError:
            print('❌ 日期须为真实存在的 YYYY-MM-DD', file=sys.stderr)
            sys.exit(1)
        date = sys.argv[4]
    else:
        date = datetime.date.today().isoformat()

    # M4 防呆：title 尾部已带（YYYY-MM-DD）则不重复附加日期
    title_has_date = bool(re.search(r'（\d{4}-\d{2}-\d{2}）$', title))

    if not INDEX_FILE.exists():
        print(f'❌ 记忆库索引缺失：{INDEX_FILE}（不是有效记忆库）', file=sys.stderr)
        sys.exit(1)

    lock_path = MEM_DIR / '.git' / 'memory-add.lock'
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with open(lock_path, 'a') as lf:   # 'a' 不截断：保证所有进程 flock 同一 inode（'w' 会截断导致互斥失效）
            import fcntl
            fcntl.flock(lf, fcntl.LOCK_EX)  # L8: 并发写互斥（多会话同主题落盘不丢条目）
            do_add(topic_arg, rel_path, title, body, date, title_has_date)
    except SystemExit:
        raise
    except Exception as e:
        print(f'❌ memory_add 失败：{e}', file=sys.stderr)
        sys.exit(1)


def do_add(topic: str, rel_path: str, title: str, body: str, date: str, title_has_date: bool) -> None:
    topic_file = MEM_DIR / rel_path
    name = topic.split('/')[-1]
    if not topic_file.exists():
        topic_file.parent.mkdir(parents=True, exist_ok=True)
        topic_file.write_text(
            f'# MEMORY-{name}.md\n'
            f'_本主题由 memory_add 创建于 {date}（索引式落盘，协议 v1.3）。_\n',
            encoding='utf-8')

    # 标题查重（同主题内；逐行精确匹配条目首部，防「条1」误杀「条10」这类前缀）
    existing = topic_file.read_text(encoding='utf-8')
    dup_re = re.compile(rf'^- \*\*{re.escape(title)}(?:（[^）]*）)?\*\*：')
    if any(dup_re.match(line) for line in existing.splitlines()):
        print(f'⛔ 已存在同标题条目（{rel_path}），未落盘。'
              f'如需记录请换标题，或确为重复可不再写入。')
        sys.exit(2)

    entry = f'- **{title}**：{body}\n' if title_has_date else f'- **{title}（{date}）**：{body}\n'
    if not existing.endswith('\n'):
        existing += '\n'
    topic_file.write_text(existing + entry, encoding='utf-8')

    count = count_entries(topic_file)
    note = upsert_index(rel_path, title, count)
    print(f'✅ 已落盘 {rel_path}（第 {count} 条）\n{note}')
    if '/' not in topic:
        print('💡 未指定域，已落记忆库根目录。建议改用「域/主题」：'
              'dsh（dsh 自身机制）/ idc-ops（机房网络运维）/ projects（外部项目）/ knowledge（通用技术知识）')


if __name__ == '__main__':
    main()
