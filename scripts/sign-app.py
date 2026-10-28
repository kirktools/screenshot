#!/usr/bin/env python3
"""签名身份与代码内容分离；本地钥匙串只放在 Git 忽略的 .local 中。"""
import argparse
import fcntl
import json
import os
import plistlib
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

NAME = 'Screenshot Local Development'


def run(args):
    try:
        result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f'{Path(args[0]).name} 超时；未输出敏感参数。') from None
    if result.returncode:
        # 安全工具参数可能含钥匙串密码，不回显命令或其错误输出。
        raise RuntimeError(f'{Path(args[0]).name} 执行失败；未更换现有签名身份。')
    return result.stdout


def state_directory():
    common = Path(run(['git', 'rev-parse', '--git-common-dir']).strip()).resolve()
    return common.parent / '.local/signing'


def local_identity(state, name=NAME):
    profile = state / 'identity.json'
    keychain = state / 'development.keychain-db'
    password_file = state / 'keychain-password'
    if profile.exists():
        data = json.loads(profile.read_text())
        if not keychain.is_file() or not password_file.is_file() or not re.fullmatch(r'[0-9A-F]{40}', data['identity']):
            raise RuntimeError('本地签名资料不完整，请从备份恢复 .local/signing；不会自动生成新身份导致授权再次失效。')
        return data['identity'], keychain, password_file.read_text()
    if keychain.exists() or password_file.exists():
        raise RuntimeError('发现未完成的本地签名初始化，请先核对 .local/signing；不会覆盖已有密钥。')
    password = secrets.token_urlsafe(40)
    password_file.write_text(password)
    try:
        with tempfile.TemporaryDirectory(prefix='create-', dir=state) as temporary:
            folder = Path(temporary)
            config = folder / 'openssl.cnf'
            config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=code\n[dn]\nCN=' + name + '\n[code]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
            key, certificate, archive = folder / 'key.pem', folder / 'certificate.pem', folder / 'identity.p12'
            run(['/usr/bin/openssl', 'req', '-new', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650', '-config', config, '-keyout', key, '-out', certificate])
            run(['/usr/bin/openssl', 'pkcs12', '-export', '-inkey', key, '-in', certificate, '-out', archive, '-passout', f'file:{password_file}'])
            run(['/usr/bin/security', 'create-keychain', '-p', password, keychain])
            run(['/usr/bin/security', 'unlock-keychain', '-p', password, keychain])
            run(['/usr/bin/security', 'import', archive, '-k', keychain, '-P', password, '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'])
            fingerprint = run(['/usr/bin/openssl', 'x509', '-in', certificate, '-noout', '-fingerprint', '-sha1']).strip().split('=')[-1].replace(':', '').upper()
            if not re.fullmatch(r'[0-9A-F]{40}', fingerprint):
                raise RuntimeError('无法读取本地签名证书指纹。')
            run(['/usr/bin/openssl', 'x509', '-in', certificate, '-outform', 'DER', '-out', state / 'certificate.cer'])
            profile.write_text(json.dumps({'identity': fingerprint, 'purpose': name}, indent=2) + '\n')
    except BaseException:
        # 已产生的钥匙串不自动替换；保留现场供恢复，避免悄悄改变身份。
        raise
    return fingerprint, keychain, password


def sign(app, mode, identity=None, keychain=None):
    if mode == 'local' and (not identity or identity == '-'):
        raise RuntimeError('本地开发必须使用固定证书，拒绝 ad-hoc 身份。')
    if mode == 'release' and (not identity or identity == '-'):
        raise RuntimeError('正式 Release 必须配置固定证书；拒绝退回会改变授权身份的 ad-hoc 签名。')
    args = ['/usr/bin/codesign', '--force', '--deep', '--sign', identity or '-']
    if keychain:
        args += ['--keychain', keychain]
    if identity and identity != '-':
        # Apple Developer ID 使用可信时间戳；本地/固定自签名不依赖联网时间戳。
        timestamp = os.environ.get('SIGN_TIMESTAMP', 'none')
        args += ['--options', 'runtime', '--timestamp' if timestamp == 'apple' else '--timestamp=none']
    args.append(app)
    run(args)
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    requirement = run(['/usr/bin/codesign', '-d', '-r-', app]).strip()
    if mode in ['local', 'release'] and ('certificate ' not in requirement or 'cdhash ' in requirement):
        raise RuntimeError('签名没有生成稳定的证书身份要求，拒绝继续安装或发布。')
    return requirement


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--mode', choices=['adhoc', 'local', 'release'], default='adhoc')
    args = parser.parse_args()
    os.umask(0o077)
    if args.mode == 'local' and not os.environ.get('SIGN_IDENTITY'):
        state = state_directory()
        state.mkdir(parents=True, mode=0o700, exist_ok=True)
        if state.is_symlink():
            raise RuntimeError('本地签名目录不能为符号链接。')
        with (state / 'signing.lock').open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            identity, keychain, password = local_identity(state)
            run(['/usr/bin/security', 'unlock-keychain', '-p', password, keychain])
            try:
                requirement = sign(args.app, args.mode, identity, keychain)
                bundle_id = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
                if bundle_id not in ['com.kirktools.screenshot', 'com.kirktools.screenshot.dev']:
                    raise RuntimeError('本项目签名器不接受其他应用标识。')
                record = state / f'requirement-{bundle_id}.txt'
                legacy_record = state / 'requirement.txt'
                if bundle_id == 'com.kirktools.screenshot' and not record.exists() and legacy_record.exists():
                    record.write_text(legacy_record.read_text())
                if record.exists() and record.read_text().strip() != requirement:
                    raise RuntimeError('本次构建签名身份发生变化；未安装，请检查签名资料。')
                record.write_text(requirement + '\n')
            finally:
                run(['/usr/bin/security', 'lock-keychain', keychain])
        print('已使用固定本地证书签名：代码变化不会改变证书身份。首次迁移仍需授权；后续由 macOS 判定。')
    else:
        sign(args.app, args.mode, os.environ.get('SIGN_IDENTITY'), os.environ.get('SIGN_KEYCHAIN'))
        print('已完成固定证书签名。' if os.environ.get('SIGN_IDENTITY') else '已完成 ad-hoc 测试签名（不适用于稳定授权的正式更新）。')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, KeyError, ValueError) as error:
        raise SystemExit(str(error))
