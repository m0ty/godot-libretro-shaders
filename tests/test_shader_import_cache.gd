extends SceneTree
## Translation reuse must leave file reads, dependencies, parameter resolution
## and Godot parser validation fresh. Synthetic fixtures need no game data.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")
const TranslationCache := preload("res://addons/retroarch_shaders/translation_cache.gd")
const GAIN_SOURCE := """#pragma parameter GAIN "Gain" %s 0.0 1.0 0.1
#if defined(FRAGMENT)
uniform float GAIN;
void main() { gl_FragColor=vec4(GAIN,0.2,0.4,1.0); }
#endif
"""
const MASK_SOURCE := """#if defined(FRAGMENT)
uniform sampler2D mask;
void main() { gl_FragColor=texture2D(mask,vec2(0.5)); }
#endif
"""
var checks := 0
var failures := 0
var folder := ""
var files: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> bool:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
	return value


func _write(name: String, text: String) -> String:
	var path := folder.path_join(name)
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(text)
	file.close()
	if path not in files:
		files.append(path)
	return path


func _image(name: String, color: Color) -> String:
	var path := folder.path_join(name)
	var image := Image.create(2,2,false,Image.FORMAT_RGBA8)
	image.fill(color)
	_check(image.save_png(path) == OK,"Write disposable LUT image")
	if path not in files:
		files.append(path)
	return path


func _load(path: String, values: Dictionary = {}, cached: bool = true) -> Dictionary:
	return Importer.load_file(path,values,{"profile":true,"cache":cached})


func _run() -> void:
	folder = OS.get_environment("TEMP").replace("\\","/").path_join("shader-import-cache-%d"%Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(folder) == OK,"Create isolated translation cache fixtures")
	_translation_reuse()
	_typed_helpers()
	_nested_expressions()
	_chain_changes()
	_lut_changes()
	_inferred_lut_changes()
	_failures()
	_cache_bounds()
	if DisplayServer.get_name() != "headless":
		await _render_equivalence()
	Importer.clear_translation_cache()
	for path: String in files:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(folder)
	print("Shader import cache: %d checks, %d failures"%[checks,failures])
	quit(0 if failures == 0 else 1)


func _translation_reuse() -> void:
	var path := _write("gain.glsl",GAIN_SOURCE%"0.5")
	Importer.clear_translation_cache()
	var limits := Importer.translation_cache_stats()
	_check(limits.max_entries == 64 and limits.max_bytes == 16*1024*1024,"Public importer cache reports its bounded default capacity")
	var uncached := _load(path,{},false)
	if not _check(uncached.ok,"Uncached translation succeeds"):
		return
	_check(Importer.translation_cache_stats().entries == 0,"Disabling translation reuse leaves the cache empty")
	var cold := _load(path)
	var warm := _load(path,{"GAIN":0.8})
	if not _check(cold.ok and warm.ok,"Cold and reused translations succeed"):
		return
	_check(uncached.shader.code == cold.shader.code and cold.shader.code == warm.shader.code,"Uncached, cold and reused shader code are identical")
	_profile(uncached,0,0,1)
	_profile(cold,0,1,0)
	_profile(warm,1,0,0)
	var before_bypass := Importer.translation_cache_stats()
	var bypass := _load(path,{"GAIN":0.3},false)
	var bypass_cache: Dictionary = bypass.profile.cache
	_check(bypass.ok and bypass.shader.code == cold.shader.code and bypass.values.GAIN == 0.3 and bypass_cache.hits == 0 and bypass_cache.misses == 0 and bypass_cache.bypasses == 1 and bypass_cache.stores == 0 and bypass_cache.oversized_skips == 0,"Bypassing a populated cache translates equivalent code with fresh values and only a per-load bypass record")
	_check(Importer.translation_cache_stats() == before_bypass,"Bypassing a populated cache leaves all global entries, bytes and activity counters unchanged")
	_check(warm.profile.translation_us == 0 and warm.profile.translation_passes.size() == 1 and warm.profile.translation_passes[0].cache_hit,"A cache hit records zero translation work while retaining a pass record")
	var reused: Dictionary = warm.profile.translation_passes[0]
	_check(reused.preprocess_us == 0 and reused.bindings_us == 0 and reused.lowering_us == 0 and reused.emission_us == 0,"A cache hit records zero source-rewrite phases")
	_check(cold.values.GAIN == 0.5 and warm.values.GAIN == 0.8,"Parameter overrides are resolved again while translation is reused")
	_check(cold.shader != warm.shader,"Each import receives a fresh Shader resource for parser validation")
	var original: String = cold.shader.code
	warm.shader.code = "shader_type canvas_item; void fragment() { COLOR=vec4(0.0); }"
	cold.parameters[0].default = 0.1
	var after_mutation := _load(path)
	_check(after_mutation.ok and after_mutation.shader.code == original and after_mutation.parameters[0].default == 0.5,"Returned shader and parameter mutations cannot alter later cache results")
	_write("gain.glsl",(GAIN_SOURCE%"0.5").replace("0.2,0.4","0.7,0.4"))
	var edited := _load(path)
	_check(edited.ok and edited.shader.code != original,"A same-length source edit invalidates translated code")
	_profile(edited,0,1,0)
	_check(not Importer.load_file(path).has("profile"),"Ordinary imports omit opt-in profiling data")


