#!/usr/bin/env python3
"""使用合成值和临时文件检查公开内容防线，不操作仓库暂存区。"""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('public_content', Path(__file__).with_name('check-public-content.py'))
public = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public)


class PublicContentTests(unittest.TestCase):
    def test_personal_paths(self):
        unix = '/' + 'Users' + '/example/private-project'
        windows = 'C:' + '\\' + 'Users' + '\\example\\private-project'
        self.assertTrue(public.inspect_bytes('sample', unix.encode()))
        self.assertTrue(public.inspect_bytes('sample', windows.encode()))

    def test_token_is_detected_without_echo(self):
        token = 'ghp_' + 'a' * 36
        errors = public.inspect_bytes('sample', token.encode())
        self.assertTrue(errors)
        self.assertNotIn(token, str(errors))

    def test_safe_functional_paths(self):
        self.assertEqual(public.inspect_bytes('sample', b'/Applications/Screenshot.app\n$HOME/Library/Caches'), [])

    def test_private_file_names_and_templates(self):
        for name in ['.local/notes.md', 'docs/VALIDATION.md', '.env', '.env.production', 'identity.p12']:
            self.assertTrue(public.private_name(name), name)
        for name in ['.env.example', '.env.production.example', 'Resources/Info.plist']:
            self.assertFalse(public.private_name(name), name)

    def test_app_and_archive_license(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); app = root / 'Screenshot.app'
            resources = app / 'Contents/Resources'; resources.mkdir(parents=True)
            expected = b'MIT License\nSynthetic fixture\n'
            self.assertTrue(public.check_app(app, expected))
            (resources / 'LICENSE.txt').write_bytes(expected)
            self.assertEqual(public.check_app(app, expected), [])
            archive = root / 'app.zip'
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr('Screenshot.app/Contents/Resources/LICENSE.txt', expected)
            self.assertEqual(public.check_zip(archive, expected), [])
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr('Screenshot.app/Contents/Resources/LICENSE.txt', b'wrong license')
            self.assertTrue(public.check_zip(archive, expected))


if __name__ == '__main__':
    unittest.main()
