# Integration and API

[Back to README](../README.md)

## Set up a source and effect

Create a `SubViewport` named `SourceViewport`, set its size (320x240 in this
example), and put the content to process inside it. Keep its render target
updating while the effect is active. Show that viewport's texture in the host
viewport beneath the effect, for example with a `TextureRect` sized to the
presentation area. The [demo](../demo/demo.tscn) creates this setup in code.

`set_framebuffer_texture()` feeds pass chains;
single-pass screen effects capture the host viewport through `BackBufferCopy`.
The demo supplies both presentations. Use a separate source viewport so pass
chains cannot sample the effect's own presentation.

Attach this script to the node that owns `SourceViewport`:

```gdscript
extends Node

const PostProcess = preload("res://addons/retroarch_shaders/post_process.gd")

func _ready() -> void:
    var effect = PostProcess.new()
    add_child(effect)
    # A separately rendered source prevents multipass feedback from sampling
    # the effect's own presentation. Set this before configuring the preset.
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

The `CanvasLayer` presents at layer 110 by default. Set `effect.layer` to suit
your scene; UI above this layer remains unprocessed. For a letterboxed source,
call `set_source_region(physical_rectangle, logical_size)`. The supplied composed
framebuffer must match that rectangle's placement in the host viewport.
The demo uses a synthetic 320x240 source and ordinary Godot controls.
Open `demo/demo.tscn` and run it, or run the packaged standalone project's F5 scene.
Replace the example's `shader_path` with a `.glslp` preset from your external
collection to apply its full pass chain and dependencies.

Enabling an effect with `configure()` returns `{ok, message, active, current}`
on success. Failed replacement presets preserve the previous effect. Disable with
`configure({"shader_enabled": false})`; this releases intermediate buffers and
returns `{ok, message, active}` with `active` set to `false`.
Parameter descriptions and committed values are in `effect.current.parameters`
and `effect.current.values`. Pass edited values back to `configure()` to apply.
Treat `current` and its pass descriptors as read-only; use `configure()` and the
size/source setters to change a running effect so cached bindings stay valid.
Keep this call on the main thread. Heavy presets can take time to translate and
compile; the demo applies parameter changes only when Apply is pressed.

For parsing without presentation, use
`RetroArchShaderImporter.load_file(path, parameter_values = {}, options = {})`. It returns an
`ok` flag, a message, parameter descriptions, values and shader/pass resources.
Shader files, presets and lookup images are read in place and never modified.
Keep their directory structure intact. `res://`, `user://` and absolute paths
are accepted; external collections are not included in this add-on.

Dependent `.glsl` helper passes return `preset_candidates` with exact referring
presets. The demo offers buttons to load a complete preset. The previous
effect stays active until a valid replacement is selected. You can also call
`RetroArchShaderImporter.find_presets(source_path, collection_root = "")`;
an explicit collection root searches that tree, while automatic discovery
searches nearby shader families. Discovery bounds file and directory traversal.
It never selects among different presets automatically.

Parameter lists in presets are advisory: names are trimmed and deduplicated,
and names absent from shader declarations are recorded in `warnings` and
`ignored_preset_parameters` without creating controls or uniforms. Unknown
explicit `parameter_values` still fail. Declared parameters accept preset
values even when absent from the list. Explicit edits override preset values;
both must be finite numbers and clamp to the declared bounds.