func _typed_helpers() -> void:
	# Most parameters do not occur in individual helpers. The active ones also
	# exercise prefix names, local shadowing, int returns and bool constructors.
	var source := "// Synthetic mixed-type helper fixture; MIT licensed.\n"
	for name: String in ["GAIN", "GAIN_LONG"]:
		source += '#pragma parameter %s "%s" 0.2 0.0 1.0 0.1\nuniform float %s;\n' % [name, name, name]
	for index in 32:
		source += '#pragma parameter UNUSED_%d "Unused %d" 0.5 0.0 1.0 0.1\nuniform float UNUSED_%d;\n' % [index, index, index]
	source += """bool positive(float value) { return value > 0.0; }
int count_value() { return 2; }
float offset_gain(float GAIN) { return GAIN + 1; }
void main() {
    float scaled = GAIN_LONG * count_value();
    float offset = offset_gain(GAIN) * 0.5;
    gl_FragColor = vec4(scaled, offset, vec2(positive(scaled)));
}
"""
	var path := _write("typed.glsl", source)
	Importer.clear_translation_cache()
	var uncached := _load(path, {}, false)
	var cold := _load(path)
	var warm := _load(path, {"GAIN_LONG": 0.3})
	if not _check(uncached.ok and cold.ok and warm.ok, "Mixed-type helpers compile with many shared parameter declarations"):
		return
	_check(uncached.shader.code == cold.shader.code and cold.shader.code == warm.shader.code,
		"Mixed-type helper code stays identical across uncached, cold and reused translation")
	_check(warm.parameters.size() == 34 and warm.values.GAIN == 0.2 and warm.values.GAIN_LONG == 0.3,
		"Unused parameter metadata and prefix-named overrides remain available")
	_check(warm.shader.code.contains("Synthetic mixed-type helper fixture; MIT licensed."),
		"Lowering and cached translation retain the source notice")


func _nested_expressions() -> void:
	# Exercise delimiters shared by argument parsing, declaration splitting,
	# comma lowering and type inference, including nested conditional branches.
	var path := _write("nested.glsl", """// UTF-8 notice: café λ; retained without changing syntax offsets.
#define CHANNEL(value) ((value) > 0.0 ? 0.6 : 0.1)
float select_channel(float value) {
    float samples[2] = float[](0.2, 0.4);
    float first; float second;
    first = samples[0], second = samples[1];
    return value > 0.0 ? (first < second ? second : first) : first;
}
void main() {
    float exponent = 2e-1+0.1;
    vec2 channels = vec2(select_channel(1.0), CHANNEL(1.0));
    gl_FragColor = vec4(channels, exponent, 1.0);
}
""")
	Importer.clear_translation_cache()
	var uncached := _load(path, {}, false)
	var cold := _load(path)
	var warm := _load(path)
	if not _check(uncached.ok and cold.ok and warm.ok, "Nested arrays, ternaries, macro arguments and comma assignments compile"):
		return
	_check(uncached.shader.code == cold.shader.code and cold.shader.code == warm.shader.code,
		"Nested expression translation stays identical across cache modes")
	_check(warm.shader.code.contains("UTF-8 notice: café λ; retained without changing syntax offsets."),
		"Syntax scans preserve Unicode source notices")


