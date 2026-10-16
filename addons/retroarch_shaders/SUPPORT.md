# Collection compatibility

Release 1.0.0 keeps this catalog as historical evidence. Importer and runtime
optimizations are verified by focused regressions and release checks;
they do not relabel this catalog as a new full-collection audit. See the
[performance guide](docs/PERFORMANCE.md) for the measured scope.

Audited with Godot 4.7.1-stable (official), Windows, Compatibility, AMD Radeon RX 7800 XT.

The snapshot contains **484 presets** and **578 GLSL sources**.
**473 presets passed fresh rendered smoke checks** at 640x480 and 800x600 (412 outside CRT).
**11 additional presets passed under specific output-size or warmup conditions**, listed below. Their standard startup/size checks remain review cases.
Rendered evidence in this snapshot uses the runtime fingerprint recorded in `compatibility.json`; no prior CRT rendering evidence is carried forward.
**0 presets are rejected by the importer; 0 have GPU errors; 0 require visual review; 0 remain unverified.**

Import acceptance and nonblank output do not establish RetroArch pixel equivalence. Other renderers, operating systems and GPUs are unverified.

This catalog is historical evidence for its recorded runtime fingerprint.
The subsequent release-readiness changes to declaration ordering and runtime
mip scheduling do not relabel that collection audit. Their focused checks and
measurement scope are described in [the performance guide](docs/PERFORMANCE.md);
use [the audit workflow](docs/DEVELOPMENT.md) to establish a new collection snapshot.

The subsequent import-cache/profiler change preserves generated code and import
metadata across all 1,062 collection inputs, comparing the audited importer with
both cold and cached loads. It also passes 576 focused GPU regression checks.
This is separate from the full collection render snapshot above; its recorded
source fingerprint is retained rather than relabeling older render evidence.

The [per-file catalog](compatibility.json) lists every tested path, SHA256, status, rendered conditions and failure reason. Source files are audited separately. 429 sources passed standalone GPU checks; 5 passed under documented conditions; 144 helper/data passes are supported through matching verified presets. For missing dependencies, the picker offers exact referring presets instead of substituting textures or parameters. Standalone source results also include 0 visual-review cases, 0 translation-only cases, 0 rejections, 0 GPU errors and 0 timeouts. Helper support through a preset is distinct from independent rendering.

The headless audit accepted 436 sources independently and identified 142 requiring preset dependencies. 2 independently compiling xBR data passes are verified through complete presets; their standalone low-contrast samples remain in the catalog.

## Presets by category

| Category | Presets | Fresh GPU pass | Conditional GPU pass | Prior CRT GPU pass | Import rejected | GPU error | Review | Unverified |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| (root) | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |
| anti-aliasing | 5 | 5 | 0 | 0 | 0 | 0 | 0 | 0 |
| blurs | 3 | 3 | 0 | 0 | 0 | 0 | 0 | 0 |
| borders | 32 | 32 | 0 | 0 | 0 | 0 | 0 | 0 |
| cel | 15 | 15 | 0 | 0 | 0 | 0 | 0 | 0 |
| crt | 61 | 61 | 0 | 0 | 0 | 0 | 0 | 0 |
| cubic | 4 | 4 | 0 | 0 | 0 | 0 | 0 | 0 |
| ddt | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| deblur | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |
| denoisers | 10 | 10 | 0 | 0 | 0 | 0 | 0 | 0 |
| dithering | 6 | 6 | 0 | 0 | 0 | 0 | 0 | 0 |
| eagle | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| film | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| gpu | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |
| handheld | 139 | 129 | 10 | 0 | 0 | 0 | 0 | 0 |
| hqx | 7 | 7 | 0 | 0 | 0 | 0 | 0 | 0 |
| interpolation | 11 | 11 | 0 | 0 | 0 | 0 | 0 | 0 |
| motionblur | 5 | 5 | 0 | 0 | 0 | 0 | 0 | 0 |
| nedi | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |
| nes_raw_palette | 4 | 4 | 0 | 0 | 0 | 0 | 0 | 0 |
| nnedi3 | 7 | 7 | 0 | 0 | 0 | 0 | 0 | 0 |
| ntsc | 13 | 13 | 0 | 0 | 0 | 0 | 0 | 0 |
| omniscale | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |
| pal | 3 | 3 | 0 | 0 | 0 | 0 | 0 | 0 |
| presets | 65 | 65 | 0 | 0 | 0 | 0 | 0 | 0 |
| procedural | 12 | 11 | 1 | 0 | 0 | 0 | 0 | 0 |
| reshade | 9 | 9 | 0 | 0 | 0 | 0 | 0 | 0 |
| sabr | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |
| scalefx | 3 | 3 | 0 | 0 | 0 | 0 | 0 | 0 |
| scalehq | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |
| scalenx | 6 | 6 | 0 | 0 | 0 | 0 | 0 | 0 |
| sharpen | 3 | 3 | 0 | 0 | 0 | 0 | 0 | 0 |
| stereoscopic-3d | 5 | 5 | 0 | 0 | 0 | 0 | 0 | 0 |
| vhs | 3 | 3 | 0 | 0 | 0 | 0 | 0 | 0 |
| windowed | 5 | 5 | 0 | 0 | 0 | 0 | 0 | 0 |
| xbr | 19 | 19 | 0 | 0 | 0 | 0 | 0 | 0 |
| xbrz | 5 | 5 | 0 | 0 | 0 | 0 | 0 | 0 |
| xsal | 5 | 5 | 0 | 0 | 0 | 0 | 0 | 0 |
| xsoft | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0 |

