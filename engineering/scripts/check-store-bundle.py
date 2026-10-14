#!/usr/bin/env python3
"""Credential-free checks of an actual iPad Release bundle; not Apple validation."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path


def check(app):
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('UIDeviceFamily') != [2]:
        raise ValueError('Store client must be iPad-only')
    if info.get('ITSAppUsesNonExemptEncryption') is not False:
        raise ValueError('Missing reviewed OS-only encryption declaration')
    if info.get('UIBackgroundModes') or info.get('NSAppTransportSecurity', {}).get('NSAllowsArbitraryLoads'):
        raise ValueError('Unexpected background capability or unrestricted ATS')
    if info.get('PadInkBuildVariant') != 'release':
        raise ValueError('Store candidate must use release transport/trust namespace')
    manifest = plistlib.loads((app / 'PrivacyInfo.xcprivacy').read_bytes())
    if manifest.get('NSPrivacyTracking') is not False or manifest.get('NSPrivacyCollectedDataTypes') != []:
        raise ValueError('Privacy declaration changed; review App Privacy before export')
    binary = app / info['CFBundleExecutable']
    symbols = subprocess.check_output(['xcrun', 'nm', '-u', str(binary)], text=True)
    frameworks = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True)
    forbidden = ['/var/run/usbmuxd', 'DeveloperDiskImage', 'com.apple.debugserver', '-PadInkUIFixture', 'PADINK_VIDEO_REFERENCE']
    data = binary.read_bytes()
    if any(token.encode() in data for token in forbidden):
        raise ValueError('Mac USB/debug tooling or Debug fixture leaked into iPad Release')
    if any(token in frameworks for token in ['/AppKit.framework/', '/ScreenCaptureKit.framework/', '/IOKit.framework/']):
        raise ValueError('Mac-only framework linked into iPad')
    if any(token in symbols for token in ['_IOHIDEvent', '_CGS', '_SLS']):
        raise ValueError('Unexpected private desktop API in iPad')
    sdk = info.get('DTSDKName', '')
    if not sdk.startswith('iphoneos') or int(sdk[len('iphoneos'):].split('.')[0]) < 26:
        raise ValueError('Current App Store upload requires iPadOS SDK 26+')
    return {'bundleID': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
            'build': info['CFBundleVersion'], 'sdk': sdk, 'sourceSHA256': info['PadInkSourceDigest'],
            'checks': 'iPad-only, privacy/encryption, no Mac USB/private desktop API or Debug fixtures',
            'appleValidation': 'not performed', 'signedUSBDeviceAcceptance': 'pending TestFlight hardware test'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    print(json.dumps(check(args.app), indent=2, ensure_ascii=False))
