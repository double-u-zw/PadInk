#!/usr/bin/env python3
"""Complete private retention of an existing public Beta; never rebuild, sign or publish it."""
import argparse
import importlib.util
import json
import plistlib
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('retention_release', ROOT / 'engineering/scripts/rc-release.py')
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)


def run(*args):
    return subprocess.check_output([str(x) for x in args], stderr=subprocess.PIPE)


def uuids(path):
    return sorted(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', run('xcrun', 'dwarfdump', '--uuid', path).decode()))


def verify_symbols(binary, symbols):
    identifiers = uuids(binary)
    if not identifiers or identifiers != uuids(symbols):
        raise ValueError('released binary and retained dSYM UUID mismatch')
    return identifiers


def binary_record(app, symbols, expected, platform):
    prefix = Path('Contents') if platform == 'mac' else Path('.')
    info = plistlib.loads((app / prefix / 'Info.plist').read_bytes())
    for key, value in {'CFBundleShortVersionString': expected['version'], 'CFBundleVersion': expected['build'],
                       'PadInkSourceRevision': expected['source']['head'], 'PadInkSourceDigest': expected['source']['sourceSHA256'],
                       'PadInkBuildVariant': 'release', 'PadInkReleaseChannel': 'rc', 'PadInkDistribution': 'altstore'}.items():
        if info.get(key) != value:
            raise ValueError('released bundle metadata does not match frozen inputs: ' + key)
    binary = app / prefix / ('MacOS' if platform == 'mac' else '.') / info['CFBundleExecutable']
    return {'binarySHA256': rc.file_sha(binary), 'uuids': verify_symbols(binary, symbols),
            'toolchainFromBuiltBundle': {k: info.get(k) for k in ['DTXcode', 'DTXcodeBuild', 'DTSDKName', 'DTSDKBuild', 'BuildMachineOSBuild']},
            'bundleID': info['CFBundleIdentifier']}


def extract_build_settings(log, source):
    text = log.read_text()
    keys = ['ARCHS', 'ONLY_ACTIVE_ARCH', 'CODE_SIGNING_ALLOWED', 'PADINK_BUILD_VARIANT', 'PADINK_RELEASE_CHANNEL',
            'PADINK_DISTRIBUTION', 'PADINK_BUNDLE_PREFIX', 'PADINK_MAC_BUNDLE_ID', 'PADINK_IPAD_BUNDLE_ID',
            'PRODUCT_BUNDLE_IDENTIFIER', 'PADINK_SOURCE_COMMIT', 'PADINK_SOURCE_REVISION', 'PADINK_SOURCE_SHA256']
    settings = {}
    for line in text.splitlines():
        match = re.fullmatch(r'    ([A-Z0-9_]+) = (.*)', line)
        if match and match[1] in keys:
            settings[match[1]] = match[2]
    if settings.get('PADINK_SOURCE_SHA256') != source['sourceSHA256'] or settings.get('PADINK_SOURCE_REVISION') != source['head']:
        raise ValueError('build log is for another source')
    return {'configuration': 'Release', 'overrides': settings, 'originalLogSHA256': rc.file_sha(log),
            'swiftLanguageVersions': sorted(set(re.findall(r'-swift-version (\S+)', text))),
            'compilerTargets': sorted(set(re.findall(r'-target (\S+)', text)))}


def retain(base):
    base = Path(base).resolve()
    if not base.is_relative_to(ROOT / 'build'):
        raise ValueError('private retention must stay in ignored build/')
    receipt = json.loads((base / 'publication-receipt.json').read_text())
    frozen, _ = rc.check(ROOT, base / 'private-source')
    source = frozen['source']
    if any(receipt['source'][k] != source[k] for k in ['head', 'label', 'sourceSHA256']):
        raise ValueError('published package/frozen source identity mismatch')
    online = json.loads((base.parent / 'beta3-online-release.json').read_text())
    if online['tag_name'] != receipt['tag'] or online['target_commitish'] != receipt['publicDocumentationCommit']:
        raise ValueError('public tag mapping differs from retained receipt')
    remote = {x['name']: x for x in online['assets']}
    for asset in receipt['assets']:
        path = base / asset['name']
        if rc.file_sha(path) != asset['sha256'] or path.stat().st_size != asset['bytes']:
            raise ValueError('published local asset checksum mismatch')
        if remote[asset['name']]['digest'] != 'sha256:' + asset['sha256'] or remote[asset['name']]['size'] != asset['bytes']:
            raise ValueError('GitHub uploaded asset does not match local frozen bytes')
    for arch in ['arm64', 'x86_64']:
        with zipfile.ZipFile(base / f"PadInk-{receipt['version']}-b{receipt['build']}-Beta-{arch}.zip") as archive:
            prefix = archive.namelist()[0].split('/')[0] + '/'
            for line in archive.read(prefix + 'SHA256SUMS').decode().splitlines():
                digest, name = line.split('  ', 1)
                if rc.sha(archive.read(prefix + name)) != digest:
                    raise ValueError('installation ZIP inner checksum mismatch')
    output = base / 'private-retention'
    output.mkdir(mode=0o700, exist_ok=True)
    work = ROOT / 'build/share-build/release'
    expected = {'version': receipt['version'], 'build': receipt['build'], 'source': source}
    binaries = {}
    symbol_sources = {}
    for arch in ['arm64', 'x86_64']:
        symbols = work / f'mac-dd-{arch}/Build/Products/Release/PadInk.app.dSYM'
        dmg = base / f"PadInk-{receipt['version']}-b{receipt['build']}-mac-{arch}.dmg"
        attached = plistlib.loads(run('hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', dmg))
        mounted = [x['mount-point'] for x in attached['system-entities'] if 'mount-point' in x]
        try:
            app = Path(mounted[0]) / 'PadInk.app'
            binaries['mac-' + arch] = binary_record(app, symbols, expected, 'mac')
        finally:
            for mount in mounted: run('hdiutil', 'detach', mount)
        symbol_sources['mac-' + arch] = symbols
        binaries['mac-' + arch]['buildSettings'] = extract_build_settings(work / f'{arch}-mac-build.log', source)
    with tempfile.TemporaryDirectory(prefix='padink-release-symbols-') as td:
        with zipfile.ZipFile(base / 'PadInk-AltStore.ipa') as archive:
            for name in ['Payload/PadInk.app/Info.plist', 'Payload/PadInk.app/PadInk']:
                destination = Path(td) / name; destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(archive.read(name))
        symbols = work / 'ipad/dd/Build/Products/Release-iphoneos/PadInk.app.dSYM'
        binaries['ipad'] = binary_record(Path(td) / 'Payload/PadInk.app', symbols, expected, 'ipad')
        symbol_sources['ipad'] = symbols
        binaries['ipad']['buildSettings'] = extract_build_settings(work / 'ipad/ipad-build.log', source)
    for platform, symbols in symbol_sources.items():
        path = output / (platform + '-symbols.zip')
        entries = {str(p.relative_to(symbols.parent)): p for p in symbols.rglob('*') if p.is_file()}
        if path.exists():
            with zipfile.ZipFile(path) as archive:
                if set(archive.namelist()) != set(entries) or any(rc.sha(archive.read(n)) != rc.file_sha(p) for n, p in entries.items()):
                    raise ValueError('existing symbol retention differs; never overwrite it')
        else:
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
                for name, original in sorted(entries.items()): archive.write(original, name)
            path.chmod(0o600)
        binaries[platform]['symbols'] = {'path': path.name, 'sha256': rc.file_sha(path)}
    source_asset = next(x for x in frozen['assets'] if x['role'] == 'developer-source-only')
    with zipfile.ZipFile(base / 'private-source' / source_asset['path']) as archive:
        prefix = archive.namelist()[0].split('/')[0] + '/'
        configuration = {name: archive.read(prefix + name).decode() for name in ['Config/Version.xcconfig', 'Config/Identity.xcconfig', 'Package.swift']}
    if '.package(' in configuration['Package.swift']:
        raise ValueError('external SwiftPM dependency graph requires resolved revision retention')
    record = {'version': receipt['version'], 'build': receipt['build'], 'channel': 'rc', 'distribution': 'altstore-public-beta',
              'source': source, 'sourceArchive': {'path': '../private-source/' + source_asset['path'], 'sha256': source_asset['sha256']},
              'publicTag': {'name': receipt['tag'], 'commit': receipt['publicDocumentationCommit'], 'matchesBuildSource': False},
              'configurationFromFrozenSource': configuration, 'externalSwiftPMDependencies': [],
              'toolchainEvidence': 'SDK/Xcode from shipped binaries; exact build overrides from matching original logs',
              'binaries': binaries, 'publishedAssets': receipt['assets'],
              'acceptance': {'priorRC1USB': 'maintainer-confirmed-complete-2026-10-13; preserve baseline, no invented item-level results',
                             'formalSignedUSB': 'not-tested', 'externalDevice': 'not-tested'}}
    manifest = output / 'BUILD-INPUTS.json'
    payload = json.dumps(record, ensure_ascii=False, indent=2) + '\n'
    if manifest.exists() and manifest.read_text() != payload:
        raise ValueError('existing private build inputs differ; never overwrite frozen records')
    manifest.write_text(payload); manifest.chmod(0o600)
    (output / 'SHA256SUMS').write_text(''.join(f'{rc.file_sha(p)}  {p.name}\n' for p in sorted(output.iterdir()) if p.name != 'SHA256SUMS'))
    print(f"Retained {receipt['version']} build {receipt['build']}: published hashes, exact private source, build settings, SDK/Xcode and 3 matching dSYMs; public tag recorded separately")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('beta', type=Path)
    args = parser.parse_args()
    retain(args.beta)