## Missing capabilities

Counts below are the **first reported rejection per preset**. Fixing one gap can reveal another, so these are not guaranteed unlock counts.

| First rejection group | Presets |
| --- | ---: |
| None | 0 |

Implemented compatibility extensions:

- Single-pass source/absolute/per-axis sizing through render targets; explicit full-viewport presets retain direct presentation.
- Integer-valued decimal frame moduli, with fractional/nonfinite/overflow values rejected.
- `textureOffset`, `textureLodOffset` and `texelFetchOffset` for logical framebuffers, pass/history/feedback inputs and external images, preserving filtering and supported wrap modes.
- Original-frame `PassPrevNTexture` references; GPU snapshot mip atlases and removal of unused sampler declarations.
- Trimmed/deduplicated advisory parameter lists; stale preset names are ignored with catalog diagnostics, while unknown explicit edits still fail.
- Shared GLSL parameters use the last declaration's metadata/default; preset and explicit values override it and clamp to those bounds.
- Optional pragma steps default to one tenth of the range (fixed values use a positive UI step).
- Affine vertex quad transforms and vertex helper functions, with per-invocation varying state and cleared uncovered output.
- Rectangular matrices, mutable stage globals, legacy array/declaration/loop syntax and GLSL numeric conversions.
- Repeat/mirrored-repeat pass sampling and mipmapped LUT wrapping, including border filtering at each level.
- Equivalent duplicate preset values, legacy unclosed line quotes and ignored out-of-range pass metadata, with diagnostics.
- Missing LUT bindings can inherit an unambiguous sibling preset's configuration for the exact same shader source; conflicting defaults still fail.
- Legacy `3dfx/shaders` paths resolve to the collection's `gpu/shaders/3dfx` location when present, with a diagnostic.

- Mixed scalar/vector matrix constructors preserve column order and evaluate each argument once; vector constructors truncate only the final surplus components as GLSL specifies.
- Runtime array initializers, prefix increments, scientific literals adjacent to arithmetic, and user functions named `light`.
- Exact-source compatibility profiles repair upstream auto-box clipping and Grade parameter names, and supply documented standalone LUT/image defaults. Changed source contents do not receive these repairs; explicit presets control texture bindings.
- Exact-reference preset discovery and selection for dependent source passes, with bounded directory/file traversal.

Parameter diagnostics are retained per file: 69 imported presets contain ignored undeclared names; 9 use differing shared declarations. These are diagnostics, not active controls or importer failures.

Remaining scope:

- Inspect review cases and validate appearance against RetroArch; smoke tests establish compilation and varied finite output, not equivalent rendering.
- Includes, arbitrary GLSL and perspective geometry remain outside the verified subset. Standalone helper passes may require their preset's textures, aliases and framebuffer configuration.
- Missing dependencies and ambiguous lookup-image defaults remain explicit errors. User-specified textures always take precedence over inherited defaults.

GPU-only failures:

None.

Initial process failures with passing repeat checks:

None.

Conditional GPU passes:

- `handheld/gameboy-light.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `handheld/gameboy-pocket.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `handheld/gameboy.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `handheld/lcd-shader-gba-color.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `handheld/lcd-shader-gbc-color.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `handheld/lcd-shader-nds-color.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `handheld/lcd-shader-palm-color.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `handheld/lcd-shader-psp-color.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `handheld/lcd-shader-vba-color.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `handheld/lcd-shader.glslp`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `procedural/iq-canyon/iq-canyon.glslp`: 640x480, 800x600, after 120 frames per size; logical input 320x240.

Conditional standalone source passes:

- `handheld/shaders/lcd-shader/lcd-pass-0.glsl`: 960x720, 1280x960, after 12 frames per size; logical input 320x240.
- `misc/flicker.glsl`: 640x480, after 13 frames per size; logical input 320x240.
- `misc/flicker.glsl`: 800x600, after 13 frames per size; logical input 320x240.
- `procedural/dave_hoskins-frozen-wasteland.glsl`: 640x480, 800x600, after 120 frames per size; logical input 320x240.
- `procedural/dave_hoskins-skin-peeler.glsl`: 640x480, 800x600, after 120 frames per size; logical input 320x240.
- `procedural/iq-canyon/iq-canyon.glsl`: 640x480, 800x600, after 120 frames per size; logical input 320x240.

Visual review:

None.

misc/flicker.glsl intentionally blacks every other frame. The standard 12-frame checks sampled black frames; isolated 13-frame checks at both output sizes verified its visible phase.

Standalone source timeouts (unverified):

None.

## Change from the previous audit

Verified presets increased from **484 to 484**. **0 additional presets** passed rendered smoke checks, including the conditional passes above. All previously supported presets retain passing evidence.

Newly verified presets:


## Reproduce

Use `tools/audit_library.py` for headless and rendered audits, then:

```powershell
python addons/retroarch_shaders/tools/summarize_audit.py --imports test-results/imports/report.json --rendered test-results/rendered/report.json --output-dir addons/retroarch_shaders
```

Use `--sizes 960x720,1280x960` and a `--case-list` for the ten handheld presets listed above, and `--warmup-frames 120` for IQ Canyon. Pass each resulting report using `--additional-rendered <report.json>`; runtime and collection hashes must match the main audits. Pass `--crt-reference <report.json>` only when preserving earlier CRT evidence. Raw logs stay outside the distributed add-on. Known Windows certificate-store and GLES shader-cache write warnings are recorded separately from shader failures.

Collection SHA256: `57ef85b622b2046c763967c96e60ba211981fb7518e8c881f71b4c8f3be9f5ac`.
