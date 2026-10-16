"""Audit an external RetroArch GLSL collection without changing it.

Each case runs in a separate Godot process with a timeout. Translation success
is kept distinct from rendered smoke validation and visual-review cases.
Uses only Python's standard library; works in the standalone demo project too.
"""

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


ADDON = Path(__file__).resolve().parents[1]
ERRORS = re.compile(r"SCRIPT ERROR:|SHADER ERROR:|^ERROR:|Shader compilation failed", re.MULTILINE)
CACHE_WARNING = re.compile(
    r'ERROR: Condition "f\.is_null\(\)" is true\.\s+'
    r'at: _save_to_cache \(drivers/gles3/shader_gles3\.cpp:\d+\)'
)


def fingerprint(paths, base):
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.relative_to(base).as_posix().encode() + b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def collection_files(root):
    return sorted(path for path in root.rglob("*") if path.is_file()
                  and not any(part.startswith(".") for part in path.relative_to(root).parts))


def reason_group(message, status):
    text = message.lower()
    rules = [
        ("timeout", ("timed out",)),
        ("includes", ("includes are not supported",)),
        ("vertex_transforms", ("vertex transform",)),
        ("missing_files", ("cannot read shader", "cannot read external texture")),
        ("texture_formats", ("cannot decode external texture",)),
        ("allocation_limits", ("budget", "megapixel", "dimension limit", "between 1 and 16")),
        ("samplers", ("additional texture", "sampler", "texture wrap mode", "pass wrap mode", "mipmapped external")),
        ("uniforms", ("unsupported shader uniform",)),
        ("preset_settings", ("preset setting", "preset sizing", "frame mod", "feedback pass")),
        ("parameter_metadata", ("parameter", "bounds",)),
        ("preprocessor", ("directive", "pragma", "macro", "unclosed", "#endif", "#else")),
        ("language_translation", ("compile", "parse error", "shader error", "script error", "function")),
        ("source_pass_context", ("entry point", "pass alias", "pass dependencies", "choose a matching preset")),
        ("visual_review", ("flat/blank",)),
    ]
    for name, terms in rules:
        if any(term in text for term in terms):
            return name
    return "accepted" if status in ("translated", "rendered") else "other"


def summarize(results):
    categories = defaultdict(Counter)
    reasons = Counter()
    kinds = defaultdict(Counter)
    for entry in results:
        categories[entry["category"]][entry["status"]] += 1
        kinds[entry["kind"]][entry["status"]] += 1
        if entry["status"] not in ("translated", "rendered"):
            reasons[entry["reason_group"]] += 1
    return {"statuses":dict(Counter(entry["status"] for entry in results)),
            "by_kind":{key:dict(value) for key,value in sorted(kinds.items())},
            "categories":{key:dict(value) for key,value in sorted(categories.items())},
            "reasons":dict(reasons.most_common())}


def write_report(output, report):
    report["summary"] = summarize(report["results"])
    temporary = output / "report.json.tmp"
    temporary.write_text(json.dumps(report, indent=2), encoding="utf-8")
    # Windows readers/virus scanners can briefly lock the destination. Keep
    # atomic replacement, but let a live progress reader finish its read.
    for attempt in range(10):
        try:
            temporary.replace(output / "report.json")
            break
        except PermissionError:
            if attempt == 9:
                raise
            time.sleep(0.05)


