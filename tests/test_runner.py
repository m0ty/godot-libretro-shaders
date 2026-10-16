"""Regression checks for failures that must never pass the release test gate."""

import importlib.util
import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


RUNNER_PATH = Path(__file__).with_name("run_tests.py")
SPEC = importlib.util.spec_from_file_location("shader_test_runner", RUNNER_PATH)
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


class OutputAssessmentTests(unittest.TestCase):
    def test_success_requires_reported_checks(self):
        result = runner.assess_output("Shader importer: 14 checks, 0 failures\n", 0)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["checks"], 14)
        self.assertEqual(result["failures"], 0)

    def test_nonzero_exit_overrides_success_summary(self):
        result = runner.assess_output("Shader importer: 14 checks, 0 failures\n", 2)
        self.assertEqual(result["status"], "fail")
        self.assertTrue(result["reason"])

    def test_script_errors_fail_even_when_godot_exits_zero(self):
        output = (
            "SCRIPT ERROR: Invalid call. Nonexistent function in base 'Node'.\n"
            "Shader importer: 14 checks, 0 failures\n"
        )
        self.assertEqual(runner.assess_output(output, 0)["status"], "fail")

    def test_shader_errors_fail_even_when_godot_exits_zero(self):
        output = "SHADER ERROR: Unknown identifier in expression.\nShader importer: 14 checks, 0 failures\n"
        self.assertEqual(runner.assess_output(output, 0)["status"], "fail")

    def test_known_certificate_warning_is_retained_separately(self):
        warning = "ERROR: Failed to read the root certificate store."
        output = warning + "\nShader importer: 14 checks, 0 failures\n"
        result = runner.assess_output(output, 0)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["environment_warnings"], [warning])

    def test_certificate_warning_does_not_hide_unexpected_errors(self):
        warning = "ERROR: Failed to read the root certificate store."
        output = warning + "\nERROR: Cannot create render target.\nShader importer: 14 checks, 0 failures\n"
        result = runner.assess_output(output, 0)
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["environment_warnings"], [warning])
        unexpected = "ERROR: Failed to read the root certificate store: access denied.\nShader importer: 14 checks, 0 failures\n"
        self.assertEqual(runner.assess_output(unexpected, 0)["status"], "fail")

    def test_clean_diagnostics_require_scanned_scripts(self):
        result = runner.assess_output("GDScript diagnostics: 24 scripts, 0 warnings/errors.\n", 0, evidence="diagnostics")
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["checks"], 24)
        self.assertEqual(result["failures"], 0)

    def test_incomplete_or_failed_diagnostics_do_not_pass(self):
        for output in (
            "GDScript diagnostics: 24 scripts, 1 warnings/errors.\n",
            "GDScript diagnostics: 0 scripts, 0 warnings/errors.\n",
            "Language server started\n",
        ):
            with self.subTest(output=output):
                self.assertEqual(runner.assess_output(output, 0, evidence="diagnostics")["status"], "fail")

    def test_empty_or_zero_check_runs_do_not_pass(self):
        for output in ("Godot Engine started\n", "Shader importer: 0 checks, 0 failures\n"):
            with self.subTest(output=output):
                self.assertEqual(runner.assess_output(output, 0)["status"], "fail")

    def test_later_success_cannot_hide_an_earlier_failed_summary(self):
        output = "First suite: 12 checks, 1 failures\nSecond suite: 8 checks, 0 failures\n"
        result = runner.assess_output(output, 0)
        self.assertEqual(result["status"], "fail")
        self.assertGreater(result["failures"], 0)

    def test_unittest_success_requires_nonempty_test_execution(self):
        output = "....\n----------------------------------------------------------------------\nRan 4 tests in 0.012s\n\nOK\n"
        result = runner.assess_output(output, 0, evidence="unittest")
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["checks"], 4)
        self.assertEqual(result["failures"], 0)
        for invalid in ("Ran 0 tests in 0.000s\n\nOK\n", "Ran 4 tests in 0.012s\n\nFAILED (failures=1)\n"):
            with self.subTest(output=invalid):
                self.assertEqual(runner.assess_output(invalid, 0, evidence="unittest")["status"], "fail")

    def test_unittest_failure_reports_summary_and_executed_count(self):
        output = "...F\nRan 4 tests in 0.012s\n\nFAILED (failures=1)\n"
        for exit_code in (0, 1):
            with self.subTest(exit_code=exit_code):
                result = runner.assess_output(output, exit_code, evidence="unittest")
                self.assertEqual(result["status"], "fail")
                self.assertEqual(result["checks"], 4)
                self.assertEqual(result["reason"], "Unittest reported FAILED (failures=1)")

    def test_unittest_missing_summary_preserves_process_error(self):
        result = runner.assess_output("Python could not start tests\n", 2, evidence="unittest")
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["reason"], "Process exited 2")


