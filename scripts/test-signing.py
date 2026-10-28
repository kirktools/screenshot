#!/usr/bin/env python3
"""签名策略回归：假命令及临时资料，不修改真实钥匙串。"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('sign_app', Path(__file__).with_name('sign-app.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningTests(unittest.TestCase):
    def test_release_refuses_missing_and_adhoc_identity(self):
        for identity in [None, '-']:
            with mock.patch.object(signing, 'run') as run, self.assertRaisesRegex(RuntimeError, '正式 Release'):
                signing.sign(Path('Screenshot.app'), 'release', identity)
            run.assert_not_called()

    def test_fixed_identity_and_keychain_are_passed_as_arguments(self):
        requirement = 'designated => identifier "com.kirktools.screenshot" and certificate leaf = H"fixture"'
        with mock.patch.object(signing, 'run', side_effect=['', '', requirement]) as run:
            self.assertEqual(signing.sign(Path('Screenshot.app'), 'local', 'Fixed Identity', Path('local.keychain-db')), requirement)
        command = run.call_args_list[0].args[0]
        self.assertIn('--timestamp=none', command)
        self.assertEqual(command[command.index('--sign') + 1], 'Fixed Identity')
        self.assertEqual(command[command.index('--keychain') + 1], Path('local.keychain-db'))

    def test_local_rejects_content_bound_requirement(self):
        with mock.patch.object(signing, 'run', side_effect=['', '', 'designated => cdhash H"fixture"']), self.assertRaisesRegex(RuntimeError, '稳定'):
            signing.sign(Path('Screenshot.app'), 'local', 'Fixed Identity')

    def test_ci_adhoc_test_build_is_still_allowed(self):
        with mock.patch.object(signing, 'run', side_effect=['', '', 'designated => cdhash H"fixture"']):
            signing.sign(Path('Screenshot.app'), 'adhoc')

    def test_profile_reuses_identity_without_regeneration(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / 'identity.json').write_text(json.dumps({'identity': 'A' * 40}))
            (state / 'development.keychain-db').write_text('fixture')
            (state / 'keychain-password').write_text('synthetic-password')
            with mock.patch.object(signing, 'run') as run:
                self.assertEqual(signing.local_identity(state)[0], 'A' * 40)
            run.assert_not_called()

    def test_lost_keychain_never_silently_generates_new_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / 'identity.json').write_text(json.dumps({'identity': 'A' * 40}))
            with mock.patch.object(signing, 'run') as run, self.assertRaisesRegex(RuntimeError, '恢复'):
                signing.local_identity(state)
            run.assert_not_called()

    def test_incomplete_initialization_never_overwrites_existing_keychain(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            (state / 'development.keychain-db').write_text('preserve')
            with mock.patch.object(signing, 'run') as run, self.assertRaisesRegex(RuntimeError, '未完成'):
                signing.local_identity(state)
            self.assertEqual((state / 'development.keychain-db').read_text(), 'preserve')
            run.assert_not_called()

    def test_timeout_does_not_echo_secret_arguments(self):
        with mock.patch.object(signing.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['security', 'synthetic-secret'], 45)):
            with self.assertRaises(RuntimeError) as caught:
                signing.run(['/usr/bin/security', '-p', 'synthetic-secret'])
        self.assertNotIn('synthetic-secret', str(caught.exception))

    def test_release_preparation_without_secrets_never_creates_keychain(self):
        spec = importlib.util.spec_from_file_location('ci_signing', Path(__file__).with_name('prepare-ci-signing.py'))
        ci = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ci)
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(ci, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, '缺少固定发布'):
                ci.main()
        run.assert_not_called()

    def test_release_identity_preparation_never_uploads_by_default(self):
        spec = importlib.util.spec_from_file_location('configure_ci', Path(__file__).with_name('configure-ci-signing.py'))
        ci = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ci)
        with tempfile.TemporaryDirectory() as folder:
            state = Path(folder)
            identity = ('A' * 40, state / 'release/development.keychain-db', 'synthetic-password')
            with mock.patch.object(ci.signing, 'state_directory', return_value=state), \
                 mock.patch.object(ci.signing, 'local_identity', return_value=identity) as create, \
                 mock.patch.object(ci.signing, 'run'), mock.patch.object(ci.subprocess, 'run') as remote:
                ci.configure()
                create.assert_called_once_with(state / 'release', 'Screenshot Release Signing')
                remote.assert_not_called()

    def test_codesign_failure_keeps_safe_system_reason_without_private_details(self):
        result = subprocess.CompletedProcess([], 1, '',
            '/private/fixture/secret-name.app: errSecInternalComponent\n'
            'Warning: unable to build chain to self-signed root for signer "synthetic-secret"')
        with mock.patch.object(signing.subprocess, 'run', return_value=result):
            with self.assertRaises(RuntimeError) as caught:
                signing.run(['/usr/bin/codesign', '--sign', 'synthetic-secret', '/private/fixture/secret-name.app'])
        message = str(caught.exception)
        self.assertIn('errSecInternalComponent', message)
        self.assertIn('证书链', message)
        for private in ['synthetic-secret', '/private/fixture', 'secret-name.app']:
            self.assertNotIn(private, message)

    def test_unknown_codesign_failure_reports_exit_code_only(self):
        result = subprocess.CompletedProcess([], 7, '', 'synthetic-secret /private/fixture')
        with mock.patch.object(signing.subprocess, 'run', return_value=result):
            with self.assertRaises(RuntimeError) as caught:
                signing.run(['/usr/bin/codesign', 'synthetic-secret'])
        self.assertIn('7', str(caught.exception))
        self.assertNotIn('synthetic-secret', str(caught.exception))
        self.assertNotIn('/private/fixture', str(caught.exception))

    def test_security_failure_does_not_echo_secret_arguments(self):
        result = subprocess.CompletedProcess([], 1, '', 'synthetic-secret')
        with mock.patch.object(signing.subprocess, 'run', return_value=result):
            with self.assertRaises(RuntimeError) as caught:
                signing.run(['/usr/bin/security', '-p', 'synthetic-secret'])
        self.assertNotIn('synthetic-secret', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