func _chain_changes() -> void:
	_write("first.glsl",GAIN_SOURCE%"0.4")
	_write("last.glsl",GAIN_SOURCE%"0.6")
	var contents := "shaders=2\nshader0=first.glsl\nshader1=last.glsl\n"
	var path := _write("chain.glslp",contents)
	Importer.clear_translation_cache()
	var cold := _load(path)
	var warm := _load(path,{"GAIN":0.7})
	if not _check(cold.ok and warm.ok,"Shared-parameter chain imports through cold and reused translation"):
		return
	_check(cold.parameters.size() == 1 and cold.values.GAIN == 0.6 and warm.values.GAIN == 0.7,"Shared last-pass defaults and explicit overrides stay fresh")
	_check(cold.passes[0].shader.code == warm.passes[0].shader.code and cold.passes[1].shader.code == warm.passes[1].shader.code,"Parameter value edits reuse both chain translations")
	_profile(warm,2,0,0)
	_write("last.glsl",GAIN_SOURCE%"0.8")
	var metadata_edit := _load(path)
	_check(metadata_edit.ok and metadata_edit.parameters[0].default == 0.8 and metadata_edit.values.GAIN == 0.8,"Editing later-pass parameter metadata refreshes the shared default")
	_check(metadata_edit.passes[0].shader.code != cold.passes[0].shader.code and metadata_edit.passes[1].shader.code != cold.passes[1].shader.code,"Shared metadata changes invalidate every affected pass, including unchanged source")
	_profile(metadata_edit,0,2,0)
	_write("chain.glslp",contents+"scale_type0=absolute\nscale0=12\n")
	var sizing := _load(path)
	_check(sizing.ok and sizing.passes[0].sizing.scale_x == 12.0 and sizing.passes[0].sizing.type_x == "absolute","Preset sizing metadata is re-read independently of translated code")
	_write("sample.glsl","#if defined(FRAGMENT)\nuniform sampler2D Texture; varying vec2 TEX0; void main() { gl_FragColor=texture2D(Texture,TEX0); }\n#endif\n")
	var filtered := _write("filtered.glslp","shaders=2\nshader0=sample.glsl\nshader1=sample.glsl\nfilter_linear1=false\n")
	var nearest := _load(filtered)
	_write("filtered.glslp","shaders=2\nshader0=sample.glsl\nshader1=sample.glsl\nfilter_linear1=true\n")
	var linear := _load(filtered)
	_check(nearest.ok and linear.ok and nearest.passes[1].shader.code != linear.passes[1].shader.code,"Preset pass filter changes invalidate the sampling translation")
	_write("alias.glsl","uniform sampler2D StageTexture; void main() { gl_FragColor=texture2D(StageTexture,vec2(0.5)); }\n")
	var aliased := _write("aliased.glslp","shaders=2\nshader0=sample.glsl\nalias0=Stage\nshader1=alias.glsl\n")
	_check(_load(aliased).ok,"A prior-pass alias imports before binding edits")
	_write("aliased.glslp","shaders=2\nshader0=sample.glsl\nalias0=Other\nshader1=alias.glsl\n")
	_check(not _load(aliased).ok,"Changing preset aliases cannot reuse obsolete successful bindings")


func _lut_changes() -> void:
	_write("mask.glsl",MASK_SOURCE)
	var image := _image("mask.png",Color.RED)
	var contents := "shaders=1\nshader0=mask.glsl\ntextures=mask\nmask=mask.png\nmask_linear=true\n"
	var path := _write("mask.glslp",contents)
	Importer.clear_translation_cache()
	var cold := _load(path)
	var warm := _load(path)
	if not _check(cold.ok and warm.ok,"Explicit LUT shader imports cold and from translation cache"):
		return
	_image("mask.png",Color.BLUE)
	var changed := _load(path)
	_check(changed.ok and changed.shader.code == warm.shader.code and changed.textures.ra_lut_mask.get_image().get_pixel(0,0) == Color.BLUE,"Edited LUT pixels are loaded again while translated code stays reusable")
	_profile(changed,1,0,0)
	DirAccess.remove_absolute(image)
	var missing := _load(path)
	_check(not missing.ok and missing.message.contains("external texture"),"A deleted LUT remains a current load error despite cached translation")
	_image("mask.png",Color.GREEN)
	var repaired := _load(path)
	_check(repaired.ok and repaired.textures.ra_lut_mask.get_image().get_pixel(0,0) == Color.GREEN,"Restoring a deleted LUT recovers without clearing translation cache")
	_write("mask.glslp",contents.replace("mask_linear=true","mask_linear=false"))
	var nearest := _load(path)
	_check(nearest.ok and not nearest.texture_descriptors[0].filter_linear and nearest.shader.code != warm.shader.code,"LUT sampler filter edits invalidate translated sampler behavior")
	_image("replacement.png",Color.BLUE)
	_write("mask.glslp",contents.replace("mask.png","replacement.png"))
	var rebound := _load(path)
	_check(rebound.ok and rebound.texture_descriptors[0].path.ends_with("replacement.png") and rebound.textures.ra_lut_mask.get_image().get_pixel(0,0) == Color.BLUE,"Changing a preset LUT binding observes the new file")


