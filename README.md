# Libretro shaders for Godot

Use RetroArch/libretro `.glsl` shaders and `.glslp` presets in Godot games with
a GDScript add-on. Version **1.0.0**, MIT licensed. Runtime use needs no native
extension, Python installation, editor plugin activation, or host-game assets.

Browse or download `.glsl` shaders and `.glslp` presets from the
[libretro GLSL shader collection on GitHub](https://github.com/libretro/glsl-shaders).

The verified baseline is **Godot 4.7.1 on Windows with the Compatibility
renderer**. Other engine versions, platforms, and renderers need their own
validation. External shader collections are supplied separately and retain
their own licenses.

## Try the demo

Open this repository's `project.godot` in Godot and press **F5**. The demo uses
a synthetic animated image, an original scanline shader, and standard Godot
controls for selecting shaders and editing parameters. It needs no external
shader collection.
Clone the repository for the development project, or download a release ZIP
ending in `-demo.zip`. The Asset Store ZIP and GitHub source archives contain
the installable `addons/` directory.

## Install in a game

Copy the entire [`addons/retroarch_shaders`](addons/retroarch_shaders) directory
into your project's `addons` directory. Keep its runtime scripts together.
Open `addons/retroarch_shaders/demo/demo.tscn` and press **F6** to check the
installation. No plugin activation is required.

Render the content you want to process into a `SubViewport`, display its texture
in the host viewport, and attach an effect:

```gdscript
extends Node

const PostProcess = preload("res://addons/retroarch_shaders/post_process.gd")

func _ready() -> void:
    var effect = PostProcess.new()
    add_child(effect)
    effect.set_framebuffer_texture($SourceViewport.get_texture())
    effect.set_input_size(Vector2(320, 240))
    var result = effect.configure({
        "shader_enabled": true,
        "shader_path": "res://addons/retroarch_shaders/demo/shaders/scanlines.glsl",
        "shader_parameters": {"STRENGTH": 0.3},
    })
    if not result.ok:
        push_warning(result.message)
```

The source viewport must exist and keep rendering. The effect presents on
canvas layer 110; put UI on a higher layer to keep it unprocessed. For an
external collection, select a complete `.glslp` preset and preserve its folder
structure. See the [integration guide and public API](addons/retroarch_shaders/docs/USAGE.md)
for source setup, parameters, disabling, export filters, and troubleshooting.

## Scope and evidence

The add-on supports up to 16 passes, pragma parameters, lookup images, pass
sizing, aliases, original/history/feedback inputs, mipmaps, HDR, and sRGB
targets. Loading and translation are synchronous; advanced pipelines add one
frame of presentation delay. Slang, Cg, includes, perspective geometry, and
arbitrary GLSL are outside the verified scope.

Compatibility is measured against a specific collection snapshot. The
[support report](addons/retroarch_shaders/SUPPORT.md) and
[per-file catalog](addons/retroarch_shaders/compatibility.json) retain that
historical evidence and its conditions. Import and nonblank rendering checks
do not establish pixel equivalence with RetroArch.

## Validate changes

Python 3.10+ is used for maintainer tools; Godot runs the shader checks. From
the repository root, replace `<godot-executable>` with a console executable or
a command available on your PATH:

```powershell
python -B -m unittest discover -s tests -p 'test_*.py'
python -B tests/run_tests.py --godot <godot-executable>
python -B tests/run_tests.py --godot <godot-executable> --render
```

Rendered checks require a working graphics context. An external GLSL collection
can be supplied with `--shader-dir <glsl-shaders>`; it is optional for the
self-contained checks. Use `--help` for timeouts and report destinations. See
[development and release instructions](addons/retroarch_shaders/docs/DEVELOPMENT.md)
and [contributing](CONTRIBUTING.md) for the full workflow.

## Project structure

| Path | Purpose |
| --- | --- |
| `addons/retroarch_shaders/*.gd` | Importer, cache and presentation runtime; relative imports keep the add-on portable. |
| `addons/retroarch_shaders/demo/` | Runnable synthetic example and original scanline shader. |
| `addons/retroarch_shaders/docs/` | Integration, supported API, performance and maintenance guides. |
| `addons/retroarch_shaders/tools/` | Portable smoke, benchmark, collection audit and package tools. |
| `tests/` | Independent regressions and GDScript diagnostics. |
| `tools/` | Repository release verification and demo capture. |
| `media/` | Store listing media, excluded from Godot imports and addon ZIPs. |
| `build/` | Generated, ignored release artifacts. |

The existing add-on folder and public preloads remain stable for 1.0.0.
Runtime scripts do not depend on Python, repository tests, or release tools.

## Build for the Godot Asset Store

On Windows, with Python 3.10+ installed:

```bat
build.bat
```

This creates **`build/godot-libretro-shaders-1.0.0.zip`** for upload as an
**Addon** at [Godot Asset Store](https://store.godotengine.org). The archive starts
with `addons/retroarch_shaders/`, includes an internal SHA-256 manifest, and
contains no root `project.godot`. Repeating an unchanged build verifies and
reuses the existing artifacts. Different existing output is preserved; choose
a fresh output directory. Project-local output paths must be below `build/`;
external destinations are also supported. Run `build.bat --help` for options.

The equivalent cross-platform command is:

```sh
python -B addons/retroarch_shaders/tools/build_package.py --format addon --output-dir build/godot-libretro-shaders-1.0.0
```

Verify installation into fresh host projects and rendered demo output with:

```sh
python -B tools/check_release.py --godot <godot-executable> --format addon --output-dir build/checked/godot-libretro-shaders-1.0.0 --render
```

For a standalone demonstration project, use the default standalone format and
a distinct name such as `build/godot-libretro-shaders-1.0.0-demo`.
CI tests both package formats alongside headless regressions and GDScript
diagnostics; manual workflow dispatch can also run the rendered tier.
See the [prepared Store listing](docs/STORE.md) for description, media, version
notes, and upload fields.

The add-on and shader regression tests were extracted from the
`fallout-godot` project's `addons/retroarch_shaders` and shader test suite.
This repository owns those shader regressions; game-specific integration tests
remain with the host game. The original project is not needed to build or test
this repository, and the migration leaves its files untouched.

See [changes](CHANGELOG.md), the [add-on documentation](addons/retroarch_shaders/README.md),
and the [MIT license](LICENSE). The license covers this add-on, not external
shader collections, lookup images, or the host game.
