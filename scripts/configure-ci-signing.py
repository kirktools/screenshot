#!/usr/bin/env python3
"""将本项目专用签名身份保存到本仓库 Actions Secrets；不输出私钥或密码。"""
import base64
import argparse
import importlib.util
import os
import fcntl
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('sign_app', Path(__file__).with_name('sign-app.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def configure(upload=False):
    os.umask(0o077)
    # 开发密钥不上传；发布者身份单独生成和备份。
    state = signing.state_directory() / 'release'
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    if state.is_symlink():
        raise RuntimeError('发布签名目录不能为符号链接。')
    with (state / 'signing.lock').open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        identity, keychain, password = signing.local_identity(state, 'Screenshot Release Signing')
        signing.run(['/usr/bin/security', 'lock-keychain', keychain])
        if not upload:
            print('固定发布身份已在本机准备好；开发密钥独立，未上传、未发布。')
            return
        encoded = base64.b64encode(keychain.read_bytes())
    # 钥匙串本身已加密，避免导出私钥时弹出额外的系统确认窗口。
    for name, value in [('MACOS_SIGNING_KEYCHAIN_BASE64', encoded), ('MACOS_SIGNING_PASSWORD', password.encode())]:
        result = subprocess.run(['gh', 'secret', 'set', name, '--repo', 'kirktools/screenshot'], input=value, capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError('Actions Secret 写入失败；可安全重试，不会生成新证书，也不会发布。')
    print('已为 kirktools/screenshot 配置固定签名 Secrets；没有触发发布。')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upload', action='store_true', help='显式将发布身份写入本仓库 Actions Secrets；默认只在本机准备')
    args = parser.parse_args()
    try:
        configure(upload=args.upload)
    except subprocess.TimeoutExpired:
        raise SystemExit('GitHub Secret 写入超时；未输出任何敏感参数。')
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        raise SystemExit(str(error))
