#!/bin/zsh
# Developer check: everything that runs without a device or taking over the mouse.
set -euo pipefail
cd "${0:A:h:h:h}"
out=${PADINK_BUILD_ROOT:-build/check}; mkdir -p "$out"
configuration=${PADINK_BUILD_CONFIGURATION:-Release}
channel=${PADINK_BUILD_CHANNEL:-preview}
variant=${PADINK_BUILD_VARIANT:-release}
simulator=${PADINK_BUILD_SIMULATOR:-0}
scope=${PADINK_CHECK_SCOPE:-local}
release_check=${PADINK_RELEASE_CHECK:-daily}
mac_architectures=${PADINK_MAC_ARCHITECTURES:-arm64}
[[ "$mac_architectures" == arm64 || "$mac_architectures" == 'arm64 x86_64' ]] || { echo "PADINK_MAC_ARCHITECTURES must be arm64 or legacy arm64 x86_64" >&2; exit 1; }
[[ "$scope" == local || "$scope" == ci ]] || { echo "PADINK_CHECK_SCOPE must be local or ci" >&2; exit 1; }
[[ "$release_check" == daily || "$release_check" == candidate || "$release_check" == submission ]] || { echo "PADINK_RELEASE_CHECK must be daily, candidate or submission" >&2; exit 1; }
[[ "$simulator" == 0 || "$simulator" == 1 ]] || { echo "PADINK_BUILD_SIMULATOR must be 0 or 1" >&2; exit 1; }
[[ "$variant" == development || "$variant" == release ]] || { echo "PADINK_BUILD_VARIANT must be development or release" >&2; exit 1; }
[[ "$channel" == preview || "$channel" == rc ]] || { echo "PADINK_BUILD_CHANNEL must be preview or rc" >&2; exit 1; }
[[ "$configuration" == Debug || "$configuration" == Release ]] || { echo "PADINK_BUILD_CONFIGURATION must be Debug or Release" >&2; exit 1; }
python3 engineering/scripts/check-provenance.py start "$out/check-provenance.json" --scope "$scope"
test_options=()
identity_options=()
if [[ "$scope" == ci ]]; then
 # Hosted runners do not prove physical Metal/codec/SCK/device behavior. All other app tests run.
 test_options=(--skip 'HardwareCodecTests|VideoDecodeRecoveryTests|MacVideoLifecycleTests|MacVideoSoakTests|VideoQualityExperimentTests')
 identity_options=(PADINK_BUNDLE_PREFIX=dev.padink.ci DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=)
 echo "CI scope excludes physical GPU/codec/SCK experiments; no device or release-binary claim"
fi
swift test --scratch-path "$out/spm" "${test_options[@]}" 2>&1 | tee "$out/swift-test.log" | grep -E "xctest' (passed|failed)|Executed [0-9]+ tests, with.*failures \(" | tail -6
python3 engineering/scripts/test-local-signing.py > "$out/signing-selftest.log" 2>&1
echo "local-signing self-test: OK"
python3 engineering/scripts/test-update-script.py > "$out/update-selftest.log" 2>&1
echo "update-script self-test: OK"
python3 engineering/scripts/selftest_build_identity.py > "$out/build-identity-selftest.log" 2>&1
echo "build-identity self-test: OK"
python3 engineering/scripts/test-package-source.py > "$out/package-selftest.log" 2>&1
echo "source-package self-test: OK"
python3 engineering/scripts/test-release-config.py > "$out/release-config-selftest.log" 2>&1
echo "paid-release configuration self-test: OK"
python3 engineering/scripts/test-release-resources.py > "$out/release-resources-selftest.log" 2>&1
echo "release-resource self-test: OK"
python3 engineering/scripts/test-rc-release.py > "$out/rc-release-selftest.log" 2>&1
echo "RC packaging self-test: OK"
python3 engineering/scripts/test-pencil-performance.py > "$out/performance-selftest.log" 2>&1
echo "performance-analysis self-test: OK"
python3 engineering/scripts/test-store-materials.py > "$out/store-materials-selftest.log" 2>&1
echo "store-materials self-test: OK"
python3 engineering/scripts/test-release-evidence.py > "$out/release-evidence-selftest.log" 2>&1
echo "release-evidence/CI source-contract self-test: OK"
material_options=()
if [[ "$release_check" != daily ]]; then
 [[ -n "${PADINK_FROZEN_RELEASE:-}" ]] || { echo "candidate/submission checks require PADINK_FROZEN_RELEASE" >&2; exit 1; }
 material_options=(--release "$PADINK_FROZEN_RELEASE")
 [[ -z "${PADINK_FROZEN_SOURCE_ROOT:-}" ]] || material_options+=(--source-root "$PADINK_FROZEN_SOURCE_ROOT")
 [[ "$release_check" != submission ]] || material_options+=(--require-ready)
