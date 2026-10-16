# Libretro Shaders for Godot

Run external RetroArch `.glsl` shaders and `.glslp` presets in Godot using
GDScript. Version **1.0.0**, MIT licensed. No native extension, editor plugin,
Python runtime, or game assets are needed to use the add-on.

The verified baseline is **Godot 4.7.1 on Windows with the Compatibility
renderer**. Other engine versions and renderers are unverified. Shader
collections are supplied separately and retain their own licenses.

## Try the demo

Open the standalone distribution's `project.godot` and press **F5**. The demo
includes an original scanline shader, a synthetic animated image, a shader
picker, and parameter controls. It works without an external collection.

Inside an existing project, copy this entire folder to
`addons/retroarch_shaders`, open `demo/demo.tscn`, and run that scene with **F6**.
No plugin activation is required. Runtime imports are relative, so the folder
can also be relocated; use its actual path in your preload.

## Add an effect

Create a `SubViewport` named `SourceViewport`, render your scene into it, and
show its texture in the host viewport (for example with a `TextureRect`). Then:

```gdscript
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

The effect presents at canvas layer **110**. Place UI on a higher layer to keep
it unprocessed. Use a separate source viewport for multipass effects, so they
cannot sample their own presentation. See the demo for a complete setup.

Call `effect.configure({"shader_enabled": false})` to disable and release the
intermediate buffers. Invalid replacements leave the previous effect active.
For external collections, select a `.glslp` preset to load all its dependencies.

## Capabilities and limits

Supports up to 16 passes, pragma parameters, lookup images, per-axis sizing,
alias/original/history/feedback inputs, mipmaps, HDR and sRGB targets. Advanced
pipelines add one frame of presentation delay. Loading and shader translation
run synchronously on the main thread; repeated translations use a bounded cache.

Compatibility is established per collection snapshot. Slang, Cg, includes,
perspective geometry, and arbitrary GLSL are outside the verified scope.
[SUPPORT.md](SUPPORT.md) describes the audited collection and conditional cases;
[compatibility.json](compatibility.json) retains per-file evidence. Smoke checks
establish compilation and nonblank output, not RetroArch pixel equivalence.

## Documentation

- [Integration, API, exports and troubleshooting](docs/USAGE.md)
- [Architecture, caching, profiling and benchmarks](docs/PERFORMANCE.md)
- [Development, standalone checks and release packaging](docs/DEVELOPMENT.md)
- [Changes](CHANGELOG.md) and [MIT license](LICENSE)

To build an Asset Store ZIP, run from your project root:

```powershell
python addons/retroarch_shaders/tools/build_package.py --format addon --output-dir build/godot-libretro-shaders-1.0.0
```

In the development repository, `build.bat` runs this format and reuses verified
identical output. The ZIP contains only `addons/retroarch_shaders/`, with its
manifest inside that folder. To build a standalone demonstration project, use
`--format standalone --output-dir build/godot-libretro-shaders-1.0.0-demo`.

The add-on license does not relicense the host game or external shaders,
presets, and lookup images. Preserve their original notices and licenses.
