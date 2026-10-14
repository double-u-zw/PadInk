#!/usr/bin/env python3
"""Material version/channel/history regressions; no account, device or publication."""
import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('store_materials', ROOT / 'engineering/scripts/store-materials.py')
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)


class MaterialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.materials = self.root / 'engineering/app-store'
        shutil.copytree(ROOT / 'engineering/app-store', self.materials)
        shutil.copytree(ROOT / 'Hosts/iPad/Assets.xcassets', self.root / 'Hosts/iPad/Assets.xcassets')
        (self.root / 'Config').mkdir()
        shutil.copy2(ROOT / 'Config/Version.xcconfig', self.root / 'Config/Version.xcconfig')
        subprocess.run(['git', 'init', '-q', self.root], check=True)

    def tearDown(self):
        self.temp.cleanup()

    def edit(self, **changes):
        path = self.materials / 'metadata.json'
        data = json.loads(path.read_text()); data.update(changes)
        path.write_text(json.dumps(data))

    def test_matching_current_candidate_passes_without_claiming_submission_ready(self):
        _, _, result = store.validate(self.root)
        self.assertEqual(result['materialRole'], 'current-candidate')
        self.assertFalse(result['submissionReady'])
        self.assertEqual(result['target']['macDistribution'], 'developer-id-notarized')

    def test_current_version_and_build_mismatch_fail(self):
        for changes in [{'build': '9999'}, {'version': '9.9.9'}]:
            with self.subTest(changes=changes):
                old = (self.materials / 'metadata.json').read_bytes()
                self.edit(**changes)
                with self.assertRaisesRegex(ValueError, 'differs'): store.validate(self.root)
                (self.materials / 'metadata.json').write_bytes(old)

    def test_prepared_proposals_do_not_satisfy_owner_declarations(self):
        self.edit(submissionProposals={'copyright': '2026 Draft', 'priceAndTerritories': 'free',
                                      'appPrivacyFinalAnswers': 'not collected',
                                      'exportComplianceFinalAnswers': 'exempt'},
                  copyright=None, priceAndTerritories=None, appPrivacyFinalAnswers=None,
                  exportComplianceFinalAnswers=None)
        result = store.validate(self.root)[2]
        self.assertFalse(result['submissionReady'])
        self.assertTrue({'copyright', 'priceAndTerritories', 'appPrivacyFinalAnswers',
                         'exportComplianceFinalAnswers'} <= set(result['pending']))

    def test_optional_review_video_is_distinct_from_required_materials(self):
        self.edit(reviewVideoRequired=False, reviewVideoURL=None)
        result = store.validate(self.root)[2]
        self.assertNotIn('reviewVideoURL', result['pending'])
        self.assertIn('optional reviewer demonstration video', result['recommended'])
        self.assertIn('macSignedDownloadURL', result['pending'])
        self.edit(reviewVideoRequired=True)
        self.assertIn('reviewVideoURL', store.validate(self.root)[2]['pending'])

    def test_download_and_video_urls_must_not_be_local_or_guessed_paths(self):
        for field in ['macSignedDownloadURL', 'reviewVideoURL']:
            with self.subTest(field=field):
                old = (self.materials / 'metadata.json').read_bytes()
                self.edit(**{field: '/Users/maintainer/private-file.zip'})
                with self.assertRaisesRegex(ValueError, 'HTTPS URL'): store.validate(self.root)
                (self.materials / 'metadata.json').write_bytes(old)

    def test_historical_role_cannot_be_current_even_with_matching_version(self):
        self.edit(materialRole='historical-frozen')
        with self.assertRaisesRegex(ValueError, 'current-candidate'): store.validate(self.root)

    def test_old_unmarked_metadata_cannot_be_current(self):
        path = self.materials / 'metadata.json'; data = json.loads(path.read_text())
        del data['materialRole']; path.write_text(json.dumps(data))
        with self.assertRaises(ValueError): store.validate(self.root)

    def test_wrong_channel_fails(self):
        self.edit(target={'variant': 'release', 'channel': 'rc', 'ipadDistribution': 'altstore', 'macDistribution': 'ad-hoc'})
        with self.assertRaisesRegex(ValueError, 'TestFlight'): store.validate(self.root)

    def test_current_materials_must_explicitly_declare_mac_scope(self):
        path = self.materials / 'metadata.json'
        data = json.loads(path.read_text()); del data['macArchitectures']
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'architectures'): store.validate(self.root)

    def test_review_notes_cannot_target_another_build(self):
        path = self.materials / 'review-zh.txt'
        build = json.loads((self.materials / 'metadata.json').read_text())['build']
        path.write_text(path.read_text().replace('build ' + build, 'build 9999'))
        with self.assertRaisesRegex(ValueError, 'review notes target'): store.validate(self.root)

    def test_support_copy_cannot_silently_remain_on_old_build(self):
        path = self.materials / 'public/support.txt'
        build = json.loads((self.materials / 'metadata.json').read_text())['build']
        path.write_text(path.read_text().replace('build ' + build, 'build 9999'))
        with self.assertRaisesRegex(ValueError, 'support.txt target'): store.validate(self.root)

    def test_frozen_candidate_binding_rejects_another_tree_or_version(self):
        meta = json.loads((self.materials / 'metadata.json').read_text())
        source = {'head': 'fixture', 'sourceSHA256': 'a' * 64, 'treeSHA256': 'b' * 64, 'dirty': True}
        manifest = {'release': {'version': meta['version'], 'build': meta['build'], 'mode': 'unsigned-working-tree-preview', 'macArchitectures': ['arm64']}, 'source': source.copy()}
        fake = SimpleNamespace(check=lambda *_: (manifest, False), source_snapshot=lambda *_: (source, {}))
        original = store.load_script
        with patch.object(store, 'load_script', side_effect=lambda name: fake if name == 'rc-release' else original(name)):
            self.assertEqual(store.validate(self.root, release='fixture')[2]['frozenSource'], source)
            manifest['source'] = dict(source, treeSHA256='c' * 64)
            with self.assertRaisesRegex(ValueError, 'source differs'): store.validate(self.root, release='fixture')
            manifest['source'] = source.copy(); manifest['release']['build'] = '9999'
            with self.assertRaisesRegex(ValueError, 'version/build differs'): store.validate(self.root, release='fixture')

    def test_materials_scope_must_match_candidate(self):
        meta = json.loads((self.materials / 'metadata.json').read_text())
        source = {'head': 'fixture', 'sourceSHA256': 'a' * 64, 'treeSHA256': 'b' * 64, 'dirty': False}
        manifest = {'release': {'version': meta['version'], 'build': meta['build'], 'mode': 'release-candidate', 'macArchitectures': ['arm64', 'x86_64']}, 'source': source}
        fake = SimpleNamespace(check=lambda *_: (manifest, False), source_snapshot=lambda *_: (source, {}))
        original = store.load_script
        with patch.object(store, 'load_script', side_effect=lambda name: fake if name == 'rc-release' else original(name)):
            with self.assertRaisesRegex(ValueError, 'scope differs'): store.validate(self.root, release='fixture')

    def test_separate_material_revision_requires_exact_frozen_app_inputs(self):
        meta = json.loads((self.materials / 'metadata.json').read_text())
        identity = store.load_script('build-identity').identity(self.root)
        source = {'head': 'clean-fixture', 'sourceSHA256': identity['sourceSHA256'], 'treeSHA256': 'b' * 64, 'dirty': False}
        materials = dict(source, head='material-fixture', treeSHA256='c' * 64, dirty=True)
        manifest = {'release': {'version': meta['version'], 'build': meta['build'], 'mode': 'release-candidate', 'macArchitectures': ['arm64']}, 'source': source.copy()}
        exact = (self.root / 'frozen').resolve()
        fake = SimpleNamespace(check=lambda *_: (manifest, False), ensure_frozen=lambda *_: None,
                               source_snapshot=lambda root: (source if root == exact else materials, {}))
        original = store.load_script
        with patch.object(store, 'load_script', side_effect=lambda name: fake if name == 'rc-release' else original(name)):
            result = store.validate(self.root, release='fixture', source_root=exact)[2]
            self.assertEqual(result['frozenSource'], source)
            self.assertEqual(result['materialCheckout'], materials)
            manifest['source'] = dict(source, sourceSHA256='d' * 64)
            source['sourceSHA256'] = 'd' * 64
            with self.assertRaisesRegex(ValueError, 'app inputs differ'): store.validate(self.root, release='fixture', source_root=exact)

    def test_frozen_history_verified_without_renumbering_and_tampering_fails(self):
        (self.materials / 'metadata.json').write_text(json.dumps({'version': '0.3.0', 'build': '10'}))
        for name, files in [('SHA256SUMS', ['metadata.json']), ('ZIP-SHA256SUMS', ['old.zip'])]:
            if name.startswith('ZIP'): (self.materials / 'old.zip').write_bytes(b'fixture')
            (self.materials / name).write_text(''.join(f'{store.sha(self.materials / f)}  {f}\n' for f in files))
        before = (self.materials / 'metadata.json').read_bytes()
        result = store.check_history(self.materials)
        self.assertEqual(result['build'], '10'); self.assertFalse(result['submissionReady'])
        self.assertEqual(before, (self.materials / 'metadata.json').read_bytes())
        (self.materials / 'old.zip').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum'): store.check_history(self.materials)

    def test_cli_history_cannot_stage_submit_or_bind_current_release(self):
        for extra in [['--out', 'build/incorrect'], ['--require-ready'], ['--release', 'build/current']]:
            p = subprocess.run(['python3', str(ROOT / 'engineering/scripts/store-materials.py'), '--history', str(self.materials), *extra], capture_output=True, text=True)
            self.assertNotEqual(p.returncode, 0)
            self.assertIn('historical materials cannot', p.stderr)


if __name__ == '__main__':
    unittest.main()