func _inferred_lut_changes() -> void:
	_write("helper.glsl",MASK_SOURCE)
	var parent_source := "shaders=1\nshader0=helper.glsl\ntextures=mask\nmask=mask.png\nmask_linear=true\n"
	_write("parent.glslp",parent_source)
	var path := _write("inferred.glslp","shaders=2\nshader0=sample.glsl\nshader1=helper.glsl\n")
	Importer.clear_translation_cache()
	var cold := _load(path)
	var warm := _load(path)
	if not _check(cold.ok and warm.ok,"Inferred sibling LUT configuration can use translation reuse"):
		return
	_write("parent.glslp",parent_source.replace("mask_linear=true","mask_linear=false"))
	var edited := _load(path)
	_check(edited.ok and not edited.texture_descriptors[0].filter_linear and edited.passes[1].shader.code != warm.passes[1].shader.code,"Sibling inferred LUT filter edits are rediscovered before cache lookup")


func _failures() -> void:
	var path := _write("repair.glsl","#include \"absent.glsl\"\nvoid main() { gl_FragColor=vec4(1.0); }\n")
	Importer.clear_translation_cache()
	var invalid := _load(path)
	_check(not invalid.ok and invalid.has("profile"),"Failed source translation still returns requested profiling evidence")
	_check(Importer.translation_cache_stats().entries == 0 and Importer.translation_cache_stats().stores == 0,"Importer failures never enter the successful translation cache")
	_profile_shape(invalid)
	_write("repair.glsl",GAIN_SOURCE%"0.3")
	var repaired := _load(path)
	_check(repaired.ok and repaired.values.GAIN == 0.3,"Correcting a failed source is never hidden by a cached failure")
	var missing := _load(folder.path_join("absent.glsl"))
	_check(not missing.ok and missing.has("profile"),"Early file-read failures still return requested profiling evidence")
	_profile_shape(missing)


func _profile(result: Dictionary, hits: int, misses: int, bypasses: int) -> void:
	if not _profile_shape(result):
		return
	var cache: Dictionary = result.profile.cache
	_check(cache.hits == hits and cache.misses == misses and cache.bypasses == bypasses,"Each load reports its own cache hits, misses and bypasses")


func _profile_shape(result: Dictionary) -> bool:
	var profile: Dictionary = result.get("profile",{})
	var phases := ["read_us","preparation_us","texture_loading_us","translation_us","shader_validation_us","cache_lookup_us"]
	var valid := profile.has("total_us") and profile.has("cache") and profile.has("translation_passes")
	var measured := 0
	for phase: String in phases:
		valid = valid and profile.has(phase) and int(profile.get(phase,-1)) >= 0
		measured += int(profile.get(phase,0))
	valid = valid and int(profile.get("total_us",-1)) == measured
	for record: Dictionary in profile.get("translation_passes",[]):
		var pass_measured := 0
		for phase: String in ["preprocess_us","bindings_us","lowering_us","emission_us"]:
			valid = valid and record.has(phase) and int(record.get(phase,-1)) >= 0
			pass_measured += int(record.get(phase,0))
		valid = valid and int(record.get("total_us",-1)) == pass_measured
	return _check(valid,"Exclusive major and translation subphases sum exactly to their elapsed totals")


