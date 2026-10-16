"""Run the independent shader regressions with isolated fixtures and saved logs.

Python 3.10+ standard library only. Rendered checks require a working display/GPU.
An external libretro GLSL collection is optional and is never modified.
"""

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
SUITES = (
    "shader_addon", "glsl_importer", "glsl_buffers", "post_process",
    "multipass", "hyllian", "shader_compatibility", "shader_completion",
    "shader_importer_review", "shader_runtime_review", "shader_import_cache",
    "shader_declaration_order",
)
COUNTS = re.compile(r"(\d+) checks, (\d+) failures")
ERRORS = re.compile(r"SCRIPT ERROR:|SHADER ERROR:|^ERROR:|Shader compilation failed", re.MULTILINE)
CERTIFICATE_WARNING = "ERROR: Failed to read the root certificate store."


def assess_output(output, exit_code, evidence="checks"):
    """Require positive test evidence, including when an engine exits zero."""
    result = {"status": "fail", "exit_code": exit_code}
    # Some restricted Windows sessions lack the OS certificate store. These
    # local shader checks use no TLS; retain the exact diagnostic separately.
    if CERTIFICATE_WARNING in output:
        result["environment_warnings"] = [CERTIFICATE_WARNING]
        output = output.replace(CERTIFICATE_WARNING, "")
    if exit_code:
        result["reason"] = f"Process exited {exit_code}"
    elif ERRORS.search(output):
        result["reason"] = "Runtime error in log"
    if evidence == "checks":
        summaries = [tuple(map(int, match)) for match in COUNTS.findall(output)]
        if not summaries:
            result["reason"] = "Missing check-count summary"
        else:
            result["checks"], result["failures"] = summaries[-1]
            if any(failures for _, failures in summaries):
                result["failures"] = max(failures for _, failures in summaries)
                result["reason"] = "Suite reported failed checks"
            elif result["checks"] == 0:
                result["reason"] = "Suite reported zero checks"
    elif evidence == "unittest":
        summary = re.search(r"^Ran (\d+) tests? in ", output, re.MULTILINE)
        success = re.search(r"^OK(?: \(skipped=\d+\))?\s*$", output, re.MULTILINE)
        failure = re.search(r"^FAILED(?: \([^\r\n]*\))?\s*$", output, re.MULTILINE)
        if summary:
            result["checks"] = int(summary[1])
        if failure:
            result["reason"] = f"Unittest reported {failure[0].strip()}"
        elif not summary or int(summary[1]) == 0 or not success:
            result.setdefault("reason", "Missing successful unittest summary")
        else:
            result.update(checks=int(summary[1]), failures=0)
    elif evidence == "import":
        if "Godot Engine v" not in output:
            result["reason"] = "Missing Godot startup evidence"
    elif evidence == "diagnostics":
        summary = re.search(r"GDScript diagnostics: (\d+) scripts, (\d+) warnings/errors\.", output)
        if not summary or int(summary[1]) == 0 or int(summary[2]):
            result["reason"] = "Missing or unsuccessful GDScript diagnostics"
        else:
            result.update(checks=int(summary[1]), failures=0)
    else:
        raise ValueError(f"Unknown evidence type: {evidence}")
    if "reason" not in result:
        result["status"] = "pass"
    return result


