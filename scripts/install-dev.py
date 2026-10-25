#!/usr/bin/env python3
"""安装当前构建到固定路径，校验在先，更新失败回滚，旧版保存为 ZIP。"""
import datetime
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
TARGET = Path('/Applications/Kirk Screenshot.app')


def run(args):
    return subprocess.run([str(a) for a in args], check=True)


def validate(app):
    run(['codesign', '--verify', '--deep', '--strict', app])
    run([app / 'Contents/MacOS/KirkScreenshot', '--packaged-resources-test'])


def stop_instances():
    result = subprocess.run(['pgrep', '-x', 'KirkScreenshot'], capture_output=True, text=True)
    pids = []
    for raw in result.stdout.split():
        owner = subprocess.run(['ps', '-p', raw, '-o', 'uid='], capture_output=True, text=True).stdout.strip()
        if owner != str(os.getuid()):
            continue
        pid = int(raw)
        try:
            os.kill(pid, signal.SIGTERM)
            pids.append(pid)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 3
    while pids and time.monotonic() < deadline:
        live = []
        for pid in pids:
            try:
                os.kill(pid, 0)
                live.append(pid)
            except ProcessLookupError:
                pass
        pids = live
        if pids:
            time.sleep(.1)
    for pid in pids:
        print(f'结束无响应的截图进程：{pid}')
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def install(source, target, backups, validate_app=None, stop=None):
    """同一文件系统内交换目录；任何替换异常都恢复原目录。"""
    validate_app = validate_app or validate
    stop = stop or stop_instances
    source, target, backups = Path(source), Path(target), Path(backups)
    if not source.is_dir():
        raise RuntimeError(f'缺少构建产物：{source}')
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    stage_root = Path(tempfile.mkdtemp(prefix='.kirk-update-', dir=target.parent))
    preserve_previous = False
    try:
        staged = stage_root / target.name
        run(['ditto', source, staged])
        validate_app(staged)  # 失败时不停止、不改动正在使用的应用。
        if target.exists():
            backups.mkdir(parents=True, exist_ok=True)
            stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
            backup = backups / f'Kirk-Screenshot-{stamp}.zip'
            run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', target, backup])
            with zipfile.ZipFile(backup) as archive:
                if archive.testzip() is not None or f'{target.name}/Contents/MacOS/KirkScreenshot' not in archive.namelist():
                    raise RuntimeError('旧版备份校验失败，未替换应用。')
        stop()
        rollback = stage_root / 'previous.app'
        had_previous = target.exists()
        if had_previous:
            os.replace(target, rollback)
        try:
            os.replace(staged, target)
        except BaseException:
            if had_previous:
                try:
                    os.replace(rollback, target)
                except OSError as restore_error:
                    preserve_previous = True
                    raise RuntimeError(f'自动恢复失败，旧应用完整保留在：{rollback}；备份 ZIP：{backup}') from restore_error
            raise
    finally:
        if not preserve_previous:
            shutil.rmtree(stage_root)
    return backup


def main():
    # 用户级临时目录中的跨仓库互斥，避免两个 worktree 同时替换固定应用。
    lock = Path(tempfile.gettempdir()) / 'kirk-screenshot-dev-install.lock'
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        install_and_launch()


def install_and_launch():
    backup = install(ROOT / 'dist/Kirk Screenshot.app', TARGET, ROOT / '.build/dev-backups')
    register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    run([register, '-f', TARGET])
    run(['open', TARGET])
    print(f'已更新并启动：{TARGET}')
    if backup:
        print(f'旧版备份：{backup}')
    print('设置窗口会显示当前分支、提交和安装路径。不会切换分支、推送或发布。')
    print('若 macOS 因签名变化要求重新录屏授权，请在该应用设置中处理；此命令不会重置授权。')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'本地更新失败：{error}\n未自动提权；请确认你对 /Applications 中的此应用有写入权限。')
