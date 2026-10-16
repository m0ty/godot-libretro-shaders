"""Release archive integrity, reproducibility and failure-boundary regressions."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "addons/retroarch_shaders/tools/build_package.py"
SPEC = importlib.util.spec_from_file_location("shader_package", BUILDER)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)
CHECK_SPEC = importlib.util.spec_from_file_location("shader_release_check", ROOT / "tools/check_release.py")
CHECK_RELEASE = importlib.util.module_from_spec(CHECK_SPEC)
CHECK_SPEC.loader.exec_module(CHECK_RELEASE)


class PackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="shader-package-")
        self.addCleanup(temporary.cleanup)
        # Windows TEMP may use an 8.3 alias. Match the builder's resolved paths
        # so containment checks and mocked filesystem operations see one spelling.
        self.folder = Path(temporary.name).resolve()
        self.source = self.folder / "source"
        self.output = self.folder / "release"
        self.archive = self.folder / "release.zip"
        for name in PACKAGE.REQUIRED_FILES:
            self.write_source(name, f"fixture: {name}\n")
        self.write_source("VERSION", "1.0.0\n")
        self.write_source("tools/build_package.py", BUILDER.read_text(encoding="utf-8"))
        self.write_source("demo/demo.gd.uid", "uid://fixture\n")
        self.write_source("docs/USAGE.md", "Usage fixture.\n")
        self.write_source("compatibility.json", '{"fixture": true}\n')
        self.write_source("future_module.gd", "extends RefCounted\n")

    def write_source(self, name, contents):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def build(self):
        return PACKAGE.build_package(self.output, self.source)

    def assert_no_release(self):
        self.assertFalse(self.output.exists())
        self.assertFalse(self.archive.exists())
        self.assertEqual(list(self.folder.glob(".retroarch-package-*")), [])

    def test_package_is_self_contained_and_reproducible(self):
        (self.folder / "host-game-secret.txt").write_text("Not part of the add-on.")
        output, archive, count = self.build()
        for source in PACKAGE.package_files(self.source):
            os.utime(source, (1234567890, 1234567890))
        _, second_archive, second_count = PACKAGE.build_package(self.folder / "another-name", self.source)
        self.assertEqual(archive.read_bytes(), second_archive.read_bytes())
        self.assertEqual(count, second_count)
        self.assertEqual(PACKAGE.verify_package(output), count)
        self.assertEqual(PACKAGE.verify_package(archive), count)
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertNotIn("host-game-secret.txt", manifest)
        self.assertIn("addons/retroarch_shaders/future_module.gd", manifest)
        self.assertIn("addons/retroarch_shaders/demo/demo.gd.uid", manifest)
        self.assertIn("addons/retroarch_shaders/docs/USAGE.md", manifest)
        self.assertEqual((output / "VERSION").read_bytes(), (self.source / "VERSION").read_bytes())
        self.assertIn("addons/retroarch_shaders/README.md", (output / "README.md").read_text())
        self.assertNotIn(b"\r\n", (output / "project.godot").read_bytes())
        with zipfile.ZipFile(archive) as bundle:
            for info in bundle.infolist():
                self.assertEqual(info.date_time, (2026, 1, 1, 0, 0, 0))
                self.assertEqual(info.create_system, 3)
                self.assertEqual(info.external_attr >> 16, 0o100644)
                self.assertEqual(info.compress_type, zipfile.ZIP_DEFLATED)

    def test_generated_artifacts_do_not_ship(self):
        for name in (".git/config", ".godot/cache.bin", "tools/__pycache__/tool.pyc",
                     "test-results/report.json", "build/release.zip", "dist/release.zip",
                     "demo/image.png.import", "tools/scratch.tmp", "tools/scratch.bak"):
            self.write_source(name, "generated")
        output, _, _ = self.build()
        manifest = (output / "manifest.json").read_text()
        for name in ("cache.bin", "tool.pyc", "report.json", "release.zip", "image.png.import", "scratch"):
            self.assertNotIn(name, manifest)

    def test_addon_archive_installs_without_root_files_or_wrapper(self):
        self.write_source("manifest.json", '{"obsolete": "manifest"}')
        output, archive, count = PACKAGE.build_package(self.output, self.source, package_format="addon")
        manifest_path = output / PACKAGE.ADDON_MANIFEST
        manifest = json.loads(manifest_path.read_text())
        self.assertNotIn(PACKAGE.ADDON_MANIFEST, manifest)
        self.assertEqual(list(output.iterdir()), [output / "addons"])
        self.assertEqual(PACKAGE.verify_package(output), count)
        self.assertEqual(PACKAGE.verify_package(archive), count)
        with zipfile.ZipFile(archive) as bundle:
            names = bundle.namelist()
            self.assertEqual(set(names), set(manifest) | {PACKAGE.ADDON_MANIFEST})
            self.assertTrue(all(name.startswith("addons/retroarch_shaders/") for name in names))
            for name in ("LICENSE", "VERSION", "README.md", "demo/demo.gd.uid", "docs/USAGE.md",
                         "tools/build_package.py", "future_module.gd"):
                member = "addons/retroarch_shaders/" + name
                self.assertEqual(bundle.read(member), (self.source / name).read_bytes())
                self.assertEqual(manifest[member], hashlib.sha256(bundle.read(member)).hexdigest())
        _, second, _ = PACKAGE.build_package(self.folder / "another-addon", self.source, package_format="addon")
        self.assertEqual(archive.read_bytes(), second.read_bytes())

    def test_addon_manifest_rejects_files_outside_addon(self):
        output, _, _ = PACKAGE.build_package(self.output, self.source, package_format="addon")
        (output / "project.godot").write_text("Unwanted host project")
        with self.assertRaisesRegex(ValueError, "may only contain files inside"):
            PACKAGE.verify_package(output)

    def test_reuse_identical_preserves_archive_bytes_and_timestamps(self):
        output, archive, count = PACKAGE.build_package(self.output, self.source, package_format="addon")
        timestamps = {path: path.stat().st_mtime_ns for path in PACKAGE.package_files(output) + [archive]}
        first_archive = archive.read_bytes()
        result = PACKAGE.build_package(self.output, self.source, package_format="addon", reuse_identical=True)
        self.assertEqual(result, (output, archive, count))
        self.assertEqual(first_archive, archive.read_bytes())
        self.assertEqual(timestamps, {path: path.stat().st_mtime_ns for path in timestamps})

    def test_reuse_refuses_changed_source_and_preserves_previous_release(self):
        self.build()
        first_archive = self.archive.read_bytes()
        self.write_source("future_module.gd", "extends Node\n")
        with self.assertRaisesRegex(ValueError, "differs from this build"):
            PACKAGE.build_package(self.output, self.source, reuse_identical=True)
        self.assertEqual(first_archive, self.archive.read_bytes())
        self.assertEqual((self.output / "addons/retroarch_shaders/future_module.gd").read_text(),
                         "extends RefCounted\n")

    def test_reuse_refuses_incomplete_or_tampered_artifacts(self):
        self.build()
        (self.output / "LICENSE").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            PACKAGE.build_package(self.output, self.source, reuse_identical=True)
        self.archive.unlink()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            PACKAGE.build_package(self.output, self.source, reuse_identical=True)
        self.assertFalse(self.archive.exists())

    def test_version_validation_and_repository_consistency(self):
        for version in ("not a version", "01.0.0", "1.0.0-01", "1.0.0-..", "1.0.0+."):
            with self.subTest(version=version):
                self.write_source("VERSION", version + "\n")
                with self.assertRaisesRegex(ValueError, "semantic release version"):
                    self.build()
        self.assert_no_release()
        self.source = self.folder / "addons/retroarch_shaders"
        self.write_source("VERSION", "1.0.0\n")
        (self.folder / "VERSION").write_text("0.1.0\n")
        with self.assertRaisesRegex(ValueError, "VERSION files differ"):
            PACKAGE.read_version(self.source)

    def test_addon_store_size_limit_failure_does_not_leave_outputs(self):
        with mock.patch.object(PACKAGE, "MAX_STORE_BYTES", 1):
            with self.assertRaisesRegex(ValueError, "1 GB"):
                PACKAGE.build_package(self.output, self.source, package_format="addon")
        self.assert_no_release()

    def test_build_directory_is_ignored_without_hiding_host_project(self):
        nested = self.folder / "addons/retroarch_shaders"
        nested.parent.mkdir()
        self.source.rename(nested)
        output = self.folder / "build/release"
        PACKAGE.build_package(output, nested, package_format="addon")
        self.assertTrue((self.folder / "build/.gdignore").is_file())
        self.assertFalse((self.folder / ".gdignore").exists())
        self.assertFalse((output / ".gdignore").exists())

    def test_in_project_outputs_outside_build_are_rejected_before_writing(self):
        nested = self.folder / "addons/retroarch_shaders"
        nested.parent.mkdir()
        self.source.rename(nested)
        before = {path.relative_to(self.folder): path.read_bytes() for path in PACKAGE.package_files(self.folder)}
        for name in ("tests/release", "docs/release", "new-release", "build"):
            with self.subTest(output=name):
                with self.assertRaisesRegex(ValueError, "subdirectory of build"):
                    PACKAGE.build_package(self.folder / name, nested)
                after = {path.relative_to(self.folder): path.read_bytes()
                         for path in PACKAGE.package_files(self.folder)}
                self.assertEqual(before, after)
                self.assertFalse((self.folder / name).exists())

    def test_release_check_rejects_source_outputs_and_reports_before_writing(self):
        nested = self.folder / "addons/retroarch_shaders"
        nested.parent.mkdir()
        self.source.rename(nested)
        (self.folder / "tests").mkdir()
        (self.folder / "tests/source_test.gd").write_text("extends SceneTree\n")
        before = {path.relative_to(self.folder): path.read_bytes() for path in PACKAGE.package_files(self.folder)}
        for output, report, message in (("tests/release", "test-results/package", "subdirectory of build"),
                                        ("build/release", "tests", "Reports inside the repository"),
                                        ("build/release", "docs/release", "Reports inside the repository")):
            with self.subTest(output=output, report=report):
                errors = io.StringIO()
                with mock.patch.object(CHECK_RELEASE, "ROOT", self.folder), \
                        mock.patch.object(CHECK_RELEASE, "ADDON", nested), \
                        mock.patch("sys.stderr", errors), self.assertRaises(SystemExit) as caught:
                    CHECK_RELEASE.main(["--godot", sys.executable, "--output-dir", output, "--report-dir", report])
                self.assertEqual(caught.exception.code, 2)
                self.assertIn(message, errors.getvalue())
                after = {path.relative_to(self.folder): path.read_bytes()
                         for path in PACKAGE.package_files(self.folder)}
                self.assertEqual(before, after)
                self.assertFalse((self.folder / "build").exists())
                self.assertFalse((self.folder / "tests/.gdignore").exists())

    def test_external_release_check_does_not_hide_the_output_parent(self):
        host = self.folder / "host"
        nested = host / "addons/retroarch_shaders"
        nested.parent.mkdir(parents=True)
        self.source.rename(nested)
        external = self.folder / "external"
        external.mkdir()
        unrelated_project = external / "project.godot"
        unrelated_project.write_text("Unrelated project must stay visible to Godot.")

        def build(output, **kwargs):
            return PACKAGE.build_package(output, nested, **kwargs)

        def smoke(name, *args):
            return {"name": name, "status": "pass", "checks": 1, "failures": 0}

        with mock.patch.object(CHECK_RELEASE, "ROOT", host), \
                mock.patch.object(CHECK_RELEASE, "ADDON", nested), \
                mock.patch.object(CHECK_RELEASE.BUILDER, "build_package", side_effect=build), \
                mock.patch.object(CHECK_RELEASE, "run_smoke", side_effect=smoke), \
                mock.patch("sys.stdout", io.StringIO()):
            result = CHECK_RELEASE.main(["--godot", sys.executable, "--format", "addon", "--output-dir",
                                         str(external / "release"), "--report-dir", str(external / "reports")])
        self.assertEqual(result, 0)
        self.assertFalse((external / ".gdignore").exists())
        self.assertFalse((external / "reports/.gdignore").exists())
        self.assertEqual(unrelated_project.read_text(), "Unrelated project must stay visible to Godot.")
        self.assertIn('config/version="1.0.0"', (external / "release-installed/project.godot").read_text())

    def test_standalone_project_uses_the_packaged_release_version(self):
        self.write_source("VERSION", "2.3.4-rc.1+build.5\n")
        output, _, _ = self.build()
        project = (output / "project.godot").read_text()
        self.assertIn('config/name="Libretro Shaders for Godot"', project)
        self.assertIn('config/version="2.3.4-rc.1+build.5"', project)
        self.assertIn("# Libretro Shaders for Godot", (output / "README.md").read_text())

    def test_addon_cli_can_build_verify_and_reuse_from_another_directory(self):
        builder = self.source / "tools/build_package.py"
        command = [sys.executable, "-B", str(builder), "--format", "addon", "--output-dir",
                   str(self.output), "--reuse-identical"]
        for _ in range(2):
            result = subprocess.run(command, cwd=self.folder, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Format: addon", result.stdout)
        result = subprocess.run([sys.executable, "-B", str(builder), "--verify", str(self.archive)],
                                cwd=self.folder, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(os.name == "nt", "Windows batch entry point")
    def test_batch_help_and_configured_python_from_another_directory(self):
        environment = dict(os.environ, PYTHON=sys.executable)
        result = subprocess.run([str(ROOT / "build.bat"), "--help"], cwd=self.folder,
                                env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--reuse-identical", result.stdout)
        self.assertIn("--format", result.stdout)

    @unittest.skipUnless(os.name == "nt", "Windows batch entry point")
    def test_batch_invalid_configured_python_fails_cleanly(self):
        environment = dict(os.environ, PYTHON=str(self.folder / "missing python.exe"))
        result = subprocess.run([str(ROOT / "build.bat"), "--help"], cwd=self.folder,
                                env=environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 1)
        self.assertIn("PYTHON must point to", result.stderr)

    def test_existing_outputs_are_preserved(self):
        for existing in (self.output, self.archive):
            with self.subTest(existing=existing.name):
                existing.write_text("existing release")
                with self.assertRaisesRegex(ValueError, "already exists"):
                    self.build()
                self.assertEqual(existing.read_text(), "existing release")
                existing.unlink()

    def test_nested_source_output_is_rejected(self):
        for output in (self.source, self.source / "new-release"):
            with self.subTest(output=output):
                with self.assertRaisesRegex(ValueError, "outside the source"):
                    PACKAGE.build_package(output, self.source)
        self.assertFalse((self.source / "new-release").exists())

    def test_missing_required_file_does_not_create_outputs(self):
        (self.source / "LICENSE").unlink()
        with self.assertRaisesRegex(ValueError, "LICENSE"):
            self.build()
        self.assert_no_release()

    def test_source_copy_failure_does_not_leave_partial_release(self):
        with mock.patch.object(PACKAGE.shutil, "copyfile", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.build()
        self.assert_no_release()

    def test_archive_failure_does_not_leave_partial_release(self):
        with mock.patch.object(PACKAGE, "write_archive", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.build()
        self.assert_no_release()

    def test_publish_failure_rolls_back_both_outputs(self):
        original = PACKAGE.shutil.copyfile
        copied = []

        def fail_during_publication(source, destination):
            if self.output in destination.parents:
                if copied:
                    raise OSError("disk full during publication")
                copied.append(destination)
            return original(source, destination)

        with mock.patch.object(PACKAGE.shutil, "copyfile", side_effect=fail_during_publication):
            with self.assertRaisesRegex(OSError, "disk full during publication"):
                self.build()
        self.assertEqual(len(copied), 1)
        self.assert_no_release()

    def test_publication_creates_fresh_files_instead_of_moving_staging_acls(self):
        staged_archive = self.folder / "staged.zip"
        staged_archive.write_bytes(b"fixture archive")
        source_files = {path.relative_to(self.source): path.read_bytes()
                        for path in PACKAGE.package_files(self.source)}
        with mock.patch.object(Path, "rename", side_effect=AssertionError("Do not move staging ACLs")):
            PACKAGE.publish_package(self.source, staged_archive, self.output, self.archive)
        for relative, contents in source_files.items():
            self.assertEqual((self.source / relative).read_bytes(), contents)
            self.assertEqual((self.output / relative).read_bytes(), contents)
        self.assertEqual(self.archive.read_bytes(), staged_archive.read_bytes())

    def test_archive_publication_failure_rolls_back_both_outputs(self):
        with mock.patch.object(PACKAGE.shutil, "copyfileobj", side_effect=OSError("locked")):
            with self.assertRaisesRegex(OSError, "locked"):
                PACKAGE.publish_package(self.source, self.source / "README.md", self.output, self.archive)
        self.assert_no_release()

    def test_concurrent_archive_creation_preserves_other_release(self):
        original = PACKAGE.publish_package

        def create_collision(project, staged_archive, output, archive):
            archive.write_bytes(b"other build")
            original(project, staged_archive, output, archive)

        with mock.patch.object(PACKAGE, "publish_package", side_effect=create_collision):
            with self.assertRaises(FileExistsError):
                self.build()
        self.assertFalse(self.output.exists())
        self.assertEqual(self.archive.read_bytes(), b"other build")

    def test_source_link_is_rejected(self):
        link = self.source / "outside.txt"
        target = self.folder / "outside.txt"
        target.write_text("host file")
        try:
            link.symlink_to(target)
        except OSError as error:
            self.skipTest(f"Symlink creation is unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "Links are not permitted"):
            self.build()
        self.assert_no_release()

    def test_windows_reparse_point_is_rejected(self):
        linked = self.source / "future_module.gd"
        original = Path.lstat

        def attributes(path):
            if path == linked:
                return type("Attributes", (), {"st_file_attributes": PACKAGE.stat.FILE_ATTRIBUTE_REPARSE_POINT})()
            return original(path)

        with mock.patch.object(Path, "lstat", attributes):
            with self.assertRaisesRegex(ValueError, "Links are not permitted"):
                self.build()
        self.assert_no_release()

    def test_directory_tampering_missing_and_extra_files_are_detected(self):
        output, _, _ = self.build()
        license_path = output / "LICENSE"
        original = license_path.read_bytes()
        license_path.write_text("changed")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch: LICENSE"):
            PACKAGE.verify_package(output)
        license_path.unlink()
        with self.assertRaisesRegex(ValueError, "missing: LICENSE"):
            PACKAGE.verify_package(output)
        license_path.write_bytes(original)
        (output / "unexpected.txt").write_text("extra")
        with self.assertRaisesRegex(ValueError, "extra: unexpected.txt"):
            PACKAGE.verify_package(output)

    def make_zip(self, members, manifest=None):
        if manifest is None:
            manifest = {name: hashlib.sha256(data).hexdigest() for name, data in members}
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "w") as bundle:
                for name, data in members:
                    bundle.writestr(name, data)
                bundle.writestr("manifest.json", json.dumps(manifest))

    def test_archive_tampering_is_detected(self):
        self.make_zip([("file.txt", b"changed")], {"file.txt": hashlib.sha256(b"original").hexdigest()})
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            PACKAGE.verify_package(self.archive)

    def test_duplicate_and_case_colliding_archive_paths_are_rejected(self):
        for name in ("file.txt", "FILE.txt"):
            with self.subTest(name=name):
                self.make_zip([("file.txt", b"one"), (name, b"two")])
                with self.assertRaisesRegex(ValueError, "Duplicate or case-colliding"):
                    PACKAGE.verify_package(self.archive)

    def test_unsafe_manifest_paths_are_rejected(self):
        for name in ("../outside", "/absolute", "C:/file", "folder\\file", "folder//file", "./file"):
            with self.subTest(name=name):
                self.make_zip([(name, b"payload")])
                with self.assertRaisesRegex(ValueError, "Invalid package path"):
                    PACKAGE.verify_package(self.archive)

    def test_malformed_manifest_is_rejected(self):
        for manifest in ([], {}, {"file": "not a digest"}, {"manifest.json": "0" * 64}):
            with self.subTest(manifest=manifest):
                self.make_zip([], manifest)
                with self.assertRaises(ValueError):
                    PACKAGE.verify_package(self.archive)
        duplicate = '{"file":"' + "0" * 64 + '","file":"' + "1" * 64 + '"}'
        with self.assertRaisesRegex(ValueError, "Duplicate manifest entry"):
            PACKAGE.validate_manifest(duplicate, ["file", "manifest.json"])

    def test_packaged_cli_verifies_directory_and_archive_without_host_project(self):
        output, archive, count = self.build()
        standalone_builder = output / "addons/retroarch_shaders/tools/build_package.py"
        for target in (output, archive):
            with self.subTest(target=target.name):
                result = subprocess.run([sys.executable, "-B", str(standalone_builder), "--verify", str(target)],
                                        cwd=self.folder, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Files: {count}", result.stdout)
        result = subprocess.run([sys.executable, "-B", str(standalone_builder), "--verify", "missing.zip"],
                                cwd=self.folder, capture_output=True, text=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Package error:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
