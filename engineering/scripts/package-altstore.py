#!/usr/bin/env python3
"""Prepare matching Mac/IPA test downloads; never install, authenticate, or notarize."""
import argparse
import hashlib
import importlib.util
import json
import plistlib
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAC_ID = 'dev.padink.altstore.mac'
ALT_URL = 'https://cdn.altstore.io/file/altstore/altserver/1_8_1.zip'
ALT_SHA = '8f48728c64ad776580939ce05ee99e979d457226fb82b1d42f95a8c1bd73e3c1'
TRIAL_DOCS = ('SUPPORT_MATRIX.md', 'PRIVACY.md', 'ECRU.md', 'RELEASE.md', '使用教程.md',
              '使用者安装指南.md', '开发者指南.md', 'ARCHITECTURE.md', 'PROTOCOL.md',
              'AltStore安装说明.txt', '试用验收清单.txt')
PUBLIC_DOCS = ('SUPPORT_MATRIX.md', 'PRIVACY.md', 'ECRU.md', '使用者安装指南.md', '使用教程.md',
               'AltStore安装说明.txt', '试用验收清单.txt')

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'engineering/scripts' / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def download_altserver(out, work):
    destination = out / 'AltServer-1.8.1.zip'
    cached = ROOT / 'build/share/AltServer-1.8.1.zip'
    if not destination.exists() and cached != destination and cached.is_file() and sha(cached) == ALT_SHA:
        shutil.copy2(cached, destination)
    if not destination.exists() or sha(destination) != ALT_SHA:
        with tempfile.TemporaryDirectory(prefix='altserver-download-', dir=work) as td:
            temporary = Path(td) / 'AltServer-1.8.1.zip'
            request = urllib.request.Request(ALT_URL, headers={'User-Agent': 'AltServer/98'})
            with urllib.request.urlopen(request, timeout=60) as source, temporary.open('wb') as target:
                shutil.copyfileobj(source, target)
            if sha(temporary) != ALT_SHA:
                raise ValueError('Official AltServer archive hash mismatch; stopped.')
            temporary.replace(destination)
    with tempfile.TemporaryDirectory(prefix='altserver-verify-', dir=work) as td:
        run(['ditto', '-x', '-k', destination, td], stdout=subprocess.DEVNULL)
        candidates = list(Path(td).glob('AltServer.app'))
        if len(candidates) != 1:
            raise ValueError('Unexpected official AltServer archive layout.')
        app = candidates[0]
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != ('1.8.1', '98'):
            raise ValueError('AltServer is not version 1.8.1 (98).')
        run(['codesign', '--verify', '--deep', '--strict', app], capture_output=True)
        details = run(['codesign', '-d', '--verbose=4', app], capture_output=True, text=True).stderr
        if 'TeamIdentifier=6XVY5G3U44' not in details:
            raise ValueError('Unexpected AltServer publisher.')
        assessment = run(['spctl', '--assess', '--type', 'execute', '--verbose=4', app], capture_output=True, text=True)
        if 'Notarized Developer ID' not in assessment.stderr:
            raise ValueError('Official AltServer notarization was not confirmed.')
    return destination

