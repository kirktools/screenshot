#!/usr/bin/env python3
"""读取本机截图耗时日志；不上传，也不读取截图文件。"""
import argparse
import json
from pathlib import Path


def summarize(record):
    events = record.get('events', [])
    lines = [f"{record.get('timestamp', '?')}  {record.get('source', '?')}  "
             f"{record.get('outcome', '?')}  总计 {record.get('total_ms', 0):.1f} ms"]
    previous = 0.0
    for event in events:
        elapsed = event.get('elapsed_ms', 0)
        detail = f"（事件排队 {event['value']:.1f} ms）" if event['stage'] == 'hotkey.callback' and 'value' in event else ''
        lines.append(f"  +{elapsed - previous:7.1f} ms  {event['stage']}{detail}")
        previous = elapsed
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', nargs='?', type=Path,
                        default=Path.home() / 'Library/Logs/Screenshot Dev/capture-timing.jsonl')
    parser.add_argument('--last', type=int, default=10, help='最近几次，默认 10')
    parser.add_argument('--slow-ms', type=float, default=0, help='只看总耗时达到此值的记录')
    args = parser.parse_args()
    if not args.path.exists():
        print('还没有耗时记录。请用开发版截图后再运行。')
        return
    records = []
    for line in args.path.read_text().splitlines():
        try:
            record = json.loads(line)
            if record.get('total_ms', 0) >= args.slow_ms:
                records.append(record)
        except (ValueError, TypeError):
            continue  # 读写并行时忽略未写完的一行。
    for record in records[-max(1, args.last):]:
        print(summarize(record))


if __name__ == '__main__':
    main()
