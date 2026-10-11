#!/usr/bin/env python3
"""RC fixture tests. All signing, Apple services and archives are isolated fakes."""
import datetime
import importlib.util
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("rc_release", ROOT / "engineering/scripts/rc-release.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
TEAM = "ABC1234567"
CONFIG = f"""DEVELOPMENT_TEAM = {TEAM}
PADINK_BUNDLE_PREFIX = com.example.padink
PADINK_MAC_BUNDLE_ID = com.example.padink.mac
PADINK_IPAD_BUNDLE_ID = com.example.padink.ipad
PADINK_MAC_SIGN_IDENTITY = Developer ID Application: Test Team ({TEAM})
PADINK_IPAD_SIGN_IDENTITY = Apple Distribution
PADINK_NOTARY_PROFILE = test-notary-profile
"""


class FakeAppleTools:
    def __init__(self, reject_notary=False, bad_dsym=False, arm_only=False, no_credentials=False):
        self.calls = []
        self.archive_architectures = {}
        self.reject_notary, self.bad_dsym, self.arm_only, self.no_credentials = reject_notary, bad_dsym, arm_only, no_credentials

    def __call__(self, arguments):
        args = [str(argument) for argument in arguments]
        self.calls.append(args)
        if args[:4] == ["security", "find-identity", "-v", "-p"]:
            text = "" if self.no_credentials else f'1) hash "Developer ID Application: Test Team ({TEAM})"\n2) hash "Apple Distribution: Test Team ({TEAM})"'
            return text.encode(), b""
        if args[:3] == ["security", "cms", "-D"]:
            app = Path(args[-1]).parent
            info = plistlib.loads((app / "Info.plist").read_bytes())
            return plistlib.dumps({"ExpirationDate": datetime.datetime(2035, 1, 1), "Entitlements": {"get-task-allow": False, "application-identifier": TEAM + "." + info["CFBundleIdentifier"]}}), b""
        if args[:3] == ["xcrun", "notarytool", "submit"]:
            return json.dumps({"id": "fixture-submission", "status": "Invalid" if self.reject_notary else "Accepted"}).encode(), b""
        if args[:3] == ["xcrun", "dwarfdump", "--uuid"]:
            path = args[-1]
            mac = "Contents/MacOS" in path or "PadInkMac.xcarchive" in path
            architectures = ["arm64"]
            for archive, value in self.archive_architectures.items():
                if path.startswith(archive): architectures = value
            if mac and "/Contents/MacOS/" in path:
                info = plistlib.loads((Path(path).parent.parent / "Info.plist").read_bytes())
                architectures = info.get("FixtureArchitectures", architectures)
            if self.arm_only and mac: architectures = ["arm64"]
            text = ""
            for index, architecture in enumerate(architectures):
                identifier = ("F" if self.bad_dsym and path.endswith(".dSYM") else str(index + 1)) * 8 + "-1111-2222-3333-444444444444"
                text += f"UUID: {identifier} ({architecture}) fixture\n"
            return text.encode(), b""
        if args[:2] == ["codesign", "-d"]:
            ipad = "/Payload/" in args[-1]
            authority = "Apple Distribution" if ipad else "Developer ID Application"
            return b"", f"Authority={authority}: Test Team ({TEAM})\nTeamIdentifier={TEAM}\nflags=0x10000(runtime)\n".encode()
        if args[0] == "xcodebuild" and "archive" in args:
            archive = Path(args[args.index("-archivePath") + 1])
            mac = args[args.index("-scheme") + 1] == "PadInkMac"
            app = archive / "Products/Applications/PadInk.app"
            app.mkdir(parents=True)
            settings = dict(argument.split("=", 1) for argument in args if "=" in argument)
            self.archive_architectures[str(archive)] = settings["ARCHS"].split()
            info = {"FixtureArchitectures": settings["ARCHS"].split(), "PadInkBuildVariant": settings["PADINK_BUILD_VARIANT"], "CFBundleName": "PadInk", "CFBundleDisplayName": "PadInk", "CFBundleExecutable": "PadInk", "CFBundleIdentifier": settings["PADINK_MAC_BUNDLE_ID" if mac else "PADINK_IPAD_BUNDLE_ID"],
                    "CFBundleShortVersionString": settings["MARKETING_VERSION"], "CFBundleVersion": settings["CURRENT_PROJECT_VERSION"],
                    "PadInkSourceCommit": settings["PADINK_SOURCE_COMMIT"], "PadInkSourceRevision": settings["PADINK_SOURCE_REVISION"],
                    "PadInkSourceDigest": settings["PADINK_SOURCE_SHA256"], "PadInkReleaseChannel": settings["PADINK_RELEASE_CHANNEL"],
                    "PadInkDistribution": settings["PADINK_DISTRIBUTION"]}
            if mac:
                (app / "Contents/MacOS").mkdir(parents=True)
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                (app / "Contents/MacOS/PadInk").write_text("fake binary")
            else:
                (app / "Info.plist").write_bytes(plistlib.dumps(info))
                (app / "PadInk").write_text("fake binary")
                (app / "embedded.mobileprovision").write_text("fake profile")
            (archive / "dSYMs" / (app.name + ".dSYM")).mkdir(parents=True)
        if args[0] == "xcodebuild" and "-exportArchive" in args:
            options = plistlib.loads(Path(args[args.index("-exportOptionsPlist") + 1]).read_bytes())
            if options["destination"] != "export" or options["method"] != "app-store-connect":
                raise AssertionError("IPA must export locally, never upload")
            archive = Path(args[args.index("-archivePath") + 1])
            app = next((archive / "Products/Applications").glob("*.app"))
            export = Path(args[args.index("-exportPath") + 1]); export.mkdir(parents=True)
            with zipfile.ZipFile(export / "PadInk.ipa", "w") as zipped:
                for path in app.rglob("*"):
                    if path.is_file(): zipped.write(path, "Payload/" + app.name + "/" + str(path.relative_to(app)))
        if args[0] == "ditto":
            if args[1:3] == ["-x", "-k"]:
                with zipfile.ZipFile(args[3]) as archive: archive.extractall(args[4])
            else:
                app, destination = Path(args[-2]), Path(args[-1])
                with zipfile.ZipFile(destination, "w") as archive:
                    for path in app.rglob("*"):
                        if path.is_file(): archive.write(path, app.name + "/" + str(path.relative_to(app)))
        return b"{}", b""


class ReleaseFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        for folder in ("engineering/scripts", "Config", "Sources", "docs", "Hosts/Mac"):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "engineering/scripts/build-identity.py", self.root / "engineering/scripts/build-identity.py")
        (self.root / "engineering/scripts/generate-project.py").write_text("# fixture generator\n")
        (self.root / "Config/Version.xcconfig").write_text("MARKETING_VERSION = 0.3.0\nCURRENT_PROJECT_VERSION = 1\nPADINK_RELEASE_CHANNEL = development\nPADINK_DISTRIBUTION = developer\n")
        (self.root / "Sources/test.swift").write_text("let original = true\n")
        (self.root / "Hosts/Mac/PadInkMac.entitlements").write_bytes(plistlib.dumps({"com.apple.security.automation.apple-events": True}))
        (self.root / ".gitignore").write_text("build/\nConfig/*.local.xcconfig\n")
        for relative in module.PUBLIC_DOCS:
            (self.root / relative).parent.mkdir(parents=True, exist_ok=True)
            (self.root / relative).write_text("# Fixture doc\n\n[Guide](" + ("docs/" if relative == "README.md" else "../docs/" if relative == "engineering/README.md" else "") + "使用者安装指南.md)\n")
        self.git("init", "-q"); self.git("config", "user.email", "test@example.invalid"); self.git("config", "user.name", "Fixture")
        self.git("add", "-A"); self.git("commit", "-qm", "fixture")
        (self.root / "Config/Release.local.xcconfig").write_text(CONFIG)
        self.output = self.root / "build/rc/candidate"

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.PIPE).decode()

    def prepare(self, preview=False, notes=None):
        return module.prepare(self.root, self.output, preview=preview, notes=notes)

    def both_platforms(self, notes_text="# 本次候选\n\n[Guide](docs/使用者安装指南.md)\n"):
        notes = self.root / "build/notes.md"
        notes.parent.mkdir(exist_ok=True)
        notes.write_text(notes_text)
        self.prepare(notes=notes)
        run = FakeAppleTools()
        module.build_platform(self.root, self.output, "mac", run)
        module.build_platform(self.root, self.output, "ipad", run)
        return run

    def test_missing_or_duplicate_architecture_blocks_complete_release(self):
        run = self.both_platforms()
        manifest, _ = module.check(self.root, self.output)
        intel = next(a for a in manifest['assets'] if a.get('architecture') == 'x86_64')
        manifest['assets'].remove(intel)
        (self.output / intel['path']).unlink()
        module.write_manifest(self.output, manifest)
        with self.assertRaises(module.ReleaseError): module.check(self.root, self.output, require_assets=True)
        public = self.root / 'build/incomplete-public'
        with self.assertRaises(module.ReleaseError): module.public_assets(self.root, self.output, public, runner=run)
        self.assertFalse(public.exists())
        arm = next(a for a in manifest['assets'] if a.get('architecture') == 'arm64')
        with self.assertRaises(module.ReleaseError): module.verify_mac_zip(self.root, self.output / arm['path'], manifest, arm['bundleID'], TEAM, run, 'x86_64')

    def test_source_identity_loading_is_read_only_without_bytecode_files(self):
        initial = self.git("status", "--porcelain")
        module.source_snapshot(self.root)
        module.source_snapshot(self.root)
        self.assertEqual(self.git("status", "--porcelain"), initial)
        self.assertFalse(list(self.root.rglob("__pycache__")))

    def test_dirty_tree_requires_explicit_preview_and_contains_current_source(self):
        (self.root / "Sources/test.swift").write_text("let changed = true\n")
        with self.assertRaises(module.ReleaseError): self.prepare()
        self.prepare(preview=True)
        manifest, verified = module.check(self.root, self.output)
        self.assertEqual(manifest["release"]["mode"], "unsigned-working-tree-preview")
        self.assertFalse(verified)
        self.assertFalse(manifest["distribution"]["endUserDistributable"])
        archive = self.output / manifest["assets"][0]["path"]
        self.assertIn("UNSIGNED-WORKING-TREE-PREVIEW", archive.name)
        with zipfile.ZipFile(archive) as zipped:
            name = next(name for name in zipped.namelist() if name.endswith("Sources/test.swift"))
            self.assertEqual(zipped.read(name), b"let changed = true\n")
            self.assertFalse(any("Release.local" in name for name in zipped.namelist()))

    def test_preview_cannot_enter_signed_release_commands(self):
        self.prepare(preview=True)
        run = FakeAppleTools()
        for platform in ("mac", "ipad"):
            with self.assertRaises(module.ReleaseError): module.build_platform(self.root, self.output, platform, run)
        self.assertEqual(run.calls, [])
        with self.assertRaises(module.ReleaseError): module.public_assets(self.root, self.output, self.root / "build/public", runner=run)

    def test_frozen_source_change_blocks_before_any_signing_or_apple_call(self):
        self.prepare()
        (self.root / "Sources/test.swift").write_text("let changed = true\n")
        run = FakeAppleTools()
        with self.assertRaises(module.ReleaseError): module.build_platform(self.root, self.output, "mac", run)
        self.assertEqual(run.calls, [])

    def test_old_source_zip_rehashed_in_manifest_is_still_rejected(self):
        self.prepare()
        manifest, _ = module.check(self.root, self.output)
        path = self.output / manifest["assets"][0]["path"]
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("old/SOURCE_COMMIT", "a" * 40)
            archive.writestr("old/SOURCE_PROVENANCE.json", json.dumps(manifest["source"]))
        module.write_manifest(self.output, manifest)
        with self.assertRaises(module.ReleaseError): module.check(self.root, self.output)

    def test_notes_tampering_and_undeclared_diagnostics_are_rejected(self):
        self.prepare()
        original = (self.output / "RELEASE_NOTES.md").read_bytes()
        (self.output / "RELEASE_NOTES.md").write_text("changed")
        with self.assertRaises(module.ReleaseError): module.check(self.root, self.output)
        (self.output / "RELEASE_NOTES.md").write_bytes(original)
        (self.output / "diagnostics.json").write_text("private")
        with self.assertRaises(module.ReleaseError): module.check(self.root, self.output)

    def test_notes_are_generated_when_no_repository_notes_file_exists(self):
        self.assertFalse((self.root / "docs/RELEASE_NOTES.md").exists())
        self.assertNotIn("docs/EVIDENCE.md", module.PUBLIC_DOCS)
        self.prepare()
        manifest, _ = module.check(self.root, self.output)
        self.assertEqual(manifest["releaseNotes"]["status"], "draft")
        self.assertIn("正式说明待补充", (self.output / "RELEASE_NOTES.md").read_text())

    def test_explicit_notes_are_required_to_exist_and_frozen_at_prepare(self):
        notes = self.root / "build/notes.md"
        with self.assertRaises(module.ReleaseError):
            module.prepare(self.root, self.output, notes=notes)
        self.assertFalse(self.output.exists())
        notes.parent.mkdir(exist_ok=True)
        notes.write_text("# 本次发布\n\n[安装指南](docs/使用者安装指南.md)\n")
        module.prepare(self.root, self.output, notes=notes)
        manifest, _ = module.check(self.root, self.output)
        self.assertEqual(manifest["releaseNotes"]["status"], "provided")
        self.assertEqual((self.output / "RELEASE_NOTES.md").read_bytes(), notes.read_bytes())

    def test_tracked_private_certificate_is_not_packaged_even_in_preview(self):
        (self.root / "secret.p8").write_text("do not ship")
        with self.assertRaises(module.ReleaseError): self.prepare(preview=True)
        self.assertFalse(self.output.exists())

    def test_paid_credentials_are_required_before_archive(self):
        self.prepare()
        run = FakeAppleTools(no_credentials=True)
        with self.assertRaises(module.ReleaseError): module.build_platform(self.root, self.output, "mac", run)
        self.assertEqual(len(run.calls), 1)
        self.assertFalse(any(asset["role"] == "end-user-mac" for asset in module.check(self.root, self.output)[0]["assets"]))

    def test_mac_and_ipad_commands_preserve_identity_symbols_and_export_only(self):
        run = self.both_platforms()
        manifest, verified = module.check(self.root, self.output, require_assets=True, verify_platform=True, runner=run)
        self.assertTrue(verified)
        self.assertFalse(manifest["release"]["published"])
        mac = next(asset for asset in manifest["assets"] if asset["role"] == "end-user-mac")
        self.assertEqual(set(mac["debugSymbols"]["uuidByArchitecture"]), {mac["architecture"]})
        self.assertEqual({a["architecture"] for a in manifest["assets"] if a["role"] == "end-user-mac"}, {"arm64", "x86_64"})
        builds = [call for call in run.calls if call[0] == "xcodebuild" and "archive" in call]
        self.assertEqual(len(builds), 3)
        for build in builds:
            self.assertIn("PADINK_SOURCE_REVISION=" + manifest["source"]["head"], build)
            self.assertIn("PADINK_SOURCE_SHA256=" + manifest["source"]["sourceSHA256"], build)
            self.assertIn("DEBUG_INFORMATION_FORMAT=dwarf-with-dsym", build)
        self.assertIn("ARCHS=arm64", builds[0])
        self.assertIn("ARCHS=x86_64", builds[1])
        for asset in manifest["assets"]:
            if asset["role"] in ("end-user-mac", "maintainer-testflight-upload-candidate"):
                with zipfile.ZipFile(self.output / asset["path"]) as archive:
                    prefix = "PadInk.app/" if asset["role"] == "end-user-mac" else "Payload/PadInk.app/"
                    self.assertTrue(all(name.startswith(prefix) for name in archive.namelist()))
        self.assertFalse(any("upload" in call or "altool" in call for call in run.calls))
        staple = next(index for index, call in enumerate(run.calls) if call[:3] == ["xcrun", "stapler", "staple"])
        final_zip = next(index for index, call in enumerate(run.calls) if call[0] == "ditto" and call[-1].endswith("arm64-DeveloperID-notarized.zip") and "-c" in call)
        self.assertLess(staple, final_zip)
        with self.assertRaises(module.ReleaseError): module.check(self.root, self.output, require_distributable=True, runner=run)

    def test_notary_rejection_never_produces_mac_distribution_asset(self):
        self.prepare()
        run = FakeAppleTools(reject_notary=True)
        with self.assertRaises(module.ReleaseError): module.build_platform(self.root, self.output, "mac", run)
        manifest, _ = module.check(self.root, self.output)
        self.assertEqual(manifest["distribution"]["mac"], "not-built")
        self.assertFalse(list(self.output.glob("*notarized.zip")))
        self.assertFalse(any(call[:3] == ["xcrun", "stapler", "staple"] for call in run.calls))

    def test_old_ipad_app_filename_is_rejected_even_with_current_metadata(self):
        run = self.both_platforms()
        manifest, _ = module.check(self.root, self.output)
        asset = next(asset for asset in manifest["assets"] if asset["role"] == "maintainer-testflight-upload-candidate")
        old_path = self.root / "build/old-name.ipa"
        with zipfile.ZipFile(self.output / asset["path"]) as original, zipfile.ZipFile(old_path, "w") as changed:
            for name in original.namelist():
                changed.writestr(name.replace("Payload/PadInk.app/", "Payload/PadInk 0.3.app/"), original.read(name))
        with self.assertRaises(module.ReleaseError):
            module.verify_ipa_metadata(old_path, manifest, asset["bundleID"])
        with self.assertRaises(module.ReleaseError):
            module.verify_ipad_export(old_path, manifest, asset["bundleID"], TEAM, run)

    def test_mismatched_dsym_or_nonuniversal_mac_blocks_rc(self):
        self.prepare()
        with self.assertRaises(module.ReleaseError): module.build_platform(self.root, self.output, "mac", FakeAppleTools(bad_dsym=True), architecture="x86_64")
        shutil.rmtree(self.root / "build/rc-private-work")
        with self.assertRaises(module.ReleaseError): module.build_platform(self.root, self.output, "mac", FakeAppleTools(arm_only=True), architecture="x86_64")
        self.assertFalse(list(self.output.glob("*notarized.zip")))

    def test_public_staging_excludes_ipa_logs_configs_and_copies_frozen_docs(self):
        run = self.both_platforms()
        (self.root / "docs/使用者安装指南.md").write_text("uncommitted new documentation must not leak")
        public = self.root / "build/public"
        module.public_assets(self.root, self.output, public, runner=run)
        manifest = module.check_public(self.root, public, verify_platform=True, runner=run)
        self.assertFalse(list(public.rglob("*.ipa")))
        self.assertFalse(list(public.rglob("*.local.xcconfig")))
        self.assertFalse(list(public.rglob("*.log")))
        self.assertEqual((public / "docs/使用者安装指南.md").read_text(), "# Fixture doc\n\n[Guide](使用者安装指南.md)\n")
        self.assertIn("](docs/使用者安装指南.md)", (public / "RELEASE_NOTES.md").read_text())
        self.assertFalse(manifest["distribution"]["endUserDistributable"])
        self.assertEqual(len([asset for asset in manifest["assets"] if asset["role"] == "public-documentation"]), 13)
        self.assertTrue((public / "docs/使用教程.md").is_file())
        (public / "private.ipa").write_text("not public")
        with self.assertRaises(module.ReleaseError): module.check_public(self.root, public)

    def test_public_missing_guide_and_broken_local_links_fail_even_after_rehashing(self):
        run = self.both_platforms()
        public = self.root / "build/public"
        module.public_assets(self.root, self.output, public, runner=run)
        manifest = module.check_public(self.root, public)
        guide = public / "docs/使用者安装指南.md"
        guide.write_text("[Recovery](missing-recovery.md)\n")
        guide_asset = next(asset for asset in manifest["assets"] if asset["path"] == "docs/使用者安装指南.md")
        guide_asset["sha256"], guide_asset["byteCount"] = module.file_sha(guide), guide.stat().st_size
        def rehash():
            (public / "PUBLIC-MANIFEST.json").write_text(json.dumps(manifest))
            names = sorted(str(path.relative_to(public)) for path in public.rglob("*") if path.is_file() and path.name != "SHA256SUMS")
            (public / "SHA256SUMS").write_text("".join(module.file_sha(public / name) + "  " + name + "\n" for name in names))
        rehash()
        with self.assertRaises(module.ReleaseError): module.check_public(self.root, public)
        guide.unlink()
        manifest["assets"].remove(guide_asset)
        rehash()
        with self.assertRaises(module.ReleaseError): module.check_public(self.root, public)

    def test_public_notes_preserve_readme_links_and_rebase_only_known_docs(self):
        run = self.both_platforms(notes_text="# 发布说明\n\n[README](README.md)\n[Guide](使用者安装指南.md)\n")
        public = self.root / "build/public"
        module.public_assets(self.root, self.output, public, runner=run)
        module.check_public(self.root, public)
        notes = (public / "RELEASE_NOTES.md").read_text()
        self.assertIn("](README.md)", notes)
        self.assertNotIn("](docs/README.md)", notes)
        self.assertIn("](docs/使用者安装指南.md)", notes)

    def test_release_identity_cannot_change_between_two_platforms(self):
        self.prepare()
        module.build_platform(self.root, self.output, "mac", FakeAppleTools())
        (self.root / "Config/Release.local.xcconfig").write_text(CONFIG.replace("com.example.padink.ipad", "com.example.padink.changed"))
        run = FakeAppleTools()
        with self.assertRaises(module.ReleaseError): module.build_platform(self.root, self.output, "ipad", run)
        self.assertEqual(run.calls, [])


if __name__ == "__main__":
    unittest.main()
