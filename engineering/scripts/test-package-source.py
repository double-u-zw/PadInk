#!/usr/bin/env python3
import importlib.util, subprocess, tempfile, unittest, zipfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("package_source", Path(__file__).with_name("package-source.py"))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.git("init", "-q"); self.git("config", "user.email", "test@example.invalid"); self.git("config", "user.name", "test")
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "scripts/generate-project.py").write_text("MARKETING_VERSION='0.3.0'")
        (self.root / "file.swift").write_text("original")
        self.git("add", "-A"); self.git("commit", "-qm", "source")
        self.commit = self.git("rev-parse", "HEAD").strip()
    def tearDown(self): self.tmp.cleanup()
    def git(self, *args): return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True, text=True).stdout
    def test_archive_uses_selected_commit_and_preserves_provenance(self):
        (self.root / "scripts/generate-project.py").write_text("MARKETING_VERSION='9.9.9'")
        (self.root / "file.swift").write_text("dirty")
        (self.root / "Config").mkdir(); (self.root / "Config/Signing.local.xcconfig").write_text("local")
        out = module.package(self.root, self.commit)
        self.assertTrue(out.name.startswith("PadInk-0.3.0-"))
        with zipfile.ZipFile(out) as z:
            prefix = f"PadInk-0.3.0-{self.commit[:12]}/"
            self.assertEqual(z.read(prefix + "SOURCE_COMMIT").decode().strip(), self.commit)
            self.assertEqual(z.read(prefix + "file.swift"), b"original")
            self.assertFalse(any("Signing.local" in n or "/build/" in n for n in z.namelist()))
    def test_version_comes_from_selected_commits_version_config(self):
        (self.root / "Config").mkdir()
        (self.root / "Config/Version.xcconfig").write_text("MARKETING_VERSION = 0.3.7\nCURRENT_PROJECT_VERSION = 9\n")
        (self.root / "scripts/generate-project.py").write_text("# Version supplied by xcconfig\n")
        self.git("add", "-A"); self.git("commit", "-qm", "centralized version")
        selected = self.git("rev-parse", "HEAD").strip()
        (self.root / "Config/Version.xcconfig").write_text("MARKETING_VERSION = 9.9.9\n")
        self.assertTrue(module.package(self.root, selected).name.startswith("PadInk-0.3.7-"))

    def test_tracked_local_signing_material_is_rejected(self):
        (self.root / "Config").mkdir(); (self.root / "Config/Signing.local.xcconfig").write_text("local")
        self.git("add", "-A"); self.git("commit", "-qm", "bad config")
        with self.assertRaises(ValueError): module.package(self.root, "HEAD")
        self.assertFalse((self.root / "build").exists())
    def test_unresolvable_commit_does_not_create_archive(self):
        with self.assertRaises(subprocess.CalledProcessError): module.package(self.root, "missing")
        self.assertFalse((self.root / "build").exists())
if __name__ == "__main__": unittest.main()
