#!/usr/bin/env python3
"""筛选本机诊断日志。可读取日志目录、单个日志文件或应用导出的 JSON。"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path


def rows(path):
    files = sorted(path.glob('*.log')) if path.is_dir() else [path]
    for file in files:
        if not file.is_file():
            continue
        with file.open(encoding='utf-8') as stream:
            if file.suffix == '.json':
                yield from json.load(stream)
                continue
            for line in stream:
                try:
                    yield json.loads(line)
                except ValueError:
                    continue  # 写入中的末行可能暂时不完整。


def operations(records):
    grouped = {}
    for record in records:
        if not isinstance(record, dict):
            continue
        if record.get('schema') == 2:
            yield record  # 兼容显式传入的旧版 JSONL。
        elif record.get('schema') == 1 and record.get('operationID'):
            key = (record['operationID'], record['module'])
            grouped.setdefault(key, []).append(record)
    for (operation, source), entries in grouped.items():
        entries.sort(key=lambda item: item['timestamp'])
        last = entries[-1]
        completed = last['level'] != 'debug' and last['event'] != 'started' and not last['event'].endswith('.failed')
        yield {
            'timestamp': datetime.fromtimestamp(entries[0]['timestamp'] / 1000, timezone.utc).isoformat(),
            'source': source,
            'operation_id': operation,
            'outcome': last['event'] if completed else 'in_progress',
            'total_ms': last.get('elapsedMS') if completed else None,
            'error_code': next((item['errorCode'] for item in reversed(entries) if item.get('errorCode')), None),
            'events': [{'stage': entry['event'], 'elapsed_ms': entry['elapsedMS']}
                       for entry in (entries[:-1] if completed else entries) if 'elapsedMS' in entry],
        }


def summarize(record):
    elapsed = record.get('total_ms')
    duration = f"  总计 {elapsed:.1f} ms" if elapsed is not None else ""
    lines = [f"{record['timestamp']}  {record['source']}  {record['outcome']}{duration}"]
    if record.get('operation_id'):
        lines[0] += f"  [{record['operation_id']}]"
    if record.get('error_code'):
        lines[0] += f"  错误 {record['error_code']}"
    for event in record.get('events', []):
        detail = f"（附加值 {event['value']:g}）" if 'value' in event else ''
        lines.append(f"   {event['elapsed_ms']:7.1f} ms  {event['stage']}{detail}")
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', nargs='?', type=Path, help='日志目录、文件或导出的 JSON')
    parser.add_argument('--channel', choices=('dev', 'release'), default='dev', help='未指定路径时的应用通道')
    parser.add_argument('--last', type=int, default=10, help='最近几次，默认 10')
    parser.add_argument('--slow-ms', type=float, default=0, help='只看总耗时达到此值的记录')
    parser.add_argument('--source', help='只看指定来源，例如 translation.chatgpt.models')
    parser.add_argument('--failures', action='store_true', help='只看记录了错误分类的操作')
    args = parser.parse_args()
    path = args.path or Path.home() / 'Library/Logs/Screenshot' / args.channel / 'host'
    records = sorted(
        (record for record in operations(rows(path))
         if (not args.failures or record.get('error_code'))
         and (not args.source or record['source'] == args.source)
         and (record.get('total_ms') or 0) >= args.slow_ms),
        key=lambda record: record['timestamp'],
    )
    if not records:
        print('没有符合筛选条件的诊断记录。')
        return
    for record in records[-max(1, args.last):]:
        print(summarize(record))


if __name__ == '__main__':
    main()
