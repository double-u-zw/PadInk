#!/bin/zsh
# Developer check: everything that runs without a device or taking over the mouse.
set -euo pipefail
cd "${0:A:h:h:h}"
out=${PADINK_BUILD_ROOT:-build/check}; mkdir -p "$out"
configuration=${PADINK_BUILD_CONFIGURATION:-Release}
channel=${PADINK_BUILD_CHANNEL:-preview}
variant=${PADINK_BUILD_VARIANT:-release}
[[ "$variant" == development || "$variant" == release ]] || { echo "PADINK_BUILD_VARIANT must be development or release" >&2; exit 1; }
[[ "$channel" == preview || "$channel" == rc ]] || { echo "PADINK_BUILD_CHANNEL must be preview or rc" >&2; exit 1; }
[[ "$configuration" == Debug || "$configuration" == Release ]] || { echo "PADINK_BUILD_CONFIGURATION must be Debug or Release" >&2; exit 1; }
swift test --scratch-path "$out/spm" 2>&1 | tee "$out/swift-test.log" | grep -E "xctest' (passed|failed)|Executed [0-9]+ tests, with [0-9]+ failures \(" | tail -6
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
xcodebuild -project PadInk.xcodeproj -scheme PadInkMac ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -configuration "$configuration" -destination 'platform=macOS' -derivedDataPath "$out/dd" build CODE_SIGNING_ALLOWED=NO PADINK_SOURCE_COMMIT="$source_label" PADINK_SOURCE_REVISION="$source_revision" PADINK_SOURCE_SHA256="$source_digest" PADINK_BUILD_VARIANT="$variant" PADINK_RELEASE_CHANNEL="$channel" PADINK_DISTRIBUTION=unsigned > "$out/mac-build.log" 2>&1
echo "PadInkMac ($configuration, unsigned $channel): built"
xcodebuild -project PadInk.xcodeproj -scheme PadInkPad -configuration "$configuration" -destination 'generic/platform=iOS' -derivedDataPath "$out/dd" build CODE_SIGNING_ALLOWED=NO PADINK_SOURCE_COMMIT="$source_label" PADINK_SOURCE_REVISION="$source_revision" PADINK_SOURCE_SHA256="$source_digest" PADINK_BUILD_VARIANT="$variant" PADINK_RELEASE_CHANNEL="$channel" PADINK_DISTRIBUTION=unsigned > "$out/ipad-build.log" 2>&1
echo "PadInkPad ($configuration, unsigned $channel): built"
python3 - "$out" "$configuration" "$channel" "$variant" <<'PYAPP'
from pathlib import Path
import json, plistlib, re, subprocess, sys
root, configuration, channel, variant = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
app_name = "PadInk Dev" if variant == "development" else "PadInk"
source = json.loads((root / "source-manifest.json").read_text())
current = json.loads(subprocess.check_output(["python3", "engineering/scripts/build-identity.py", "--json"], text=True))
if current != source: raise SystemExit("Source changed during the build; rebuild both apps from one frozen tree")
version = dict(re.findall(r'^([A-Z_]+)\s*=\s*([^\n]+)$', Path("Config/Version.xcconfig").read_text(), re.M))
for platform, directory, bundle_prefix in [("Mac", configuration, Path("Contents")), ("iPad", configuration + "-iphoneos", Path("."))]:
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
  if platform == "Mac" and {arch for _, arch in binary_ids} != {"arm64", "x86_64"}: raise SystemExit("Mac: universal architectures missing")
 print(f"{platform}: built version/provenance/privacy/icon" + ("/dSYM UUID verified" if configuration == "Release" else " verified"))
PYAPP
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
 echo "PASS $(git rev-parse --short HEAD) + working-tree changes"
else
 echo "PASS $(git rev-parse --short HEAD)"
fi