func _cache_bounds() -> void:
	var cache := TranslationCache.new(2,64)
	_check(cache.store_translation("a",{"ok":true,"code":"é","custom_geometry":false}) and cache.stats().bytes == 16,"Cache byte accounting includes retained Godot key/code characters and terminators")
	cache.store_translation("b",{"ok":true,"code":"B","custom_geometry":false})
	var borrowed: Dictionary = cache.get_translation("a")
	borrowed.code = "mutated"
	cache.store_translation("c",{"ok":true,"code":"C","custom_geometry":false})
	_check(cache.get_translation("b").is_empty() and cache.get_translation("a").code == "é","LRU eviction retains the touched entry and cache reads cannot mutate stored code")
	_check(cache.stats().entries == 2 and cache.stats().evictions == 1,"Translation entry count stays bounded through eviction")
	cache.store_translation("a",{"ok":true,"code":"ZZZ","custom_geometry":true})
	_check(cache.stats().bytes == 40 and cache.stats().entries == 2 and cache.get_translation("a").custom_geometry,"Replacing an entry updates bytes and geometry metadata without growing its entry count")
	cache.remove_translation("a")
	cache.remove_translation("absent")
	_check(cache.stats().entries == 1 and cache.stats().bytes == 16 and cache.get_translation("a").is_empty(),"Discarding parser-rejected translations releases bytes and safely tolerates absent keys")
	cache = TranslationCache.new(8,48)
	cache.store_translation("a",{"ok":true,"code":"123456","custom_geometry":false})
	cache.store_translation("b",{"ok":true,"code":"654321","custom_geometry":false})
	_check(cache.stats().entries == 1 and cache.stats().bytes <= 48 and cache.stats().evictions == 1,"Byte budget evicts entries before the entry-count limit")
	_check(not cache.store_translation("large",{"ok":true,"code":"x".repeat(13),"custom_geometry":false}) and cache.stats().oversized_skips == 1 and cache.get_translation("b").code == "654321","Oversized translations are skipped while existing useful entries remain")
	_check(not cache.store_translation("failed",{"ok":false,"code":"X"}) and cache.get_translation("failed").is_empty(),"Failed translations cannot poison the cache")
	cache.clear()
	var stats: Dictionary = cache.stats()
	_check(stats.entries == 0 and stats.bytes == 0 and stats.hits == 0 and stats.misses == 0 and stats.stores == 0 and stats.evictions == 0 and stats.oversized_skips == 0,"Clearing a cache releases entries and resets evidence counters")


func _render_equivalence() -> void:
	var path := _write("render.glsl",GAIN_SOURCE%"0.5")
	Importer.clear_translation_cache()
	var uncached := _load(path,{},false)
	var cold := _load(path)
	var warm := _load(path)
	var edited := _load(path,{"GAIN":0.8})
	var viewport := SubViewport.new()
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.size = Vector2i(32,24)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var display := ColorRect.new()
	display.size = Vector2(viewport.size)
	viewport.add_child(display)
	var pixels: Array[Color] = []
	for result: Dictionary in [uncached,cold,warm,edited]:
		if not _check(result.ok,"Rendered cache equivalence fixture imports"):
			continue
		var material := ShaderMaterial.new()
		material.shader = result.shader
		for name: String in result.values:
			material.set_shader_parameter(name,result.values[name])
		display.material = material
		for frame in 4:
			await process_frame
			await RenderingServer.frame_post_draw
		pixels.append(viewport.get_texture().get_image().get_pixel(16,12))
	if pixels.size() == 4:
		_check(_close(pixels[0],Color(0.5,0.2,0.4,1.0)) and _close(pixels[0],pixels[1]) and _close(pixels[1],pixels[2]),"Uncached, cold and reused translations render equivalent reference pixels")
		_check(_close(pixels[3],Color(0.8,0.2,0.4,1.0)),"A parameter override changes pixels through reused shader translation")
	for cached: bool in [false, true]:
		var typed := _load(folder.path_join("typed.glsl"), {}, cached)
		if not _check(typed.ok, "Mixed-type helper rendering imports"):
			continue
		var material := ShaderMaterial.new()
		material.shader = typed.shader
		for name: String in typed.values:
			material.set_shader_parameter(name, typed.values[name])
		display.material = material
		for frame in 4:
			await process_frame
			await RenderingServer.frame_post_draw
		_check(_close(viewport.get_texture().get_image().get_pixel(16,12), Color(0.4,0.6,1.0,1.0)),
			"Integer helpers, bool constructors and shadowed parameter arithmetic retain their rendered values")
	for cached: bool in [false, true]:
		var nested := _load(folder.path_join("nested.glsl"), {}, cached)
		if not _check(nested.ok, "Nested expression rendering imports"):
			continue
		var material := ShaderMaterial.new()
		material.shader = nested.shader
		display.material = material
		for frame in 4:
			await process_frame
			await RenderingServer.frame_post_draw
		_check(_close(viewport.get_texture().get_image().get_pixel(16,12), Color(0.4,0.6,0.3,1.0)),
			"Nested ternaries, indexed comma assignments and exponent arithmetic retain their rendered values")
	viewport.free()


func _close(a: Color,b: Color) -> bool:
	return absf(a.r-b.r) < 0.012 and absf(a.g-b.g) < 0.012 and absf(a.b-b.b) < 0.012
