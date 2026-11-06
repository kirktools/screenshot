#!/usr/bin/env python3
"""确认文档演示只进入显式的本地演示包，防止被误带入日常/正式包。"""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--demo', action='store_true')
args = parser.parse_args()
data = (args.app / 'Contents/MacOS/Screenshot').read_bytes()
markers = [b'--documentation-features-demo', b'writeFeatureDemonstration',
           b'--documentation-scroll-demo', b'--overlay-demo', b'--demo-editor']
if args.demo:
    assert markers[0] in data, '演示包缺少导出入口'
else:
    assert not any(marker in data for marker in markers), '普通包中发现开发演示入口或符号'
    assert not any(p.suffix.lower() in {'.mp4', '.gif'} for p in args.app.rglob('*')), '应用包混入演示媒体'
print('开发演示边界检查通过：' + ('仅本地演示包启用' if args.demo else '普通包不含演示入口或媒体'))
