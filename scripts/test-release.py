#!/usr/bin/env python3
"""使用临时本地 Git 仓库验证发布脚本；不访问 GitHub，不发布任何版本。"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='screenshot-release-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.local, self.remote = root / 'local', root / 'remote.git'
        self.local.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0')
        self.git('init', '-q', '--bare', '-b', 'master', str(self.remote))
        self.git('init', '-q', '-b', 'master')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'release-test@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'tag.gpgsign', 'false')
        (self.local / 'scripts').mkdir()
        for name in ('release.sh', 'bump-version.py'):
            shutil.copy2(SOURCE / name, self.local / 'scripts' / name)
        (self.local / 'VERSION').write_text('0.1.0\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.initial = self.git('rev-parse', 'HEAD')
        self.git('remote', 'add', 'origin', str(self.remote))
        self.git('push', '-q', 'origin', 'master')
        # 只伪装地址检查；所有 fetch/push 仍由真实 Git 对临时 bare 仓库执行。
        binary = shutil.which('git')
        tools = root / 'tools'
        tools.mkdir()
        wrapper = tools / 'git'
        wrapper.write_text(f'''#!/bin/bash
if [[ "$*" == 'remote get-url --push origin' ]]; then
  echo https://github.com/kirktools/screenshot.git
else
  exec '{binary}' "$@"
fi
''')
        wrapper.chmod(0o755)
        self.env['PATH'] = str(tools) + os.pathsep + self.env['PATH']

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.local, env=self.env, stderr=subprocess.PIPE, text=True).strip()

    def run_release(self, *args, success=True):
        result = subprocess.run(['bash', 'scripts/release.sh', *args], cwd=self.local, env=self.env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_dry_run_changes_nothing(self):
        # 连远端读取都不能依赖：临时移走 bare 仓库仍应能预览。
        shutil.rmtree(self.remote)
        for part, version in (('--patch', '0.1.1'), ('--minor', '0.2.0'), ('--major', '1.0.0')):
            self.assertIn(version, self.run_release(part, '--dry-run').stdout)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual(self.git('tag'), '')

    def test_real_git_commit_tag_and_atomic_push(self):
        self.run_release()
        self.assertEqual(self.git('show', 'HEAD:VERSION'), '0.1.1')
        self.assertEqual(self.git('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'), 'VERSION')
        self.assertEqual(self.git('cat-file', '-t', 'v0.1.1'), 'tag')
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.git('--git-dir', str(self.remote), 'rev-parse', 'master'))
        self.assertEqual(self.git('rev-list', '-n', '1', 'v0.1.1'), self.git('--git-dir', str(self.remote), 'rev-list', '-n', '1', 'v0.1.1'))
        self.run_release(success=False)
        self.assertEqual(self.git('show', 'HEAD:VERSION'), '0.1.1')

    def test_dirty_worktree_and_invalid_arguments(self):
        (self.local / 'uncommitted.txt').write_text('keep me')
        self.run_release(success=False)
        self.run_release('--unknown', success=False)
        self.run_release('--minor', '--major', success=False)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)
        self.assertEqual((self.local / 'VERSION').read_text(), '0.1.0\n')

    def test_existing_tag_is_not_overwritten(self):
        self.git('tag', 'v0.1.1')
        self.run_release(success=False)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)

    def test_behind_remote_stops_before_version_change(self):
        self.git('commit', '--allow-empty', '-qm', 'remote advance')
        advanced = self.git('rev-parse', 'HEAD')
        self.git('push', '-q', 'origin', 'master')
        self.git('checkout', '-q', '-B', 'master', self.initial)
        self.run_release(success=False)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.initial)
        self.assertEqual(self.git('--git-dir', str(self.remote), 'rev-parse', 'master'), advanced)

    def test_push_failure_preserves_local_and_remote(self):
        hook = self.remote / 'hooks' / 'pre-receive'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        self.run_release(success=False)
        self.assertEqual(self.git('--git-dir', str(self.remote), 'rev-parse', 'master'), self.initial)
        self.assertEqual(self.git('--git-dir', str(self.remote), 'tag'), '')
        self.assertEqual(self.git('show', 'HEAD:VERSION'), '0.1.1')
        self.assertEqual(self.git('tag'), 'v0.1.1')
        self.run_release(success=False)
        self.assertEqual(self.git('show', 'HEAD:VERSION'), '0.1.1')


if __name__ == '__main__':
    unittest.main(verbosity=2)
