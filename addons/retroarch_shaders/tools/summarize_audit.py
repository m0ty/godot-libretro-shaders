"""Create a portable per-file catalog and compatibility notes from audit reports."""

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re

SUPPORTED = ("rendered", "rendered_conditional", "previously_rendered")
# These exact sources emit edge flags divided by 255, rather than a display
# image. A contrast threshold cannot validate them independently. Retain the
# standalone review and establish support only through their verified preset.
DATA_PASSES = {
    ("xbr/shaders/2xBR-multipass/2xbr-lv1-c-pass0.glsl", "7ce3002873c2d988f0e4cff99b52a2b9a3953bf1b153c6f925f77fb59506f44a"):
        "xbr/2xBR-lv1-multipass.glslp",
    ("xbr/shaders/xbr-mlv4-multipass/xbr-mlv4-pass1.glsl", "70e942be48c7c9606271438da6e5b2ba48c2d2eee12556fa36839acf3a58adef"):
        "xbr/xbr-mlv4-multipass.glslp",
}


def load_audit(path, parser, label, *, render):
    """Reject ambiguous evidence before merging any per-file results."""
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        parser.error(f"Cannot read {label}: {error}")
    if not isinstance(report, dict) or not all(
            report.get(key) is True for key in ("complete", "source_unchanged", "collection_unchanged")):
        parser.error(f"{label} must be complete with unchanged inputs.")
    if report.get("settings", {}).get("render") is not render:
        parser.error(f"{label} must be a {'rendered' if render else 'headless import'} audit.")
    results = report.get("results")
    if not isinstance(results, list) or not results:
        parser.error(f"{label} must contain shader cases.")
    paths = set()
    for entry in results:
        path = entry.get("path") if isinstance(entry, dict) else None
        if not isinstance(path, str) or not path or path in paths:
            parser.error(f"{label} must contain distinct, nonempty case paths.")
        paths.add(path)
    return report


