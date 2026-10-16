# Development and releases

[Back to README](../README.md)

The add-on directory is the maintained runtime source. This repository also
owns the shader-focused regression suite in `tests/`, migrated from the
`fallout-godot` project. Game-specific frontend integration tests remain in that
project. No original game checkout, assets, autoloads, or external collection is
required for the self-contained checks. The migration leaves the original
project's files untouched.

Standalone distributions include the portable smoke test and runtime tools;
the full `tests/` suite is maintained in the repository checkout.

Keep runtime dependencies relative and free of game resources, autoloads,
native extensions, and Python. The Python
tools are optional maintainer utilities. Runtime code runs on Godot's main thread.

## Changing the runtime

Keep source preparation, parameter/dependency resolution, translation, and
presentation separate. Translation-cache entries must contain code and immutable
metadata, never a caller's Shader, Texture, or material. File reads and validation
must remain fresh even on a cache hit. Failed imports must preserve the active
effect. Preserve source license notices in generated shaders.

Prefer descriptive names and one operation per line when touching dense code.
Document why a translation pass must precede another. Validate changes with
synthetic fixtures and rendered output for the affected behavior; a successful
headless import is insufficient evidence for rendering changes. Use the
[profiler and benchmark](PERFORMANCE.md) to support performance claims.

## Repository regression checks

Use Python 3.10+ and the tested Godot 4.7.1 Windows Compatibility baseline.
From the repository root:

```powershell
python -B -m unittest discover -s tests -p 'test_*.py'
python -B tests/run_tests.py --godot <godot-executable>
python -B tests/run_tests.py --godot <godot-executable> --render
```

The Python checks cover maintainer tooling. The runner checks the portable
smoke test and migrated shader regressions; `--render` enables checks that need
a working graphics context. Pass a console Godot executable on Windows to
capture its diagnostics. An optional `--shader-dir <glsl-shaders>` enables
cases needing an external collection. Use `--timeout` and `--output-dir` to
control process limits and report destinations; `--help` documents their units
and defaults. Do not commit generated reports or external collections.

Self-contained checks must keep working without `--shader-dir`. Report omitted
external-library checks separately from passing checks. A headless run validates
imports and lifecycle, but cannot establish GPU pixel output.
The runner also checks every GDScript through Godot's language server, writes
complete stage logs and a JSON summary, and isolates temporary files and user
configuration. The exact Windows diagnostic `Failed to read the root certificate
store` is recorded as an environment warning for these offline checks; other
engine and shader errors fail the run.

CI runs the headless suite and package smoke checks on Windows. Its manual
`render` input adds the GPU tier when the runner has a usable graphics context.

## Standalone smoke check

From any project containing the add-on, with `godot` on PATH:

```powershell
godot --headless --path . --script addons/retroarch_shaders/tools/smoke_test.gd
godot --path . --script addons/retroarch_shaders/tools/smoke_test.gd
```

The first command checks loading, parameters, disabling/re-enabling, and exact
preset selection. The second also checks rendered demo pixels. Both use synthetic
fixtures and exit nonzero on failed assertions. The test cleans up its temporary
fixtures; it requires no external shader collection or game files.

## Build and verify a distribution

Python 3.10+ is sufficient for packaging; Godot is required to run the result.
From the repository root on Windows, `build.bat` creates the Asset Store ZIP at
`build/godot-libretro-shaders-1.0.0.zip`. It discovers `py -3` or `python`; set
`PYTHON` to a Python executable path if needed. Run `build.bat --help` for the
builder options, or `build.bat --output-dir build/another-release` for a fresh
output location. Project-local package destinations must be descendants of
`build/`, where Godot ignores generated copies. External destinations are also
supported. Explicit relative builder paths resolve from the current directory;
the default output resolves from the project containing the add-on.

The equivalent commands on any platform are:

```sh
python -B addons/retroarch_shaders/tools/build_package.py --format addon --output-dir build/godot-libretro-shaders-1.0.0 --reuse-identical
python -B addons/retroarch_shaders/tools/build_package.py --verify build/godot-libretro-shaders-1.0.0.zip
```

