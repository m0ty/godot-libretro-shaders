"""Evidence checks for dependency support and portable shader audit summaries."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "addons/retroarch_shaders/tools"
SUMMARIZER = TOOLS / "summarize_audit.py"
SPEC = importlib.util.spec_from_file_location("shader_auditor", TOOLS / "audit_library.py")
AUDITOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDITOR)


class AuditEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="shader-audit-evidence-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.parent = dict(path="family/example.glslp", kind="preset", category="family", sha256="a" * 64,
                           status="translated", message="", reason_group="accepted", godot="fixture",
                           adapter="fixture", display="fixture")
        self.helper = dict(path="family/source.glsl", kind="source", category="family", sha256="b" * 64,
                           status="preset_required", message="Choose a matching preset.", reason_group="source_pass_context",
                           preset_candidates=["D:\\fixture\\glsl-shaders\\family\\example.glslp"])
        self.imports = dict(complete=True, source_unchanged=True, collection_unchanged=True,
                            collection_sha256="c" * 64, source_sha256="d" * 64, collection="D:/fixture/glsl-shaders",
                            finished_utc="fixture", settings=dict(render=False), scope="Synthetic regression fixture.",
                            results=[self.parent, self.helper])
        self.gpu = copy.deepcopy(self.imports)
        self.gpu["settings"] = dict(render=True, sizes="640x480,800x600", warmup_frames=12)
        self.gpu["results"][0]["status"] = "rendered"

    def summarize(self, extra=None, reference=None):
        paths = []
        for name, report in (("imports", self.imports), ("gpu", self.gpu)):
            path = self.folder / (name + ".json")
            path.write_text(json.dumps(report), encoding="utf-8")
            paths.append(path)
        command = [sys.executable, "-B", str(SUMMARIZER), "--imports", str(paths[0]), "--rendered", str(paths[1]),
                   "--output-dir", str(self.folder / "output")]
        if extra is not None:
            path = self.folder / "extra.json"
            path.write_text(json.dumps(extra), encoding="utf-8")
            command += ["--additional-rendered", str(path)]
        if reference is not None:
            path = self.folder / "reference.json"
            path.write_text(json.dumps(reference), encoding="utf-8")
            command += ["--crt-reference", str(path)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
        catalog = self.folder / "output/compatibility.json"
        return result, json.loads(catalog.read_text()) if catalog.exists() else None

    def test_dependency_requires_verified_parent_and_retains_direct_import_status(self):
        result, catalog = self.summarize()
        self.assertEqual(result.returncode, 0, result.stderr)
        case = catalog["cases"][1]
        self.assertEqual(case["status"], "supported_via_preset")
        self.assertEqual(case["import_status"], "preset_required")
        self.assertEqual(case["supported_presets"], ["family/example.glslp"])
        self.assertNotIn("D:", json.dumps(catalog))

    def test_unverified_parent_does_not_establish_helper_support(self):
        self.gpu["results"][0]["status"] = "review"
        result, catalog = self.summarize()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(catalog["cases"][1]["status"], "preset_required")

    def test_gpu_error_cannot_be_hidden_by_matching_parent(self):
        self.gpu["results"][1].update(status="error", message="SHADER ERROR: fixture")
        result, catalog = self.summarize()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(catalog["cases"][1]["status"], "error")

    def test_mismatched_runtime_evidence_is_rejected(self):
        self.gpu["source_sha256"] = "e" * 64
        result, catalog = self.summarize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(catalog)

    def test_changed_file_between_audits_is_rejected(self):
        self.gpu["results"][1]["sha256"] = "e" * 64
        result, catalog = self.summarize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(catalog)

    def test_incomplete_audit_is_rejected(self):
        self.imports["complete"] = False
        result, catalog = self.summarize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(catalog)

    def test_headless_report_cannot_establish_gpu_support(self):
        self.gpu["settings"]["render"] = False
        result, catalog = self.summarize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(catalog)

    def test_rendered_report_cannot_replace_import_evidence(self):
        self.imports["settings"]["render"] = True
        result, catalog = self.summarize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(catalog)

    def test_duplicate_gpu_case_cannot_hide_a_failure(self):
        failed = copy.deepcopy(self.gpu["results"][0])
        failed.update(status="error", message="SHADER ERROR: fixture")
        self.gpu["results"].insert(0, failed)
        result, catalog = self.summarize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(catalog)

    def test_duplicate_import_case_is_rejected(self):
        self.imports["results"].append(copy.deepcopy(self.parent))
        result, catalog = self.summarize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(catalog)

    def test_gpu_cases_must_belong_to_the_import_inventory(self):
        unimported = copy.deepcopy(self.gpu["results"][0])
        unimported["path"] = "family/other.glslp"
        self.gpu["results"].append(unimported)
        result, catalog = self.summarize()
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(catalog)

    def test_nested_repeat_diagnostics_are_portable(self):
        extra = copy.deepcopy(self.gpu)
        extra["results"] = [extra["results"][1]]
        extra["results"][0].update(status="error", message="Cannot read D:\\fixture\\glsl-shaders\\family\\image.png")
        result, catalog = self.summarize(extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("D:", json.dumps(catalog))
        self.assertIn("<collection>", catalog["cases"][1]["additional_rendered"][0]["message"])

    def test_duplicate_additional_case_is_rejected(self):
        extra = copy.deepcopy(self.gpu)
        extra["results"].append(copy.deepcopy(extra["results"][0]))
        result, catalog = self.summarize(extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(catalog)

    def test_historical_parent_does_not_establish_current_helper_support(self):
        self.parent.update(path="crt/example.glslp", category="crt")
        self.helper["preset_candidates"] = ["D:/fixture/glsl-shaders/crt/example.glslp"]
        self.gpu["results"] = [dict(self.helper, godot="fixture", adapter="fixture", display="fixture")]
        reference = dict(complete=True, source_unchanged=True, collection_unchanged=True,
                         results=[dict(preset="crt/example.glslp", sha256="a" * 64,
                                       ok=True, render=dict(status="passed"))])
        result, catalog = self.summarize(reference=reference)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(catalog["cases"][0]["status"], "previously_rendered")
        self.assertEqual(catalog["cases"][1]["status"], "preset_required")

    def test_conditional_source_evidence_preserves_standard_review(self):
        self.imports["results"][1]["status"] = "translated"
        self.gpu["results"][1]["status"] = "review"
        extra = copy.deepcopy(self.gpu)
        extra["results"] = [extra["results"][1]]
        extra["results"][0].update(status="rendered", render_conditions=dict(sizes=[[960,720]], warmup_frames=120, input_size=[320,240]))
        result, catalog = self.summarize(extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(catalog["cases"][1]["status"], "rendered_conditional")
        self.assertEqual(catalog["cases"][1]["standard_render_status"], "review")

    def data_fixture(self):
        for report in (self.imports,self.gpu):
            report["results"][0]["path"] = "xbr/2xBR-lv1-multipass.glslp"
            report["results"][1].update(path="xbr/shaders/2xBR-multipass/2xbr-lv1-c-pass0.glsl",
                                         sha256="7ce3002873c2d988f0e4cff99b52a2b9a3953bf1b153c6f925f77fb59506f44a")
        self.imports["results"][1]["status"] = "translated"
        self.gpu["results"][1]["status"] = "review"

    def test_known_data_pass_requires_parent_and_preserves_standalone_review(self):
        self.data_fixture()
        result, catalog = self.summarize()
        self.assertEqual(result.returncode, 0, result.stderr)
        case = catalog["cases"][1]
        self.assertEqual(case["status"], "supported_via_preset")
        self.assertEqual(case["import_status"], "translated")
        self.assertEqual(case["standard_render_status"], "review")
        self.assertEqual(case["supported_presets"], ["xbr/2xBR-lv1-multipass.glslp"])

    def test_data_pass_cannot_claim_support_with_unverified_parent(self):
        self.data_fixture()
        self.gpu["results"][0]["status"] = "review"
        result, catalog = self.summarize()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(catalog["cases"][1]["status"], "review")

    def test_changed_data_source_does_not_receive_known_context(self):
        self.data_fixture()
        for report in (self.imports,self.gpu):
            report["results"][1]["sha256"] = "f" * 64
        result, catalog = self.summarize()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(catalog["cases"][1]["status"], "review")


class AuditProbeTests(unittest.TestCase):
    """Exercise process/result boundaries without launching a GPU process."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="shader-audit-probe-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.shader = self.folder / "fixture.glsl"
        self.shader.write_text("void main() {}", encoding="utf-8")
        self.output = self.folder / "output"
        for name in ("cases", "logs"):
            (self.output / name).mkdir(parents=True)
        self.result_path = self.output / "cases/0000.json"
        self.args = type("Arguments", (), dict(godot="fixture", shader_dir=self.folder,
                                             render=False, timeout=1))()

    def probe(self, status=None, log="", returncode=0):
        def run(command, **kwargs):
            self.assertFalse(self.result_path.exists(), "Remove stale evidence before launching Godot")
            if status is not None:
                self.result_path.write_text(json.dumps(dict(status=status, message="")), encoding="utf-8")
            kwargs["stdout"].write(log.encode("utf-8"))
            return subprocess.CompletedProcess(command, returncode)

        with mock.patch.object(AUDITOR.subprocess, "run", side_effect=run):
            return AUDITOR.probe(0, self.shader, self.args, ROOT, self.output)

    def test_stale_result_cannot_turn_a_failed_process_into_a_pass(self):
        self.result_path.write_text(json.dumps(dict(status="rendered", message="")), encoding="utf-8")
        result = self.probe()
        self.assertEqual(result["status"], "error")
        self.assertIn("without a case result", result["message"])

    def test_engine_error_invalidates_dependency_discovery(self):
        result = self.probe(status="preset_required", log="SCRIPT ERROR: fixture\n")
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["diagnostic"], "SCRIPT ERROR: fixture\n")

    def test_environment_warnings_remain_separate_from_shader_results(self):
        result = self.probe(status="translated", log=(
            "ERROR: Failed to read the root certificate store.\n"
            'ERROR: Condition "f.is_null()" is true.\n'
            '   at: _save_to_cache (drivers/gles3/shader_gles3.cpp:123)\n'))
        self.assertEqual(result["status"], "translated")
        self.assertEqual(len(result["environment_warnings"]), 2)


if __name__ == "__main__":
    unittest.main()