fi
python3 engineering/scripts/store-materials.py "${material_options[@]}" > "$out/store-materials-check.json"
echo "current store-materials version/channel/source check: OK ($release_check; pending account fields are not submission acceptance)"
# Release must strip detailed diagnostics even when a caller requests them.
swift test -c release --scratch-path "$out/spm" --filter 'DiagnosticReleaseTests|BuildIdentityTests' > "$out/release-diagnostics-test.log" 2>&1
echo "Release diagnostics/build identity tests: OK"
# Compare generated files to their pre-check contents, allowing intentional uncommitted host UI edits.
python3 - <<'PYGEN'
from pathlib import Path
import subprocess
paths = [Path("PadInk.xcodeproj/project.pbxproj"), *Path("PadInk.xcodeproj/xcshareddata/xcschemes").glob("*.xcscheme"), Path("Hosts/Mac/Info.plist"), Path("Hosts/iPad/Info.plist"), Path("Hosts/Mac/PadInkMac.entitlements")]
before = {path: path.read_bytes() for path in paths}
subprocess.run(["python3", "engineering/scripts/generate-project.py"], check=True)
changed = [str(path) for path in paths if path.read_bytes() != before[path]]
if changed:
 raise SystemExit("Generated files were out of date; review and rerun: " + ", ".join(changed))
PYGEN
source_label=$(python3 engineering/scripts/build-identity.py)
python3 engineering/scripts/build-identity.py --json > "$out/source-manifest.json"
source_revision=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["head"])' "$out/source-manifest.json")
source_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceSHA256"])' "$out/source-manifest.json")
xcodebuild -project PadInk.xcodeproj -scheme PadInkMac ARCHS="$mac_architectures" ONLY_ACTIVE_ARCH=NO -configuration "$configuration" -destination 'platform=macOS' -derivedDataPath "$out/dd" build CODE_SIGNING_ALLOWED=NO "${identity_options[@]}" PADINK_SOURCE_COMMIT="$source_label" PADINK_SOURCE_REVISION="$source_revision" PADINK_SOURCE_SHA256="$source_digest" PADINK_BUILD_VARIANT="$variant" PADINK_RELEASE_CHANNEL="$channel" PADINK_DISTRIBUTION=unsigned > "$out/mac-build.log" 2>&1
echo "PadInkMac ($configuration, unsigned $channel): built"
xcodebuild -project PadInk.xcodeproj -scheme PadInkPad -configuration "$configuration" -destination 'generic/platform=iOS' -derivedDataPath "$out/dd" build CODE_SIGNING_ALLOWED=NO "${identity_options[@]}" PADINK_SOURCE_COMMIT="$source_label" PADINK_SOURCE_REVISION="$source_revision" PADINK_SOURCE_SHA256="$source_digest" PADINK_BUILD_VARIANT="$variant" PADINK_RELEASE_CHANNEL="$channel" PADINK_DISTRIBUTION=unsigned > "$out/ipad-build.log" 2>&1
echo "PadInkPad ($configuration, unsigned $channel): built"
if [[ "$simulator" == 1 ]]; then
 # Local ad-hoc simulator signing emits the simulated application-identifier needed by
 # Keychain. No certificate, provisioning update, device install or production identity change.
 xcodebuild -project PadInk.xcodeproj -scheme PadInkPad -configuration "$configuration" -destination 'generic/platform=iOS Simulator' -derivedDataPath "$out/dd" build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PADINK_SOURCE_COMMIT="$source_label" PADINK_SOURCE_REVISION="$source_revision" PADINK_SOURCE_SHA256="$source_digest" PADINK_BUILD_VARIANT="$variant" PADINK_RELEASE_CHANNEL="$channel" PADINK_DISTRIBUTION=unsigned > "$out/simulator-build.log" 2>&1
 echo "PadInkPad ($configuration, simulator): built"