class StageExecutionTests(unittest.TestCase):
    def test_timeout_fails_and_preserves_partial_output(self):
        command = [
            sys.executable,
            "-u",
            "-c",
            "import time; print('stage started', flush=True); time.sleep(30)",
        ]
        with tempfile.TemporaryDirectory(prefix="shader-runner-test-") as temporary:
            output_dir = Path(temporary)
            result = runner.run_stage(
                "timeout fixture", command, output_dir, timeout=0.5,
                environment=os.environ.copy(),
            )
            self.assertEqual(result["status"], "fail")
            self.assertRegex(result["reason"].lower(), r"time(?:d out|out)")
            log = Path(result.get("log_path", result.get("log", "")))
            if not log.is_absolute():
                log = output_dir / log
            self.assertTrue(log.is_file(), "A timed-out stage must retain its log")
            self.assertIn("stage started", log.read_text(encoding="utf-8"))


class ReportDestinationTests(unittest.TestCase):
    def test_source_destinations_are_rejected_without_mutation(self):
        with tempfile.TemporaryDirectory(prefix="shader-runner-destination-") as temporary:
            root = Path(temporary).resolve() / "repo"
            (root / "tests").mkdir(parents=True)
            source = root / "tests/test_fixture.gd"
            source.write_text("extends Node\n", encoding="utf-8")
            before = set(root.rglob("*"))
            for relative in (".", "tests", "tests/invalid", "tools/invalid", "addons/retroarch_shaders/invalid"):
                with self.subTest(relative=relative), mock.patch.object(runner, "ROOT", root), \
                        mock.patch.object(runner.shutil, "which", return_value=sys.executable), \
                        mock.patch.object(runner, "run_stage") as run_stage, contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as stopped:
                        runner.main(["--output-dir", str(root / relative)])
                    self.assertEqual(stopped.exception.code, 2)
                    run_stage.assert_not_called()
                    self.assertEqual(set(root.rglob("*")), before)
                    self.assertEqual(source.read_text(encoding="utf-8"), "extends Node\n")

    def test_generated_and_external_destinations_only_mark_the_report_directory(self):
        for relative in ("repo/test-results", "repo/test-results/run", "repo/build", "repo/build/run", "external/run"):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory(prefix="shader-runner-destination-") as temporary:
                folder = Path(temporary).resolve()
                root = folder / "repo"
                root.mkdir()
                output = folder / relative
                with mock.patch.object(runner, "ROOT", root), \
                        mock.patch.object(runner.shutil, "which", return_value=sys.executable), \
                        mock.patch.object(runner, "SUITES", ()), \
                        mock.patch.object(runner, "run_stage", return_value={"name":"fixture", "status":"pass", "checks":1}), \
                        contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(runner.main(["--output-dir", str(output)]), 0)
                self.assertTrue((output / ".gdignore").is_file())
                self.assertTrue((output / "summary.json").is_file())
                self.assertFalse((output.parent / ".gdignore").exists())
                self.assertFalse((root / ".gdignore").exists())


if __name__ == "__main__":
    unittest.main()
