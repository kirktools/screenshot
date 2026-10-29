#!/usr/bin/env python3
"""离线回归：仅更新官网兼容旧正式版的带版本名 DMG。"""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
workflow = (ROOT / '.github/workflows/pages.yml').read_text()
script = workflow.split("          python3 - <<'PY'\n", 1)[1].split('\n          PY', 1)[0]
script = '\n'.join(line[10:] for line in script.splitlines())


class WebsiteDownloadTests(unittest.TestCase):
    def run_workflow(self, assets, *, branch='master', draft=False, prerelease=False):
        release = dict(tag_name='v0.1.2', draft=draft, prerelease=prerelease,
                       assets=[dict(name=name) for name in assets])
        calls = []

        def api(args):
            calls.append(args[-1])
            return json.dumps(dict(sha='a' * 40) if args[-1].endswith('commits/master') else release).encode()

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            env = dict(GITHUB_REF=f'refs/heads/{branch}', GITHUB_REPOSITORY='kirktools/screenshot',
                       GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(Path(directory) / 'summary'))
            with patch.dict(os.environ, env), patch('subprocess.check_output', side_effect=api):
                exec(compile(script, 'pages-workflow', 'exec'), {})
            self.assertEqual(calls, ['repos/kirktools/screenshot/releases/latest',
                                     'repos/kirktools/screenshot/commits/master'])
            values = dict(line.split('=', 1) for line in output.read_text().splitlines())
            self.assertEqual(values['ref'], 'a' * 40)
            return values['download']

    def test_legacy_release(self):
        self.assertEqual(self.run_workflow(['Screenshot-0.1.2-macOS.dmg']),
                         'https://github.com/kirktools/screenshot/releases/download/v0.1.2/Screenshot-0.1.2-macOS.dmg')

    def test_fixed_name_preferred(self):
        self.assertEqual(self.run_workflow(['Screenshot-0.1.2-macOS.dmg', 'Screenshot-macOS.dmg']),
                         'https://github.com/kirktools/screenshot/releases/latest/download/Screenshot-macOS.dmg')

    def test_missing_or_wrong_version_dmg_rejected(self):
        for assets in [[], ['Screenshot-0.1.1-macOS.dmg'], ['Screenshot-0.1.2-macOS.zip']]:
            with self.subTest(assets=assets), self.assertRaises(SystemExit):
                self.run_workflow(assets)

    def test_unpublished_release_rejected(self):
        for flags in [dict(draft=True), dict(prerelease=True)]:
            with self.subTest(flags=flags), self.assertRaises(SystemExit):
                self.run_workflow(['Screenshot-macOS.dmg'], **flags)

    def test_other_branch_rejected(self):
        with self.assertRaises(SystemExit):
            self.run_workflow(['Screenshot-macOS.dmg'], branch='topic')


if __name__ == '__main__':
    unittest.main()
