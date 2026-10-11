#!/usr/bin/env python3
"""Build an unsigned PadInk IPA for official AltStore Classic; never install or sign."""
import argparse
import hashlib
import importlib.util
import json
import plistlib
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = 'dev.padink.altstore.ipad'

def build(output, channel=None, variant='release'):
    if variant not in {'development', 'release'}: raise ValueError('Unknown build variant.')
    channel = channel or ('development' if variant == 'development' else 'rc')
    app_name = 'PadInk Dev' if variant == 'development' else 'PadInk'
    bundle_id = BUNDLE_ID + ('.development' if variant == 'development' else '')
    prefix = 'PadInk-Dev-AltStore' if variant == 'development' else 'PadInk-AltStore'
    if channel not in {'development', 'rc'}:
        raise ValueError('AltStore build channel must be development or rc.')
    output = output.resolve()
    if not output.is_relative_to(ROOT / 'build'):
        raise ValueError('Output must be inside build/.')
    output.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('build_identity', ROOT / 'engineering/scripts/build-identity.py')
    identity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(identity)
    source = identity.identity(ROOT)
    log = output / 'ipad-build.log'
    with log.open('w') as stream:
        subprocess.run([
            'xcodebuild', '-project', str(ROOT / 'PadInk.xcodeproj'), '-scheme', 'PadInkPad',
            '-configuration', 'Release', '-destination', 'generic/platform=iOS',
            '-derivedDataPath', str(output / 'dd'), 'build',
            'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=',
            'PADINK_BUNDLE_PREFIX=dev.padink.altstore', 'PADINK_IPAD_BUNDLE_ID=' + bundle_id,
            'PRODUCT_BUNDLE_IDENTIFIER=' + bundle_id,
            'PADINK_SOURCE_COMMIT=' + source['label'], 'PADINK_SOURCE_REVISION=' + source['head'],
            'PADINK_SOURCE_SHA256=' + source['sourceSHA256'],
            'PADINK_BUILD_VARIANT=' + variant, 'PADINK_RELEASE_CHANNEL=' + channel, 'PADINK_DISTRIBUTION=altstore',
        ], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)
    if identity.identity(ROOT) != source:
        raise ValueError('Source changed during the build; rerun before distributing the IPA.')
    app = output / 'dd/Build/Products/Release-iphoneos' / (app_name + '.app')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != bundle_id or (app / 'embedded.mobileprovision').exists():
        raise ValueError('Unexpected signing identity or provisioning profile in unsigned build.')
    for key, expected in [('PadInkSourceDigest', source['sourceSHA256']), ('PadInkDistribution', 'altstore'),
                          ('PadInkReleaseChannel', channel), ('PadInkBuildVariant', variant), ('CFBundleDisplayName', app_name)]:
        if info.get(key) != expected:
            raise ValueError('Built source/channel metadata does not match.')
    ipa = output / (prefix + '.ipa')
    temporary = output / (prefix + '.ipa.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(app.rglob('*')):
                if path.is_symlink():
                    raise ValueError('Unexpected symlink in iPad app.')
                if not path.is_file():
                    continue
                relative = Path('Payload') / (app_name + '.app') / path.relative_to(app)
                if path.name == 'Info.plist' and path.parent == app:
                    archive.writestr(str(relative), plistlib.dumps(info))
                else:
                    archive.write(path, str(relative))
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError('IPA archive integrity check failed.')
            executable = 'Payload/' + app_name + '.app/' + info['CFBundleExecutable']
            if not archive.getinfo(executable).external_attr >> 16 & 0o111:
                raise ValueError('IPA executable permissions are missing.')
        temporary.replace(ipa)
    finally:
        temporary.unlink(missing_ok=True)
    metadata = {'bundleIdentifier': bundle_id, 'variant': variant, 'displayName': info['CFBundleDisplayName'],
                'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                'sourceRevision': source['head'], 'sourceSHA256': source['sourceSHA256'],
                'ipaSHA256': hashlib.sha256(ipa.read_bytes()).hexdigest(), 'signed': False,
                'releaseChannel': channel, 'installer': 'Official AltStore Classic'}
    (output / (prefix + '.json')).write_text(json.dumps(metadata, indent=2) + '\n')
    return ipa

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'build/altstore')
    parser.add_argument('--variant', choices=['development','release'], default='release')
    args = parser.parse_args()
    try:
        print(build(args.out, variant=args.variant))
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error) + '\nSee ' + str(args.out / 'ipad-build.log'))