def package(out, public_beta=False, variant='release'):
    if variant not in {'development', 'release'}:
        raise ValueError('Unknown build variant.')
    if public_beta and variant != 'release':
        raise ValueError('Public beta must use the release App identity.')
    out = out.resolve()
    if not out.is_relative_to(ROOT / 'build'):
        raise ValueError('Output must be inside build/.')
    out.mkdir(parents=True, exist_ok=True)
    work = ROOT / 'build/share-build' / variant
    work.mkdir(parents=True, exist_ok=True)
    identity = module('package_identity', 'build-identity.py')
    source = identity.identity(ROOT)
    channel = 'development' if variant == 'development' else 'rc'
    app_name = 'PadInk Dev' if variant == 'development' else 'PadInk'
    brand = 'PadInk-Dev' if variant == 'development' else 'PadInk'
    mac_id = MAC_ID + ('.development' if variant == 'development' else '')
    ipa = module('package_ipa', 'build-altstore-ipa.py').build(work / 'ipad', channel=channel, variant=variant)
    ipad = json.loads(ipa.with_suffix('.json').read_text())
    base = f"{brand}-{ipad['version']}-b{ipad['build']}"
    names = {arch: base + '-' + ('Beta' if public_beta else 'Test') + '-' + arch for arch in ('arm64', 'x86_64')}
    if any((out / (n + '.zip')).exists() or (out / n).exists() for n in names.values()):
        raise ValueError('Existing candidate will not be overwritten; increment build or choose a new output directory.')
    official = download_altserver(out, work)
    outputs = []
    for arch, name in names.items():
        with (work / (arch + '-mac-build.log')).open('w') as log:
            run(['xcodebuild', '-project', ROOT / 'PadInk.xcodeproj', '-scheme', 'PadInkMac',
                 'ARCHS=' + arch, 'ONLY_ACTIVE_ARCH=NO', '-configuration', 'Release',
                 '-destination', 'generic/platform=macOS', '-derivedDataPath', work / ('mac-dd-' + arch), 'build',
                 'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGN_IDENTITY=', 'DEVELOPMENT_TEAM=',
                 'PADINK_BUNDLE_PREFIX=dev.padink.altstore', 'PADINK_MAC_BUNDLE_ID=' + mac_id,
                 'PRODUCT_BUNDLE_IDENTIFIER=' + mac_id, 'PADINK_BUILD_VARIANT=' + variant,
                 'PADINK_RELEASE_CHANNEL=' + channel, 'PADINK_DISTRIBUTION=altstore',
                 'PADINK_SOURCE_COMMIT=' + source['label'], 'PADINK_SOURCE_REVISION=' + source['head'],
                 'PADINK_SOURCE_SHA256=' + source['sourceSHA256']], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        products = work / ('mac-dd-' + arch) / 'Build/Products/Release'
        app = products / (app_name + '.app')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        expected = {'CFBundleIdentifier': mac_id, 'CFBundleDisplayName': app_name,
                    'PadInkBuildVariant': variant, 'PadInkDistribution': 'altstore',
                    'PadInkReleaseChannel': channel, 'PadInkSourceRevision': source['head'],
                    'PadInkSourceDigest': source['sourceSHA256'], 'CFBundleShortVersionString': ipad['version'],
                    'CFBundleVersion': ipad['build']}
        if any(info.get(k) != v for k, v in expected.items()) or ipad['sourceSHA256'] != source['sourceSHA256']:
            raise ValueError('Mac/iPad identity or source metadata mismatch.')
        executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
        architectures = set(subprocess.check_output(['lipo', '-archs', executable], text=True).split())
        if architectures != {arch}: raise ValueError('Mac architecture does not match package label.')
        def uuids(path):
            import re
            return set(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', subprocess.check_output(['xcrun','dwarfdump','--uuid',path], text=True)))
        if not uuids(executable) or uuids(executable) != uuids(products / (app_name + '.app.dSYM')):
            raise ValueError('Mac executable and dSYM mismatch.')
        if identity.identity(ROOT) != source: raise ValueError('Source changed during the build.')
        run(['codesign', '--force', '--options', 'runtime', '--sign', '-', '--entitlements',
             ROOT / 'Hosts/Mac/PadInkMac.entitlements', app], capture_output=True)
        run(['codesign', '--verify', '--deep', '--strict', app], capture_output=True)
        with tempfile.TemporaryDirectory(prefix='padink-package-', dir=work) as td:
            stage = Path(td) / name; stage.mkdir()
            image = Path(td) / 'image'; image.mkdir()
            shutil.copytree(app, image / (app_name + '.app'), symlinks=True)
            (image / 'Applications').symlink_to('/Applications')
            dmg_name = base + '-mac-' + arch + '.dmg'
            dmg = stage / dmg_name
            run(['hdiutil', 'create', '-volname', app_name + ' ' + arch, '-srcfolder', image,
                 '-format', 'UDZO', dmg], stdout=subprocess.DEVNULL)
            run(['hdiutil', 'verify', dmg], stdout=subprocess.DEVNULL)
            shutil.copy2(ipa, stage / ipa.name)
            shutil.copy2(ROOT / 'docs/AltStore安装说明.txt', stage / '安装说明.txt')
            shutil.copy2(ROOT / 'docs/试用验收清单.txt', stage / '真人验收清单.txt')
            tutorial = (ROOT / 'docs/使用教程.md').read_text()
            for original, target in [('AltStore安装说明.txt', '安装说明.txt'),
                                     ('试用验收清单.txt', '真人验收清单.txt'),
                                     ('SUPPORT_MATRIX.md', 'docs/SUPPORT_MATRIX.md')]:
                tutorial = tutorial.replace('(' + original + ')', '(' + target + ')')
            (stage / '使用教程.md').write_text(tutorial)
            shutil.copy2(ROOT / 'LICENSE', stage / 'LICENSE')
            (stage / 'docs').mkdir()
            for document in PUBLIC_DOCS if public_beta else TRIAL_DOCS:
                content = (ROOT / 'docs' / document).read_text()
                if public_beta:
                    import re
                    for target in ('RELEASE.md','开发者指南.md'):
                        content = re.sub(r'\(' + re.escape(target) + r'(#[^)]*)?\)',
                                         lambda match: '(https://github.com/double-u-zw/PadInk/blob/main/docs/' + target + (match.group(1) or '') + ')', content)
                (stage / 'docs' / document).write_text(content)
            chip = 'Apple Silicon（M 系列）' if arch == 'arm64' else 'Intel'
            (stage / '先读我.txt').write_text(
                f"{app_name} {ipad['version']} build {ipad['build']} — {chip}\n\n"
                f"Mac 打开 {dmg_name}，将 {app_name}.app 拖入 Applications；iPad 用官方 AltStore Classic 导入 {ipa.name}。\n"
                "Mac 为 ad-hoc 签名测试包，尚未公证；iPad 免费签名约 7 天，安装不需要 Xcode。\n"
                "开发版与正式版独立安装、设置、配对和连接发现；双端必须选择同一版本身份。首次开发版需要重新授权与配对。\n"
                "芯片包共用同一版本身份，换架构不增加另一份设置或配对。本次为测试版，不代表稳定版已发布。\n"
                "官方 AltServer：" + ALT_URL + "\n"
                "先按安装说明.txt 安装，再看使用教程.md；按真人验收清单.txt 记录。本包完整真人验收未完成。\n"
                "Intel 实机、最低系统、第二套设备、长时间文稿、Wi-Fi 恢复、后台自动续签、过期恢复和覆盖升级仍待验证。\n"
                f"双端源码标识：{source['label']}\n")
            manifest = {'version':ipad['version'], 'build':ipad['build'], 'variant':variant,
                        'displayName':app_name, 'sourceRevision':source['head'], 'sourceSHA256':source['sourceSHA256'],
                        'macBundleID':mac_id, 'ipadUnsignedBundleID':ipad['bundleIdentifier'], 'macArchitectures':[arch],
                        'macSignature':'ad-hoc', 'macNotarized':False, 'newBuildDeviceTested':False,
                        'releaseChannel':channel, 'distribution':'altstore',
                        'candidateKind':'public-beta' if public_beta else 'invited-trial',
                        'publicationStatusAtPackaging':'prepared-not-uploaded',
                        'sourceDirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT)),
                        'acceptanceChecklist':'真人验收清单.txt', 'altserverOfficialURL':ALT_URL,
                        'altserverVersion':'1.8.1 (98)', 'altserverSHA256':ALT_SHA}
            if not public_beta: manifest['published'] = False
            (stage / 'VERSIONS.json').write_text(json.dumps(manifest,indent=2)+'\n')
            files=sorted(p for p in stage.rglob('*') if p.is_file())
            (stage / 'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.relative_to(stage).as_posix()}\n' for p in files))
            bundle=Path(td)/(name+'.zip')
            with zipfile.ZipFile(bundle,'w',zipfile.ZIP_DEFLATED) as archive:
                for p in sorted(stage.rglob('*')):
                    if p.is_file(): archive.write(p,name+'/'+p.relative_to(stage).as_posix())
            with zipfile.ZipFile(bundle) as archive:
                if archive.testzip() is not None: raise ValueError('Distribution ZIP integrity check failed.')
            shutil.copytree(stage,out/name)
            shutil.copy2(dmg,out/dmg_name)
            bundle.replace(out/bundle.name)
            outputs.append(out/name)
            print(out/(name+'.zip'))
    (out/'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.name}\n' for p in sorted(out.iterdir()) if p.suffix in {'.dmg','.zip'}))
    print(official)
    return outputs

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path)
    parser.add_argument('--variant', choices=['development','release'], default='release')
    parser.add_argument('--public-beta', action='store_true', help='Prepare public beta materials locally; never upload.')
    args = parser.parse_args()
    try:
        package(args.out or ROOT / 'build/share' / args.variant, public_beta=args.public_beta, variant=args.variant)
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error) + '\nSee build/share-build/ for build logs.')