For shared GLSL parameters, the last pass's declaration supplies the default,
label, bounds and step for the single shared control. This follows the GLSL
driver's ordered uniform uploads; different metadata produces a warning.
See [RetroArch's parameter loading](https://github.com/libretro/RetroArch/blob/master/gfx/video_shader_parse.c)
and [GLSL uniform uploads](https://github.com/libretro/RetroArch/blob/master/gfx/drivers_shader/shader_glsl.c).
Pragma steps are optional and default to 10% of the range; fixed-value
parameters use a positive UI step. Invalid declarations remain errors.

## Public API

`post_process.gd` extends `CanvasLayer`. Add it to the scene tree before
configuring it. Keep the source viewport alive for the effect's lifetime.

| Method | Contract |
| --- | --- |
| `configure(options)` | Load and apply `shader_path` with optional `shader_parameters` when `shader_enabled` is true. Omitted/false `shader_enabled` disables the effect. |
| `configure_imported(result)` | Apply a successful importer result, including a previously retained result for rollback. Treat it and its resources as immutable. |
| `set_framebuffer_texture(texture)` | Supply the separately rendered source required by pass chains. Its content may update each frame; only call again when the texture resource changes. |
| `set_input_size(size)` | Set the logical source resolution; clear any source region. Finite positive sizes are floored per axis to whole pixels, with a minimum of one pixel. Invalid/nonpositive values use the output size. |
| `set_source_region(rect, logical_size)` | Restrict processing to a physical viewport rectangle and specify its logical source resolution, normalized as for `set_input_size`. Invalid rectangles restore full-viewport presentation. |

Read `active`, `error_message`, and `current` for status. A failed configuration
returns `ok: false`, a `message`, and the previous `active` state. It may include
`preset_candidates`. A successful active configuration also returns `current`.
Use the setters rather than changing size fields directly. Disabling clears
`current`, resets the frame counter and releases the intermediate chain.

Importer results always include `ok` and `message`. Successful results contain
`path`, `label`, `parameters`, `values`, `warnings`, `textures`, and either a
`shader` or ordered `passes`. Each parameter describes `name`, `label`,
`default`, `min`, `max`, and `step`. Internal pass descriptors are not a stable
serialization format. Do not serialize Shader/Texture resources as settings;
store the path and parameter values instead.

## Supported pipeline

- Single-pass and multipass presets, up to 16 passes.
- Pragma parameters, preset overrides and parameter bounds.
- Previous-pass, original-frame and alias inputs; per-axis pass sizing.
- Sized single-pass targets and original-frame `PassPrevNTexture` references.
- `textureOffset`, `textureLodOffset` and `texelFetchOffset`, including mip levels.
- PNG/JPEG/WebP lookup images with independent filtering and wrapping.
- Frame history, feedback, frame-count moduli, mipmaps, HDR and sRGB targets.
- Physical output coordinates separate from the logical source texel grid.
- Affine vertex quad transforms, vertex helpers and mutable per-invocation globals.
- Rectangular matrices and legacy GLSL numeric, array and loop syntax.
- Mixed matrix constructors with one evaluation per argument, final vector
  component truncation, parameter-dependent arrays and prefix increments.
- Repeat/mirrored-repeat pass wrapping and mipmapped LUT border/wrap filtering.
- Transactional loading and explicit errors for unsupported input.

Compatibility is established per collection snapshot, not for arbitrary GLSL.
See the [compatibility report and missing-feature priorities](../SUPPORT.md) and
[per-file catalog](../compatibility.json) for the audited collection.
Slang/Slangp and Cg are outside this version's scope. Includes, perspective
geometry and arbitrary GLSL constructs/preset settings remain unverified. A source pass
that requires a preset returns matching choices when opened alone.
Advanced history/mipmap/HDR presets use `DrawableTexture2D` and texture-blit
shaders, and add one frame of presentation delay. These APIs require the tested
Godot generation; older engine versions and other renderers are unverified.
Original/history/feedback mip levels use GPU atlases, as do earlier-pass mip
levels. Unused compatibility samplers are removed before Godot binds textures.
Allocation limits are 16 megapixels per pass, 64 megapixels across passes and
256 MiB including history, feedback and mipmaps. Larger output can exceed them.

Legacy presets may contain equivalent duplicate values, an unclosed line quote
or settings for nonexistent passes. Equivalent values and line content are
preserved; unused pass settings produce warnings. Missing LUT bindings can
inherit defaults from nearby presets referencing the exact same shader file.
For a shared LUT name, matching configurations across every pass must agree;
incomplete directory scans cannot establish a default. Explicit bindings take
priority, and ambiguous defaults remain errors. Legacy `3dfx/shaders` paths can resolve to
`gpu/shaders/3dfx` in the same collection, with a warning. Diagnostics are returned
by `load_file()` and retained in the compatibility catalog.

Seven compatibility profiles match the complete decoded source fingerprint,
normalizing CRLF/LF. They repair the auto-box shaders' upstream 0..1 clamps to use their
transformed texture coordinates, reconcile Grade's pragma and uniform names,
and supply standalone defaults for unconfigured border, CRT-mask, NES-table
and Grade sources. Defaults use existing collection images; Grade uses identity
16/64 LUTs. Explicit presets choose their own images. Each profile emits a
warning, visible in the picker's status tooltip, and leaves external files
untouched. Edited source contents do not receive these repairs automatically.

## Exporting a game

External absolute paths remain ordinary files on the player's machine. For
bundled `res://` shaders, include `*.glsl` and `*.glslp` in the Godot export
preset's non-resource include filter. LUTs are decoded from their original
PNG/JPEG/WebP bytes; arrange for those original image files to be included and
accessible too. Test the exported build, since running inside the editor does
not prove that raw source files were packaged. External collections and their
licenses are your responsibility.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| A helper source needs additional textures or uniforms | Select one of `preset_candidates`, or open its complete `.glslp` preset. |
| Multipass effects need a separate composed framebuffer | Call `set_framebuffer_texture()` with a live source viewport texture before configuring. |
| The old effect remains visible after Apply | Inspect the returned `message`; replacement is transactional. |
| LUT/source not found | Preserve the collection's directory structure and check exported raw files. |
| Output is blank or flat | Use the rendered probe; check source/output dimensions and startup frames against [SUPPORT.md](../SUPPORT.md). |
| A resize hides the effect | Inspect `error_message` for allocation limits; reduce output or pass scale. A valid subsequent resize can recover. |
| First load pauses the main thread | Translation and compilation are synchronous. Load during a transition; measure with the [import profiler](PERFORMANCE.md). |

The verified baseline is Godot 4.7.1, Windows, Compatibility. Other engine
versions, platforms and rendering backends need their own rendered checks.
Headless checks validate imports and lifecycle, but cannot establish pixel output.