def probe(index, path, args, project, output):
    result_path = output / "cases" / f"{index:04}.json"
    log_path = output / "logs" / f"{index:04}.log"
    engine_log = output / "logs" / f"{index:04}.engine.log"
    relative = path.relative_to(args.shader_dir).as_posix()
    command = [args.godot, "--path", str(project), "--audio-driver", "Dummy",
               "--log-file", str(engine_log), "--script",
               "res://" + (ADDON / "tools/probe_shader.gd").relative_to(project).as_posix()]
    if not args.render:
        command.append("--headless")
    else:
        command += ["--rendering-method", "gl_compatibility", "--windowed", "--resolution", args.sizes.split(",")[0]]
    command += ["--", "--shader=" + str(path), "--result=" + str(result_path)]
    if args.render:
        command += ["--render", "--sizes="+args.sizes, "--warmup-frames="+str(args.warmup_frames)]
    entry = {"path":relative, "kind":"preset" if path.suffix.lower() == ".glslp" else "source",
             "category":relative.split("/")[0] if "/" in relative else "(root)",
             "sha256":hashlib.sha256(path.read_bytes()).hexdigest(),
             "log":log_path.relative_to(output).as_posix(), "command":command}
    started = time.monotonic()
    try:
        # A resumed case can have written its result just before the runner was
        # interrupted. A failed replacement process must not reuse that result.
        result_path.unlink(missing_ok=True)
        with log_path.open("wb") as log:
            process = subprocess.run(command, cwd=project, stdout=log, stderr=subprocess.STDOUT,
                                     timeout=args.timeout, check=False,
                                     creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        entry["exit_code"] = process.returncode
        if result_path.exists():
            data = json.loads(result_path.read_text(encoding="utf-8"))
            data.pop("path", None)
            entry.update(data)
        else:
            entry.update(status="error", message="Godot exited without a case result.")
        text = log_path.read_text(encoding="utf-8", errors="replace")
        # This Windows sandbox can lack a certificate store. Preserve the
        # startup warning separately; it does not validate or invalidate shaders.
        certificate_warning = "ERROR: Failed to read the root certificate store."
        if certificate_warning in text:
            entry["environment_warnings"] = [certificate_warning]
            text = text.replace(certificate_warning, "")
        if CACHE_WARNING.search(text):
            entry.setdefault("environment_warnings", []).append("Godot could not save its GLES3 shader cache.")
            text = CACHE_WARNING.sub("", text)
        error = ERRORS.search(text)
        # Engine errors invalidate dependency discovery too: a matching parent
        # preset cannot establish support for a probe that failed at runtime.
        if process.returncode or error:
            entry["status"] = "error"
            entry["message"] = (text[error.start():].splitlines()[0] if error else
                                f"Godot exited with code {process.returncode}.")
        if error:
            entry["diagnostic"] = text[error.start():error.start()+1200]
    except subprocess.TimeoutExpired:
        entry.update(status="timeout", message=f"Godot timed out after {args.timeout:g} seconds.")
    except (OSError, ValueError) as error:
        entry.update(status="error", message=str(error))
    entry["seconds"] = round(time.monotonic()-started, 3)
    entry["reason_group"] = reason_group(entry.get("message", ""), entry["status"])
    return entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--shader-dir", type=Path, required=True)
    parser.add_argument("--project", type=Path, default=ADDON.parents[1])
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--render", action="store_true")
    parser.add_argument("--sizes", default="640x480,800x600", help="Comma-separated rendered output sizes")
    parser.add_argument("--warmup-frames", type=int, default=12, help="Frames to settle at each output size, 1 to 600")
    parser.add_argument("--include-sources", action="store_true", help="Also audit sources; dependent helpers report matching presets")
    parser.add_argument("--exclude-category", action="append", default=[])
    parser.add_argument("--category", action="append", default=[])
    parser.add_argument("--candidates", type=Path, help="Audit only translated presets from a prior headless report")
    parser.add_argument("--case-list", type=Path, help="Select collection-relative paths from a JSON string array")
    parser.add_argument("--workers", type=int, default=1, help="Isolated Godot processes; default 1 avoids GPU contention")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    executable = Path(args.godot)
    if executable.name.lower().endswith("_console.exe"):
        direct = executable.with_name(executable.name[:-12] + ".exe")
        if direct.is_file():
            args.godot = str(direct)
    args.shader_dir = args.shader_dir.resolve()
    project = args.project.resolve()
    if not args.shader_dir.is_dir() or not (project / "project.godot").is_file():
        parser.error("Supply an existing collection and Godot project.")
    if args.workers < 1 or args.timeout <= 0:
        parser.error("Use positive workers and timeout.")
    dimensions = args.sizes.split(",")
    if not all(re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*", size) and
               all(int(value) <= 8192 for value in size.split("x")) for size in dimensions):
        parser.error("Sizes must be comma-separated WIDTHxHEIGHT values, each dimension at most 8192.")
    if not 1 <= args.warmup_frames <= 600:
        parser.error("Warmup must be between 1 and 600 frames.")
    files = collection_files(args.shader_dir)
    inventory = Counter(path.suffix.lower() for path in files)
    paths = [path for path in files if path.suffix.lower() == ".glslp" or
             (args.include_sources and path.suffix.lower() == ".glsl")]
    selected = None
    if args.candidates:
        prior = json.loads(args.candidates.read_text(encoding="utf-8"))
        selected = {entry["path"] for entry in prior["results"]
                    if entry["kind"] == "preset" and entry["status"] == "translated"}
    if args.case_list:
        requested = json.loads(args.case_list.read_text(encoding="utf-8"))
        if not isinstance(requested, list) or not all(isinstance(path, str) for path in requested):
            parser.error("Case list must be a JSON array of collection-relative paths.")
        known = {path.relative_to(args.shader_dir).as_posix() for path in paths}
        if set(requested) - known:
            parser.error("Case list contains paths outside the selected shader inventory.")
        selected = set(requested) if selected is None else selected.intersection(requested)
    paths = [path for path in paths if
             (not args.category or path.relative_to(args.shader_dir).parts[0] in args.category) and
             path.relative_to(args.shader_dir).parts[0] not in args.exclude_category and
             (selected is None or path.relative_to(args.shader_dir).as_posix() in selected)]
    if not paths:
        parser.error("No matching shader cases.")
    started = datetime.now(timezone.utc)
    output = (args.output_dir or project / "test-results" /
              ("shader-library-" + started.strftime("%Y%m%dT%H%M%S%fZ"))).resolve()
    if output == args.shader_dir or args.shader_dir in output.parents or output == ADDON or ADDON in output.parents:
        parser.error("Audit output must stay outside the collection and add-on.")
    source_paths = sorted(ADDON.glob("*.gd")) + [Path(__file__), ADDON / "tools/probe_shader.gd"]
    source_hash = fingerprint(source_paths, ADDON)
    collection_hash = fingerprint(files, args.shader_dir)
    settings = {"render":args.render,"include_sources":args.include_sources,
                "sizes":args.sizes,"warmup_frames":args.warmup_frames,
                "categories":args.category,"exclude_categories":args.exclude_category,
                "cases":[path.relative_to(args.shader_dir).as_posix() for path in paths]}
    if args.resume:
        report = json.loads((output / "report.json").read_text(encoding="utf-8"))
        if (report["source_sha256"] != source_hash or report["collection_sha256"] != collection_hash
                or report["settings"] != settings):
            parser.error("Resume requires the same source, collection and selected cases.")
        report["complete"] = False
    else:
        output.mkdir(parents=True, exist_ok=False)
        (output / "cases").mkdir()
        (output / "logs").mkdir()
        report = {"started_utc":started.isoformat(),"complete":False,
                  "collection":str(args.shader_dir),"project":str(project),
                  "source_sha256":source_hash,"collection_sha256":collection_hash,
                  "settings":settings,"inventory":dict(sorted(inventory.items())),
                  "scope":f"Rendered checks are smoke validation at {args.sizes}, after {args.warmup_frames} frames per size, not RetroArch pixel equivalence. Headless acceptance only establishes translation. Source files may be helper passes requiring a preset.",
                  "results":[]}
    finished = {entry["path"] for entry in report["results"]}
    print(f"Auditing {len(paths)} cases into {output}", flush=True)
    write_report(output, report)
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = [executor.submit(probe, index, path, args, project, output)
                   for index,path in enumerate(paths) if path.relative_to(args.shader_dir).as_posix() not in finished]
        for future in as_completed(futures):
            entry = future.result()
            report["results"].append(entry)
            write_report(output, report)
            print(f"{len(report['results'])}/{len(paths)} {entry['status']}: {entry['path']} "
                  f"({entry['seconds']:.2f}s) {entry.get('message','')}", flush=True)
    report["results"].sort(key=lambda entry: entry["path"])
    report["source_unchanged"] = fingerprint(source_paths, ADDON) == source_hash
    report["collection_unchanged"] = fingerprint(collection_files(args.shader_dir), args.shader_dir) == collection_hash
    report["complete"] = True
    report["finished_utc"] = datetime.now(timezone.utc).isoformat()
    write_report(output, report)
    print(json.dumps(report["summary"], indent=2), flush=True)
    return 0 if report["source_unchanged"] and report["collection_unchanged"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
