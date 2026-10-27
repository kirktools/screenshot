#!/usr/bin/env python3
"""安装当前构建到固定路径，校验在先，更新失败回滚，旧版保存为 ZIP。"""
import datetime
import fcntl
import os
import plistlib
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
TARGET = Path('/Applications/Screenshot.app')
LEGACY_NAME = 'Kirk Screenshot.app'


def run(args):
    return subprocess.run([str(a) for a in args], check=True)


def executable_name(app):
    with (Path(app) / 'Contents/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    name = info.get('CFBundleExecutable')
    if info.get('CFBundleIdentifier') != 'com.kirktools.screenshot' or name not in ['Screenshot', 'KirkScreenshot']:
        raise RuntimeError(f'不是本项目的有效应用：{app}')
    return name


def validate(app):
    run(['codesign', '--verify', '--deep', '--strict', app])
    run([app / 'Contents/MacOS' / executable_name(app), '--packaged-resources-test'])


def is_our_process(executable):
    path = Path(executable)
    for parent in path.parents:
        if parent.suffix == '.app':
            try:
                return path.name == executable_name(parent)
            except (OSError, ValueError, RuntimeError):
                return False
    return path.name in ['Screenshot', 'KirkScreenshot'] and ROOT.resolve() in path.resolve().parents and '.build' in path.parts


def stop_instances():
    candidates = set()
    for name in ['Screenshot', 'KirkScreenshot']:
        result = subprocess.run(['pgrep', '-x', name], capture_output=True, text=True)
        candidates.update(result.stdout.split())
    pids = []
    for raw in sorted(candidates):
        owner = subprocess.run(['ps', '-p', raw, '-o', 'uid='], capture_output=True, text=True).stdout.strip()
        if owner != str(os.getuid()):
            continue
        executable = subprocess.run(['ps', '-p', raw, '-o', 'comm='], capture_output=True, text=True).stdout.strip()
        if not is_our_process(executable):
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


def install(source, target, backups, validate_app=None, stop=None, previous_target=None):
    """同一文件系统内交换目录；任何替换异常都恢复原目录。"""
    validate_app = validate_app or validate
    stop = stop or stop_instances
    source, target, backups = Path(source), Path(target), Path(backups)
    previous = Path(previous_target) if previous_target else target
    if previous != target and target.exists():
        raise RuntimeError("新旧路径同时存在，请先核对并保留一份应用；未改动任何安装。")
    if not source.is_dir():
        raise RuntimeError(f'缺少构建产物：{source}')
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = None
    stage_root = Path(tempfile.mkdtemp(prefix='.screenshot-update-', dir=target.parent))
    preserve_previous = False
    try:
        staged = stage_root / target.name
        run(['ditto', source, staged])
        validate_app(staged)  # 失败时不停止、不改动正在使用的应用。
        if previous.exists():
            backups.mkdir(parents=True, exist_ok=True)
            stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
            backup = backups / f'Screenshot-{stamp}.zip'
            run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', previous, backup])
            with zipfile.ZipFile(backup) as archive:
                if archive.testzip() is not None or f'{previous.name}/Contents/MacOS/{executable_name(previous)}' not in archive.namelist():
                    raise RuntimeError('旧版备份校验失败，未替换应用。')
        stop()
        rollback = stage_root / 'previous.app'
        had_previous = previous.exists()
        if had_previous:
            os.replace(previous, rollback)
        try:
            os.replace(staged, target)
        except BaseException:
            if had_previous:
                try:
                    os.replace(rollback, previous)
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
    # 与旧版安装器共用锁名，避免升级时两个版本并发替换应用。
    lock = Path(tempfile.gettempdir()) / 'kirk-screenshot-dev-install.lock'
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        install_and_launch()


def owned_install(app):
    if app.is_symlink():
        raise RuntimeError(f'拒绝替换链接：{app}')
    with (app / 'Contents/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    if info.get('CFBundleIdentifier') != 'com.kirktools.screenshot':
        raise RuntimeError(f'此路径属于其他应用，不会覆盖：{app}')


def install_and_launch():
    legacy = TARGET.with_name(LEGACY_NAME)
    for app in [TARGET, legacy]:
        if app.exists() or app.is_symlink():
            owned_install(app)
    if TARGET.exists() and legacy.exists():
        raise RuntimeError('检测到新旧两份应用，请先核对并保留一份；没有停止或替换应用。')
    backup = install(ROOT / 'dist/Screenshot.app', TARGET, ROOT / '.build/dev-backups', previous_target=legacy if legacy.exists() else None)
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
