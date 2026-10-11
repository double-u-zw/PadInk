#!/usr/bin/env python3
"""Run the installer in an isolated fake Xcode/device environment; never install on this Mac."""
import os
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STUB = r'''#!/usr/bin/env python3
import datetime, json, os, plistlib, shutil, sys, zipfile
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'xcodebuild':
    with Path('build/mock-xcode-calls.jsonl').open('a') as stream:
        stream.write(json.dumps(args) + '\n')
    if '-version' in args:
        print('Xcode test'); sys.exit(0)
    if '-checkFirstLaunchStatus' in args:
        sys.exit(0)
    scheme = args[args.index('-scheme') + 1]
    settings = dict(a.split('=',1) for a in args if '=' in a)
    if scheme == 'PadInkPad' and settings.get('CODE_SIGNING_ALLOWED') != 'NO' and os.environ.get('PADINK_TEST_APP_ID_LIMIT'):
        print('App ID limit reached', file=sys.stderr); sys.exit(1)
    variant = settings.get('PADINK_BUILD_VARIANT','release')
    app_name = 'PadInk Dev' if variant == 'development' else 'PadInk'
    derived = Path(args[args.index('-derivedDataPath') + 1])
    app = derived / 'Build/Products' / ('Release' if scheme == 'PadInkMac' else 'Release-iphoneos') / (app_name + '.app')
    app.mkdir(parents=True, exist_ok=True)
    (app / 'new-version').write_text(scheme)
    info = {'CFBundleIdentifier': 'dev.padink03.abc1234567.' + ('mac' if scheme == 'PadInkMac' else 'ipad'), 'CFBundleExecutable': app_name, 'CFBundleDisplayName': app_name, 'PadInkBuildVariant': variant, 'TestTeam': os.environ.get('PADINK_TEST_NEW_TEAM', 'ABC1234567'), 'CFBundleShortVersionString': '0.3.0', 'CFBundleVersion': '8', 'PadInkSourceDigest': settings.get('PADINK_SOURCE_SHA256'), 'PadInkReleaseChannel': settings.get('PADINK_RELEASE_CHANNEL'), 'PadInkDistribution': settings.get('PADINK_DISTRIBUTION')}
    if variant == 'development': info['CFBundleIdentifier'] += '.development'
    if scheme == 'PadInkMac':
        info['CFBundleIdentifier'] = os.environ.get('PADINK_TEST_NEW_BUNDLE', info['CFBundleIdentifier'])
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Contents/MacOS' / app_name).write_text('new executable')
    else:
        info['CFBundleIdentifier'] = settings.get('PRODUCT_BUNDLE_IDENTIFIER', info['CFBundleIdentifier'])
        (app / 'Info.plist').write_bytes(plistlib.dumps(info))
        (app / app_name).write_text('iPad executable')
        (app / app_name).chmod(0o755)
        if settings.get('CODE_SIGNING_ALLOWED') != 'NO':
            (app / 'embedded.mobileprovision').write_text('test')
elif name == 'xcrun':
    with Path('build/mock-device-calls.jsonl').open('a') as stream:
        stream.write(json.dumps(args) + '\n')
    if args[:3] == ['devicectl', 'list', 'devices']:
        path = Path(args[args.index('--json-output') + 1])
        path.write_text(json.dumps({'result': {'devices': [{'hardwareProperties': {'reality': 'physical', 'deviceType': 'iPad', 'udid': 'fake-ipad'}, 'connectionProperties': {'transportType': 'wired', 'pairingState': 'paired'}, 'deviceProperties': {'name': 'Test iPad', 'osVersionNumber': 'test', 'developerModeStatus': 'enabled'}}]}}))
elif name == 'ditto':
    if args[:2] == ['-c', '-k']:
        with zipfile.ZipFile(args[3], 'w') as archive:
            for file in Path(args[2]).rglob('*'):
                if file.is_file(): archive.write(file, file.relative_to(args[2]))
    else:
        shutil.copytree(args[0], args[1], symlinks=True)
elif name == 'codesign':
    app = Path(args[-1])
    installed_new = app.parent.resolve() == Path(os.environ['PADINK_INSTALL_DIRECTORY']).resolve() and (app / 'new-version').exists()
    if installed_new and os.environ.get('PADINK_TEST_INSTALLED_DISPLAY_FAIL'):
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        (app / 'Contents/MacOS' / info['CFBundleExecutable']).write_text('corrupt executable signature')
        print('unreadable code signature', file=sys.stderr); sys.exit(1)
    if '--verify' in args and (os.environ.get('PADINK_TEST_CODESIGN_FAIL') or (os.environ.get('PADINK_TEST_INSTALLED_VERIFY_FAIL') and installed_new)):
        print('invalid signature', file=sys.stderr); sys.exit(1)
    if '-d' in args:
        info = plistlib.loads((Path(args[-1]) / 'Contents/Info.plist').read_bytes())
        print('TeamIdentifier=' + info.get('TestTeam', 'ABC1234567'), file=sys.stderr)
elif name == 'security':
    sys.stdout.buffer.write(plistlib.dumps({'ExpirationDate': datetime.datetime(2030, 1, 1)}))
elif name == 'open':
    if args[0] == '-R': sys.exit(0)
    app = Path(args[-1])
    if os.environ.get('PADINK_TEST_OPEN_FAIL') and (app / 'new-version').exists():
        print('launch failed', file=sys.stderr); sys.exit(1)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    Path(os.environ['PADINK_TEST_PROCESS_FILE']).write_text(str(app / 'Contents/MacOS' / info['CFBundleExecutable']))
elif name == 'ps':
    process = Path(os.environ['PADINK_TEST_PROCESS_FILE'])
    if process.exists() and process.read_text(): print('123 ' + process.read_text())
elif name == 'osascript':
    Path(os.environ['PADINK_TEST_PROCESS_FILE']).write_text('')
    with Path(os.environ['PADINK_TEST_QUIT_FILE']).open('a') as f: f.write(args[-1] + '\n')
'''


class UpdateScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / 'PadInk source'
        self.root.mkdir()
        self.install = Path(self.tmp.name) / 'Applications'
        self.install.mkdir()
        self.previous = self.install / 'PadInk 0.3.app'
        self.make_old_app(self.previous, 'dev.padink03.abc1234567.mac', 'PadInk 0.3')
        self.current = self.install / 'PadInk.app'
        (self.root / 'engineering/commands').mkdir(parents=True)
        shutil.copy2(ROOT / 'engineering/commands/更新 PadInk.command', self.root / 'engineering/commands')
        for name in ('configure-local-signing.sh', 'lib/device_check.py', 'lib/local_signing.py', 'lib/mac_install.py', 'build-altstore-ipa.py'):
            target = self.root / 'engineering/scripts' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / 'engineering/scripts' / name, target)
        (self.root / 'engineering/scripts/build-identity.py').write_text("import json, sys\nvalue = {'head': 'a' * 40, 'sourceSHA256': 'b' * 64, 'label': 'test-source+test-digest'}\ndef identity(root): return value\nif __name__ == '__main__': print(json.dumps(value) if '--json' in sys.argv else value['label'])\n")
        (self.root / 'engineering/scripts/generate-project.py').write_text("print('test project')\n")
        (self.root / 'Config').mkdir()
        (self.root / 'Config/Signing.local.xcconfig').write_text('DEVELOPMENT_TEAM = ABC1234567\nPADINK_BUNDLE_PREFIX = dev.padink03.abc1234567\n')
        self.bin = Path(self.tmp.name) / 'bin'
        self.bin.mkdir()
        for name in ('xcodebuild', 'xcrun', 'ditto', 'codesign', 'security', 'open', 'osascript', 'sleep', 'ps'):
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def make_old_app(self, app, bundle, executable='PadInk', team='ABC1234567'):
        import plistlib
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'old-version').write_text('keep this until replacement is verified')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle, 'CFBundleExecutable': executable, 'TestTeam': team}))
        (app / 'Contents/MacOS' / executable).write_text('old executable')

    def environment(self, **extra):
        return dict(dict(os.environ, PADINK_BUILD_VARIANT='release'), PATH=str(self.bin) + os.pathsep + os.environ['PATH'], PADINK_INSTALL_DIRECTORY=str(self.install), PADINK_TEST_PROCESS_FILE=str(self.root / 'build/process.txt'), PADINK_TEST_QUIT_FILE=str(self.root / 'build/quit.txt'), **extra)

    def run_installer(self, confirm=False, **extra):
        return subprocess.run(['/bin/zsh', str(self.root / 'engineering/commands/更新 PadInk.command')], input=('yes\n\n' if confirm else '\n\n'), text=True, capture_output=True, env=self.environment(**extra))

    def helper(self, command, *args):
        receipt = next((self.root / 'build/update').glob('*/mac-install.json'))
        return subprocess.run(['python3', str(self.root / 'engineering/scripts/lib/mac_install.py'), command, '--receipt', str(receipt), *args], text=True, capture_output=True, env=self.environment())

    def test_development_install_preserves_release_and_legacy_apps(self):
        self.make_old_app(self.current, 'dev.padink03.abc1234567.mac')
        result = self.run_installer(confirm=True, PADINK_BUILD_VARIANT='development', PADINK_IPAD_INSTALLER='xcode')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        dev = self.install / 'PadInk Dev.app'
        self.assertTrue((dev / 'new-version').exists())
        self.assertTrue((self.current / 'old-version').exists())
        self.assertTrue((self.previous / 'old-version').exists())
        receipt = json.loads(next((self.root / 'build/update').glob('*/mac-install.json')).read_text())
        self.assertEqual(receipt['appName'], 'PadInk Dev.app')
        self.assertIsNone(receipt['legacy'])

    def test_development_default_prepares_altstore_ipa_without_device_install_or_provisioning(self):
        self.make_old_app(self.current, 'dev.padink03.abc1234567.mac')
        result = self.run_installer(PADINK_BUILD_VARIANT='development', PADINK_TEST_APP_ID_LIMIT='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.install / 'PadInk Dev.app/new-version').exists())
        self.assertTrue((self.current / 'old-version').exists())
        self.assertTrue((self.previous / 'old-version').exists())
        metadata = json.loads(next((self.root / 'build/update').glob('*/altstore/PadInk-Dev-AltStore.json')).read_text())
        self.assertEqual(metadata['bundleIdentifier'], 'dev.padink.altstore.ipad.development')
        self.assertEqual(metadata['releaseChannel'], 'development')
        self.assertFalse(metadata['signed'])
        self.assertFalse((self.root / 'build/mock-device-calls.jsonl').exists())
        calls = [json.loads(line) for line in (self.root / 'build/mock-xcode-calls.jsonl').read_text().splitlines()]
        mac = next(call for call in calls if 'PadInkMac' in call)
        ipad = next(call for call in calls if 'PadInkPad' in call)
        self.assertIn('PADINK_DISTRIBUTION=altstore', mac)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', ipad)
        self.assertNotIn('-allowProvisioningUpdates', ipad)
        self.assertNotIn('两端安装完成', result.stdout)
        self.assertIn('iPad IPA 已生成', result.stdout)
        self.assertIn('Background Refresh', result.stdout)

    def test_invalid_new_signature_preserves_existing_mac_app(self):
        result = self.run_installer(PADINK_TEST_CODESIGN_FAIL='1')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.previous / 'old-version').exists())
        self.assertFalse((self.previous / 'new-version').exists())
        self.assertEqual(len(list((self.root / 'build/update').glob('*.zip'))), 1)
        self.assertIn('invalid signature', result.stdout)

    def test_success_replaces_verified_app_and_explains_next_steps(self):
        result = self.run_installer(confirm=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.current / 'new-version').read_text(), 'PadInkMac')
        self.assertFalse(self.previous.exists())
        self.assertFalse(list(self.install.glob('.PadInk-update.*')))
        self.assertIn('两端安装完成', result.stdout)
        self.assertIn('首次在两端各点“允许配对”', result.stdout)
        self.assertIn('本次 iPad 签名有效至', result.stdout)
        builds = [json.loads(line) for line in (self.root / 'build/mock-xcode-calls.jsonl').read_text().splitlines() if '-scheme' in json.loads(line)]
        self.assertEqual(len(builds), 2)
        for build in builds:
            self.assertIn('PADINK_SOURCE_REVISION=' + 'a' * 40, build)
            self.assertIn('PADINK_SOURCE_SHA256=' + 'b' * 64, build)
            self.assertIn('PADINK_RELEASE_CHANNEL=development', build)
            self.assertIn('PADINK_DISTRIBUTION=developer', build)

    def test_app_id_registration_limit_does_not_tell_user_to_delete_an_app(self):
        result = self.run_installer(PADINK_TEST_APP_ID_LIMIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('删除已装 App 不会立即释放此额度', result.stdout)
        self.assertTrue((self.previous / 'old-version').exists())

    def test_rename_retains_old_app_until_state_confirmation_and_supports_rollback(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.previous / 'old-version').exists())
        self.assertTrue((self.current / 'new-version').exists())
        self.assertNotEqual(self.helper('finalize').returncode, 0)
        self.assertTrue(self.previous.exists())
        self.assertEqual(self.helper('rollback').returncode, 0)
        self.assertFalse(self.current.exists())
        self.assertTrue((self.previous / 'old-version').exists())
        self.assertFalse(list(self.install.glob('.PadInk-update.*')))

    def test_known_older_padink_at_canonical_path_is_backed_up_until_confirmed(self):
        self.make_old_app(self.current, 'app.padink.greenfield.mac', 'PadInkMac')
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.previous / 'old-version').exists())
        stage = next(self.install.glob('.PadInk-update.*'))
        self.assertTrue((stage / 'previous.app/old-version').exists())
        quit_calls = (self.root / 'build/quit.txt').read_text()
        self.assertIn('app.padink.greenfield.mac', quit_calls)
        self.assertIn('dev.padink03.abc1234567.mac', quit_calls)
        self.assertEqual(self.helper('rollback').returncode, 0)
        self.assertTrue((self.current / 'old-version').exists())
        self.assertTrue(self.previous.exists())

    def test_unrelated_app_at_canonical_path_is_never_replaced(self):
        self.make_old_app(self.current, 'com.example.unrelated')
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.current / 'old-version').exists())
        self.assertTrue((self.previous / 'old-version').exists())
        self.assertFalse(list(self.install.glob('.PadInk-update.*')))

    def test_future_update_of_padink_app_can_restore_same_name_backup(self):
        self.make_old_app(self.current, 'dev.padink03.abc1234567.mac')
        shutil.rmtree(self.previous)
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.current / 'new-version').exists())
        self.assertEqual(self.helper('rollback').returncode, 0)
        self.assertTrue((self.current / 'old-version').exists())
        self.assertFalse((self.current / 'new-version').exists())

    def test_different_bundle_or_team_preserves_existing_installations(self):
        for extra in ({'PADINK_TEST_NEW_BUNDLE': 'com.example.changed'}, {'PADINK_TEST_NEW_TEAM': 'DIFFER1234'}):
            result = self.run_installer(**extra)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((self.previous / 'old-version').exists())
            self.assertFalse(self.current.exists())

    def test_launch_failure_restores_previous_app_and_keeps_current_identity(self):
        self.make_old_app(self.current, 'app.padink.greenfield.mac', 'PadInkMac')
        result = self.run_installer(PADINK_TEST_OPEN_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.current / 'old-version').exists())
        self.assertTrue((self.previous / 'old-version').exists())
        self.assertFalse((self.current / 'new-version').exists())
        self.assertFalse(list(self.install.glob('.PadInk-update.*')))

    def test_installed_signature_failure_rolls_back_before_removing_legacy(self):
        result = self.run_installer(PADINK_TEST_INSTALLED_VERIFY_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.previous / 'old-version').exists())
        self.assertFalse(self.current.exists())

    def test_unreadable_installed_signature_restores_both_old_apps_and_retains_failed_app(self):
        self.make_old_app(self.current, 'app.padink.greenfield.mac', 'PadInkMac')
        result = self.run_installer(PADINK_TEST_INSTALLED_DISPLAY_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unreadable code signature', result.stdout)
        self.assertIn('安装已回滚', result.stdout)
        self.assertTrue((self.current / 'old-version').exists())
        self.assertFalse((self.current / 'new-version').exists())
        self.assertTrue((self.previous / 'old-version').exists())
        receipt = json.loads(next((self.root / 'build/update').glob('*/mac-install.json')).read_text())
        self.assertEqual(receipt['status'], 'rolled-back')
        self.assertTrue((Path(receipt['failedAppRetained']) / 'new-version').exists())
        self.assertEqual((Path(receipt['failedAppRetained']) / 'Contents/MacOS/PadInk').read_text(), 'corrupt executable signature')
        self.assertEqual((self.root / 'build/process.txt').read_text(), str(self.previous.resolve() / 'Contents/MacOS/PadInk 0.3'))

    def test_external_replacement_after_install_is_not_removed_by_rollback(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        shutil.rmtree(self.current)
        self.make_old_app(self.current, 'com.example.external')
        result = self.helper('rollback')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.current / 'old-version').exists())
        self.assertTrue(self.previous.exists())


if __name__ == '__main__':
    unittest.main()
