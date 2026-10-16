"""Build a fresh release and smoke-test its contents and extracted ZIP.

Uses Python 3.10+ standard library and the repository's existing package builder.
Godot runs with disposable user data. Add-on packages are installed into clean
test projects before running, just as an Asset Store installation would be.
"""

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons/retroarch_shaders"
sys.path.insert(0, str(ROOT / "tests"))
from run_tests import assess_output

SPEC = importlib.util.spec_from_file_location("release_builder", ADDON / "tools/build_package.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


def resolve_path(path):
    return (path if path.is_absolute() else ROOT / path).resolve()


def run_smoke(name, project, binary, report_dir, timeout, rendered):
    """Run the packaged smoke without resources, settings or scripts from the host."""
    command = [binary]
    if not rendered:
        command.append("--headless")
    command += ["--path", str(project), "--rendering-method", "gl_compatibility",
                "--script", "res://addons/retroarch_shaders/tools/smoke_test.gd"]
    log_path = report_dir / f"{name}.log"
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="libretro-release-") as temporary:
            runtime = Path(temporary)
            user_data = runtime / "userdata"
            user_data.mkdir()
            environment = dict(os.environ, PYTHONUTF8="1", PYTHONDONTWRITEBYTECODE="1",
                               TEMP=temporary, TMP=temporary, TMPDIR=temporary,
                               APPDATA=str(user_data), LOCALAPPDATA=str(user_data),
                               XDG_DATA_HOME=str(user_data), XDG_CONFIG_HOME=str(user_data),
                               XDG_CACHE_HOME=str(user_data))
            with log_path.open("w", encoding="utf-8") as log:
                process = subprocess.Popen(command, cwd=project, env=environment,
                                           stdout=log, stderr=subprocess.STDOUT,
                                           creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                try:
                    exit_code = process.wait(timeout=timeout)
                except BaseException:
                    process.kill()
                    process.wait()
                    raise
        result = assess_output(log_path.read_text(encoding="utf-8", errors="replace"), exit_code)
    except subprocess.TimeoutExpired:
        result = {"status": "fail", "reason": f"Timed out after {timeout:g}s"}
    except OSError as error:
        result = {"status": "fail", "reason": str(error)}
    result.update(name=name, command=command, project=str(project), log=str(log_path),
                  elapsed_seconds=round(time.monotonic() - started, 3))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"),
                        help="Godot executable (or GODOT_BIN)")
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="Fresh package directory, normally build/<release-name>")
    parser.add_argument("--format", choices=BUILDER.FORMATS, default="standalone", dest="package_format",
                        help="addon: install into clean hosts; standalone: run packaged project (default)")
    parser.add_argument("--report-dir", type=Path, help="Directory for saved logs and summary.json")
    parser.add_argument("--render", action="store_true", help="Also run actual GPU smoke checks")
    parser.add_argument("--timeout", type=float, default=600, help="Seconds per smoke stage (default: 600)")
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    binary = shutil.which(args.godot)
    if binary is None:
        parser.error(f"Godot executable not found: {args.godot}")
    binary = str(Path(binary).resolve())
    output = resolve_path(args.output_dir)
    archive = output.with_name(output.name + ".zip")
    extracted = output.with_name(output.name + "-extracted")
    installed = output.with_name(output.name + "-installed") if args.package_format == "addon" else output
    try:
        BUILDER.validate_output_location(output, ADDON)
    except ValueError as error:
        parser.error(str(error))
    for path in (output, archive, extracted, installed):
        if path.exists() or path.is_symlink():
            parser.error(f"Release artifact already exists; choose a fresh --output-dir: {path}")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    report_dir = resolve_path(args.report_dir or Path("test-results") / f"release-{output.name}-{stamp}")
    generated_roots = (ROOT / "build", ROOT / "test-results")
    if ((report_dir == ROOT or ROOT in report_dir.parents)
            and not any(report_dir == folder or folder in report_dir.parents for folder in generated_roots)):
        parser.error("Reports inside the repository must be under test-results/ or build/.")
    if (report_dir == archive or report_dir == output or output in report_dir.parents
            or report_dir == extracted or extracted in report_dir.parents or report_dir in ROOT.parents
            or report_dir == installed or installed in report_dir.parents):
        parser.error("Choose a report directory outside the sources and release artifacts")
    if (report_dir / "summary.json").exists():
        parser.error(f"Release report already exists; choose a fresh --report-dir: {report_dir}")
    report_dir.mkdir(parents=True, exist_ok=True)
    # Only exclude known generated trees. A caller's external output parent
    # might contain a real project, and must never be hidden from Godot.
    for folder in generated_roots:
        if folder == report_dir or folder in report_dir.parents:
            (folder / ".gdignore").touch(exist_ok=True)
    report = {"started_utc": datetime.now(timezone.utc).isoformat(), "render_requested": args.render,
              "package_format": args.package_format, "installed_project": str(installed),
              "project": str(output), "archive": str(archive), "extracted_project": str(extracted),
              "manifest_scope": "Exact directory and ZIP inventory verified before Godot runs.", "results": []}

    def record(result):
        report["results"].append(result)
        report["status"] = "fail" if any(item["status"] == "fail" for item in report["results"]) else "pass"
        report["checks"] = sum(item.get("checks", 0) for item in report["results"])
        (report_dir / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        detail = result.get("reason", f"{result.get('checks', 0)} checks")
        print(f"{result['status'].upper():4} {result['name']}: {detail}", flush=True)

    started = time.monotonic()
    try:
        _, _, count = BUILDER.build_package(output, package_format=args.package_format)
        counts = {"project": BUILDER.verify_package(output), "archive": BUILDER.verify_package(archive)}
        # The builder already rejects unsafe paths, duplicate members and links.
        # Verify again before extraction so only the reviewed archive is unpacked.
        extracted.mkdir()
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(extracted)
        counts["extracted_project"] = BUILDER.verify_package(extracted)
        if set(counts.values()) != {count}:
            raise ValueError(f"Package file counts differ: {counts}")
        if args.package_format == "addon":
            shutil.copytree(output, installed)
            for host in (installed, extracted):
                version = BUILDER.read_version(host / BUILDER.ADDON_PREFIX)
                (host / "project.godot").write_text(BUILDER.PROJECT.format(version=version),
                                                   encoding="utf-8", newline="\n")
        report["files"] = count
        report["archive_sha256"] = BUILDER.sha256_file(archive)
        record({"name": "build-and-manifests", "status": "pass", "checks": 3, "failures": 0,
                "verified_files": counts, "elapsed_seconds": round(time.monotonic() - started, 3)})
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        record({"name": "build-and-manifests", "status": "fail", "reason": str(error),
                "elapsed_seconds": round(time.monotonic() - started, 3)})
    if report["status"] == "pass":
        for label, project in (("installed" if args.package_format == "addon" else "project", installed),
                               ("extracted", extracted)):
            for rendered in ([False, True] if args.render else [False]):
                name = f"{label}-{'rendered' if rendered else 'headless'}"
                record(run_smoke(name, project, binary, report_dir, args.timeout, rendered))
        try:
            if BUILDER.verify_package(archive) != report["files"]:
                raise ValueError("Archive file count changed during smoke checks")
            if BUILDER.sha256_file(archive) != report["archive_sha256"]:
                raise ValueError("Archive bytes changed during smoke checks")
            record({"name": "archive-unchanged", "status": "pass", "checks": 1, "failures": 0})
        except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
            record({"name": "archive-unchanged", "status": "fail", "reason": str(error)})
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    (report_dir / "summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"{report['status'].upper()}: {report['checks']} checks. Report: {report_dir / 'summary.json'}")
    print(f"Package: {output}\nArchive: {archive}\nSmoke project: {installed}\nExtracted project: {extracted}")
    return 1 if report["status"] == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
