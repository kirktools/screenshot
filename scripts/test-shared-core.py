#!/usr/bin/env python3
"""在 macOS/Linux 编译真实 Swift C ABI，并用 .NET 适配层执行相同测试。"""
import argparse
import os
from pathlib import Path
import platform
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dotnet', default='dotnet')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
if platform.system() == 'Windows':
    raise SystemExit('Windows 请运行 make windows-test 或 scripts/test-windows.ps1')
directory = root/'.build/shared-core'/f'{platform.system()}-{platform.machine()}'
directory.mkdir(parents=True, exist_ok=True)
library = directory/('libStitchCoreABI.dylib' if platform.system() == 'Darwin' else 'libStitchCoreABI.so')
sources = sorted((root/'Sources/StitchCore').glob('*.swift')) + [root/'platforms/interop/StitchCoreABI.swift']
subprocess.run(['swiftc', '-O', '-emit-library', '-module-name', 'StitchCoreABI', '-debug-prefix-map', f'{root}=/_/screenshot', *map(str, sources), '-o', str(library)], check=True, cwd=root)
environment = os.environ.copy()
environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
subprocess.run([str(Path(args.dotnet).resolve()) if '/' in args.dotnet else args.dotnet, 'run', '--project', 'platforms/windows/Screenshot.Tests', '-c', 'Release', f'-p:SharedCoreDirectory={directory}'], check=True, cwd=root, env=environment)