The **addon** format contains only `addons/retroarch_shaders/`, including its
license, demo, documentation, portable tools and internal `manifest.json`.
It installs into an existing project without adding a root project configuration.

For a complete standalone demo project, use **standalone** (the Python builder's
default) with a distinct name:

```sh
python -B addons/retroarch_shaders/tools/build_package.py --format standalone --output-dir build/godot-libretro-shaders-1.0.0-demo
```

That format includes `project.godot`, the demo entry point, and a root manifest.
Both formats preserve script UIDs and exclude caches, imported data, test reports
and external shader collections. Root and add-on version files must agree.

The builder stages and verifies files before creating the final directory and
ZIP. It does not replace an existing release. `--reuse-identical` (enabled by
`build.bat`) verifies both existing artifacts against the staged build and
succeeds only when they match exactly. Changed or incomplete outputs are
preserved and require a fresh destination. Archive metadata is fixed so identical
source bytes built with the same Python/zlib produce identical archives.
The manifest detects changed, missing and extra files; it is not a signature.

Verify pristine directories before opening them in the editor. The combined
release checker builds a fresh package, verifies and extracts the ZIP, then
runs the portable smoke checks against both copies:

```sh
python -B tools/check_release.py --godot <godot-executable> --format addon --output-dir build/checked/godot-libretro-shaders-1.0.0 --render
python -B tools/check_release.py --godot <godot-executable> --format standalone --output-dir build/checked/godot-libretro-shaders-1.0.0-demo --render
```

For addon packages, it installs each copy into a separate clean Godot host first.
The addon distribution itself stays pristine. Choose fresh output paths for this
checker; logs and `summary.json` are saved under `test-results/`, or the specified
`--report-dir`. Repository-local report destinations must be under `test-results/`
or `build/`. The checker's relative paths resolve from the repository root.
CI runs both formats and checks that `build.bat` can reuse the
verified addon output.

Run the repository regressions, review versions, changelog, licenses, rendered
results and Store listing media, then upload the addon ZIP. Clone the repository
for the full development project and tests; Git source archives include only the
installable add-on through `.gitattributes`. Build commands perform no upload.

## Audit an external collection


Python 3 and a Godot executable are required. From the project root:

```powershell
python addons/retroarch_shaders/tools/audit_library.py --godot <godot-executable> --shader-dir <glsl-shaders> --include-sources --workers 4 --output-dir test-results/imports
python addons/retroarch_shaders/tools/audit_library.py --godot <godot-executable> --shader-dir <glsl-shaders> --include-sources --render --output-dir test-results/rendered
```

The first command audits every preset and optionally each source independently.
`translated` means the importer accepted the input; it does not establish GPU
behavior. The rendered tier tests a structured image at 640x480 and 800x600.
`rendered` means smoke validation passed; `review` means flat/blank output needs
inspection. Neither tier establishes RetroArch pixel equivalence. Rejections,
timeouts and engine errors keep their own status, reason and complete log.
`preset_required` identifies a dependent source with exact matching choices.
The summary marks it `supported_via_preset` only when at least one matching
preset has passing rendered evidence from the same audited runtime and collection.
Each case has its own process and timeout. Rendered audits default to one worker;
`--workers` allows concurrent isolated processes when GPU resources permit.
Use `--sizes 960x720,1280x960` for 3x/4x output, or `--warmup-frames 120`
for shaders with startup fades. Pass those completed reports to
`summarize_audit.py --additional-rendered <report.json>` to retain the conditions;
they do not erase a failed standard-size/startup check.
If an engine process crashes without a shader diagnostic, two additional passing
audits at the standard conditions can establish a retried pass. The catalog
retains the original process failure and both repeat results.
Reports include per-category counts, file/runtime fingerprints, environment
details and checks that the collection and runtime remained unchanged.
Use `--resume` with the same output directory and unchanged inputs to continue.

## Compatibility evidence

[SUPPORT.md](../SUPPORT.md) and [compatibility.json](../compatibility.json) describe
an exact historical runtime and collection fingerprint. Keep those identities
intact when changing runtime code. Record subsequent regression checks separately;
regenerate the catalog only from complete, matching audits. Nonblank smoke output
does not establish pixel equivalence with RetroArch.
