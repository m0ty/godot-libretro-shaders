# Architecture and performance

[Back to README](../README.md)


## 1.0.0 performance

### Final review

Syntax scanners read character codes without allocating one-character strings
and temporary membership arrays. They skip absent constructs before scanning
and reuse parsed units while the source stays unchanged. Source decoding uses
native searches to skip ASCII spans, while retaining strict UTF-8 checks and
the Latin-1 fallback for legacy notices. Dense mixed text and NUL-containing
inputs use the original byte-validation loop.

Sequential before/after measurements on 2026-10-16, with Godot 4.7.1 headless on
Windows, Ryzen 5 7600:

| Input | Uncached before | Uncached after | Cache hit before | Cache hit after |
| --- | ---: | ---: | ---: | ---: |
| 32 helpers / 32 parameters | 20.78 ms | 14.98 ms | 2.19 ms | 2.03 ms |
| Demo scanlines | 5.93 ms | 4.07 ms | 0.98 ms | 0.86 ms |
| CRT Lottes | 42.51 ms | 34.52 ms | 4.32 ms | 4.01 ms |
| CRT Royale, 12 passes | 7.53 s | 5.77 s | 450 ms | 308 ms |

These are median synchronous CPU import times after warmup: nine samples for
the synthetic shader and demo, three for each external preset. No other test
workers ran during the measurements. Every generated shader digest matched
before and after, across cache bypass, cleared-cache and primed-cache modes.
They measure this machine and these inputs, not rendered FPS or all shaders.
The final encoding implementation also matched Python's strict UTF-8 decoder
in 209,664 comparisons; syntax helpers matched the baseline in 8,228 cases.

### Earlier import measurements

Type lowering now reuses parsed units and boolean-function signatures, and
checks whether a name occurs before constructing its replacement expression.
On a synthetic shader with 32 helpers and 32 parameters, the nine-sample median
uncached import time changed from **39.21 ms to 19.99 ms** on the local Godot
4.7.1 Windows baseline. The generated shader digest was identical. This measures
synchronous CPU import work for that fixture, not FPS or every shader's speed.
The focused cache regression retains mixed-type and name-shadowing coverage.

Representative external presets also improved in three-sample median uncached
imports on the same machine (Ryzen 5 7600, Radeon RX 7800 XT):

| Input | Before | After the earlier pass |
| --- | ---: | ---: |
| CRT Lottes | 54.05 ms | 45.18 ms |
| CRT Royale, 12 passes | 19.28 s | 7.34 s |

All generated shader digests matched before and after, including every Royale
pass. These are indicative local CPU timings; concurrent packaging activity
may add noise. They do not establish compatibility or speed for other presets.
Reproduce the synthetic workload from a repository checkout with a new output:

```sh
godot --headless --path . --script addons/retroarch_shaders/tools/benchmark_import.gd -- --shader=res://tests/fixtures/type_lowering_benchmark.glsl --iterations=9 --output=res://test-results/type-lowering.json
```

### Runtime work and allocations

Temporal allocation now follows the resource that actually changed: changing
physical output dimensions preserves original-frame history when logical input
dimensions stay fixed. Feedback is recreated only when its target dimensions
or logical input change. A 32-resize regression with four history textures now
replaces **0 history textures instead of 128**, and rendered checks verify
preserved history and feedback pixels. This removes allocation work and avoids
blank historical frames during output resizing; it is not a frame-rate benchmark.

Mip resources are allocated only through the first 1x1 level. An 8x4 input now
creates **3 downsampling viewports and 7 materials instead of 15 and 31**; a
1x1 input needs only the atlas and one copy material. Growing the input extends
the pool, and shrinking retains it for reuse while disabling surplus levels.
The shader-visible 16-slot atlas layout is unchanged. Rendered checks cover
growth, shrinkage, suspension, rotating sources and the highest mip slot, and
retain the baseline's two-draw source-update/readback bound. These are reduced
object-allocation counts, not measured GPU memory or FPS gains.

## Earlier release-readiness improvements

Declaration ordering scans each helper's dependency edges once, then visits
stable topological layers. This preserves declaration order, overload groups,
unused-helper pruning and cycle handling without rescanning function bodies for
every dependency layer. A 96-helper synthetic chain measured on 2026-10-15 with
Godot 4.7.1 on Windows improved from **43,220 to 1,255 microseconds** (seven-sample
median). This isolates declaration ordering; it does not measure whole-import
latency or rendered FPS. The repository regression
`tests/test_shader_declaration_order.gd -- --benchmark` reproduces the workload.

Mip atlases stop downsampling when both dimensions reach 1x1. A single copy fills
the repeated terminal rows, preserving the existing 16-level sampling layout.
For an 8x4 input, this enables **3 downsampling passes instead of 15**, and
**4 atlas copy draws instead of 16**. A 320x240 input uses 8 downsampling passes.
The final release also allocates levels on demand as described above. These
draw counts describe eliminated rendering work, not an FPS measurement.

Disabled effects stop processing, and only drawable chains subscribe to the
frame-completion signal. Invalid layouts suspend pass and mip rendering until
a valid layout returns. Stable feedback/atlas texture bindings and unchanged
crop uniforms are retained between frames; rotating history textures are still
updated after drawing.

## Runtime organization

| File | Responsibility |
| --- | --- |
| `glsl_importer.gd` | Read presets, resolve parameters/dependencies, then translate each GLSL stage into a Godot canvas shader. |
| `import_session.gd` | Hold one import's options and exclusive timing records. |
| `translation_cache.gd` | Bound retained generated-code payloads and evict the least recently used translation. |
| `source_profiles.gd` | Apply explicit compatibility repairs/defaults to exact source fingerprints. |
| `post_process.gd` | Own presentation, pass viewports and materials; update layout and frame-dependent uniforms. |
| `glsl_drawable_chain.gd` | Copy original/history/feedback frames on the GPU after drawing. |
| `glsl_mip_atlas.gd` | Build GPU mip levels and pack them into a viewport-backed atlas. |
| `demo/demo.gd` | Create the synthetic source, collect parameter edits and show matching presets. |
| `tools/` | Run isolated import/render probes, validate evidence and build addon or standalone packages. |

