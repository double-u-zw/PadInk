#!/usr/bin/env python3
"""Deterministic Xcode project for the two app hosts (adapted from Baseline v0.1.0's generator).
All logic lives in the SwiftPM kits; targets here only contain Hosts/<platform>/*.swift.
Identity and signing come from Config/Identity.xcconfig (+ untracked Signing.local.xcconfig)."""
from pathlib import Path
import hashlib, json, plistlib
root = Path(__file__).resolve().parents[2]
objects = {}
def ident(key): return hashlib.sha256(key.encode()).hexdigest()[:24].upper()
def obj(key, isa, **kw): i = ident(key); objects[i] = dict(isa=isa, **kw); return i
def quote(s): return json.dumps(str(s), ensure_ascii=False)
def serialize(x):
    if isinstance(x, dict): return '{ ' + ' '.join(quote(k) + ' = ' + serialize(v) + ';' for k, v in x.items()) + ' }'
    if isinstance(x, list): return '( ' + ', '.join(serialize(v) for v in x) + ' )'
    return quote(x)
files, products, targets = [], [], []
package = obj('local-package', 'XCLocalSwiftPackageReference', relativePath='.')
xcconfig = obj('Config/Identity.xcconfig', 'PBXFileReference', lastKnownFileType='text.xcconfig', path='Config/Identity.xcconfig', sourceTree='<group>'); files.append(xcconfig)
def configs(key, settings, base=None):
    arr = []
    for name in ['Debug', 'Release']:
        s = dict(settings); s.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if name == 'Debug' else '-O', DEBUG_INFORMATION_FORMAT='dwarf' if name == 'Debug' else 'dwarf-with-dsym')
        if name == 'Debug': s.update(SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG', ONLY_ACTIVE_ARCH='YES')
        kw = dict(name=name, buildSettings=s)
        if base: kw['baseConfigurationReference'] = base
        arr.append(obj(key + name, 'XCBuildConfiguration', **kw))
    return obj(key + 'configs', 'XCConfigurationList', buildConfigurations=arr, defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
for name, platform, folder, kit in [('PadInkMac', 'macosx', 'Hosts/Mac', 'PadInkMacKit'), ('PadInkPad', 'iphoneos', 'Hosts/iPad', 'PadInkPadKit')]:
    build = []; resources = []
    for p in sorted((root / folder).glob('*.swift')):
        rel = str(p.relative_to(root)); ref = obj(rel, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=rel, sourceTree='<group>'); files.append(ref)
        build.append(obj(name + rel, 'PBXBuildFile', fileRef=ref))
    for filename, filetype in [('PrivacyInfo.xcprivacy', 'text.xml'), ('Assets.xcassets', 'folder.assetcatalog')]:
        rel = folder + '/' + filename
        ref = obj(rel, 'PBXFileReference', lastKnownFileType=filetype, path=rel, sourceTree='<group>'); files.append(ref)
        resources.append(obj(name + rel, 'PBXBuildFile', fileRef=ref))
    product = obj(name + 'product' , 'PBXFileReference', explicitFileType='wrapper.application', path='PadInk.app', sourceTree='BUILT_PRODUCTS_DIR'); products.append(product)
    deps, links = [], []
    for module in ['PadInkCore', kit]:
        dep = obj(name + module, 'XCSwiftPackageProductDependency', productName=module); deps.append(dep); links.append(obj(name + module + 'link', 'PBXBuildFile', productRef=dep))
    phases = [obj(name + 'sources', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=build, runOnlyForDeploymentPostprocessing=0),
              obj(name + 'frameworks', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=links, runOnlyForDeploymentPostprocessing=0),
              obj(name + 'resources', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)]
    settings = dict(SWIFT_VERSION='5.0', SDKROOT=platform, MACOSX_DEPLOYMENT_TARGET='14.0', IPHONEOS_DEPLOYMENT_TARGET='17.0',
                    ENABLE_APP_SANDBOX='NO', GENERATE_INFOPLIST_FILE='NO', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',
                    INFOPLIST_FILE=folder + '/Info.plist', PADINK_SOURCE_COMMIT='unknown', PADINK_SOURCE_REVISION='unknown', PADINK_SOURCE_SHA256='unknown', SKIP_INSTALL='NO')
    if platform == 'macosx':
        settings.update(PRODUCT_BUNDLE_IDENTIFIER='$(PADINK_MAC_BUNDLE_ID)', ENABLE_HARDENED_RUNTIME='YES', CODE_SIGN_ENTITLEMENTS='Hosts/Mac/PadInkMac.entitlements')
    else:
        settings.update(PRODUCT_BUNDLE_IDENTIFIER='$(PADINK_IPAD_BUNDLE_ID)', TARGETED_DEVICE_FAMILY='2', SUPPORTED_PLATFORMS='iphoneos iphonesimulator',
                        SUPPORTS_MACCATALYST='NO', SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD='NO')
    tid = obj(name, 'PBXNativeTarget', name=name, productName='PadInk', productReference=product, productType='com.apple.product-type.application',
              buildConfigurationList=configs(name, settings, xcconfig), buildPhases=phases, buildRules=[], dependencies=[], packageProductDependencies=deps)
    targets.append(tid)
group = obj('main', 'PBXGroup', children=list(dict.fromkeys(files)) + [obj('products', 'PBXGroup', name='Products', children=products, sourceTree='<group>')], sourceTree='<group>')
project = obj('project', 'PBXProject', attributes={'LastUpgradeCheck': '2700'}, buildConfigurationList=configs('project', {'CLANG_ENABLE_MODULES': 'YES'}),
              compatibilityVersion='Xcode 14.0', developmentRegion='zh-Hans', knownRegions=['zh-Hans', 'en', 'Base'], mainGroup=group, projectDirPath='', projectRoot='',
              targets=targets, packageReferences=[package])
p = root / 'PadInk.xcodeproj'; p.mkdir(exist_ok=True)
(p / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + serialize(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)) + '\n')
schemes = p / 'xcshareddata/xcschemes'; schemes.mkdir(parents=True, exist_ok=True)
for name in ['PadInkMac', 'PadInkPad']:
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident(name)}" BuildableName="PadInk.app" BlueprintName="{name}" ReferencedContainer="container:PadInk.xcodeproj"/>'
    (schemes / (name + '.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug"/><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
common = {'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleDisplayName': '$(PADINK_DISPLAY_NAME)', 'CFBundleName': '$(PRODUCT_NAME)', 'CFBundleExecutable': '$(EXECUTABLE_NAME)',
          'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleInfoDictionaryVersion': '6.0', 'CFBundlePackageType': 'APPL',
          'CFBundleShortVersionString': '$(MARKETING_VERSION)', 'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)', 'PadInkSourceCommit': '$(PADINK_SOURCE_COMMIT)', 'PadInkSourceRevision': '$(PADINK_SOURCE_REVISION)',
          'PadInkSourceDigest': '$(PADINK_SOURCE_SHA256)', 'PadInkReleaseChannel': '$(PADINK_RELEASE_CHANNEL)', 'PadInkDistribution': '$(PADINK_DISTRIBUTION)'}
common.update(PadInkBuildVariant='$(PADINK_BUILD_VARIANT)')
common.update(NSLocalNetworkUsageDescription='在同一局域网发现已配对的设备，并加密传输画面和输入。', NSBonjourServices=['$(PADINK_BONJOUR_SERVICE_TYPE)'])
mac = dict(common, LSUIElement=True, LSMinimumSystemVersion='$(MACOSX_DEPLOYMENT_TARGET)', NSHighResolutionCapable=True, NSHumanReadableCopyright='PadInk',
           NSScreenCaptureUsageDescription='把 Mac 主屏显示到 iPad。', NSAppleEventsUsageDescription='通过 PowerPoint 的公开接口调整当前演示文稿视图的缩放比例。')
ipad = dict(common, LSRequiresIPhoneOS=True, ITSAppUsesNonExemptEncryption=False, UILaunchScreen={}, UIRequiresFullScreen=True, UIStatusBarHidden=True, UIViewControllerBasedStatusBarAppearance=True,
            UISupportedInterfaceOrientations=['UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
            UIApplicationSupportsIndirectInputEvents=False, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False})
(root / 'Hosts/Mac/Info.plist').write_bytes(plistlib.dumps(mac))
(root / 'Hosts/iPad/Info.plist').write_bytes(plistlib.dumps(ipad))
print('Generated PadInk.xcodeproj: PadInkMac, PadInkPad ("PadInk.app" by default)')

(root / 'Hosts/Mac/PadInkMac.entitlements').write_bytes(plistlib.dumps({'com.apple.security.automation.apple-events': True}))
