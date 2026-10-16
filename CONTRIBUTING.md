# Contributing

This repository maintains the GDScript runtime in `addons/retroarch_shaders`,
its synthetic demo, shader regression tests, and maintainer tools. It runs
independently of the game project from which it was extracted. Keep game assets,
autoloads, frontend settings, and host-game integration tests out of the add-on.

## Development setup

Use Godot 4.7.1 with the Compatibility renderer and Python 3.10 or newer. The
verified rendering baseline is Windows; report the engine version, renderer,
OS, and GPU when testing elsewhere. Open `project.godot` to run the demo.
An external shader collection is optional and should stay outside the repository.

Keep runtime imports relative and avoid dependencies on editor plugins, native
extensions, Python, or a particular host project. Use tabs for GDScript and
four spaces for Python. Preserve `.uid` files for Godot scripts and resources.

## Validate a change

Run from the repository root:

```powershell
python -B -m unittest discover -s tests -p 'test_*.py'
python -B tests/run_tests.py --godot <godot-executable>
python -B tests/run_tests.py --godot <godot-executable> --render
```

Use a console Godot executable on Windows so diagnostics are captured. Rendered
checks require a graphics context. Pass `--shader-dir <glsl-shaders>` when
checking an external collection, and use `--help` for report and timeout options.

Add a small synthetic fixture when fixing a shader translation or rendering
bug. Check rendered output for GPU behavior; a headless import alone does not
prove the effect renders correctly. Run the packaging checks when changing
distribution contents or the package builder. The
[development guide](addons/retroarch_shaders/docs/DEVELOPMENT.md) describes
runtime invariants, external collection audits, and release verification.

## Issues and pull requests

Include the trigger, expected behavior, actual behavior, and a minimal
reproduction. For shader failures, include the shader/preset path, collection
revision or file fingerprint, engine/renderer details, and complete diagnostics.
Share only shader code and assets you have permission to distribute.

Describe what changed, why, and which checks ran. State any skipped rendered
checks or external-library cases explicitly. Keep compatibility evidence tied
to its recorded runtime and collection; do not present historical audit results
as validation of new runtime code. Record user-visible changes in the
[add-on changelog](addons/retroarch_shaders/CHANGELOG.md).

## Releases

Keep the root and add-on `VERSION` files consistent. Review the changelog,
documentation, license notices, tests, and packaged demo before publishing.
Builds are local artifacts; publishing a release is a separate step. See the
[release checklist](addons/retroarch_shaders/docs/DEVELOPMENT.md#build-and-verify-a-distribution).

Run `build.bat` to create the versioned Asset Store ZIP. For a complete
installation check, run `tools/check_release.py --format addon` with a fresh
output path and `--render`. Run the same checker with `--format standalone`
and a `-demo` output name to verify the standalone demonstration project.
Review generated artifacts before tagging `v1.0.0` and uploading.

The [prepared Store listing](docs/STORE.md) contains upload fields, a description,
the 16:9 thumbnail, version notes and an AI-assistance disclosure. Follow the
[Store guidelines](https://store.godotengine.org/guidelines/) for the current
submission rules. The square icon inside the add-on remains the project icon;
`media/store-thumbnail.png` is the separate Store listing image.

Git source archives include only `addons/` through `.gitattributes`, so installing
the add-on does not replace a game's project configuration. Clone the repository
for its development project and full tests. Keep regression reports outside
distributions. Store submission and approval are separate from local packaging.