fi
python3 - "$out" "$configuration" "$channel" "$variant" "$simulator" "$mac_architectures" <<'PYAPP'
from pathlib import Path
import json, plistlib, re, subprocess, sys
root, configuration, channel, variant = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
app_name = "PadInk" if variant == "development" else "PadInk"
source = json.loads((root / "source-manifest.json").read_text())
current = json.loads(subprocess.check_output(["python3", "engineering/scripts/build-identity.py", "--json"], text=True))
if current != source: raise SystemExit("Source changed during the build; rebuild both apps from one frozen tree")
version = dict(re.findall(r'^([A-Z_]+)\s*=\s*([^\n]+)$', Path("Config/Version.xcconfig").read_text(), re.M))
platforms = [("Mac", configuration, Path("Contents")), ("iPad", configuration + "-iphoneos", Path("."))]
if sys.argv[5] == "1": platforms.append(("iPad Simulator", configuration + "-iphonesimulator", Path(".")))
for platform, directory, bundle_prefix in platforms:
 products = root / "dd/Build/Products" / directory
 app = products / (app_name + ".app")
 info = plistlib.loads((app / bundle_prefix / "Info.plist").read_bytes())
 for key, expected in {"CFBundleShortVersionString":version["MARKETING_VERSION"], "CFBundleVersion":version["CURRENT_PROJECT_VERSION"], "PadInkSourceCommit":source["label"], "PadInkSourceRevision":source["head"], "PadInkSourceDigest":source["sourceSHA256"], "PadInkBuildVariant":variant, "CFBundleDisplayName":app_name, "PadInkReleaseChannel":channel, "PadInkDistribution":"unsigned"}.items():
  if str(info.get(key)) != expected: raise SystemExit(f"{platform}: built {key} mismatch")
 resources = app / "Contents/Resources" if platform == "Mac" else app
 privacy = plistlib.loads((resources / "PrivacyInfo.xcprivacy").read_bytes())
 if privacy["NSPrivacyTracking"] or not (resources / "Assets.car").is_file(): raise SystemExit(f"{platform}: missing release resources")
 if configuration == "Release":
  executable = app / "Contents/MacOS" / info["CFBundleExecutable"] if platform == "Mac" else app / info["CFBundleExecutable"]
  symbols = products / (app_name + ".app.dSYM")
  def uuids(path):
   return set(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(path)], text=True)))
  binary_ids, symbol_ids = uuids(executable), uuids(symbols)
  if not binary_ids or binary_ids != symbol_ids: raise SystemExit(f"{platform}: dSYM UUID mismatch")
  if platform == "Mac" and {arch for _, arch in binary_ids} != set(sys.argv[6].split()): raise SystemExit("Mac: declared architectures mismatch")
 print(f"{platform}: built version/provenance/privacy/icon" + ("/dSYM UUID verified" if configuration == "Release" else " verified"))
PYAPP
if [[ "$configuration" == Release && "$variant" == release ]]; then
 python3 engineering/scripts/check-store-bundle.py "$out/dd/Build/Products/Release-iphoneos/PadInk.app" > "$out/store-bundle-check.json"
 echo "iPad App Store bundle preflight: OK (unsigned; TestFlight USB acceptance pending)"
fi
python3 engineering/scripts/check-provenance.py finish "$out/check-provenance.json" --scope "$scope"