Keep import-time work separate from frame updates. Translation and texture
decoding happen during `configure()`; dimension changes invalidate the layout,
while frame counts and rotating history bindings update during rendering.
Runtime snapshots and mip generation stay on the GPU. Image readbacks belong
to the audit probe and regression tests, where they verify actual output.
Temporal sampler bindings are filtered once per configuration, and mip levels
share shader programs while keeping separate material parameters. Inferred LUT
settings are cached for one import only, so editing external presets is visible
on the next load.

Successful source translations are also cached in memory between imports. The
cache holds generated shader code and translation metadata, with a limit of 64
entries and 16 MiB of retained string payload, plus bounded container overhead,
and least-recently-used eviction. It never retains a caller's
Shader, Texture or material resources. Sources, presets, inferred dependencies
and LUT images are checked again on every load; the key includes the prepared
source and all translation inputs. Parameter value edits reuse code while their
values are resolved again. Changing parameter declarations, sampler settings or
pass bindings selects a different entry. Entries larger than the byte budget
are translated without being retained.

Call `RetroArchShaderImporter.clear_translation_cache()` to release entries and
reset counters. `translation_cache_stats()` returns entries, bytes, limits and
cumulative hit, miss, store, eviction and oversized-entry counts. This cache is
process-local; it does not eliminate the first translation after restarting.
Keep importer calls and cache operations on the main thread.

Opt into import timings or bypass the cache for comparison:

```gdscript
const Importer = preload("res://addons/retroarch_shaders/glsl_importer.gd")
var imported = Importer.load_file(path, {}, {"profile": true})
print(imported.profile)
var uncached = Importer.load_file(path, {}, {"profile": true, "cache": false})
```

Profiled successes and failures include `profile`. Its exclusive import phases
are `read_us`, `preparation_us`, `texture_loading_us`, `translation_us`,
`shader_validation_us` and `cache_lookup_us`; their sum is `total_us`. Read time
includes source text validation/decoding. Texture loading excludes byte reads,
which are counted in `read_us`. Cache lookup includes
key construction and storage. `translation_passes` records pass indices (-1 for
a direct screen translation), cache hits and exclusive `preprocess_us`,
`bindings_us`, `lowering_us` and `emission_us`
within each translation. Cache hits skip translation but still create and
validate fresh shader resources. Timings measure synchronous import work, not
GPU frame time or all deferred driver compilation. Profiling is off by default.

The pure translation boundary takes prepared source and resolved declaration/
sampler metadata and returns generated code. It is the candidate for a future
C++ GDExtension if measured first-load latency warrants native packaging. The
cache and profiler require no native library or Python runtime.

Run a sequential import benchmark with Godot alone:

```powershell
godot --headless --path . --script addons/retroarch_shaders/tools/benchmark_import.gd -- --shader=res://addons/retroarch_shaders/demo/shaders/scanlines.glsl --iterations=3 --output=test-results/import-benchmark.json
```

Repeat `--shader=<path>` to compare external presets. The report retains raw
samples, medians, cache counts, generated-code digests and the environment. It
compares cache bypass, a cleared translation cache and primed cache hits in one
process, after an unmeasured import warmup. A cold translation cache is distinct
from a cold process, filesystem cache or GPU driver. The tool checks actual hits
and reports partial caching when a preset exceeds the cache budget. Its output
must be a new file. Run it without other audit workers for useful timings.
Completed cases are checkpointed with `complete: false` until the run finishes;
progress goes to stderr. Existing or externally modified reports are preserved.

Historical measurements from 2026-10-11, before the release-readiness changes,
with Godot 4.7.1 Compatibility on Windows, Ryzen 5 7600
and Radeon RX 7800 XT. These are three-sample median synchronous import times
after warmup, with one benchmark process and no concurrent audit workers:

| Preset | Cache bypass | Cleared translation cache | Primed cache hit |
| --- | ---: | ---: | ---: |
| FXAA | 44.95 ms | 44.48 ms | 3.15 ms |
| CRT Lottes | 49.80 ms | 50.86 ms | 4.10 ms |
| CRT Royale | 22.25 s | 21.15 s | 439 ms |
| NNEDI3 nns64 2x / nns32 4x / nns16 8x RGB | 46.81 s | 47.99 s | 388 ms |

All measured cache-hit samples reused every translation and preserved generated
code. Syntax/type lowering dominated uncached translation: about 78% of Royale's
total import time and 97% of the largest NNEDI preset's. This is the measured
candidate for a C++ backend. First loads still pay translation costs; these
measurements establish neither a C++ speedup nor a rendered FPS improvement.
Collection-wide comparison also preserved generated code, import metadata and
diagnostics for all 1,062 inputs, and all 920 independently accepted inputs fit
in the default cache for their immediately repeated load.

The translation passes have ordering dependencies: macro expansion precedes
type conversion, and invocation-state rewrites precede sampler routing and
declaration ordering. Preserve these boundaries when adding GLSL constructs;
test generated code and rendered behavior, including vertex/fragment scope.

For CPU-side update counts, set `effect.performance_counters = true` and inspect
`effect.performance_stats`. Layout updates should stop while source and output
dimensions are unchanged. These counters describe work performed; use Godot's
profiler to measure frame time and GPU cost for the particular preset and size.

