#!/usr/bin/env python3
"""Validate store version, privacy resources and opaque application icons without credentials."""
import json
import plistlib
import re
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

class ReleaseResourceTests(unittest.TestCase):
    def test_shared_version_is_store_safe_and_developer_defaults_are_separate(self):
        values = dict(re.findall(r'^([A-Z_]+)\s*=\s*([^\n]+)$', (ROOT / 'Config/Version.xcconfig').read_text(), re.M))
        self.assertRegex(values['MARKETING_VERSION'], r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')
        self.assertRegex(values['CURRENT_PROJECT_VERSION'], r'^[1-9]\d{0,3}$')
        self.assertEqual(values['PADINK_RELEASE_CHANNEL'], 'development')
        self.assertEqual(values['PADINK_DISTRIBUTION'], 'developer')
        self.assertIn('#include "Version.xcconfig"', (ROOT / 'Config/Identity.xcconfig').read_text())
        generator = (ROOT / 'engineering/scripts/generate-project.py').read_text()
        self.assertNotIn("MARKETING_VERSION='0.3.0'", generator)
        self.assertIn("'dwarf-with-dsym'", generator)

    def test_both_hosts_have_provenance_and_linked_privacy_resources(self):
        project = (ROOT / 'PadInk.xcodeproj/project.pbxproj').read_text()
        for platform in ['Mac', 'iPad']:
            info = plistlib.loads((ROOT / f'Hosts/{platform}/Info.plist').read_bytes())
            for key, value in {'CFBundleVersion':'$(CURRENT_PROJECT_VERSION)',
                'PadInkSourceRevision':'$(PADINK_SOURCE_REVISION)', 'PadInkSourceDigest':'$(PADINK_SOURCE_SHA256)',
                'PadInkBuildVariant':'$(PADINK_BUILD_VARIANT)', 'CFBundleDisplayName':'$(PADINK_DISPLAY_NAME)',
                'PadInkReleaseChannel':'$(PADINK_RELEASE_CHANNEL)', 'PadInkDistribution':'$(PADINK_DISTRIBUTION)'}.items():
                self.assertEqual(info[key], value)
            self.assertEqual(info['NSBonjourServices'], ['$(PADINK_BONJOUR_SERVICE_TYPE)'])
            self.assertNotIn('NSAllowsArbitraryLoads', info)
            self.assertNotIn('ITSAppUsesNonExemptEncryption', info)
            privacy = plistlib.loads((ROOT / f'Hosts/{platform}/PrivacyInfo.xcprivacy').read_bytes())
            reasons = {e['NSPrivacyAccessedAPIType']: set(e['NSPrivacyAccessedAPITypeReasons']) for e in privacy['NSPrivacyAccessedAPITypes']}
            self.assertEqual(reasons['NSPrivacyAccessedAPICategoryUserDefaults'], {'CA92.1'})
            self.assertEqual(reasons['NSPrivacyAccessedAPICategorySystemBootTime'], {'35F9.1','8FFB.1'})
            self.assertFalse(privacy['NSPrivacyTracking'])
            self.assertEqual(privacy['NSPrivacyCollectedDataTypes'], [])
            self.assertIn(f'Hosts/{platform}/PrivacyInfo.xcprivacy', project)
            self.assertIn(f'Hosts/{platform}/Assets.xcassets', project)

    def test_icon_dimensions_match_slots_and_marketing_icon_has_no_alpha(self):
        for platform in ['Mac', 'iPad']:
            folder = ROOT / f'Hosts/{platform}/Assets.xcassets/AppIcon.appiconset'
            entries = json.loads((folder / 'Contents.json').read_text())['images']
            for item in entries:
                png = (folder / item['filename']).read_bytes()
                self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
                expected = round(float(item['size'].split('x')[0]) * int(item['scale'][:-1]))
                self.assertEqual(struct.unpack('>II', png[16:24]), (expected, expected))
                self.assertEqual(png[25], 2, 'RGB without alpha is required')
            if platform == 'iPad':
                self.assertTrue(any(e['idiom']=='ios-marketing' and e['size']=='1024x1024' for e in entries))

if __name__ == '__main__':
    unittest.main()
