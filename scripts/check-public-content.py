#!/usr/bin/env python3
"""检查待公开文件和应用包；错误只输出位置及规则名，不输出敏感值。"""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import zipfile

RULES = {
    '本机用户目录': re.compile(rb'(?<![A-Za-z0-9_])/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'Windows 用户目录': re.compile(rb'(?i)\b[A-Z]:\\Users\\[A-Za-z0-9_. -]+\\'),
    '私钥': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    'GitHub 令牌': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{35,})\b'),
    '云服务访问密钥': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'AI 服务令牌': re.compile(rb'\bsk-(?:proj-|svcacct-|ant-)?[A-Za-z0-9_-]{24,}'),
    'Google API 密钥': re.compile(rb'\bAIza[A-Za-z0-9_-]{35}\b'),
    'Slack 令牌': re.compile(rb'\bxox[baprs]-[A-Za-z0-9-]{20,}'),
}
PRIVATE_SUFFIXES = {'.p12', '.pfx', '.pem', '.key', '.mobileprovision'}


def inspect_bytes(label, data):
    errors = []
    for name, pattern in RULES.items():
        match = pattern.search(data)
        if match:
            line = data[:match.start()].count(b'\n') + 1
            errors.append(f'{label}:{line}: {name}')
    return errors


def private_name(path):
    parts = Path(path).parts
    name = Path(path).name
    env = name == '.env' or name.startswith('.env.')
    template = name.endswith(('.example', '.sample', '.template'))
    return ('.local' in parts or path == 'docs/VALIDATION.md'
            or (env and not template) or Path(path).suffix.lower() in PRIVATE_SUFFIXES
            or name.endswith(('.local.json', '.local.toml')))


def check_sources(root):
    # 包括未暂存的新文件，排除被忽略的本地资料；不会暂存或提交任何文件。
    output = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root)
    errors = []
    for raw in sorted(set(output.split(b'\0'))):
        if not raw:
            continue
        name = raw.decode('utf-8', errors='surrogateescape')
        file = root / name
        if not file.exists() and not file.is_symlink():
            continue  # 工作树中已删除、尚未暂存的文件。
        if private_name(name):
            errors.append(f'{name}: 个人记录、机器配置或私钥文件不能公开')
        elif file.is_symlink():
            errors.append(f'{name}: 不自动检查符号链接目标，请明确审核')
        elif file.is_file():
            errors.extend(inspect_bytes(name, file.read_bytes()))
    return errors


def check_app(app, expected_license):
    errors = []
    license_file = app / 'Contents/Resources/LICENSE.txt'
    if not license_file.is_file() or license_file.read_bytes() != expected_license:
        errors.append('app/Contents/Resources/LICENSE.txt: 缺少或不匹配项目许可证')
    for file in app.rglob('*'):
        label = 'app/' + str(file.relative_to(app))
        if file.is_symlink():
            errors.append(label + ': 不支持未经审核的符号链接')
        elif file.is_file():
            errors.extend(inspect_bytes(label, file.read_bytes()))
    return errors


def check_zip(archive, expected_license):
    errors = []
    with zipfile.ZipFile(archive) as zipped:
        names = zipped.namelist()
        licenses = [n for n in names if n.endswith('.app/Contents/Resources/LICENSE.txt') and not n.startswith('__MACOSX/')]
        if len(licenses) != 1 or zipped.read(licenses[0]) != expected_license:
            errors.append('zip: 缺少唯一且完整的项目许可证')
        total = 0
        for entry in zipped.infolist():
            total += entry.file_size
            if entry.file_size > 128 * 1024 * 1024 or total > 512 * 1024 * 1024:
                errors.append('zip: 文件超过检查大小上限')
                break
            errors.extend(inspect_bytes('zip/' + entry.filename, zipped.read(entry)))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--zip', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    errors = check_sources(root)
    license_data = (root / 'LICENSE').read_bytes()
    if args.app:
        errors += check_app(args.app, license_data)
    if args.zip:
        errors += check_zip(args.zip, license_data)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print('公开内容检查通过：未发现规则覆盖的个人路径/凭据。')
    if args.app or args.zip:
        print('指定产物检查通过：许可证完整，未发现规则覆盖的本机路径。')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