def portable_value(value, collection_pattern):
    """Strip collection locations from nested diagnostics, including reruns."""
    if isinstance(value, str):
        return re.sub(collection_pattern, "<collection>", value, flags=re.IGNORECASE)
    if isinstance(value, list):
        return [portable_value(item, collection_pattern) for item in value]
    if isinstance(value, dict):
        return {key: portable_value(item, collection_pattern) for key, item in value.items()}
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--imports", type=Path, required=True)
    parser.add_argument("--rendered", type=Path, required=True)
    parser.add_argument("--additional-rendered", type=Path, action="append", default=[], help="Matching audits at additional output sizes or warmup durations")
    parser.add_argument("--crt-reference", type=Path, help="Optional earlier CRT GPU report; explicitly labeled as prior evidence")
    parser.add_argument("--baseline", type=Path, help="Optional previous compatibility.json for measured support changes")
    parser.add_argument("--review-note", action="append", default=[], help="Verified explanation accompanying visual-review results")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    imports = load_audit(args.imports, parser, "Import evidence", render=False)
    gpu = load_audit(args.rendered, parser, "Main rendered evidence", render=True)
    baseline = json.loads(args.baseline.read_text(encoding="utf-8")) if args.baseline else None
    if imports["collection_sha256"] != gpu["collection_sha256"]:
        parser.error("Import and rendered audits must describe the same collection.")
    if imports["source_sha256"] != gpu["source_sha256"]:
        parser.error("Import and rendered audits must use the same runtime source.")
    rendered = {entry["path"]:entry for entry in gpu["results"]}
    imported_paths = {entry["path"] for entry in imports["results"]}
    if set(rendered) - imported_paths:
        parser.error("Rendered evidence contains files absent from the import audit.")
    standard_conditions = {"sizes":[[int(value) for value in size.split("x")]
                                   for size in gpu["settings"].get("sizes","640x480,800x600").split(",")],
                           "warmup_frames":gpu["settings"].get("warmup_frames",12),"input_size":[320,240]}
    additional = defaultdict(list)
    seen_reports = {args.rendered.resolve()}
    for path in args.additional_rendered:
        if path.resolve() in seen_reports:
            parser.error("Additional rendered audits must be distinct reports.")
        seen_reports.add(path.resolve())
        report = load_audit(path, parser, "Additional rendered evidence", render=True)
        if (report["collection_sha256"] != imports["collection_sha256"] or
                report["source_sha256"] != imports["source_sha256"]):
            parser.error("Additional rendered evidence requires the same collection and runtime.")
        for entry in report["results"]:
            if entry["path"] not in rendered or entry["sha256"] != rendered[entry["path"]]["sha256"]:
                parser.error("Additional evidence must match a file in the main rendered audit.")
            additional[entry["path"]].append(entry)
    previous = {}
    if args.crt_reference:
        reference = json.loads(args.crt_reference.read_text(encoding="utf-8"))
        if not all(reference.get(key) for key in ("complete","source_unchanged","collection_unchanged")):
            parser.error("The CRT reference must be complete with unchanged inputs.")
        previous = {entry["preset"]:entry for entry in reference["results"]
                    if entry["ok"] and entry.get("render",{}).get("status") == "passed"}
    cases = []
    collection_pattern = re.escape(imports["collection"].replace("\\","/")).replace("/",r"[\\/]")
    for entry in imports["results"]:
        case = {key:entry[key] for key in ("path","kind","category","sha256","status","message","reason_group")}
        case["import_status"] = entry["status"]
        case["render_status"] = "not_requested"
        for key in ("passes","parameters","diagnostic","warnings","ignored_preset_parameters","preset_candidates"):
            if key in entry:
                case[key] = entry[key]
        newer = rendered.get(entry["path"])
        if newer:
            if newer["sha256"] != entry["sha256"]:
                parser.error("A shader changed between audits: " + entry["path"])
            case.update(status=newer["status"],render_status=newer["status"],
                        message=newer.get("message",""),reason_group=newer["reason_group"])
            if "diagnostic" in newer:
                case["diagnostic"] = newer["diagnostic"]
            case["render_conditions"] = newer.get("render_conditions",{})
            case["render"] = newer.get("render",{})
        elif entry["kind"] == "preset" and entry["category"] == "crt" and entry["path"] in previous:
            if previous[entry["path"]]["sha256"] != entry["sha256"]:
                parser.error("A CRT preset changed since its reference run: " + entry["path"])
            if entry["status"] == "translated":
                case.update(status="previously_rendered",render_status="previously_rendered")
        if entry["path"] in additional:
            case["additional_rendered"] = [{"status":extra["status"],"render_conditions":extra.get("render_conditions",{}),
                                             "render":extra.get("render",{}),"message":extra.get("message",""),
                                             "exit_code":extra.get("exit_code")}
                                            for extra in additional[entry["path"]]]
            repeats = additional[entry["path"]]
            if (case["status"] == "error" and case["message"].startswith("Godot exited with code ")
                    and len(repeats) >= 2 and all(extra["status"] == "rendered" and
                        extra.get("render_conditions") == standard_conditions for extra in repeats)):
                case["initial_render_failure"] = {"message":case["message"],"exit_code":newer["exit_code"]}
                case.update(status="rendered",render_status="rendered",reason_group="accepted",
                            render_conditions=repeats[-1]["render_conditions"],render=repeats[-1]["render"],
                            message="Passed two isolated repeat checks after an initial Godot process crash; the initial failure is retained.")
            if case["status"] == "review" and any(extra["status"] == "rendered" for extra in additional[entry["path"]]):
                case["standard_render_status"] = "review"
                case.update(status="rendered_conditional",render_status="rendered_conditional",reason_group="accepted",
                            message="Passed additional rendered checks under the documented conditions; standard startup/size checks require review.")
        if "preset_candidates" in case:
            case["preset_candidates"] = [re.sub("^"+collection_pattern+r"[\\/]?","",path,flags=re.IGNORECASE).replace("\\","/")
                                          for path in case["preset_candidates"]]
        cases.append(portable_value(case, collection_pattern))
    # Historical CRT results can remain explicitly labeled, but do not prove a
    # dependent source works with the current runtime.
    verified_presets = {entry["path"] for entry in cases if entry["kind"] == "preset"
                        and entry["status"] in ("rendered", "rendered_conditional")}
    for entry in cases:
        if entry["kind"] != "source":
            continue
        data_parent = DATA_PASSES.get((entry["path"],entry["sha256"]))
        if entry["status"] == "review" and data_parent in verified_presets:
            entry.update(standard_render_status="review",status="supported_via_preset",render_status="via_preset",
                         supported_presets=[data_parent],reason_group="source_pass_context",
                         support_note="Encoded intermediate edge flags divided by 255, not a display image. Standalone contrast review is retained; support is established through the matching verified complete preset.")
            continue
        if entry["status"] != "preset_required":
            continue
        matches = sorted(set(entry.get("preset_candidates",[])).intersection(verified_presets))
        if matches:
            entry.update(status="supported_via_preset",render_status="via_preset",supported_presets=matches,
                         reason_group="source_pass_context")
    presets = [entry for entry in cases if entry["kind"] == "preset"]
    sources = [entry for entry in cases if entry["kind"] == "source"]
    categories = defaultdict(Counter)
    for entry in presets:
        categories[entry["category"]][entry["status"]] += 1
    failures = Counter(entry["reason_group"] for entry in presets if entry["status"] == "rejected")
    metadata = {"collection_sha256":imports["collection_sha256"],
                "import_audit_source_sha256":imports["source_sha256"],
                "render_audit_source_sha256":gpu["source_sha256"],
                "finished_utc":gpu["finished_utc"],
                "godot":gpu["results"][0]["godot"],
                "adapter":gpu["results"][0]["adapter"],
                "display":gpu["results"][0]["display"],
                "presets":dict(Counter(entry["status"] for entry in presets)),
                "sources":dict(Counter(entry["status"] for entry in sources)),
                "crt_note":"CRT rendering evidence is from an earlier runtime. Matching preset hashes and successful current imports are required to retain it; focused rendered regressions cover the current pipeline.",
                "scope":imports["scope"]}
    if args.review_note:
        metadata["review_notes"] = args.review_note
    imported = [entry for entry in presets if entry["import_status"] == "translated"]
    metadata["parameter_diagnostics"] = {
        "imported_presets_with_ignored_names":sum(bool(entry.get("ignored_preset_parameters")) for entry in imported),
        "imported_presets_with_shared_metadata_differences":sum(any(note.startswith("Shared parameter") for note in entry.get("warnings",[])) for entry in imported)}
    if not any(entry["status"] == "previously_rendered" for entry in presets):
        metadata["crt_note"] = "No prior CRT rendering evidence is carried forward; rendered evidence uses the current runtime."
    if baseline:
        if baseline["metadata"]["collection_sha256"] != imports["collection_sha256"]:
            parser.error("Support changes require the same collection snapshot.")
        prior = {entry["path"] for entry in baseline["cases"] if entry["kind"] == "preset"
                 and entry["status"] in SUPPORTED}
        supported = {entry["path"] for entry in presets if entry["status"] in SUPPORTED}
        metadata["changes"] = {"previous_supported":len(prior),"current_supported":len(supported),
                               "added":sorted(supported-prior),"no_longer_verified":sorted(prior-supported)}
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "compatibility.json").write_text(json.dumps({"metadata":metadata,"cases":cases},indent=2),encoding="utf-8")
    current = sum(entry["status"] == "rendered" for entry in presets)
    conditional = [entry for entry in presets if entry["status"] == "rendered_conditional"]
    retried = [entry for entry in presets if "initial_render_failure" in entry]
    noncrt = sum(entry["status"] == "rendered" and entry["category"] != "crt" for entry in presets)
    old = sum(entry["status"] == "previously_rendered" for entry in presets)
    rejected = sum(entry["status"] == "rejected" for entry in presets)
    errors = [entry for entry in presets if entry["status"] == "error"]
    reviews = [entry for entry in presets if entry["status"] == "review"]
    unverified = [entry for entry in presets if entry["status"] not in
                  (*SUPPORTED,"rejected","error","review")]
    source_counts = Counter(entry["status"] for entry in sources)
    data_helpers = [entry for entry in sources if "support_note" in entry]
    timeouts = [entry["path"] for entry in sources if entry["status"] == "timeout"]
    primary_sizes = gpu["settings"].get("sizes","640x480,800x600").replace(",", " and ")
    lines = ["# Collection compatibility", "",
             f"Audited with Godot {metadata['godot']}, {metadata['display']}, Compatibility, {metadata['adapter']}.", "",
             f"The snapshot contains **{len(presets)} presets** and **{len(sources)} GLSL sources**.",
             f"**{current} presets passed fresh rendered smoke checks** at {primary_sizes} ({noncrt} outside CRT).",
             f"**{len(conditional)} additional presets passed under specific output-size or warmup conditions**, listed below. Their standard startup/size checks remain review cases.",
             (f"**{old} CRT presets retain prior rendered evidence** and all re-imported successfully with the current runtime."
              if old else "Rendered evidence in this report uses the current runtime; no prior CRT rendering evidence is carried forward."),
             f"**{rejected} presets are rejected by the importer; {len(errors)} have GPU errors; {len(reviews)} require visual review; {len(unverified)} remain unverified.**", "",
             (("CRT evidence is from an earlier runtime; focused rendered regressions cover the current pipeline. " if old else "")
              + "Import acceptance and nonblank output do not establish RetroArch pixel equivalence. Other renderers, operating systems and GPUs are unverified."), "",
             "The [per-file catalog](compatibility.json) lists every tested path, SHA256, status, rendered conditions and failure reason. Source files are audited separately. "
             f"{source_counts['rendered']} sources passed standalone GPU checks; {source_counts['rendered_conditional']} passed under documented conditions; "
             f"{source_counts['supported_via_preset']} helper/data passes are supported through matching verified presets. For missing dependencies, the picker offers exact referring presets instead of substituting textures or parameters. "
             f"Standalone source results also include {source_counts['review']} visual-review cases, {source_counts['translated']} translation-only cases, {source_counts['rejected']} rejections, {source_counts['error']} GPU errors and {source_counts['timeout']} timeouts. "
             "Helper support through a preset is distinct from independent rendering.", "",
             f"The headless audit accepted {sum(entry['import_status'] == 'translated' for entry in sources)} sources independently and identified "
             f"{sum(entry['import_status'] == 'preset_required' for entry in sources)} requiring preset dependencies. "
             f"{len(data_helpers)} independently compiling xBR data passes are verified through complete presets; their standalone low-contrast samples remain in the catalog.", "",
             "## Presets by category", "",
             "| Category | Presets | Fresh GPU pass | Conditional GPU pass | Prior CRT GPU pass | Import rejected | GPU error | Review | Unverified |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for name,count in sorted(categories.items()):
        pending = sum(value for status,value in count.items() if status not in
                      (*SUPPORTED,"rejected","error","review"))
        lines.append(f"| {name} | {sum(count.values())} | {count['rendered']} | {count['rendered_conditional']} | {count['previously_rendered']} | {count['rejected']} | {count['error']} | {count['review']} | {pending} |")
    lines += ["", "## Missing capabilities", "",
              "Counts below are the **first reported rejection per preset**. Fixing one gap can reveal another, so these are not guaranteed unlock counts.", "",
              "| First rejection group | Presets |", "| --- | ---: |"]
    for name,count in failures.most_common():
        lines.append(f"| {name} | {count} |")
    if not failures:
        lines.append("| None | 0 |")
    lines += ["", "Implemented compatibility extensions:", "",
              "- Single-pass source/absolute/per-axis sizing through render targets; explicit full-viewport presets retain direct presentation.",
              "- Integer-valued decimal frame moduli, with fractional/nonfinite/overflow values rejected.",
              "- `textureOffset`, `textureLodOffset` and `texelFetchOffset` for logical framebuffers, pass/history/feedback inputs and external images, preserving filtering and supported wrap modes.",
              "- Original-frame `PassPrevNTexture` references; GPU snapshot mip atlases and removal of unused sampler declarations.",
              "- Trimmed/deduplicated advisory parameter lists; stale preset names are ignored with catalog diagnostics, while unknown explicit edits still fail.",
              "- Shared GLSL parameters use the last declaration's metadata/default; preset and explicit values override it and clamp to those bounds.",
              "- Optional pragma steps default to one tenth of the range (fixed values use a positive UI step).",
              "- Affine vertex quad transforms and vertex helper functions, with per-invocation varying state and cleared uncovered output.",
              "- Rectangular matrices, mutable stage globals, legacy array/declaration/loop syntax and GLSL numeric conversions.",
              "- Repeat/mirrored-repeat pass sampling and mipmapped LUT wrapping, including border filtering at each level.",
              "- Equivalent duplicate preset values, legacy unclosed line quotes and ignored out-of-range pass metadata, with diagnostics.",
              "- Missing LUT bindings can inherit an unambiguous sibling preset's configuration for the exact same shader source; conflicting defaults still fail.",
              "- Legacy `3dfx/shaders` paths resolve to the collection's `gpu/shaders/3dfx` location when present, with a diagnostic.", "",
              "- Mixed scalar/vector matrix constructors preserve column order and evaluate each argument once; vector constructors truncate only the final surplus components as GLSL specifies.",
              "- Runtime array initializers, prefix increments, scientific literals adjacent to arithmetic, and user functions named `light`.",
              "- Exact-source compatibility profiles repair upstream auto-box clipping and Grade parameter names, and supply documented standalone LUT/image defaults. Changed source contents do not receive these repairs; explicit presets control texture bindings.",
              "- Exact-reference preset discovery and selection for dependent source passes, with bounded directory/file traversal.", "",
              f"Parameter diagnostics are retained per file: {metadata['parameter_diagnostics']['imported_presets_with_ignored_names']} imported presets contain ignored undeclared names; "
              f"{metadata['parameter_diagnostics']['imported_presets_with_shared_metadata_differences']} use differing shared declarations. These are diagnostics, not active controls or importer failures.", "",
              "Remaining scope:", "",
              "- Inspect review cases and validate appearance against RetroArch; smoke tests establish compilation and varied finite output, not equivalent rendering.",
              "- Includes, arbitrary GLSL and perspective geometry remain outside the verified subset. Standalone helper passes may require their preset's textures, aliases and framebuffer configuration.",
              "- Missing dependencies and ambiguous lookup-image defaults remain explicit errors. User-specified textures always take precedence over inherited defaults.", "",
              "GPU-only failures:", ""]
    for entry in errors:
        lines.append(f"- `{entry['path']}`: {entry['message']}")
    if not errors:
        lines.append("None.")
    lines += ["", "Initial process failures with passing repeat checks:", ""]
    for entry in retried:
        lines.append(f"- `{entry['path']}`: {entry['initial_render_failure']['message']} Two isolated reruns passed at the standard sizes/warmup; the original failure remains in the catalog.")
    if not retried:
        lines.append("None.")
    lines += ["", "Conditional GPU passes:", ""]
    for entry in conditional:
        for extra in entry["additional_rendered"]:
            if extra["status"] != "rendered": continue
            conditions = extra["render_conditions"]
            sizes = ", ".join(f"{width}x{height}" for width,height in conditions["sizes"])
            lines.append(f"- `{entry['path']}`: {sizes}, after {conditions['warmup_frames']} frames per size; logical input 320x240.")
    if not conditional:
        lines.append("None.")
    lines += ["", "Conditional standalone source passes:", ""]
    source_conditional = [entry for entry in sources if entry["status"] == "rendered_conditional"]
    for entry in source_conditional:
        for extra in entry["additional_rendered"]:
            if extra["status"] != "rendered":
                continue
            conditions = extra["render_conditions"]
            sizes = ", ".join(f"{width}x{height}" for width,height in conditions["sizes"])
            lines.append(f"- `{entry['path']}`: {sizes}, after {conditions['warmup_frames']} frames per size; logical input 320x240.")
    if not source_conditional:
        lines.append("None.")
    lines += ["", "Visual review:", ""]
    for entry in reviews:
        lines.append(f"- `{entry['path']}`: {entry['message']}")
    if not reviews:
        lines.append("None.")
    if args.review_note:
        lines += [""] + args.review_note
    lines += ["", "Standalone source timeouts (unverified):", ""]
    lines += ["- `"+path+"`" for path in timeouts] or ["None."]
    if baseline:
        change = metadata["changes"]
        lines += ["", "## Change from the previous audit", "",
                  f"Verified presets increased from **{change['previous_supported']} to {change['current_supported']}**. "
                  f"**{len(change['added'])} additional presets** passed rendered smoke checks, including the conditional passes above. "
                  +(f"{len(change['no_longer_verified'])} previously supported presets no longer have passing evidence in this audit."
                    if change["no_longer_verified"] else "All previously supported presets retain passing evidence."), "",
                  "Newly verified presets:", ""]
        lines += ["- `"+path+"`" for path in change["added"]]
    lines += ["",
              "## Reproduce", "",
              "Use `tools/audit_library.py` for headless and rendered audits, then:", "",
              "```powershell",
              "python addons/retroarch_shaders/tools/summarize_audit.py --imports test-results/imports/report.json --rendered test-results/rendered/report.json --output-dir addons/retroarch_shaders",
              "```", "",
              "Use `--sizes 960x720,1280x960` and a `--case-list` for the ten handheld presets listed above, and `--warmup-frames 120` for IQ Canyon. "
              "Pass each resulting report using `--additional-rendered <report.json>`; runtime and collection hashes must match the main audits. "
              "Pass `--crt-reference <report.json>` only when preserving earlier CRT evidence. Raw logs stay outside the distributed add-on. Known Windows certificate-store and GLES shader-cache write warnings are recorded separately from shader failures.", "",
              f"Collection SHA256: `{metadata['collection_sha256']}`.", ""]
    (args.output_dir / "SUPPORT.md").write_text("\n".join(lines),encoding="utf-8")
    print(json.dumps(metadata,indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