def run_stage(name, command, output_dir, timeout, environment, evidence="checks"):
    """Run one owned process; retain its complete output on failure or timeout."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    log_path = output_dir / f"{name}.log"
    started = time.monotonic()
    try:
        with log_path.open("w", encoding="utf-8") as log:
            # Godot's console executable stays in this process; no shell is used.
            process = subprocess.Popen(command, cwd=ROOT, env=environment,
                                       stdout=log, stderr=subprocess.STDOUT,
                                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            try:
                exit_code = process.wait(timeout=timeout)
            except BaseException:
                process.kill()
                process.wait()
                raise
        result = assess_output(log_path.read_text(encoding="utf-8", errors="replace"), exit_code, evidence)
    except subprocess.TimeoutExpired:
        result = {"status": "fail", "reason": f"Timed out after {timeout:g}s"}
    except OSError as error:
        result = {"status": "fail", "reason": str(error)}
    result.update(name=name, command=list(map(str, command)), log=str(log_path),
                  elapsed_seconds=round(time.monotonic() - started, 3))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"), help="Godot executable (or GODOT_BIN)")
    parser.add_argument("--render", action="store_true", help="Also run real GPU checks after headless checks")
    parser.add_argument("--shader-dir", type=Path, help="Optional external glsl-shaders collection")
    parser.add_argument("--timeout", type=float, default=600, help="Seconds per stage (default: 600)")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "test-results/latest")
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    binary = shutil.which(args.godot)
    if binary is None:
        parser.error(f"Godot executable not found: {args.godot}")
    if args.shader_dir is not None:
        args.shader_dir = args.shader_dir.resolve()
        if not args.shader_dir.is_dir() or not any(args.shader_dir.rglob("*.glslp")):
            parser.error("--shader-dir must contain an external GLSL preset collection")
    output = args.output_dir.resolve()
    # Reports carry .gdignore; restrict in-project destinations so a typo
    # cannot hide source directories such as tests/ or tools/ from Godot.
    generated_roots = (ROOT / "test-results", ROOT / "build")
    if (output == ROOT or ROOT in output.parents) and not any(
            output == generated or generated in output.parents for generated in generated_roots):
        parser.error("Use test-results/ or build/ for reports inside the repository, or choose an external directory")
    output.mkdir(parents=True, exist_ok=True)
    (output / ".gdignore").touch()
    environment = dict(os.environ, PYTHONUTF8="1", PYTHONDONTWRITEBYTECODE="1")
    report = {"started_utc": datetime.now(timezone.utc).isoformat(), "render_requested": args.render,
              "shader_collection": str(args.shader_dir) if args.shader_dir else None, "results": []}

    def record(entry):
        report["results"].append(entry)
        report["status"] = "fail" if any(r["status"] == "fail" for r in report["results"]) else "pass"
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        detail = entry.get("reason", f"{entry.get('checks', 0)} checks")
        print(f"{entry['status'].upper():4} {entry['name']}: {detail}", flush=True)

    with tempfile.TemporaryDirectory(prefix="libretro-tests-") as temporary:
        # Legacy suites use TEMP; set all platform variants without touching user settings.
        environment.update(TEMP=temporary, TMP=temporary, TMPDIR=temporary)
        user_data = Path(temporary) / "userdata"
        user_data.mkdir()
        environment.update(APPDATA=str(user_data), LOCALAPPDATA=str(user_data),
                           XDG_DATA_HOME=str(user_data), XDG_CONFIG_HOME=str(user_data),
                           XDG_CACHE_HOME=str(user_data))
        record(run_stage("python", [sys.executable, "-B", "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py"],
                         output, args.timeout, environment, "unittest"))
        record(run_stage("editor-import", [binary, "--headless", "--path", str(ROOT), "--editor", "--import"],
                         output, args.timeout, environment, "import"))
        if report["results"][-1]["status"] == "pass":
            record(run_stage("diagnostics", [sys.executable, "-B", "tests/check_warnings.py", "--godot", binary,
                                            "--report", str(output / "diagnostics.json")],
                             output, args.timeout, environment, "diagnostics"))
            suites = SUITES + (("crt_library",) if args.shader_dir else ())
            for rendered in ([False, True] if args.render else [False]):
                for suite in suites:
                    command = [binary]
                    if not rendered:
                        command.append("--headless")
                    command += ["--path", str(ROOT), "--rendering-method", "gl_compatibility",
                                "--script", f"tests/test_{suite}.gd"]
                    user_args = []
                    if args.shader_dir:
                        user_args.append(f"--shader-dir={args.shader_dir.as_posix()}")
                    if suite == "crt_library" and rendered:
                        user_args.append("--render")
                    if user_args:
                        command += ["--", *user_args]
                    record(run_stage(f"{suite}-{'rendered' if rendered else 'headless'}", command,
                                     output, args.timeout, environment))
    report["checks"] = sum(entry.get("checks", 0) for entry in report["results"])
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"{report['status'].upper()}: {report['checks']} checks. Report: {output / 'summary.json'}")
    return 1 if report["status"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
