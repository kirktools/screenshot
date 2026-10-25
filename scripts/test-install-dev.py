#!/usr/bin/env python3
"""用临时假应用验证更新与失败回滚，不安装、不退出任何实际应用。"""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

spec = importlib.util.spec_from_file_location('install_dev', Path(__file__).with_name('install-dev.py'))
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='kirk-dev-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'build/Kirk Screenshot.app'
        self.target = self.root / 'Applications/Kirk Screenshot.app'
        self.backups = self.root / 'backups'
        for app, value in [(self.source, 'new'), (self.target, 'old')]:
            binary = app / 'Contents/MacOS/KirkScreenshot'
            binary.parent.mkdir(parents=True)
            binary.write_text(value)
        self.stopped = []

    def binary(self):
        return self.target / 'Contents/MacOS/KirkScreenshot'

    def update(self, validate=lambda _: None, stop=None):
        return dev.install(self.source, self.target, self.backups, validate_app=validate,
                           stop=stop or (lambda: self.stopped.append(True)))

    def test_update_and_recoverable_backup(self):
        archive = self.update()
        self.assertEqual(self.binary().read_text(), 'new')
        self.assertEqual(self.stopped, [True])
        with zipfile.ZipFile(archive) as z:
            self.assertEqual(z.read('Kirk Screenshot.app/Contents/MacOS/KirkScreenshot'), b'old')
        self.assertEqual(list(self.target.parent.glob('.kirk-update-*')), [])

    def test_invalid_build_keeps_old_and_does_not_stop(self):
        def reject(_):
            raise RuntimeError('resource/signature check failed')
        with self.assertRaises(RuntimeError):
            self.update(validate=reject)
        self.assertEqual(self.binary().read_text(), 'old')
        self.assertFalse(self.stopped)

    def test_swap_failure_restores_old(self):
        replace = dev.os.replace
        def fail_new(source, target):
            if Path(source).name == 'Kirk Screenshot.app' and '.kirk-update-' in str(source):
                raise OSError('simulated installation failure')
            return replace(source, target)
        with mock.patch.object(dev.os, 'replace', side_effect=fail_new):
            with self.assertRaises(OSError):
                self.update()
        self.assertEqual(self.binary().read_text(), 'old')
        self.assertEqual(len(list(self.backups.glob('*.zip'))), 1)

    def test_failed_restore_keeps_previous_directory(self):
        replace = dev.os.replace
        def fail_both(source, target):
            if Path(target) == self.target:
                raise OSError('simulated target unavailable')
            return replace(source, target)
        with mock.patch.object(dev.os, 'replace', side_effect=fail_both):
            with self.assertRaisesRegex(RuntimeError, '旧应用完整保留'):
                self.update()
        previous = list(self.target.parent.glob('.kirk-update-*/previous.app/Contents/MacOS/KirkScreenshot'))
        self.assertEqual(len(previous), 1)
        self.assertEqual(previous[0].read_text(), 'old')
        self.assertEqual(len(list(self.backups.glob('*.zip'))), 1)

    def test_failed_shutdown_does_not_replace(self):
        def fail():
            raise RuntimeError('shutdown failed')
        with self.assertRaises(RuntimeError):
            self.update(stop=fail)
        self.assertEqual(self.binary().read_text(), 'old')

    def test_command_main_updates_fixed_target_and_launches_once(self):
        import shutil
        shutil.copytree(self.source, self.root / 'dist/Kirk Screenshot.app')
        commands = []
        original_run = dev.run
        def execute(args):
            values = [str(a) for a in args]
            if values[0] == 'open' or values[0].endswith('/lsregister'):
                commands.append(values)
                return
            return original_run(args)
        with mock.patch.object(dev, 'ROOT', self.root), mock.patch.object(dev, 'TARGET', self.target), \
             mock.patch.object(dev, 'validate', return_value=None), mock.patch.object(dev, 'stop_instances') as stop, \
             mock.patch.object(dev, 'run', side_effect=execute), \
             mock.patch.object(dev.tempfile, 'gettempdir', return_value=str(self.root)):
            dev.main()
        self.assertEqual(self.binary().read_text(), 'new')
        stop.assert_called_once()
        self.assertEqual(commands[-1], ['open', str(self.target)])
        self.assertEqual(len(commands), 2)

    def test_first_install(self):
        import shutil
        shutil.rmtree(self.target)
        self.assertIsNone(self.update())
        self.assertEqual(self.binary().read_text(), 'new')


if __name__ == '__main__':
    unittest.main()
