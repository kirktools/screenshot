#!/usr/bin/env python3
"""仅在 Release runner 中导入固定证书；不生成临时发布身份。"""
import base64
import os
from pathlib import Path
import re
import shlex
import subprocess


def run(args):
    try:
        result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired:
        raise RuntimeError('发布签名工具超时；未输出敏感参数。') from None
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} 失败，请核对发布证书配置；敏感参数未输出。')
    return result.stdout


def main():
    encoded = os.environ.get('MACOS_SIGNING_KEYCHAIN_BASE64', '')
    password = os.environ.get('MACOS_SIGNING_PASSWORD', '')
    if not encoded or not password:
        raise RuntimeError('缺少固定发布签名身份：请配置 MACOS_SIGNING_KEYCHAIN_BASE64 和 MACOS_SIGNING_PASSWORD；不会发布 ad-hoc 包。')
    os.umask(0o077)
    folder = Path(os.environ['RUNNER_TEMP']) / 'screenshot-signing'
    folder.mkdir(mode=0o700)
    keychain = folder / 'release.keychain-db'
    keychain.write_bytes(base64.b64decode(encoded, validate=True))
    previous_search_list = None
    try:
        run(['/usr/bin/security', 'unlock-keychain', '-p', password, keychain])
        run(['/usr/bin/security', 'set-keychain-settings', '-lut', '21600', keychain])
        # 临时 runner 没有可交互钥匙串窗口；仅给 Apple 签名工具访问项目专用密钥。
        run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, keychain])
        identities = re.findall(r'\b([0-9A-F]{40})\b', run(['/usr/bin/security', 'find-identity', '-p', 'codesigning', keychain]))
        identities = sorted(set(identities))
        if len(identities) != 1:
            raise RuntimeError('发布钥匙串必须恰好包含一个固定代码签名身份。')
        # 直接写回数据库不会把钥匙串注册到当前用户的搜索列表。
        # find-identity 的显式路径查询能成功，但 macOS runner 的私钥查找仍会失败。
        current = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
        if str(keychain) not in current:
            previous_search_list = current
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', keychain, *current])
        with open(os.environ['GITHUB_ENV'], 'a') as target:
            target.write(f'SIGN_IDENTITY={identities[0]}\nSIGN_KEYCHAIN={keychain}\nSCREENSHOT_SIGNING_MODE=release\n')
        print('固定发布证书已载入临时钥匙串；未修改系统信任。')
    except BaseException:
        if previous_search_list is not None:
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *previous_search_list])
        run(['/usr/bin/security', 'lock-keychain', keychain])
        raise


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError, KeyError):
        raise SystemExit('发布签名准备失败：需配置有效的项目专用钥匙串和密码；不会生成临时身份或发布 ad-hoc 包。')
