class_name RetroArchShaderImporter
extends RefCounted
## Converts self-contained RetroArch GLSL passes at runtime.
## Source files remain in the user's collection; translated code retains notices.
## Presets can resize intermediate buffers and read original/earlier passes.
## HDR, mipmaps, original-frame history and feedback use Godot GPU resources.
## Affine quad transforms, legacy GLSL state and sampling are translated.
## Unsupported includes and unresolved dependencies fail explicitly.

const MAX_SOURCE_BYTES := 4 * 1024 * 1024
const SourceProfiles := preload("./source_profiles.gd")
const ImportSession := preload("./import_session.gd")
const TranslationCache := preload("./translation_cache.gd")
const MAX_TEXTURE_BYTES := 64 * 1024 * 1024
const MAX_TEXTURE_PIXELS := 16 * 1024 * 1024
const MAX_PASSES := 16
const STANDARD_UNIFORMS := ["Texture", "s_p", "decal", "TextureSize", "InputSize", "OutputSize", "FrameCount", "FrameDirection", "MVPMatrix"]
const COMPAT_MACROS := ["COMPAT_TEXTURE", "COMPAT_ATTRIBUTE", "COMPAT_VARYING", "COMPAT_PRECISION", "FragColor", "texture", "texture2D"]
static var _regex_cache := {}
static var _translation_cache := TranslationCache.new()

## Build an import result when configuring a shader selection. Reads, source
## dependency resolution and Godot parser validation run on every call.
## Pure translated code is cached by content; {"cache":false} bypasses the cache.
## {"profile":true} adds exclusive microsecond timings on success or failure.
## Results carry editable parameter metadata, warnings and either a shader or
## ordered passes. A failed result must leave the caller's active effect intact.
## Importing and cache access are main-thread operations.
static func load_file(path: String, parameter_values: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	var context := ImportSession.new(options)
	var result := _load_file(path,parameter_values,context)
	if not result.ok and path.get_extension().to_lower() == "glsl" and (str(result.message).contains("additional texture") or str(result.message).contains("Unsupported shader uniform")):
		result["preset_candidates"] = _find_presets(path,"",context)
		if not result.preset_candidates.is_empty(): result.message += " Choose a matching preset to load this pass with its dependencies."
	if context.profiling: result["profile"] = context.finish()
	return result

## Drop all cached translations and reset hit/miss/eviction counters.
static func clear_translation_cache() -> void:
	_translation_cache.clear()

## Returns entries/bytes/max_entries/max_bytes and hits/misses/stores/evictions/
## oversized_skips. Bytes bounds retained key + code String payloads, not containers.
static func translation_cache_stats() -> Dictionary:
	return _translation_cache.stats()

## Find exact references, without compiling or guessing a preset. Explicit
## roots search a collection; automatic discovery stops at the nearest family
## with matches. Budgets bound traversal and symlinks cannot cause recursion.
static func find_presets(source_path: String, collection_root: String = "") -> Array[String]:
	return _find_presets(source_path,collection_root)

static func _find_presets(source_path: String, collection_root: String = "", context: ImportSession = null) -> Array[String]:
	source_path = source_path.replace("\\","/").simplify_path()
	collection_root = collection_root.replace("\\","/").simplify_path() if not collection_root.is_empty() else ""
	var matches: Array[String] = []
	var directory := source_path.get_base_dir()
	var seen := {}
	var budget := 2048
	for level in (1 if not collection_root.is_empty() else 5):
		var pending: Array[String] = [collection_root if not collection_root.is_empty() else directory]
		var depths: Array[int] = [0]
		while not pending.is_empty() and budget > 0:
			var current := pending.pop_back() as String
			var depth := depths.pop_back() as int
			if seen.has(current.to_lower()): continue
			seen[current.to_lower()] = true
			budget -= 1
			for filename: String in DirAccess.get_files_at(current):
				if filename.get_extension().to_lower() != "glslp": continue
				budget -= 1
				if budget < 0: break
				var path := current.path_join(filename)
				if _preset_references(path,source_path,context): matches.append(path)
			if depth >= (12 if not collection_root.is_empty() else 2): continue
			for child: String in DirAccess.get_directories_at(current):
				if not child.begins_with("."): pending.append(current.path_join(child)); depths.append(depth+1)
		if not matches.is_empty() or not collection_root.is_empty() or budget <= 0: break
		var parent := directory.get_base_dir()
		if parent == directory or parent.is_empty() or parent.ends_with(":/") or parent == "/" or parent == "res:" or parent == "user:": break
		directory = parent
	matches.sort()
	return matches

static func _preset_references(preset_path: String, source_path: String, context: ImportSession = null) -> bool:
	var file := _read(preset_path,context)
	if not file.ok: return false
	var parsed := _preset(file.text)
	if not parsed.ok: return false
	return _preset_values_reference(parsed.values, preset_path, source_path)

# Both discovery paths use the declared pass count. Stale shaderN entries in
# a preset must not supply either a picker candidate or an inferred LUT.
static func _preset_values_reference(values: Dictionary, preset_path: String, source_path: String) -> bool:
	var count := str(values.get("shaders", ""))
	if not count.is_valid_int() or int(count) < 1 or int(count) > MAX_PASSES: return false
	var normalized_source := source_path.replace("\\", "/").simplify_path().to_lower()
	for index in int(count):
		var path := str(values.get("shader%d" % index, "")).replace("\\", "/")
		if path.is_empty(): continue
		if not path.is_absolute_path(): path = preset_path.get_base_dir().path_join(path)
		# The preset's own base directory may still use Windows separators.
		if path.replace("\\", "/").simplify_path().to_lower() == normalized_source: return true
	return false

static func _load_file(path: String, parameter_values: Dictionary = {}, context: ImportSession = null) -> Dictionary:
	var result := {"ok":false, "message":"", "path":path, "label":path.get_file().get_basename(), "parameters":[], "values":{}, "warnings":[], "ignored_preset_parameters":[], "filter_linear":false, "textures":{}, "texture_descriptors":[]}
	var extension := path.get_extension().to_lower()
	if extension not in ["glsl", "glslp"]: return _fail(result, "Choose a RetroArch .glsl shader or .glslp preset.")
	var source_path := path
	var preset := {}
	if extension == "glslp":
		var preset_file := _read(path,context)
		if not preset_file.ok: return _fail(result, preset_file.message)
		var parsed := _preset(preset_file.text)
		if not parsed.ok: return _fail(result, parsed.message)
		preset = parsed.values
		var pass_count := str(preset.get("shaders", ""))
		if not pass_count.is_valid_int() or pass_count.to_int() < 1 or pass_count.to_int() > MAX_PASSES: return _fail(result, "Presets must declare between 1 and %d passes."%MAX_PASSES)
		# Preserve the direct screen path for an explicitly full-viewport pass.
		var sizing := false
		for key: String in ["scale_type0", "scale_type_x0", "scale_type_y0", "scale0", "scale_x0", "scale_y0"]:
			if preset.has(key): sizing = true
		if sizing:
			for axis: String in ["x", "y"]:
				var type := str(preset.get("scale_type_%s0"%axis,preset.get("scale_type0","source")))
				var scale := str(preset.get("scale_%s0"%axis,preset.get("scale0","1.0")))
				if type != "viewport" or not scale.is_valid_float() or scale.to_float() != 1.0: return _load_chain(path,preset,parameter_values,false,context)
		for key: String in ["frame_count_mod0", "texture_wrap_mode0"]:
			if preset.has(key): return _load_chain(path, preset, parameter_values,false,context)
		if str(preset.get("wrap_mode0","clamp_to_edge")) in ["repeat","mirrored_repeat","edge"]: return _load_chain(path,preset,parameter_values,false,context)
		if pass_count.to_int() > 1 or preset.has("feedback_pass") or str(preset.get("srgb_framebuffer0","false")).to_lower() == "true" or str(preset.get("float_framebuffer0","false")).to_lower() == "true" or str(preset.get("mipmap_input0","false")).to_lower() == "true": return _load_chain(path, preset, parameter_values,false,context)
		if not preset.has("shader0") or str(preset.shader0).is_empty(): return _fail(result, "The preset has no shader0 source.")
		source_path = str(preset.shader0)
		if not source_path.is_absolute_path() and not source_path.begins_with("res://") and not source_path.begins_with("user://"):
			source_path = path.get_base_dir().path_join(source_path).simplify_path()
		if source_path.get_extension().to_lower() != "glsl": return _fail(result, "The preset must reference a .glsl source.")
		if preset.has("filter_linear0"):
			if str(preset.filter_linear0).to_lower() not in ["true", "false"]: return _fail(result, "Invalid filter_linear0 value.")
			result.filter_linear = str(preset.filter_linear0).to_lower() == "true"
	var file := _read(source_path,context)
	if not file.ok: return _fail(result, file.message)
	var profile := SourceProfiles.get_profile(file.text)
	if extension == "glsl" and profile.has("preset"):
		var default_preset: Dictionary = profile.preset.duplicate()
		default_preset.merge({"shaders":"1","shader0":source_path})
		return _load_chain(path,default_preset,parameter_values,false,context)
	file.text = SourceProfiles.prepare(file.text,profile)
	if profile.has("warning"): result.warnings.append(profile.warning)
	var active_source := _without_comments(file.text)
	var temporal := false
	for name: RegExMatch in _regex('\\b(?:Prev[0-6]?Texture|FeedbackTexture)\\b').search_all(active_source):
		if _regex('\\b%s\\b'%name.get_string()).search_all(active_source).size() > 1: temporal = true; break
	if temporal or _regex('\\b(?:textureLod(?:Offset)?|texelFetch(?:Offset)?|textureSize)\\s*\\(').search(active_source):
		var chain_preset: Dictionary = preset.duplicate()
		chain_preset["shaders"] = "1"
		chain_preset["shader0"] = source_path
		chain_preset["mipmap_input0"] = chain_preset.get("mipmap_input0","false")
		return _load_chain(path,chain_preset,parameter_values,true,context)
	var parameters := _parameters(file.text)
	if not parameters.ok: return _fail(result, parameters.message)
	result.parameters = parameters.parameters
	var allowed := ["shaders", "shader0", "filter_linear0", "parameters"]
	allowed.append_array(["scale_type0", "scale_type_x0", "scale_type_y0", "scale0", "scale_x0", "scale_y0"])
	for key: String in ["mipmap_input0", "float_framebuffer0", "srgb_framebuffer0"]:
		if preset.has(key):
			if str(preset[key]).to_lower() not in ["true", "false"]: return _fail(result, "Invalid preset setting '%s'."%key)
			if str(preset[key]).to_lower() != "false": return _fail(result, "Unsupported preset setting '%s': input mipmaps and floating-point targets are not supported."%key)
			allowed.append(key)
	if preset.has("alias0"):
		if not str(preset.alias0).is_empty() and not str(preset.alias0).is_valid_identifier(): return _fail(result, "Pass aliases must be valid identifiers.")
		allowed.append("alias0")
	var border := false
	if preset.has("wrap_mode0"):
		if str(preset.wrap_mode0) not in ["clamp_to_edge", "clamp_to_border"]: return _fail(result, "Unsupported texture wrap mode: %s"%preset.wrap_mode0)
		border = str(preset.wrap_mode0) == "clamp_to_border"
		allowed.append("wrap_mode0")
	var texture_config := _texture_config(preset, path, result.parameters)
	if not texture_config.ok: return _fail(result, texture_config.message)
	result.texture_descriptors = texture_config.descriptors
	allowed.append_array(texture_config.allowed)
	var resolved := _resolve_parameters(result.parameters, preset, parameter_values)
	if not resolved.ok: return _fail(result, resolved.message)
	result.values = resolved.values
	result.ignored_preset_parameters = resolved.ignored
	result.warnings.append_array(resolved.warnings)
	allowed.append_array(resolved.allowed)
	for key: String in preset:
		if key not in allowed: return _fail(result, "Unsupported preset setting '%s'."%key)
	var loaded_textures := _load_textures(result.texture_descriptors,context)
	if not loaded_textures.ok: return _fail(result, loaded_textures.message)
	result.textures = loaded_textures.textures
	var translated := _translate_with_context(file.text, result.parameters, result.filter_linear, border, result.texture_descriptors, str(preset.get("alias0", "")),true,[],false,false,false,false,"",context)
	if not translated.ok: return _fail(result, translated.message)
	if translated.get("custom_geometry",false):
		var geometry_preset: Dictionary = preset.duplicate()
		geometry_preset["shaders"] = "1"
		geometry_preset["shader0"] = source_path
		return _load_chain(path,geometry_preset,parameter_values,false,context)
	if context != null: context.enter_phase("shader_validation_us")
	var shader := Shader.new()
	shader.code = translated.code
	result.shader = shader
	# Uniform inspection invokes Godot's shader parser, including in headless runs.
	var compiled := false
	for uniform: Dictionary in shader.get_shader_uniform_list():
		if str(uniform.name) == "ra_import_valid": compiled = true
	if context != null: context.leave_phase()
	if not compiled:
		_discard_translation(translated,context)
		return _fail(result, "Godot could not compile this GLSL shader. The previous effect remains active.")
	result.shader = shader
	result.ok = true
	result.message = ""
	return result

static func _load_chain(path: String, preset: Dictionary, parameter_values: Dictionary, force_drawable: bool = false, context: ImportSession = null) -> Dictionary:
	var result := {"ok":false, "message":"", "path":path, "label":path.get_file().get_basename(), "parameters":[], "values":{}, "warnings":[], "ignored_preset_parameters":[], "textures":{}, "texture_descriptors":[], "passes":[]}
	var count := int(preset.shaders)
	var allowed: Array[String] = ["shaders", "parameters", "feedback_pass"]
	if preset.has("feedback_pass"):
		if not str(preset.feedback_pass).is_valid_int() or int(preset.feedback_pass) < 0 or int(preset.feedback_pass) >= count: return _fail(result,"Invalid feedback pass index.")
		result.feedback_pass = int(preset.feedback_pass)
	var sources: Array[String] = []
	var source_paths: Array[String] = []
	var drawable := force_drawable
	var parameters := {}
	var aliases := {}
	for index in count:
		var suffix := str(index)
		var source_path := str(preset.get("shader"+suffix, ""))
		if source_path.is_empty() or source_path.get_extension().to_lower() != "glsl": return _fail(result, "Pass %d needs a .glsl source."%index)
		if not source_path.is_absolute_path(): source_path = path.get_base_dir().path_join(source_path).simplify_path()
		# This collection moved its 3dfx passes under gpu/shaders/3dfx.
		if not FileAccess.file_exists(source_path) and source_path.get_base_dir().get_file() == "shaders" and source_path.get_base_dir().get_base_dir().get_file() == "3dfx":
			var migrated := source_path.get_base_dir().get_base_dir().get_base_dir().path_join("gpu/shaders/3dfx").path_join(source_path.get_file())
			if FileAccess.file_exists(migrated):
				result.warnings.append("Resolved legacy 3dfx pass path to %s."%migrated)
				source_path = migrated
		var source := _read(source_path,context)
		if not source.ok: return _fail(result, "Pass %d: %s"%[index, source.message])
		var profile := SourceProfiles.get_profile(source.text)
		source.text = SourceProfiles.prepare(source.text,profile)
		if profile.has("warning"): result.warnings.append(profile.warning)
		sources.append(source.text)
		source_paths.append(source_path)
		var parsed := _parameters(source.text)
		if not parsed.ok: return _fail(result, "Pass %d: %s"%[index, parsed.message])
		for parameter: Dictionary in parsed.parameters:
			if parameters.has(parameter.name):
				# The GLSL driver uploads declarations in pass order: the last
				# declaration supplies a shared uniform's effective default.
				# Keep one editable entry with the same deterministic precedence.
				if parameters[parameter.name] != parameter:
					result.warnings.append("Shared parameter '%s' uses metadata from pass %d (last declaration)."%[parameter.name,index])
				parameters[parameter.name].merge(parameter, true)
			else:
				parameters[parameter.name] = parameter
				result.parameters.append(parameter)
		for prefix: String in ["filter_linear", "mipmap_input", "float_framebuffer", "srgb_framebuffer"]:
			var key := prefix+suffix
			allowed.append(key)
			if preset.has(key) and str(preset[key]).to_lower() not in ["true", "false"]: return _fail(result, "Invalid preset setting '%s'."%key)
			if prefix in ["mipmap_input", "float_framebuffer"] and str(preset.get(key, "false")).to_lower() == "true": drawable = true
		var active_source := _without_comments(source.text)
		if _regex('\\b(?:Prev[0-6]?Texture|FeedbackTexture)\\b').search(active_source): drawable = true
		if _regex('\\b(?:textureLod(?:Offset)?|texelFetch(?:Offset)?|textureSize)\\s*\\(').search(active_source): drawable = true
		var wrap_mode := str(preset.get("wrap_mode"+suffix,preset.get("texture_wrap_mode"+suffix,"clamp_to_border")))
		if wrap_mode == "edge": wrap_mode = "clamp_to_edge"
		if wrap_mode not in ["clamp_to_border", "clamp_to_edge", "repeat", "mirrored_repeat"]: return _fail(result, "Unsupported pass wrap mode: %s"%wrap_mode)
		var alias := str(preset.get("alias"+suffix, ""))
		if not alias.is_empty():
			if not alias.is_valid_identifier() or aliases.has(alias) or alias in STANDARD_UNIFORMS or alias in COMPAT_MACROS or alias in ["Source", "SourceSize", "TEX0", "COL0", "PI", "TAU", "E"] or alias.begins_with("ra_") or _regex('^(?:Orig|Prev[0-9]*|Pass[0-9]+(?:Texture|InputSize|TextureSize|TexCoord))').search(alias): return _fail(result, "Invalid or duplicate pass alias: %s"%alias)
			aliases[alias] = index
		allowed.append_array(["shader"+suffix, "alias"+suffix, "wrap_mode"+suffix, "texture_wrap_mode"+suffix])
		var sizing := {"type_x":"viewport" if index == count-1 else "source", "type_y":"viewport" if index == count-1 else "source", "scale_x":1.0, "scale_y":1.0}
		for axis: String in ["x", "y"]:
			var type_value := str(preset.get("scale_type_%s%s"%[axis,suffix],preset.get("scale_type"+suffix,sizing["type_"+axis])))
			var scale_value := str(preset.get("scale_%s%s"%[axis,suffix],preset.get("scale"+suffix,"1.0")))
			if type_value not in ["source", "viewport", "absolute"] or not scale_value.is_valid_float() or not is_finite(scale_value.to_float()) or scale_value.to_float() <= 0.0: return _fail(result, "Invalid sizing for pass %d, axis %s."%[index,axis])
			sizing["type_"+axis] = type_value
			sizing["scale_"+axis] = scale_value.to_float()
		for prefix: String in ["scale_type", "scale_type_x", "scale_type_y", "scale", "scale_x", "scale_y"]: allowed.append(prefix+suffix)
		var modulo := str(preset.get("frame_count_mod"+suffix,"0"))
		if not modulo.is_valid_float() or not is_finite(modulo.to_float()) or modulo.to_float() < 0.0 or modulo.to_float() > 2147483647.0 or floor(modulo.to_float()) != modulo.to_float(): return _fail(result,"Invalid frame counter modulus for pass %d."%index)
		allowed.append("frame_count_mod"+suffix)
		result.passes.append({"index":index, "alias":alias, "sizing":sizing, "filter_linear":str(preset.get("filter_linear"+suffix,"false")).to_lower() == "true", "border":wrap_mode == "clamp_to_border", "srgb_framebuffer":str(preset.get("srgb_framebuffer"+suffix,"false")).to_lower() == "true", "float_framebuffer":str(preset.get("float_framebuffer"+suffix,"false")).to_lower() == "true", "mipmap_input":str(preset.get("mipmap_input"+suffix,"false")).to_lower() == "true"})
		result.passes.back()["frame_count_mod"] = int(modulo.to_float())
		result.passes.back()["wrap_mode"] = wrap_mode
	result.drawable = drawable
	for info: Dictionary in result.passes: info["advanced"] = drawable
	var resolved := _resolve_parameters(result.parameters, preset, parameter_values)
	if not resolved.ok: return _fail(result, resolved.message)
	result.values = resolved.values
	result.ignored_preset_parameters = resolved.ignored
	result.warnings.append_array(resolved.warnings)
	allowed.append_array(resolved.allowed)
	var texture_config := _texture_config(preset,path,result.parameters)
	if not texture_config.ok: return _fail(result,texture_config.message)
	var defaults := _pass_texture_defaults(path,source_paths,sources,texture_config.descriptors,result.parameters,aliases,context)
	texture_config.descriptors.append_array(defaults.descriptors)
	result.warnings.append_array(defaults.warnings)
	allowed.append_array(texture_config.allowed)
	for alias: String in aliases:
		if parameters.has(alias): return _fail(result, "Pass alias and parameter names conflict: %s"%alias)
		for descriptor: Dictionary in texture_config.descriptors:
			if descriptor.name in [alias,alias+"Texture"]: return _fail(result, "Pass alias and external texture names conflict: %s"%alias)
	for key: String in preset:
		if key not in allowed:
			var extra := _regex('^(?:shader|filter_linear|mipmap_input|float_framebuffer|srgb_framebuffer|alias|wrap_mode|texture_wrap_mode|frame_count_mod|scale(?:_type)?(?:_[xy])?)([0-9]+)$').search(key)
			if extra != null and int(extra.get_string(1)) >= count:
				result.warnings.append("Ignored setting '%s' beyond the declared pass count."%key)
			else: return _fail(result, "Unsupported preset setting '%s'."%key)
	var loaded := _load_textures(texture_config.descriptors,context)
	if not loaded.ok: return _fail(result,loaded.message)
	result.textures = loaded.textures
	result.texture_descriptors = texture_config.descriptors
	for pass_info: Dictionary in result.passes:
		var dynamic: Array[Dictionary] = [{"name":"OrigTexture", "uniform":"ra_orig", "dynamic":true, "pass_index":-1, "filter_linear":pass_info.filter_linear, "wrap_mode":pass_info.wrap_mode}]
		# RetroArch also names the original input PassPrev<one-based pass>.
		# See gfx/drivers_shader/shader_glsl.c: gl_glsl_find_uniforms().
		if pass_info.index > 0:
			var original: Dictionary = dynamic[0].duplicate()
			original.name = "PassPrev%dTexture"%(pass_info.index+1)
			original.uniform = "ra_pass_"+original.name
			dynamic.append(original)
		for previous in pass_info.index:
			var names: Array[String] = ["Pass%dTexture"%(previous+1), "PassPrev%dTexture"%(pass_info.index-previous)]
			var alias: String = result.passes[previous].alias
			if not alias.is_empty(): names.append_array([alias,alias+"Texture"])
			for name: String in names: dynamic.append({"name":name, "size_prefix":name.trim_suffix("Texture"), "uniform":"ra_pass_"+name, "dynamic":true, "pass_index":previous, "filter_linear":pass_info.filter_linear, "wrap_mode":pass_info.wrap_mode, "srgb":result.passes[previous].srgb_framebuffer})
		if drawable:
			for history in 7:
				var name := "PrevTexture" if history == 0 else "Prev%dTexture"%history
				dynamic.append({"name":name,"uniform":"ra_history_%d"%history,"dynamic":true,"history_index":history,"pass_index":-1,"filter_linear":pass_info.filter_linear,"wrap_mode":pass_info.wrap_mode})
			if result.has("feedback_pass"): dynamic.append({"name":"FeedbackTexture","uniform":"ra_feedback","dynamic":true,"feedback":true,"pass_index":result.feedback_pass,"filter_linear":pass_info.filter_linear,"wrap_mode":pass_info.wrap_mode,"srgb":result.passes[result.feedback_pass].srgb_framebuffer})
		# Alias uniforms may overlap the numbered namespace. RetroArch binds
		# earlier buffers in order, so the latest matching binding wins.
		var unique := {}
		for descriptor: Dictionary in dynamic: unique[descriptor.name] = descriptor
		dynamic.assign(unique.values())
		var input_srgb: bool = pass_info.index > 0 and result.passes[pass_info.index-1].srgb_framebuffer
		var translated := _translate_with_context(sources[pass_info.index],result.parameters,pass_info.filter_linear,pass_info.border,result.texture_descriptors,"",false,dynamic,input_srgb,pass_info.srgb_framebuffer,drawable,pass_info.mipmap_input,pass_info.wrap_mode,context,pass_info.index)
		if not translated.ok: return _fail(result, "Pass %d: %s"%[pass_info.index,translated.message])
		if context != null: context.enter_phase("shader_validation_us")
		var shader := Shader.new()
		shader.code = translated.code
		pass_info.shader = shader
		var compiled := false
		for uniform: Dictionary in shader.get_shader_uniform_list():
			if str(uniform.name) == "ra_import_valid": compiled = true
		if context != null: context.leave_phase()
		if not compiled:
			_discard_translation(translated,context)
			return _fail(result, "Godot could not compile pass %d. The previous effect remains active."%pass_info.index)
		pass_info.shader = shader
		pass_info.dynamic_textures = dynamic
	result.ok = true
	return result

static func _texture_config(preset: Dictionary, preset_path: String, parameters: Array) -> Dictionary:
	var descriptors: Array[Dictionary] = []
	var allowed: Array[String] = []
	if not preset.has("textures"): return {"ok":true, "descriptors":descriptors, "allowed":allowed}
	allowed.append("textures")
	var names := {}
	for name: String in str(preset.textures).split(";", false):
		name = name.strip_edges()
		if not name.is_valid_identifier() or name in STANDARD_UNIFORMS or name in COMPAT_MACROS or name in ["PI", "TAU", "E", "Source", "SourceSize", "TEX0", "COL0"] or name.begins_with("ra_"):
			return {"ok":false, "message":"Invalid external texture name: '%s'."%name}
		if _regex('^(?:Prev[0-9]*(?:Texture)?|OrigTexture|Pass[0-9]+Texture)$').search(name): return {"ok":false, "message":"History and previous-pass texture names are reserved for preset buffers: %s."%name}
		if names.has(name): return {"ok":false, "message":"Duplicate external texture: %s."%name}
		for parameter: Dictionary in parameters:
			if parameter.name == name: return {"ok":false, "message":"External texture and parameter names conflict: %s."%name}
		names[name] = true
		if not preset.has(name) or str(preset[name]).is_empty(): return {"ok":false, "message":"External texture '%s' has no image path."%name}
		var path := str(preset[name])
		if not path.is_absolute_path() and not path.begins_with("res://") and not path.begins_with("user://"): path = preset_path.get_base_dir().path_join(path).simplify_path()
		# RetroArch's OpenGL LUT loader defaults to linear when unspecified.
		var linear := true
		var legacy_filter := "filter_"+name
		if preset.has(legacy_filter):
			if str(preset[legacy_filter]) not in ["linear", "nearest"]: return {"ok":false,"message":"Invalid external texture filter: %s"%legacy_filter}
			linear = str(preset[legacy_filter]) == "linear"
			allowed.append(legacy_filter)
		var mipmap := false
		for suffix: String in ["linear", "mipmap"]:
			var key := name+"_"+suffix
			if preset.has(key) and str(preset[key]).to_lower() not in ["true", "false"]: return {"ok":false, "message":"Invalid external texture setting '%s'."%key}
			if suffix == "linear" and preset.has(key): linear = str(preset[key]).to_lower() == "true"
			else: mipmap = str(preset.get(key, "false")).to_lower() == "true"
		var wrap_mode := str(preset.get(name+"_wrap_mode", "clamp_to_border"))
		if preset.has(name+"_repeat"):
			if str(preset[name+"_repeat"]).to_lower() not in ["true", "false"]: return {"ok":false,"message":"Invalid external texture repeat flag: %s"%name}
			wrap_mode = "repeat" if str(preset[name+"_repeat"]).to_lower() == "true" else "clamp_to_edge"
			allowed.append(name+"_repeat")
		if wrap_mode not in ["repeat", "mirrored_repeat", "clamp_to_edge", "clamp_to_border"]: return {"ok":false, "message":"Unsupported external texture wrap mode '%s' for %s."%[wrap_mode, name]}
		descriptors.append({"name":name, "uniform":"ra_lut_"+name, "path":path, "filter_linear":linear, "wrap_mode":wrap_mode, "mipmap":mipmap})
		allowed.append_array([name, name+"_linear", name+"_wrap_mode", name+"_mipmap"])
	return {"ok":true, "descriptors":descriptors, "allowed":allowed}

static func _pass_texture_defaults(preset_path: String, paths: Array[String], sources: Array[String], explicit: Array, parameters: Array, aliases: Dictionary, context: ImportSession = null) -> Dictionary:
	# A composed preset can omit a pass's LUT declarations. Reuse a default
	# only when sibling presets referencing every source using that name agree.
	# Explicit declarations always win; ambiguous defaults remain an error.
	var explicit_names := {}
	for descriptor: Dictionary in explicit: explicit_names[descriptor.name] = true
	var inferred := {}
	var incomplete := {}
	var descriptors: Array[Dictionary] = []
	var warnings: Array[String] = []
	# Multipass presets revisit the same sibling files. Cache only for this
	# load so subsequent selections still observe edited preset/LUT settings.
	var candidates := {}
	for index in paths.size():
		var required := {}
		var clean := _without_comments(sources[index])
		for sampler: RegExMatch in _regex('\\buniform\\s+(?:(?:lowp|mediump|highp|COMPAT_PRECISION)\\s+)?sampler2D\\s+([A-Za-z_][A-Za-z_0-9]*)').search_all(clean):
			var name := sampler.get_string(1)
			if explicit_names.has(name) or name in STANDARD_UNIFORMS or aliases.has(name) or aliases.has(name.trim_suffix("Texture")) or _regex('^(?:Orig|Pass[0-9]+|PassPrev[0-9]+|Prev[0-9]*|Feedback)(?:Texture)?$').search(name): continue
			if _regex('\\b%s\\b'%name).search_all(clean).size() > 1: required[name] = {}
		if required.is_empty(): continue
		var directory := paths[index].get_base_dir()
		var complete := true
		for depth in 3:
			var scanned := 0
			for filename: String in DirAccess.get_files_at(directory):
				if filename.get_extension().to_lower() != "glslp": continue
				scanned += 1
				if scanned > 64:
					complete = false
					break
				var candidate_path := directory.path_join(filename)
				if candidate_path.simplify_path() == preset_path.simplify_path(): continue
				if not candidates.has(candidate_path):
					var candidate := _read(candidate_path,context)
					candidates[candidate_path] = _preset(candidate.text) if candidate.ok else {"ok":false}
				var parsed: Dictionary = candidates[candidate_path]
				if not parsed.ok or not _preset_values_reference(parsed.values, candidate_path, paths[index]): continue
				if not parsed.has("texture_config"):
					parsed.texture_config = _texture_config(parsed.values, candidate_path, parameters)
				var config: Dictionary = parsed.texture_config
				if not config.ok: continue
				for descriptor: Dictionary in config.descriptors:
					if required.has(descriptor.name): required[descriptor.name][JSON.stringify(descriptor)] = {"descriptor":descriptor,"preset":candidate_path}
			directory = directory.get_base_dir()
		if not complete:
			# A truncated source scan may hide a conflicting default, including
			# one for a name already encountered in an earlier pass.
			for name: String in required: incomplete[name] = true
			continue
		for name: String in required:
			if not inferred.has(name): inferred[name] = {}
			inferred[name].merge(required[name])
	# Textures are bound globally for the chain. Choosing after every pass has
	# contributed avoids silently letting the first source's default win.
	for name: String in inferred:
		if incomplete.has(name) or inferred[name].size() != 1: continue
		var value: Dictionary = inferred[name].values()[0]
		descriptors.append(value.descriptor)
		warnings.append("Texture '%s' uses the shared default from %s; this preset omits its declaration."%[name,value.preset])
	return {"descriptors":descriptors,"warnings":warnings}

static func _load_textures(descriptors: Array, context: ImportSession = null) -> Dictionary:
	if context != null: context.enter_phase("texture_loading_us")
	var result := _load_textures_impl(descriptors,context)
	if context != null: context.leave_phase()
	return result

static func _load_textures_impl(descriptors: Array, context: ImportSession = null) -> Dictionary:
	var textures := {}
	for descriptor: Dictionary in descriptors:
		if context != null: context.enter_phase("read_us")
		var file := FileAccess.open(descriptor.path, FileAccess.READ)
		if file == null:
			if context != null: context.leave_phase()
			return {"ok":false, "message":"Cannot read external texture '%s': %s"%[descriptor.name, descriptor.path]}
		if file.get_length() > MAX_TEXTURE_BYTES:
			if context != null: context.leave_phase()
			return {"ok":false, "message":"External texture '%s' exceeds the 64 MiB file limit."%descriptor.name}
		var bytes := file.get_buffer(file.get_length())
		if context != null: context.leave_phase()
		var image := Image.new()
		var error := ERR_FILE_UNRECOGNIZED
		match str(descriptor.path).get_extension().to_lower():
			"png":
				if bytes.size() >= 8 and bytes.slice(0, 8) == PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]): error = image.load_png_from_buffer(bytes)
			"jpg", "jpeg":
				if bytes.size() >= 2 and bytes[0] == 255 and bytes[1] == 216: error = image.load_jpg_from_buffer(bytes)
			"webp":
				if bytes.size() >= 12 and bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP": error = image.load_webp_from_buffer(bytes)
		if error != OK or image.is_empty(): return {"ok":false, "message":"Cannot decode external texture '%s': choose a valid PNG, JPEG or WebP image (%s)."%[descriptor.name, descriptor.path]}
		if image.get_width()*image.get_height() > MAX_TEXTURE_PIXELS: return {"ok":false, "message":"External texture '%s' exceeds the 16 megapixel image limit."%descriptor.name}
		if descriptor.mipmap and image.generate_mipmaps() != OK: return {"ok":false, "message":"Cannot generate mipmaps for external texture '%s'."%descriptor.name}
		descriptor.size = image.get_size()
		textures[descriptor.uniform] = ImageTexture.create_from_image(image)
	return {"ok":true, "textures":textures}

static func _fail(result: Dictionary, message: String) -> Dictionary:
	result.message = message
	return result

static func _read(path: String, context: ImportSession = null) -> Dictionary:
	# Includes source encoding validation/decoding, not just filesystem I/O.
	if context != null: context.enter_phase("read_us")
	var result := _read_source(path)
	if context != null: context.leave_phase()
	return result

static func _read_source(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"ok":false, "message":"Cannot read shader file: %s"%path}
	if file.get_length() > MAX_SOURCE_BYTES: return {"ok":false, "message":"Shader files must be smaller than 4 MiB."}
	var bytes := file.get_buffer(file.get_length())
	# Some older shader notices use Latin-1 names rather than UTF-8.
	var source := bytes.get_string_from_utf8() if _valid_utf8(bytes) else bytes.get_string_from_ascii()
	return {"ok":true, "text":source.trim_prefix(String.chr(0xfeff))}

static func _valid_utf8(bytes: PackedByteArray) -> bool:
	# Latin-1 decoding is silent for every byte value and preserves byte offsets
	# until a NUL. Native searching skips the long ASCII runs in shader sources;
	# only non-ASCII spans need the strict UTF-8 checks below. A truncated decode
	# must fall back to checking all bytes, including anything after the NUL.
	if bytes.size() < 64: return _valid_utf8_range(bytes,0,bytes.size())
	var latin1 := bytes.get_string_from_ascii()
	if latin1.length() != bytes.size(): return _valid_utf8_range(bytes,0,bytes.size())
	var non_ascii := _regex('[\\x80-\\xFF]+')
	var span := non_ascii.search(latin1)
	var index := 0
	var short_runs := 0
	while span != null:
		# Dense mixed text should use one byte loop, not allocate a regex match
		# for every few characters. Sparse notices still take the native path.
		if span.get_start()-index < 64:
			short_runs += 1
			if short_runs >= 32: return _valid_utf8_range(bytes,index,bytes.size())
		else:
			short_runs = 0
		if not _valid_utf8_range(bytes,span.get_start(),span.get_end()): return false
		index = span.get_end()
		span = non_ascii.search(latin1,index)
	return true

static func _valid_utf8_range(bytes: PackedByteArray, index: int, end: int) -> bool:
	while index < end:
		var lead := int(bytes[index])
		if lead < 0x80:
			index += 1
			continue
		var count := 1 if lead >= 0xc2 and lead <= 0xdf else 2 if lead >= 0xe0 and lead <= 0xef else 3 if lead >= 0xf0 and lead <= 0xf4 else 0
		if count == 0 or index+count >= end: return false
		for offset in range(1, count+1):
			if bytes[index+offset] < 0x80 or bytes[index+offset] > 0xbf: return false
		var next := int(bytes[index+1])
		if lead == 0xe0 and next < 0xa0 or lead == 0xed and next >= 0xa0 or lead == 0xf0 and next < 0x90 or lead == 0xf4 and next >= 0x90: return false
		index += count+1
	return true

static func _regex(pattern: String) -> RegEx:
	if _regex_cache.has(pattern): return _regex_cache[pattern]
	var regex := RegEx.new()
	regex.compile(pattern)
	if _regex_cache.size() >= 1024: _regex_cache.clear()
	_regex_cache[pattern] = regex
	return regex

static func _preset(source: String) -> Dictionary:
	var values := {}
	for line: String in source.split("\n"):
		line = line.strip_edges()
		if line.is_empty() or line.begins_with("#"): continue
		var match := _regex('^([A-Za-z_][A-Za-z_0-9]*)\\s*=\\s*(?:"([^"]*)"|([^#]*))(?:\\s*#.*)?$').search(line)
		if match == null: return {"ok":false, "message":"Malformed GLSL preset line: %s"%line}
		var name := match.get_string(1)
		var value := (match.get_string(2) if line.get_slice("=", 1).strip_edges().begins_with('"') else match.get_string(3)).strip_edges().replace("\\", "/")
		# Older presets occasionally omit a closing quote at the end of a line.
		if match.get_string(3).strip_edges().begins_with('"'): value = match.get_string(3).strip_edges().trim_prefix('"')
		if values.has(name):
			if values[name] == value or value.is_valid_float() and str(values[name]).is_valid_float() and value.to_float() == str(values[name]).to_float(): continue
			return {"ok":false, "message":"Duplicate preset setting: %s"%name}
		values[name] = value
	return {"ok":true, "values":values}

static func _parameters(source: String) -> Dictionary:
	var parameters: Array[Dictionary] = []
	var found := {}
	var pattern := '^\\s*#\\s*pragma\\s+parameter\\s+([A-Za-z_][A-Za-z_0-9]*)\\s+"([^"]*)"\\s+([^\\s]+)\\s+([^\\s]+)\\s+([^\\s]+)(?:\\s+([^\\s]+))?\\s*$'
	for line: String in _without_comments(source).split("\n"):
		if _regex('^\\s*#\\s*pragma\\s+parameter\\b').search(line) == null: continue
		var match := _regex(pattern).search(line)
		if match == null: return {"ok":false, "message":"Malformed shader parameter declaration."}
		var name := match.get_string(1)
		if name in ["PI", "TAU", "E"]: return {"ok":false, "message":"Shader parameter '%s' conflicts with a Godot built-in constant."%name}
		if found.has(name): return {"ok":false, "message":"Duplicate shader parameter: %s"%name}
		var numbers: Array[float] = []
		for index in range(3, 7):
			var number := match.get_string(index)
			if index == 6 and number.is_empty():
				numbers.append(0.1 * (numbers[2] - numbers[1]) if numbers[2] > numbers[1] else 1.0)
				continue
			if not number.is_valid_float() or not is_finite(number.to_float()): return {"ok":false, "message":"Invalid bounds for shader parameter: %s"%name}
			numbers.append(number.to_float())
		if numbers[1] > numbers[2] or numbers[3] <= 0.0 or numbers[0] < numbers[1] or numbers[0] > numbers[2]: return {"ok":false, "message":"Invalid bounds for shader parameter: %s"%name}
		found[name] = true
		parameters.append({"name":name, "label":match.get_string(2), "default":numbers[0], "min":numbers[1], "max":numbers[2], "step":numbers[3]})
	return {"ok":true, "parameters":parameters}

static func _resolve_parameters(parameters: Array, preset: Dictionary, overrides: Dictionary) -> Dictionary:
	var values := {}
	var allowed: Array[String] = []
	var ignored: Array[String] = []
	var warnings: Array[String] = []
	for parameter: Dictionary in parameters:
		allowed.append(parameter.name)
		var value: Variant = overrides.get(parameter.name, preset.get(parameter.name, parameter.default))
		if value is String:
			value = value.strip_edges().trim_suffix(";").strip_edges()
			if not value.is_valid_float(): return {"ok":false, "message":"Parameter '%s' must be a finite number."%parameter.name}
			value = value.to_float()
		if (not value is int and not value is float) or not is_finite(float(value)): return {"ok":false, "message":"Parameter '%s' must be a finite number."%parameter.name}
		values[parameter.name] = clampf(float(value), parameter.min, parameter.max)
	# A preset's list is advisory. RetroArch loads values for the declarations
	# it actually found, ignoring obsolete names left behind by shader updates.
	# Report those names; never manufacture uniforms or guess renamed controls.
	for listed: String in str(preset.get("parameters", "")).split(";", false):
		var name := listed.strip_edges()
		if name.is_empty(): continue
		if not name.is_valid_identifier(): return {"ok":false, "message":"Invalid preset parameter name: '%s'."%name}
		if name in allowed: continue
		if _regex('^(?:shaders|parameters|textures|feedback_pass|shader[0-9]+|(?:filter_linear|mipmap_input|float_framebuffer|srgb_framebuffer|alias|wrap_mode|texture_wrap_mode|frame_count_mod|scale(?:_type)?(?:_[xy])?)[0-9]+)$').search(name):
			return {"ok":false, "message":"Preset parameter '%s' conflicts with a preset setting."%name}
		allowed.append(name)
		ignored.append(name)
		warnings.append("Ignored undeclared preset parameter '%s'."%name)
	for name: String in preset:
		if name in allowed or _regex('^(?:shaders|parameters|textures|feedback_pass|shader[0-9]+|(?:filter_linear|mipmap_input|float_framebuffer|srgb_framebuffer|alias|wrap_mode|texture_wrap_mode|frame_count_mod|scale(?:_type)?(?:_[xy])?)[0-9]+)$').search(name): continue
		var number := str(preset[name]).strip_edges()
		if number.is_valid_float() and is_finite(number.to_float()):
			allowed.append(name)
			ignored.append(name)
			warnings.append("Ignored undeclared numeric preset parameter '%s'."%name)
	for name: Variant in overrides:
		if not values.has(name): return {"ok":false, "message":"Unknown shader parameter '%s'."%str(name)}
	return {"ok":true, "values":values, "allowed":allowed, "ignored":ignored, "warnings":warnings}

static func _without_comments(source: String) -> String:
	return _regex('(?s)/\\*.*?\\*/|//[^\\r\\n]*').sub(source, " ", true)

static func _condition(text: String, macros: Dictionary) -> Dictionary:
	for match: RegExMatch in _regex('defined\\s*(?:\\(\\s*([A-Za-z_][A-Za-z_0-9]*)\\s*\\)|([A-Za-z_][A-Za-z_0-9]*))').search_all(text):
		var name := match.get_string(1) if not match.get_string(1).is_empty() else match.get_string(2)
		text = text.replace(match.get_string(), "1" if macros.has(name) else "0")
	for _iteration in 12:
		var before := text
		for match: RegExMatch in _regex('\\b[A-Za-z_][A-Za-z_0-9]*\\b').search_all(text):
			var name := match.get_string()
			text = _regex('\\b%s\\b'%name).sub(text, "(%s)"%str(macros.get(name, "0")), true)
		if text == before: break
	# Deliberately limit evaluation to numeric preprocessor expressions.
	if _regex('[^0-9eE\\.\\s\\(\\)\\+\\-\\*/%<>=!&|]').search(text) != null: return {"ok":false, "message":"Unsupported preprocessor condition."}
	text = text.replace("&&", " and ").replace("||", " or ")
	text = _regex('!(?!=)').sub(text, " not ", true)
	var expression := Expression.new()
	if expression.parse(text) != OK: return {"ok":false, "message":"Unsupported preprocessor condition: %s"%text}
	var value: Variant = expression.execute([], null, false)
	if expression.has_execute_failed(): return {"ok":false, "message":"Unsupported preprocessor condition: %s"%text}
	return {"ok":true, "value":bool(value)}

static func _preprocess(source: String, stage: String) -> Dictionary:
	var macros := {"__VERSION__":"330", "PARAMETER_UNIFORM":"1", stage:"1"}
	var stack: Array[Dictionary] = []
	var active := true
	var lines := PackedStringArray()
	for line: String in source.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.begins_with("#"):
			if active: lines.append(line)
			continue
		var directive_match := _regex('^#\\s*([A-Za-z_][A-Za-z_0-9]*)').search(trimmed)
		if directive_match == null: return {"ok":false,"message":"Malformed shader directive."}
		var directive := directive_match.get_string(1)
		var body := trimmed.trim_prefix("#").strip_edges().trim_prefix(directive).strip_edges()
		if directive in ["if", "ifdef", "ifndef"]:
			var value := false
			if active:
				if directive == "ifdef": value = macros.has(body)
				elif directive == "ifndef": value = not macros.has(body)
				else:
					var condition := _condition(body, macros)
					if not condition.ok: return condition
					value = condition.value
			stack.append({"parent":active, "taken":value, "else":false})
			active = active and value
		elif directive in ["elif", "else"]:
			if stack.is_empty() or stack[-1]["else"]: return {"ok":false, "message":"Unbalanced preprocessor branches."}
			var branch := stack[-1]
			var value := false
			if directive == "else":
				value = not branch.taken
				branch["else"] = true
			elif branch.parent and not branch.taken:
				var condition := _condition(body, macros)
				if not condition.ok: return condition
				value = condition.value
			active = branch.parent and value
			branch.taken = branch.taken or value
		elif directive == "endif":
			if stack.is_empty(): return {"ok":false, "message":"Unbalanced preprocessor branches."}
			active = stack.pop_back().parent
		elif active:
			if directive == "define":
				var definition := _regex('^([A-Za-z_][A-Za-z_0-9]*)(.*)$').search(body)
				if definition == null: return {"ok":false, "message":"Malformed shader macro."}
				var name := definition.get_string(1)
				var value := definition.get_string(2).strip_edges()
				macros[name] = "1" if value.begins_with("(") and body.begins_with(name+"(") else value
				if name not in COMPAT_MACROS: lines.append("#define "+body)
			elif directive == "undef":
				macros.erase(body)
				if body not in COMPAT_MACROS: lines.append("#undef "+body)
			elif directive == "include": return {"ok":false, "message":"Shader includes are not supported; choose a self-contained GLSL shader."}
			elif directive == "pragma":
				if _regex('^(?:parameter|name)\\s').search(body) == null and body not in ["stage vertex", "stage fragment", "format R8G8B8A8_SRGB", "format R16G16B16A16_SFLOAT"]: return {"ok":false, "message":"Unsupported shader pragma: %s"%body}
			elif directive not in ["version", "line"]: return {"ok":false, "message":"Unsupported shader directive: #%s"%directive}
	if not stack.is_empty(): return {"ok":false, "message":"Unclosed preprocessor condition."}
	return {"ok":true, "code":"\n".join(lines)}

static func _units(source: String) -> Array[String]:
	var units: Array[String] = []
	var depth := 0
	var start := 0
	var first_token := true
	var macro_line := false
	for index in source.length():
		# Read ASCII syntax as code points without allocating a string and a
		# membership array for every character in every lowering pass.
		var character := source.unicode_at(index)
		if first_token:
			if character == 32 or character == 9 or character == 13 or character == 10: continue
			macro_line = character == 35 # #
			first_token = false
		# Macro bodies can contain semicolons and braces. Keep their entire line
		# together rather than interpreting it as shader declarations.
		if macro_line:
			if character == 10:
				units.append(source.substr(start,index-start).strip_edges())
				start = index+1
				first_token = true
				macro_line = false
			continue
		if character == 123: depth += 1 # {
		elif character == 125: depth -= 1 # }
		if depth == 0 and character == 125 and source.substr(start,index-start).strip_edges().begins_with("struct "): continue
		if depth == 0 and (character == 59 or character == 125): # ; or }
			var unit := source.substr(start, index-start+1).strip_edges()
			if not unit.is_empty(): units.append(unit)
			start = index+1
			first_token = true
	var remaining := source.substr(start).strip_edges()
	if not remaining.is_empty(): units.append(remaining)
	return units

static func _arguments(code: String, start: int) -> Dictionary:
	var depth := 1
	var begin := start
	var arguments: Array[String] = []
	for index in range(start,code.length()):
		var character := code.unicode_at(index)
		if character == 40 or character == 91: depth += 1 # ( or [
		elif character == 41 or character == 93: depth -= 1 # ) or ]
		if character == 44 and depth == 1 or depth == 0: # ,
			arguments.append(code.substr(begin,index-begin).strip_edges())
			begin = index+1
		if depth == 0: return {"ok":true,"arguments":arguments,"end":index+1}
	return {"ok":false}

static func _expand_text(code: String, macros: Dictionary, disabled: Array[String] = [], depth: int = 0) -> String:
	if depth > 32: return code
	var chunks := PackedStringArray()
	var cursor := 0
	for token: RegExMatch in _regex('\\b[A-Za-z_][A-Za-z_0-9]*\\b').search_all(code):
		if token.get_start() < cursor: continue
		var name := token.get_string()
		if not macros.has(name): continue
		if name in disabled:
			# Preserve C's disabled-token state when an expanded argument is
			# inserted into another macro and its replacement is rescanned.
			chunks.append(code.substr(cursor,token.get_start()-cursor))
			chunks.append("ra_macro_disabled_"+name)
			cursor = token.get_end()
			continue
		var macro: Dictionary = macros[name]
		var end := token.get_end()
		var body: String = macro.body
		if macro.has("arguments"):
			while end < code.length() and code[end] in [" ","\t","\r","\n"]: end += 1
			if end >= code.length() or code[end] != "(": continue
			var parsed := _arguments(code,end+1)
			if not parsed.ok or parsed.arguments.size() != macro.arguments.size(): continue
			var replacements := {}
			for index in macro.arguments.size():
				replacements[macro.arguments[index]] = _expand_text(parsed.arguments[index],macros,disabled,depth+1)
			var tokens := _regex('\\b[A-Za-z_][A-Za-z_0-9]*\\b').search_all(body)
			tokens.reverse()
			for argument: RegExMatch in tokens:
				if replacements.has(argument.get_string()): body = body.substr(0,argument.get_start())+replacements[argument.get_string()]+body.substr(argument.get_end())
			# GLSL preprocessing uses token pasting for vector type aliases.
			body = _regex('\\s*##\\s*').sub(body,"",true)
			end = parsed.end
		var nested := disabled.duplicate()
		nested.append(name)
		chunks.append(code.substr(cursor,token.get_start()-cursor))
		chunks.append(_expand_text(body,macros,nested,depth+1))
		cursor = end
	chunks.append(code.substr(cursor))
	return "".join(chunks)

static func _expand_macros(code: String) -> String:
	# Expand before renaming uniforms. In C, OutputSize may expand to an
	# expression containing its own unexpanded uniform name.
	var macros := {}
	var chunks := PackedStringArray()
	var pending := PackedStringArray()
	for line: String in code.split("\n"):
		var define := _regex('^\\s*#define\\s+([A-Za-z_][A-Za-z_0-9]*)(.*)$').search(line)
		var undef := _regex('^\\s*#undef\\s+([A-Za-z_][A-Za-z_0-9]*)').search(line)
		if define == null and undef == null:
			pending.append(line)
			continue
		chunks.append(_expand_text("\n".join(pending),macros))
		pending.clear()
		if undef != null:
			macros.erase(undef.get_string(1))
			continue
		var tail := define.get_string(2)
		var macro := {"body":tail.strip_edges()}
		if tail.begins_with("("):
			var closing := tail.find(")")
			macro.arguments = Array(tail.substr(1,closing-1).split(",",false))
			for index in macro.arguments.size(): macro.arguments[index] = macro.arguments[index].strip_edges()
			macro.body = tail.substr(closing+1).strip_edges()
		macros[define.get_string(1)] = macro
	chunks.append(_expand_text("\n".join(pending),macros))
	return "\n".join(chunks).replace("ra_macro_disabled_","")

static func _specialize_samplers(code: String, textures: Array) -> Dictionary:
	# GLSL permits sampler arguments. Specialize their functions per binding so
	# the existing logical-grid, sRGB and border samplers keep exact semantics.
	var generic := {}
	var retained := PackedStringArray()
	for unit: String in _units(code):
		var signature := _regex('^(?:inline\\s+)?(?:(?:lowp|mediump|highp)\\s+)?(?:[A-Za-z_][A-Za-z_0-9]*)\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search(unit)
		if signature == null or not unit.contains("sampler2D") or not unit.contains("{"):
			retained.append(unit)
			continue
		var parsed := _arguments(unit,signature.get_end())
		if not parsed.ok: return {"ok":false,"message":"Malformed sampler function."}
		var samplers := {}
		for index in parsed.arguments.size():
			var argument := _regex('\\bsampler2D\\s+([A-Za-z_][A-Za-z_0-9]*)$').search(parsed.arguments[index])
			if argument != null: samplers[index] = argument.get_string(1)
		if samplers.is_empty():
			retained.append(unit)
			continue
		var name := signature.get_string(1)
		if not generic.has(name): generic[name] = []
		generic[name].append({"unit":unit,"signature":signature,"parsed":parsed,"samplers":samplers})
	code = "\n".join(retained)
	var bindings: Array[String] = ["ra_source"]
	for descriptor: Dictionary in textures: bindings.append(descriptor.uniform)
	var emitted := {}
	for iteration in 32:
		var created := PackedStringArray()
		var changed := false
		for name: String in generic:
			var calls := _regex('\\b%s\\s*\\('%name).search_all(code)
			calls.reverse()
			for invocation: RegExMatch in calls:
				var parsed := _arguments(code,invocation.get_end())
				if not parsed.ok: continue
				for definition: Dictionary in generic[name]:
					if definition.parsed.arguments.size() != parsed.arguments.size(): continue
					var suffix := ""
					var valid := true
					for index: int in definition.samplers:
						var binding: String = parsed.arguments[index]
						if binding not in bindings: valid = false; break
						suffix += "_"+binding
					if not valid: continue
					# Godot rejects a function calling another overload of itself.
					# Give different arities distinct names as well as bindings.
					var specialized := name+suffix+"_a%d"%parsed.arguments.size()
					var arguments: Array = parsed.arguments.duplicate()
					var keys: Array = definition.samplers.keys()
					keys.sort(); keys.reverse()
					for index: int in keys: arguments.remove_at(index)
					code = code.substr(0,invocation.get_start())+specialized+"("+", ".join(arguments)+")"+code.substr(parsed.end)
					var key := specialized+str(definition.parsed.arguments)
					if not emitted.has(key):
						var unit: String = definition.unit
						var declaration: Array = definition.parsed.arguments.duplicate()
						for index: int in keys: declaration.remove_at(index)
						unit = unit.substr(0,definition.signature.get_start(1))+specialized+"("+", ".join(declaration)+")"+unit.substr(definition.parsed.end)
						for index: int in definition.samplers: unit = _regex('\\b%s\\b'%definition.samplers[index]).sub(unit,parsed.arguments[index],true)
						created.append(unit)
						emitted[key] = true
					changed = true
					break
		if not changed: return {"ok":true,"code":code}
		code = "\n".join(created)+"\n"+code
	return {"ok":false,"message":"Sampler specialization exceeds the nesting limit."}

static func _operand_end(code: String, start: int) -> int:
	var cursor := start
	while cursor < code.length() and code[cursor] in [" ","\t","\n","\r"]: cursor += 1
	if cursor < code.length() and code[cursor] == "(":
		var parsed := _arguments(code,cursor+1)
		if not parsed.ok: return start
		cursor = parsed.end
	else:
		var token := _regex('^[A-Za-z_][A-Za-z_0-9]*|^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?').search(code.substr(cursor))
		if token == null: return start
		cursor += token.get_end()
	while cursor < code.length():
		var next := cursor
		while next < code.length() and code[next] in [" ","\t","\n","\r"]: next += 1
		if next < code.length() and code[next] in ["(","["]:
			var parsed := _arguments(code,next+1)
			if not parsed.ok: break
			cursor = parsed.end
		elif next < code.length() and code[next] == ".":
			var member := _regex('^\\.[A-Za-z_][A-Za-z_0-9]*').search(code.substr(next))
			if member == null: break
			cursor = next+member.get_end()
		else: break
	return cursor

static func _operand_start(code: String, end: int) -> int:
	var tail_start := maxi(0,end-256)
	var number := _regex('(?<![.A-Za-z_0-9])(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?\\s*$').search(code.substr(tail_start,end-tail_start))
	if number != null: return tail_start+number.get_start()
	var cursor := end-1
	while cursor >= 0 and code[cursor] in [" ","\t","\n","\r"]: cursor -= 1
	while cursor >= 0 and "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789.".contains(code[cursor]): cursor -= 1
	if cursor >= 0 and code[cursor] in [")","]"]:
		var call := code[cursor] == ")"
		var depth := 1
		cursor -= 1
		while cursor >= 0 and depth > 0:
			if code[cursor] in [")","]"]: depth += 1
			elif code[cursor] in ["(","["]: depth -= 1
			cursor -= 1
		if call:
			var name := _regex('([A-Za-z_][A-Za-z_0-9]*)\\s*$').search(code.left(cursor+1))
			if name != null and name.get_string(1) not in ["return","if","for","while","switch"]: cursor = name.get_end(1)-1
	while cursor >= 0 and "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789.".contains(code[cursor]): cursor -= 1
	return cursor+1

static func _expression_type(value: String, types: Dictionary, depth: int = 0) -> String:
	value = value.strip_edges()
	if depth > 24 or value.is_empty(): return ""
	if value.is_valid_int(): return "int"
	if value.is_valid_float(): return "float"
	if value in ["true","false"]: return "bool"
	if types.has(value): return types[value]
	if value.contains("?"):
		var level := 0
		var question := -1
		var ternaries := 0
		for index in value.length():
			var character := value.unicode_at(index)
			if character == 40 or character == 91: level += 1 # ( or [
			elif character == 41 or character == 93: level -= 1 # ) or ]
			elif level == 0 and character == 63: # ?
				if question < 0: question = index
				ternaries += 1
			elif level == 0 and character == 58 and question >= 0: # :
				ternaries -= 1
				if ternaries == 0: return _expression_type(value.substr(question+1,index-question-1),types,depth+1)
	var nesting := 0
	for index in range(value.length()-1,-1,-1):
		var character := value.unicode_at(index)
		if character == 41 or character == 93: nesting += 1 # ) or ]
		elif character == 40 or character == 91: nesting -= 1 # ( or [
		elif nesting == 0 and (character == 60 or character == 62 or character == 61 or character == 33 or character == 38 or character == 124): return "bool" # < > = ! & |
		elif nesting == 0 and (character == 43 or character == 45 or character == 42 or character == 47) and index > 0 and value[index-1] not in ["e","E","+","-","*","/"]: # + - * /
			var left := _expression_type(value.left(index),types,depth+1)
			var right := _expression_type(value.substr(index+1),types,depth+1)
			if left.begins_with("mat"): return "vec"+left.right(1) if right.contains("vec") else left
			if right.begins_with("mat"): return "vec"+right.right(1) if left.contains("vec") else right
			if left.contains("vec"): return left
			if right.contains("vec"): return right
			if "float" in [left,right]: return "float"
			return "int" if left == "int" and right == "int" else ""
	if value.begins_with("("):
		var parsed := _arguments(value,1)
		if parsed.ok and parsed.end == value.length(): return _expression_type(value.substr(1,value.length()-2),types,depth+1)
	if value.begins_with("-") or value.begins_with("+"): return _expression_type(value.substr(1),types,depth+1)
	var swizzle := _regex('\\.([xyzwrgba]+)$').search(value)
	if swizzle != null:
		var base := _expression_type(value.left(swizzle.get_start()),types,depth+1)
		var scalar := "int" if base.begins_with("ivec") else "bool" if base.begins_with("bvec") else "float"
		return scalar if swizzle.get_string(1).length() == 1 else ("ivec" if scalar == "int" else "bvec" if scalar == "bool" else "vec")+str(swizzle.get_string(1).length())
	var token := _regex('^([A-Za-z_][A-Za-z_0-9]*)').search(value)
	if token == null: return ""
	var name := token.get_string()
	if _regex('^(?:[biu]?vec[234]|mat[234]|float|int|bool)$').search(name): return name
	if value.substr(token.get_end()).strip_edges().begins_with("["):
		var type := str(types.get(name,""))
		if type.ends_with("[]"): return type.trim_suffix("[]")
		return "vec"+type.right(1) if type.begins_with("mat") else "float" if type.begins_with("vec") else "int" if type.begins_with("ivec") else type
	if name in ["texture","textureLod","texelFetch","textureOffset","textureLodOffset","texelFetchOffset"]: return "vec4"
	if name in ["dot","length","distance","determinant"]: return "float"
	if name in ["all","any","isnan","isinf"]: return "bool"
	if name == "textureSize": return "ivec2"
	if name in ["lessThan","greaterThan","equal","notEqual","lessThanEqual","greaterThanEqual"]:
		var call := _arguments(value,value.find("(")+1)
		if call.ok and not call.arguments.is_empty():
			var type := _expression_type(call.arguments[0],types,depth+1)
			if type.contains("vec"): return "bvec"+type.right(1)
		return ""
	if types.has(name): return types[name]
	var invocation := _regex('^[A-Za-z_][A-Za-z_0-9]*\\s*\\(').search(value)
	if invocation != null:
		var parsed := _arguments(value,invocation.get_end())
		if parsed.ok and not parsed.arguments.is_empty(): return _expression_type(parsed.arguments[0],types,depth+1)
	return ""

static func _coerce_value(value: String, expected: String, types: Dictionary) -> String:
	var actual := _expression_type(value,types)
	if expected == "float" and actual in ["int","bool"]: return "float(%s)"%value
	if expected.begins_with("vec") and actual.begins_with("ivec"): return expected+"("+value+")"
	if expected.begins_with("vec") and actual.begins_with("vec") and int(expected.right(1)) < int(actual.right(1)): return "(%s).%s"%[value,"xyzw".left(int(expected.right(1)))]
	if expected.begins_with("mat") and actual.begins_with("mat") and int(expected.right(1)) < int(actual.right(1)):
		var columns := PackedStringArray()
		for column in int(expected.right(1)): columns.append("(%s)[%d].%s"%[value,column,"xyzw".left(int(expected.right(1)))])
		return expected+"("+", ".join(columns)+")"
	return value

static func _coerce_glsl(code: String, parameters: Array) -> String:
	var globals := {"ra_input_size":"vec2","ra_output_size":"vec2","ra_output_origin":"vec2","ra_frame_count":"int"}
	for parameter: Dictionary in parameters: globals[parameter.name] = "float"
	var units := _units(code)
	for unit: String in units:
		var typed := _regex('^(?:const\\s+|varying\\s+)?(float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*)(\\s*\\[)?').search(unit)
		if typed != null: globals[typed.get_string(2)] = typed.get_string(1)+("[]" if not typed.get_string(3).is_empty() else "")
	var output := PackedStringArray()
	for unit: String in units:
		if not unit.contains("{") or unit.begins_with("struct "): output.append(unit); continue
		var types := globals.duplicate()
		for typed: RegExMatch in _regex('\\b(float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*)(\\s*\\[)?').search_all(unit): types[typed.get_string(2)] = typed.get_string(1)+("[]" if not typed.get_string(3).is_empty() else "")
		for declaration: RegExMatch in _regex('\\b(float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*\\s*[,=;\\[][^;{}]*);').search_all(unit):
			var parsed := _arguments(declaration.get_string(2)+")",0)
			for item: String in parsed.get("arguments",[]):
				var variable := _regex('^([A-Za-z_][A-Za-z_0-9]*)(\\s*\\[)?').search(item)
				if variable != null: types[variable.get_string(1)] = declaration.get_string(1)+("[]" if not variable.get_string(2).is_empty() else "")
		var calls := _regex('\\b(float|mix|vec[234]|bvec[234]|mat[234]|textureLod|textureLodOffset)\\s*\\(').search_all(unit)
		calls.reverse()
		for call: RegExMatch in calls:
			var parsed := _arguments(unit,call.get_end())
			if not parsed.ok: continue
			if call.get_string(1) in ["textureLod","textureLodOffset"]:
				if parsed.arguments.size() >= 3:
					parsed.arguments[2] = _coerce_value(parsed.arguments[2],"float",types)
					unit = unit.substr(0,call.get_end())+", ".join(parsed.arguments)+")"+unit.substr(parsed.end)
				continue
			if call.get_string(1).begins_with("mat"):
				var matrix := _matrix_constructor(call.get_string(1),parsed.arguments,types)
				if not matrix.is_empty():
					unit = unit.substr(0,call.get_start())+matrix.call+unit.substr(parsed.end)
					globals[matrix.name] = call.get_string(1)
					if matrix.code not in output: output.append(matrix.code)
				continue
			if call.get_string(1).begins_with("vec") or call.get_string(1).begins_with("bvec"):
				var changed := false
				var remaining := int(call.get_string(1).right(1))
				for index in parsed.arguments.size():
					var argument: String = parsed.arguments[index]
					var type := _expression_type(argument,types)
					var width := int(type.right(1)) if type.contains("vec") else 1
					if width > remaining and remaining > 0 and index == parsed.arguments.size()-1:
						argument = "(%s).%s"%[argument,"xyzw".left(remaining)]
						type = ("float" if type.begins_with("vec") else "int" if type.begins_with("ivec") else "bool") if remaining == 1 else type.left(-1)+str(remaining)
						parsed.arguments[index] = argument
						changed = true
					remaining -= width
					if call.get_string(1).begins_with("bvec") and type in ["float","int"]: parsed.arguments[index] = "bool(%s)"%argument; changed = true
					elif call.get_string(1).begins_with("vec") and type in ["bool","int"]: parsed.arguments[index] = "float(%s)"%argument; changed = true
					elif call.get_string(1).begins_with("vec") and type.begins_with("bvec"):
						var components := PackedStringArray()
						for component in int(type.right(1)): components.append("float((%s).%s)"%[argument,"xyzw"[component]])
						parsed.arguments[index] = "vec%s(%s)"%[type.right(1),", ".join(components)]; changed = true
				if changed: unit = unit.substr(0,call.get_end())+", ".join(parsed.arguments)+")"+unit.substr(parsed.end)
				continue
			if call.get_string(1) == "float" and parsed.arguments.size() == 1:
				var type := _expression_type(parsed.arguments[0],types)
				if type.begins_with("ivec"): unit = unit.substr(0,call.get_start())+"vec"+type.right(1)+"("+parsed.arguments[0]+")"+unit.substr(parsed.end)
				elif type.begins_with("bvec"):
					var components := PackedStringArray()
					for index in int(type.right(1)): components.append("float((%s).%s)"%[parsed.arguments[0],"xyzw"[index]])
					unit = unit.substr(0,call.get_start())+"vec"+type.right(1)+"("+", ".join(components)+")"+unit.substr(parsed.end)
			elif parsed.arguments.size() == 3:
				var selector: String = parsed.arguments[2]
				if _expression_type(selector,types) == "bool":
					unit = unit.substr(0,call.get_start())+"((%s) ? (%s) : (%s))"%[selector,parsed.arguments[1],parsed.arguments[0]]+unit.substr(parsed.end)
				else:
					for index in 2:
						var actual := _expression_type(parsed.arguments[index],types)
						if actual.begins_with("ivec"): parsed.arguments[index] = "vec"+actual.right(1)+"("+parsed.arguments[index]+")"
						elif actual == "int": parsed.arguments[index] = "float("+parsed.arguments[index]+")"
					unit = unit.substr(0,call.get_end())+", ".join(parsed.arguments)+")"+unit.substr(parsed.end)
		for iteration in 3:
			var before := unit
			var operations := _regex('[+*/-]').search_all(unit)
			operations.reverse()
			for operation: RegExMatch in operations:
				var index := operation.get_start()
				if index == 0 or index+1 >= unit.length() or unit[index+1] in ["=","+","-"] or unit[index-1] in ["+","-","*","/","e","E"]: continue
				var begin := _operand_start(unit,index)
				var end := _operand_end(unit,index+1)
				if begin >= index or end <= index+1: continue
				var left := unit.substr(begin,index-begin).strip_edges()
				var right := unit.substr(index+1,end-index-1).strip_edges()
				var left_type := _expression_type(left,types)
				var right_type := _expression_type(right,types)
				if operation.get_string() == "*" and left_type.begins_with("mat") and right_type.begins_with("vec") and int(left_type.right(1)) > int(right_type.right(1)): right = "vec%s(%s%s)"%[left_type.right(1),right,", 0.0".repeat(int(left_type.right(1))-int(right_type.right(1)))]
				elif operation.get_string() == "*" and right_type.begins_with("mat") and left_type.begins_with("vec") and int(right_type.right(1)) > int(left_type.right(1)): left = "vec%s(%s%s)"%[right_type.right(1),left,", 0.0".repeat(int(right_type.right(1))-int(left_type.right(1)))]
				elif operation.get_string() == "*" and left_type.begins_with("mat") and right_type.begins_with("mat") and left_type != right_type:
					var size := maxi(int(left_type.right(1)),int(right_type.right(1)))
					if int(left_type.right(1)) < size: left = _pad_matrix(left,int(left_type.right(1)),size)
					if int(right_type.right(1)) < size: right = _pad_matrix(right,int(right_type.right(1)),size)
				elif left_type == "int" and (right_type == "float" or right_type.begins_with("vec")): left = "float(%s)"%left
				elif right_type == "int" and (left_type == "float" or left_type.begins_with("vec")): right = "float(%s)"%right
				else: continue
				unit = unit.substr(0,begin)+left+" "+operation.get_string()+" "+right+unit.substr(end)
			if unit == before: break
		var assignments := _regex('\\b([A-Za-z_][A-Za-z_0-9]*(?:\\.[xyzwrgba]+)?)\\s*[+*/-]?=(?!=)\\s*([^;{}]+);').search_all(unit)
		assignments.reverse()
		for assignment: RegExMatch in assignments:
			var expected := _expression_type(assignment.get_string(1),types)
			var value := _coerce_value(assignment.get_string(2),expected,types)
			unit = unit.substr(0,assignment.get_start(2))+value+unit.substr(assignment.get_end(2))
		output.append(unit)
	return "\n".join(output)

static func _matrix_constructor(type: String, arguments: Array, types: Dictionary) -> Dictionary:
	# GLSL consumes scalar/vector components in column order. A helper keeps
	# each argument evaluated once when it straddles a Godot matrix column.
	var size := int(type.right(1))
	if arguments.size() <= 1: return {}
	var signature := PackedStringArray()
	var declarations := PackedStringArray()
	var components := PackedStringArray()
	for index in arguments.size():
		var actual := _expression_type(arguments[index],types)
		if actual not in ["float","int","bool","vec2","vec3","vec4","ivec2","ivec3","ivec4"]: return {}
		signature.append(actual)
		var name := "ra_c%d"%index
		declarations.append(actual+" "+name)
		var width := int(actual.right(1)) if actual.contains("vec") else 1
		for component in width:
			var value := name+("."+"xyzw"[component] if width > 1 else "")
			components.append("float(%s)"%value if actual in ["int","bool"] or actual.begins_with("ivec") else value)
	if components.size() != size*size: return {}
	if arguments.size() == size and signature.count("vec%d"%size) == size: return {}
	var columns := PackedStringArray()
	for index in size: columns.append("vec%d(%s)"%[size,", ".join(components.slice(index*size,(index+1)*size))])
	var name := "ra_construct_"+type+"_"+"_".join(signature)
	return {"name":name,"call":name+"("+", ".join(arguments)+")","code":"%s %s(%s) { return %s(%s); }"%[type,name,", ".join(declarations),type,", ".join(columns)]}

static func _pad_matrix(value: String, old_size: int, new_size: int) -> String:
	var columns := PackedStringArray()
	for column in old_size: columns.append("vec%d((%s)[%d]%s)"%[new_size,value,column,", 0.0".repeat(new_size-old_size)])
	for column in range(old_size,new_size): columns.append("vec%d(0.0)"%new_size)
	return "mat%d(%s)"%[new_size,", ".join(columns)]

static func _vector_width(expression: String, code: String) -> int:
	var swizzle := _regex('\\.([xyzwrgba]{2,4})$').search(expression.strip_edges())
	if swizzle != null: return swizzle.get_string(1).length()
	var token := _regex('^\\s*([A-Za-z_][A-Za-z_0-9]*)').search(expression)
	if token == null: return 0
	var constructor := _regex('^[biu]?vec([234])$').search(token.get_string(1))
	if constructor != null: return int(constructor.get_string(1))
	var typed := _regex('\\b[biu]?vec([234])\\s+(?:[A-Za-z_][A-Za-z_0-9]*\\s*,\\s*)*%s\\b'%token.get_string(1)).search(code)
	return int(typed.get_string(1)) if typed != null else 0

static func _rectangular_matrices(code: String) -> String:
	var output := PackedStringArray()
	var types := ""
	for unit: String in _units(code):
		if not unit.contains("{"): types += unit+"\n"
	for unit: String in _units(code): output.append(_rectangular_matrix_unit(unit,types))
	return "\n".join(output)

static func _rectangular_matrix_unit(code: String, types: String = "") -> String:
	# Embed a CxR matrix in a square matrix with zero padding. Arithmetic
	# remains column-major; crop column reads and vector products to R rows.
	var shapes := {}
	for variable: RegExMatch in _regex('\\bmat([234])x([234])\\s+([A-Za-z_][A-Za-z_0-9]*)').search_all(code):
		shapes[variable.get_string(3)] = Vector2i(int(variable.get_string(1)),int(variable.get_string(2)))
	var constructors := _regex('\\bmat([234])x([234])\\s*\\(').search_all(code)
	constructors.reverse()
	for constructor: RegExMatch in constructors:
		var parsed := _arguments(code,constructor.get_end())
		if not parsed.ok: continue
		var columns := int(constructor.get_string(1))
		var rows := int(constructor.get_string(2))
		var size := maxi(columns,rows)
		var values := PackedStringArray()
		if parsed.arguments.size() == columns:
			for argument: String in parsed.arguments:
				values.append("vec%d(%s%s)"%[size,argument,", 0.0".repeat(size-rows)])
		elif parsed.arguments.size() == columns*rows:
			for column in columns: values.append("vec%d(%s%s)"%[size,", ".join(parsed.arguments.slice(column*rows,(column+1)*rows)),", 0.0".repeat(size-rows)])
		elif parsed.arguments.size() == 1 and not parsed.arguments[0].is_empty():
			for column in columns:
				var components := PackedStringArray()
				for row in size: components.append(parsed.arguments[0] if column == row else "0.0")
				values.append("vec%d(%s)"%[size,", ".join(components)])
		else: continue
		for column in range(columns,size): values.append("vec%d(0.0)"%size)
		var expression := "mat%d(%s)"%[size,", ".join(values)]
		var start := constructor.get_start()
		var left := _regex('\\*\\s*$').search(code.left(start))
		if left != null:
			var begin := _operand_start(code,left.get_start())
			var lhs := code.substr(begin,left.get_start()-begin).strip_edges()
			if _vector_width(lhs,types+code) > 0:
				expression = "(vec%d(%s%s) * %s).%s"%[size,lhs,", 0.0".repeat(size-rows),expression,"xyzw".left(columns)]
				start = begin
		var end: int = parsed.end
		var product := _regex('^\\s*\\*\\s*').search(code.substr(end))
		if product != null:
			var begin: int = end+product.get_end()
			var rhs_end := _operand_end(code,begin)
			if rhs_end > begin and _vector_width(code.substr(begin,rhs_end-begin),code) > 0:
				var rhs := code.substr(begin,rhs_end-begin)
				expression = "(%s * vec%d(%s%s)).%s"%[expression,size,rhs,", 0.0".repeat(size-columns),"xyzw".left(rows)]
				end = rhs_end
		code = code.substr(0,start)+expression+code.substr(end)
	for name: String in shapes:
		var shape: Vector2i = shapes[name]
		var size := maxi(shape.x,shape.y)
		var products := _regex('(?<![.A-Za-z_0-9])%s\\s*\\*\\s*'%name).search_all(code)
		products.reverse()
		for product: RegExMatch in products:
			var end := _operand_end(code,product.get_end())
			if end <= product.get_end(): continue
			var rhs := code.substr(product.get_end(),end-product.get_end())
			if _vector_width(rhs,code) == 0: continue
			code = code.substr(0,product.get_start())+"(%s * vec%d(%s%s)).%s"%[name,size,rhs,", 0.0".repeat(size-shape.x),"xyzw".left(shape.y)]+code.substr(end)
		var matrix_array := _regex('\\bmat[234]x[234]\\s+%s\\s*\\['%name).search(code) != null
		var columns := _regex('(?<![.A-Za-z_0-9])%s\\s*(%s\\[[^]\\n]+\\])'%[name,'\\[[^]\\n]+\\]\\s*' if matrix_array else '']).search_all(code)
		columns.reverse()
		for column: RegExMatch in columns:
			if _regex('\\bmat[234]x[234]\\s*$').search(code.left(column.get_start())): continue
			code = code.substr(0,column.get_start())+"("+column.get_string()+")."+"xyzw".left(shape.y)+code.substr(column.get_end())
	return _square_matrix_types(code)

static func _square_matrix_types(code: String) -> String:
	for columns in [2,3,4]:
		for rows in [2,3,4]: code = _regex('\\bmat%dx%d\\b'%[columns,rows]).sub(code,"mat%d"%maxi(columns,rows),true)
	return code

static func _matrices(code: String) -> String:
	code = _regex('\\bmat([234])x\\1\\b').sub(code,"mat$1",true)
	code = _rectangular_matrices(code)
	# A GLSL vec4 can flatten a mat2 into column-major components. Godot
	# requires explicit columns, including Royale's matrix/vector round trips.
	var matrix_names := {}
	var vector_names := {}
	for declaration: RegExMatch in _regex('\\b(mat2|[biu]?vec[234])\\s+([A-Za-z_][A-Za-z_0-9]*)').search_all(code):
		if declaration.get_string(1) == "mat2": matrix_names[declaration.get_string(2)] = true
		else: vector_names[declaration.get_string(2)] = true
	var flattenings := _regex('\\bvec4\\s*\\(').search_all(code)
	flattenings.reverse()
	for invocation: RegExMatch in flattenings:
		var parsed := _arguments(code,invocation.get_end())
		if not parsed.ok or parsed.arguments.size() != 1: continue
		var expression: String = parsed.arguments[0]
		var product := _regex('^\\s*([A-Za-z_][A-Za-z_0-9]*)(?:\\s*[*/]\\s*([-+]?[0-9.]+|[A-Za-z_][A-Za-z_0-9]*))?\\s*$').search(expression)
		if product == null or not matrix_names.has(product.get_string(1)) or vector_names.has(product.get_string(2)): continue
		code = code.substr(0,invocation.get_start())+"vec4((%s)[0], (%s)[1])"%[expression,expression]+code.substr(parsed.end)
	for declaration: RegExMatch in _regex('\\bmat([234])x([234])\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*=\\s*mat[234]x[234]\\s*\\(').search_all(code):
		var parsed := _arguments(code,declaration.get_end())
		if parsed.ok and parsed.arguments.size() == int(declaration.get_string(1)):
			code = code.substr(0,declaration.get_start())+"vec%s %s[%s] = vec%s[](%s)"%[declaration.get_string(2),declaration.get_string(3),declaration.get_string(1),declaration.get_string(2),", ".join(parsed.arguments)]+code.substr(parsed.end)
	var rectangular := _regex('\\bmat([234])x([234])\\s*\\(').search_all(code)
	rectangular.reverse()
	for constructor: RegExMatch in rectangular:
		var parsed := _arguments(code,constructor.get_end())
		if not parsed.ok: continue
		var product := _regex('^\\s*\\*\\s*([A-Za-z_][A-Za-z_0-9]*(?:\\.[xyzwrgba]+)?)').search(code.substr(parsed.end))
		var columns := int(constructor.get_string(1))
		if product == null or parsed.arguments.size() != columns: continue
		var weight := product.get_string(1)
		var product_end: int = parsed.end+product.get_end()
		var rhs_call := _regex('^\\s*\\(').search(code.substr(product_end))
		if rhs_call != null:
			var vector := _arguments(code,product_end+rhs_call.get_end())
			if not vector.ok: continue
			weight += "("+", ".join(vector.arguments)+")"
			product_end = vector.end
		var terms := PackedStringArray()
		for index in columns: terms.append("(%s)*(%s).%s"%[parsed.arguments[index],weight,"xyzw"[index]])
		code = code.substr(0,constructor.get_start())+"("+" + ".join(terms)+")"+code.substr(product_end)
	# GLSL accepts N*N scalar matrix constructor arguments; Godot wants columns.
	var matches := _regex('\\bmat([234])\\s*\\(').search_all(code)
	matches.reverse()
	for match: RegExMatch in matches:
		var size := int(match.get_string(1))
		var start := match.get_end()
		var depth := 1
		var arguments := PackedStringArray()
		var argument_start := start
		for index in range(start, code.length()):
			if code[index] == "(": depth += 1
			elif code[index] == ")": depth -= 1
			if code[index] == "," and depth == 1 or depth == 0:
				arguments.append(code.substr(argument_start, index-argument_start).strip_edges())
				argument_start = index+1
			if depth == 0:
				if arguments.size() == 1:
					if size == 2 and _regex('^vec4\\s*\\(').search(arguments[0]):
						code = code.substr(0,match.get_start())+"mat2((%s).xy, (%s).zw)"%[arguments[0],arguments[0]]+code.substr(index+1)
						break
					for variable: RegExMatch in _regex('\\bmat%d\\s+([A-Za-z_][A-Za-z_0-9]*)'%size).search_all(code):
						if _regex('\\b%s\\b(?!\\s*\\[)'%variable.get_string(1)).search(arguments[0]):
							code = code.substr(0,match.get_start())+"("+arguments[0]+")"+code.substr(index+1)
							break
				elif arguments.size() == size*size:
					var columns := PackedStringArray()
					for column in size: columns.append("vec%d(%s)"%[size, ", ".join(arguments.slice(column*size, (column+1)*size))])
					code = code.substr(0, start)+", ".join(columns)+code.substr(index)
				elif size == 4 and arguments.size() == 10:
					var columns := PackedStringArray()
					if _vector_width(arguments[0],code) == 4 and _vector_width(arguments[1],code) == 4:
						columns.append("vec4(%s)"%arguments[0]); columns.append("vec4(%s)"%arguments[1])
						columns.append("vec4(%s)"%", ".join(arguments.slice(2,6))); columns.append("vec4(%s)"%", ".join(arguments.slice(6)))
					else:
						# vec3/scalar column pairs followed by four scalars.
						for column in 3: columns.append("vec4(%s, float(%s))"%[arguments[column*2],arguments[column*2+1]])
						columns.append("vec4(%s)"%", ".join(arguments.slice(6)))
					code = code.substr(0,start)+", ".join(columns)+code.substr(index)
				break
	return code

static func _stage_state(code: String, stage: String) -> String:
	# Godot has immutable globals and a shared stage scope. Thread invocation
	# state through helpers instead of sharing mutable storage between pixels.
	var units := _units(code)
	var fields := {}
	var retained := PackedStringArray()
	var varyings := PackedStringArray()
	for unit: String in units:
		var declaration := _regex('(?s)^(varying\\s+)?([A-Za-z_][A-Za-z_0-9]*)\\s+([^;{}]+);$').search(unit)
		if declaration == null or declaration.get_string(2) in ["const","uniform","return"]:
			retained.append(unit)
			continue
		var varying := not declaration.get_string(1).is_empty()
		if varying and stage != "vertex": retained.append(unit); continue
		var parsed := _arguments(declaration.get_string(3)+")",0)
		var keep := PackedStringArray()
		for item: String in parsed.get("arguments",[]):
			var variable := _regex('(?s)^([A-Za-z_][A-Za-z_0-9]*)(\\s*\\[[^]]+\\])?(?:\\s*=\\s*(.*))?$').search(item)
			if variable == null: keep.append(item); continue
			var name := variable.get_string(1)
			var initialized := item.contains("=")
			var writes := _regex('\\b%s\\b(?:\\s*(?:\\.[A-Za-z_][A-Za-z_0-9]*|\\[[^]]+\\]))*\\s*(?:[+*/-]?=(?!=)|\\+\\+|--)'%name).search_all(code).size()
			writes += _regex('(?:\\+\\+|--)\\s*\\b%s\\b'%name).search_all(code).size()
			if not varying and initialized and writes <= 1 and variable.get_string(2).is_empty(): keep.append(item); continue
			fields[name] = {"type":declaration.get_string(2),"array":variable.get_string(2),"init":variable.get_string(3)}
			if varying: varyings.append(name)
		if varying or not keep.is_empty(): retained.append(("varying " if varying else "")+declaration.get_string(2)+" "+(", ".join(parsed.arguments) if varying else ", ".join(keep))+";")
	# Built-ins are only available in entry points. Helpers receive snapshots.
	for builtin: String in ["FRAGCOORD","UV"]:
		for unit: String in units:
			if unit.contains("{") and not unit.begins_with("struct ") and not _regex('^void\\s+main\\s*\\(').search(unit) and _regex('\\b%s\\b'%builtin).search(unit):
				fields[builtin] = {"type":"vec4" if builtin == "FRAGCOORD" else "vec2","array":"","init":builtin}
				break
	if fields.is_empty(): return code
	var state_type := "ra_"+stage+"_state"
	var structure := "struct "+state_type+" { "
	var initialization := ""
	for name: String in fields:
		var info: Dictionary = fields[name]
		structure += "%s %s%s; "%[info.type,name,info.array]
		if not str(info.init).is_empty(): initialization += "ra_state.%s = %s; "%[name,info.init]
		elif info.array.is_empty() and info.type in ["float","int","uint","bool","vec2","vec3","vec4","ivec2","ivec3","ivec4","bvec2","bvec3","bvec4","mat2","mat3","mat4"]:
			initialization += "ra_state.%s = %s(%s); "%[name,info.type,"false" if info.type.begins_with("b") else "0"]
	structure += "};"
	var functions := {}
	# Passing the same state to all stage helpers also handles overloaded and
	# nested functions without changing their original argument evaluation.
	for unit: String in retained:
		var function := _regex('^[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search(unit)
		if function != null and function.get_string(1) != "main" and unit.contains("{"): functions[function.get_string(1)] = true
	var output := PackedStringArray()
	for unit: String in retained:
		if not unit.contains("{") or unit.begins_with("struct "): output.append(unit); continue
		var signature := _regex('^[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search(unit)
		if signature == null: output.append(unit); continue
		var main := signature.get_string(1) == "main"
		for name: String in fields: unit = _regex('(?<![.A-Za-z_0-9])%s\\b'%name).sub(unit,"ra_state."+name,true)
		var calls := _regex('\\b([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search_all(unit)
		calls.reverse()
		for call: RegExMatch in calls:
			if not functions.has(call.get_string(1)): continue
			var end := call.get_end()
			var argument := "inout "+state_type+" ra_state" if call.get_start() == signature.get_start(1) else "ra_state"
			unit = unit.substr(0,end)+argument+("" if unit.substr(end).strip_edges().begins_with(")") else ", ")+unit.substr(end)
		if main:
			var begin := unit.find("{")+1
			var flush := ""
			for name: String in varyings: flush += "%s = ra_state.%s; "%[name,name]
			if stage == "vertex": flush += "VERTEX = ra_output_size * (ra_state.ra_clip_position.xy / ra_state.ra_clip_position.w * 0.5 + 0.5);"
			if stage == "vertex" and unit.contains("return;"):
				var body := unit.substr(begin,unit.length()-begin-1)
				body = _regex('\\bUV\\b').sub(body,"ra_uv",true)
				body = _regex('\\bCOLOR\\b').sub(body,"ra_color",true)
				output.append("void ra_vertex_body(inout %s ra_state, vec2 ra_uv, inout vec4 ra_color) { %s }"%[state_type,body])
				unit = "void main() { %s ra_state; %s ra_vertex_body(ra_state, UV, COLOR); %s }"%[state_type,initialization,flush]
			else:
				unit = unit.substr(0,begin)+state_type+" ra_state; "+initialization+unit.substr(begin)
				unit = unit.left(unit.length()-1)+flush+"\n}"
		output.append(unit)
	return structure+"\n"+"\n".join(output)

static func _runtime_globals(code: String, parameters: Array) -> String:
	# GLSL often caches uniform-only coefficients in mutable globals. With a
	# single assignment they can be recomputed as pure functions in Godot.
	var known := {}
	for parameter: Dictionary in parameters: known[parameter.name] = true
	var units := _units(code)
	for unit: String in units:
		var global := _regex('^(?:const\\s+|varying\\s+)?(?:float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*)').search(unit)
		if global != null: known[global.get_string(1)] = true
	var cached := {}
	for unit: String in units:
		var global := _regex('^(float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*;$').search(unit)
		if global == null: continue
		var name := global.get_string(2)
		var assignments := _regex('\\b%s\\s*=(?!=)\\s*([^;]+);'%name).search_all(code)
		if assignments.size() != 1: continue
		var expression := assignments[0].get_string(1)
		var pure := true
		for token: RegExMatch in _regex('\\b[A-Za-z_][A-Za-z_0-9]*\\b').search_all(expression):
			var identifier := token.get_string()
			if not known.has(identifier) and identifier not in ["true","false","float","int","vec2","vec3","vec4","mat2","mat3","mat4"] and not identifier.begins_with("ra_"): pure = false; break
		if not pure: continue
		code = code.replace(assignments[0].get_string(),"").replace(unit,"%s ra_cached_%s() { return %s; }"%[global.get_string(1),name,expression])
		cached[name] = true
	for name: String in cached: code = _regex('\\b%s\\b'%name).sub(code,"ra_cached_%s()"%name,true)
	var runtime: Array[String] = ["ra_input_size", "ra_output_size", "ra_frame_count"]
	for parameter: Dictionary in parameters: runtime.append(parameter.name)
	for uniform: RegExMatch in _regex('\\buniform\\s+[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)').search_all(code): runtime.append(uniform.get_string(1))
	for uniform: RegExMatch in _regex('\\bra_[A-Za-z_0-9]*_size\\b').search_all(code): runtime.append(uniform.get_string())
	for varying: RegExMatch in _regex('\\bvarying\\s+[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)').search_all(code): runtime.append(varying.get_string(1))
	var expressions := {}
	for unit: String in _units(code):
		var match := _regex('(?s)^(?:const\\s+)?(float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*=([^;]+);$').search(unit)
		if match != null: expressions[match.get_string(2)] = {"type":match.get_string(1),"expression":match.get_string(3),"unit":unit}
	for iteration in expressions.size():
		var changed := false
		for name: String in expressions:
			if name in runtime: continue
			for token: RegExMatch in _regex('\\b[A-Za-z_][A-Za-z_0-9]*\\b').search_all(expressions[name].expression):
				if token.get_string() in runtime: runtime.append(name); changed = true; break
		if not changed: break
	for name: String in expressions:
		if name not in runtime: continue
		var info: Dictionary = expressions[name]
		code = code.replace(info.unit,"%s ra_global_%s() { return %s; }"%[info.type,name,info.expression])
	for name: String in expressions:
		if name in runtime: code = _regex('\\b%s\\b'%name).sub(code,"ra_global_%s()"%name,true)
	return code

static func _strict_types(code: String, parameters: Array) -> String:
	# Godot's lexer consumes a following +/- as part of an exponent unless
	# separated. Preserve the literal and separate the arithmetic operator.
	code = _regex('(?<![.A-Za-z_0-9])((?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)[eE][+-]?[0-9]+)(?=[+-])').sub(code,"$1 ",true)
	code = _regex('\\(\\s*void\\s*\\)').sub(code,"()",true)
	code = _regex('\\[([0-9]+)\\.\\]').sub(code,"[$1]",true)
	code = _regex('(\\bfor\\s*\\(\\s*int\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*=[^;]+;\\s*\\2\\s*[<>]=?\\s*)([0-9]+)\\.(?![0-9])').sub(code,"$1$3",true)
	# Infer GLSL's unsized array constructors; Godot requires a declared size.
	var arrays := _regex('\\b([biu]?vec[234]|float|int|bool)\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\[\\s*\\]\\s*=\\s*[A-Za-z_][A-Za-z_0-9]*\\s*\\[\\s*\\]\\s*\\(').search_all(code)
	arrays.reverse()
	for array: RegExMatch in arrays:
		var parsed := _arguments(code,array.get_end())
		if parsed.ok: code = code.substr(0,array.get_start())+"%s %s[%d] = %s[]("%[array.get_string(1),array.get_string(2),parsed.arguments.size(),array.get_string(1)]+code.substr(array.get_end())
	var output := PackedStringArray()
	var globals := {}
	var global_floats := {"ra_input_size":true,"ra_output_size":true,"ra_output_origin":true}
	var global_integers := {"ra_frame_count":true}
	var function_types := {}
	var booleans := {}
	for function: RegExMatch in _regex('\\bbool\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search_all(code): booleans[function.get_string(1)] = true
	for parameter: Dictionary in parameters: globals[parameter.name] = true
	for parameter: Dictionary in parameters: global_floats[parameter.name] = true
	for name: String in ["ra_input_size","ra_output_size","ra_frame_count","ra_output_origin"]: globals[name] = true
	# Both passes inspect the same source. Keep the parsed units and shared
	# return types once instead of rescanning the full shader for every helper.
	var units := _units(code)
	for unit: String in units:
		var function := _regex('^[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search(unit)
		if function != null:
			var parsed := _arguments(unit,function.get_end())
			if parsed.ok:
				var types: Array[String] = []
				for argument: String in parsed.arguments: types.append(argument.strip_edges().get_slice(" ",0))
				if not function_types.has(function.get_string(1)): function_types[function.get_string(1)] = []
				function_types[function.get_string(1)].append(types)
		var declaration := _regex('^(?:varying|const)\\s+[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)').search(unit)
		if declaration != null: globals[declaration.get_string(1)] = true
		var global := _regex('^(?:varying\\s+|const\\s+)?(?:float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*[=;\\[]').search(unit)
		if global != null: globals[global.get_string(1)] = true
		var typed := _regex('^(?:varying\\s+|const\\s+)?(float|int|vec[234])\\s+([A-Za-z_][A-Za-z_0-9]*)').search(unit)
		if typed != null:
			var name := typed.get_string(2)
			if typed.get_string(1) == "int": global_integers[name+"()" if unit.contains("{") else name] = true
			else: global_floats[name] = true
	for unit: String in units:
		var signature := _regex('^[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search(unit)
		if signature != null:
			var parsed := _arguments(unit,signature.get_end())
			if parsed.ok:
				for argument: String in parsed.arguments:
					var param := _regex('\\b[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)$').search(argument)
					if param != null and globals.has(param.get_string(1)): unit = _regex('\\b%s\\b'%param.get_string(1)).sub(unit,"ra_arg_"+param.get_string(1),true)
			var locals := _regex('\\b(?:float|int|bool|[biu]?vec[234])\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*[=;]').search_all(unit)
			locals.reverse()
			for local: RegExMatch in locals:
				var name := local.get_string(1)
				if not globals.has(name): continue
				var initializer_end := unit.find(";",local.get_end()-1)+1
				if initializer_end < 1: continue
				# GLSL permits a local initialized from the global it shadows.
				# Its new scope starts after the initializer, not inside the RHS.
				var tail := _regex('(?<!\\.)\\b%s\\b'%name).sub(unit.substr(initializer_end),"ra_local_"+name,true)
				unit = unit.substr(0,local.get_start(1))+"ra_local_"+name+unit.substr(local.get_end(1),initializer_end-local.get_end(1))+tail
		var floats := global_floats.duplicate()
		var integers := global_integers.duplicate()
		var vectors := {}
		for variable: RegExMatch in _regex('\\b([biu]?vec[234])\\s+([A-Za-z_][A-Za-z_0-9]*)').search_all(unit): vectors[variable.get_string(2)] = variable.get_string(1)
		for variable: RegExMatch in _regex('\\b(?:float|vec[234])\\s+([A-Za-z_][A-Za-z_0-9]*(?:\\s*,\\s*(?!(?:float|int|vec[234])\\b)[A-Za-z_][A-Za-z_0-9]*)*)').search_all(unit):
			for name: String in variable.get_string(1).split(","): floats[name.strip_edges()] = true; integers.erase(name.strip_edges())
		for variable: RegExMatch in _regex('\\b(?:int|ivec[234])\\s+([A-Za-z_][A-Za-z_0-9]*)').search_all(unit): floats.erase(variable.get_string(1)); integers[variable.get_string(1)] = true
		for name: String in integers: floats.erase(name)
		for integer: String in integers:
			# Most shared parameters/globals are absent from any one helper.
			# A cheap substring rejection avoids constructing regexes which
			# cannot match; retained candidates still use exact token boundaries.
			if not unit.contains(integer): continue
			var escaped := integer.replace("(","\\(").replace(")","\\)")
			var value := '(?<![.A-Za-z_0-9])%s(?![A-Za-z_0-9])'%escaped
			unit = _regex('('+value+')(\\s*(?:[+*/-]|<=|>=|<|>|==|!=)\\s*[0-9]+\\.[0-9]*)').sub(unit,"float($1)$2",true)
			unit = _regex('([0-9]+\\.[0-9]*(?:[eE][+-]?[0-9]+)?\\s*[+*/-]\\s*)('+value+')').sub(unit,"$1float($2)",true)
			unit = _regex('('+value+')(\\s*[*/]\\s*\\(\\s*[0-9]+\\.[0-9]*)').sub(unit,"float($1)$2",true)
			for name: String in floats:
				if not unit.contains(name): continue
				var floating := '\\b%s(?:\\.[xyzwrgba]+)?\\b'%name
				unit = _regex('('+value+')(\\s*(?:[+*/-]|<=|>=|<|>|==|!=)\\s*'+floating+')').sub(unit,"float($1)$2",true)
				unit = _regex('('+floating+'\\s*[+*/-]\\s*)('+value+')').sub(unit,"$1float($2)",true)
		for name: String in floats:
			if not unit.contains(name): continue
			var value := '\\b%s(?:\\.[xyzwrgba]+)?'%name
			unit = _regex('('+value+'\\s*(?:[+*/-]|<=|>=|<|>|==|!=)\\s*)([0-9]+)(?![.A-Za-z_0-9])').sub(unit,"$1$2.0",true)
			unit = _regex('(?<![.A-Za-z_0-9])(?<![Ee][+-])([0-9]+)(\\s*[+*/-]\\s*'+value+'\\b)').sub(unit,"$1.0$2",true)
			var assignments := _regex('\\b%s\\s*=\\s*([^;]+);'%name).search_all(unit)
			assignments.reverse()
			for assignment: RegExMatch in assignments:
				if _integer_expression(assignment.get_string(1),integers): unit = unit.substr(0,assignment.get_start(1))+"float("+assignment.get_string(1)+")"+unit.substr(assignment.get_end(1))
		var constructors := _regex('\\bvec([234])\\s*\\(').search_all(unit)
		constructors.reverse()
		for constructor: RegExMatch in constructors:
			var parsed := _arguments(unit,constructor.get_end())
			if not parsed.ok: continue
			for index in parsed.arguments.size():
				var value: String = parsed.arguments[index]
				if value.is_valid_int(): parsed.arguments[index] = value+".0"
				elif vectors.has(value) or _regex('^[A-Za-z_][A-Za-z_0-9]*\\.[xyzwrgba]{2,4}$').search(value):
					var width := int(str(vectors.get(value,"vec%d"%value.get_slice(".",1).length())).right(1))
					var expected := int(constructor.get_string(1))
					if parsed.arguments.size() == 1:
						if width > expected: parsed.arguments[index] = "(%s).%s"%[value,"xyzw".left(expected)]
						elif str(vectors.get(value,"")).begins_with("ivec"): parsed.arguments[index] = "vec%d(%s)"%[width,value]
				elif _integer_expression(value,integers): parsed.arguments[index] = "float(%s)"%value
				elif value in ["true","false"] or not value.contains("?") and booleans.has(value.get_slice("(",0).strip_edges()): parsed.arguments[index] = "float(%s)"%value
				elif not value.contains("?") and _regex('(?:<=|>=|==|!=|<|>|&&|\\|\\|)').search(value): parsed.arguments[index] = "float(%s)"%value
			unit = unit.substr(0,constructor.get_end())+", ".join(parsed.arguments)+")"+unit.substr(parsed.end)
		# A comma between assignment statements is GLSL's comma operator,
		# which Godot does not expose. Split only top-level assignment commas.
		unit = _regex('(?m)(^\\s*|[;{]\\s*)([A-Za-z_][A-Za-z_0-9]*(?:\\.[xyzwrgba]+)?\\s*=[^,;{}()]+),\\s*(?=[A-Za-z_][A-Za-z_0-9]*(?:\\.[xyzwrgba]+)?\\s*=)').sub(unit,"$1$2; ",true)
		unit = _regex('(?m)(^\\s*|[;{]\\s*)([A-Za-z_][A-Za-z_0-9]*(?:\\.[xyzwrgba]+)?\\s*=[^,;{}()]+),\\s*(?=[A-Za-z_][A-Za-z_0-9]*(?:\\.[xyzwrgba]+)?\\s*=)').sub(unit,"$1$2; ",true)
		unit = _regex('\\bmod\\s*\\(\\s*ra_frame_count\\s*,\\s*([0-9]+)\\s*\\)').sub(unit,"mod(float(ra_frame_count), $1.0)",true)
		var calls := _regex('\\b([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search_all(unit)
		calls.reverse()
		for invocation: RegExMatch in calls:
			var name := invocation.get_string(1)
			if not function_types.has(name) or signature != null and invocation.get_start(1) == signature.get_start(1): continue
			var parsed := _arguments(unit,invocation.get_end())
			if not parsed.ok: continue
			var changed := false
			for index in parsed.arguments.size():
				var value: String = parsed.arguments[index]
				if not value.is_valid_int() and not integers.has(value): continue
				var accepts_float := false
				var accepts_other := false
				for types: Array in function_types[name]:
					if types.size() != parsed.arguments.size(): continue
					if types[index] == "float": accepts_float = true
					else: accepts_other = true
				if accepts_float and not accepts_other: parsed.arguments[index] = "float(%s)"%value; changed = true
			if changed: unit = unit.substr(0,invocation.get_end())+", ".join(parsed.arguments)+")"+unit.substr(parsed.end)
		output.append(unit)
	return "\n".join(output)

static func _statement_end(code: String, start: int) -> int:
	while start < code.length() and code[start] in [" ","\t","\n","\r"]: start += 1
	if start >= code.length(): return start
	if code[start] == "{":
		var depth := 1
		for index in range(start+1,code.length()):
			if code[index] == "{": depth += 1
			elif code[index] == "}": depth -= 1
			if depth == 0: return index+1
	var control := _regex('^(if|for|while|switch)\\s*\\(').search(code.substr(start))
	if control != null:
		var parsed := _arguments(code,start+control.get_end())
		if not parsed.ok: return start
		var end := _statement_end(code,parsed.end)
		var otherwise := _regex('^\\s*else\\b').search(code.substr(end))
		if control.get_string(1) == "if" and otherwise != null: end = _statement_end(code,end+otherwise.get_end())
		return end
	var depth := 0
	for index in range(start,code.length()):
		if code[index] in ["(","["]: depth += 1
		elif code[index] in [")","]"]: depth -= 1
		elif code[index] == ";" and depth == 0: return index+1
	return start

static func _external_loops(code: String) -> String:
	# Godot requires a declaration in a for initializer. A while loop keeps
	# the lifetime and final value of a counter declared outside the loop.
	var loops := _regex('\\bfor\\s*\\(\\s*[A-Za-z_][A-Za-z_0-9]*\\s*=').search_all(code)
	loops.reverse()
	for loop: RegExMatch in loops:
		var opening := code.find("(",loop.get_start())
		var parsed := _arguments(code,opening+1)
		if not parsed.ok: continue
		var parts := code.substr(opening+1,parsed.end-opening-2).split(";")
		if parts.size() != 3: continue
		var begin: int = parsed.end
		while begin < code.length() and code[begin] in [" ","\t","\n","\r"]: begin += 1
		var end := _statement_end(code,begin)
		if end <= begin or code[begin] != "{": continue
		var body := code.substr(begin+1,end-begin-2)
		var nested: Array[Vector2i] = []
		for inner: RegExMatch in _regex('\\b(?:for|while)\\s*\\(').search_all(body): nested.append(Vector2i(inner.get_start(),_statement_end(body,inner.get_start())))
		var continuations := _regex('\\bcontinue\\s*;').search_all(body)
		continuations.reverse()
		for continuation: RegExMatch in continuations:
			var belongs := true
			for span: Vector2i in nested:
				if continuation.get_start() >= span.x and continuation.get_start() < span.y: belongs = false; break
			if belongs: body = body.substr(0,continuation.get_start())+"{ "+parts[2]+"; continue; }"+body.substr(continuation.get_end())
		code = code.substr(0,loop.get_start())+"{ %s; while (%s) { %s %s; } }"%[parts[0],parts[1],body,parts[2]]+code.substr(end)
	return code

static func _local_scopes(code: String) -> String:
	# Rename repeated block locals so later type inference never confuses, for
	# example, a vec4 inside a loop with a vec2 declared after that loop.
	var output := PackedStringArray()
	for unit: String in _units(code):
		if not unit.contains("{") or unit.begins_with("struct "): output.append(unit); continue
		var declarations := {}
		for variable: RegExMatch in _regex('\\b(?:float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*)(?![A-Za-z_0-9])').search_all(unit):
			if unit.substr(variable.get_end()).strip_edges().begins_with("("): continue
			declarations[variable.get_start(1)] = variable.get_string(1)
		var stack: Array[Dictionary] = [{}]
		var used := {}
		var chunks := PackedStringArray()
		var cursor := 0
		for token: RegExMatch in _regex('[{}]|\\b[A-Za-z_][A-Za-z_0-9]*\\b').search_all(unit):
			var value := token.get_string()
			if value == "{": stack.append({}); continue
			if value == "}":
				if stack.size() > 1: stack.pop_back()
				continue
			if declarations.has(token.get_start()):
				var replacement := "ra_scope_%d_%s"%[token.get_start(),value] if used.has(value) else value
				used[value] = true
				stack.back()[value] = replacement
			if token.get_start() > 0 and unit[token.get_start()-1] == ".": continue
			var replacement := value
			for index in range(stack.size()-1,-1,-1):
				if stack[index].has(value): replacement = stack[index][value]; break
			if replacement != value:
				chunks.append(unit.substr(cursor,token.get_start()-cursor)); chunks.append(replacement); cursor = token.get_end()
		chunks.append(unit.substr(cursor))
		output.append("".join(chunks))
	return "\n".join(output)

static func _control_blocks(code: String) -> String:
	var controls := _regex('\\b(if|else|for|while)\\b').search_all(code)
	controls.reverse()
	for control: RegExMatch in controls:
		var begin := control.get_end()
		while begin < code.length() and code[begin] in [" ","\t","\n","\r"]: begin += 1
		if control.get_string() != "else":
			if begin >= code.length() or code[begin] != "(": continue
			var parsed := _arguments(code,begin+1)
			if not parsed.ok: continue
			begin = parsed.end
			while begin < code.length() and code[begin] in [" ","\t","\n","\r"]: begin += 1
		if begin >= code.length() or code[begin] in ["{",";"]: continue
		var end := _statement_end(code,begin)
		if end > begin: code = code.substr(0,begin)+"{ "+code.substr(begin,end-begin)+" }"+code.substr(end)
	return code

static func _array_syntax(code: String) -> String:
	for constant: RegExMatch in _regex('\\bint\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*=\\s*([0-9]+)\\s*;').search_all(code):
		var name := constant.get_string(1)
		if _regex('\\b%s\\s*(?:[+*/-]?=(?!=)|\\+\\+|--)'%name).search_all(code).size() == 1:
			code = _regex('\\[\\s*%s\\s*\\]'%name).sub(code,"["+constant.get_string(2)+"]",true)
	var arrays := _regex('\\b(float|int|bool|[biu]?vec[234])\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\[([0-9]+)\\]\\s*\\[([0-9]+)\\]\\s*=\\s*\\{').search_all(code)
	arrays.reverse()
	for array: RegExMatch in arrays:
		var end := _statement_end(code,array.get_end()-1)
		if end <= array.get_end(): continue
		var values := code.substr(array.get_end(),end-array.get_end()-1).replace("{","").replace("}","")
		var name := array.get_string(2)
		code = code.substr(0,array.get_start())+"%s %s[%d] = %s[](%s)"%[array.get_string(1),name,int(array.get_string(3))*int(array.get_string(4)),array.get_string(1),values]+code.substr(end)
		code = _regex('\\b%s\\s*\\[([^]\\n]+)\\]\\s*\\[([^]\\n]+)\\]'%name).sub(code,name+"[($1) * "+array.get_string(4)+" + ($2)]",true)
	return code

static func _assignment_commas(code: String) -> String:
	if not code.contains(","): return code
	# Pure reads preceding a comma expression have no effect in GLSL.
	code = _regex('([;{}]\\s*)(?:[A-Za-z_][A-Za-z_0-9]*\\s*,\\s*)+(?=[A-Za-z_][A-Za-z_0-9]*\\s*=(?!=))').sub(code,"$1",true)
	var depth := 0
	var start := 0
	for index in code.length():
		var character := code.unicode_at(index)
		if character == 40 or character == 91: depth += 1 # ( or [
		elif character == 41 or character == 93: depth -= 1 # ) or ]
		elif depth == 0 and (character == 123 or character == 125 or character == 59): start = index+1 # { } ;
		elif depth == 0 and character == 44: # ,
			if _regex('^\\s*[A-Za-z_][A-Za-z_0-9]*(?:\\.[xyzwrgba]+)?\\s*=').search(code.substr(start,index-start)) and _regex('^\\s*[A-Za-z_][A-Za-z_0-9]*(?:\\.[xyzwrgba]+)?\\s*=').search(code.substr(index+1)):
				code[index] = ";"
				start = index+1
	return code

static func _assignment_values(code: String) -> String:
	# Godot's GLES generator drops parentheses around assignment expressions.
	# Lower standalone chains, including Cel's a.xy = -(a.zw = offset), in
	# evaluation order. Conditions and short-circuit expressions stay intact.
	var target := '[A-Za-z_][A-Za-z_0-9]*(?:\\.[A-Za-z_][A-Za-z_0-9]*)*'
	for iteration in 16:
		var changed := false
		var statements := _regex('(^|[;{}])\\s*((?:(?:float|int|bool|[biu]?vec[234]|mat[234])\\s+)?'+target+')\\s*=(?!=)\\s*([^;{}]+);').search_all(code)
		statements.reverse()
		for statement: RegExMatch in statements:
			var value := statement.get_string(3).strip_edges()
			var prefix := ""
			while not value.is_empty() and value[0] in ["-","+","!","~"]:
				prefix += value[0]
				value = value.substr(1).strip_edges()
			if value.begins_with("("):
				var parsed := _arguments(value,1)
				if not parsed.ok or parsed.end != value.length(): continue
				value = value.substr(1,value.length()-2).strip_edges()
			elif not prefix.is_empty(): continue
			var assignment := _regex('^('+target+')\\s*=(?!=)\\s*(.+)$').search(value)
			if assignment == null: continue
			var replacement := "%s %s = %s; %s = %s%s;"%[statement.get_string(1),assignment.get_string(1),assignment.get_string(2),statement.get_string(2),prefix,assignment.get_string(1)]
			code = code.substr(0,statement.get_start())+replacement+code.substr(statement.get_end())
			changed = true
		if not changed: break
	return code

static func _split_declarations(code: String) -> String:
	var declarations := _regex('\\b((?:(?:uniform|varying|attribute|const)\\s+)?(?:float|int|bool|[biu]?vec[234]|mat[234](?:x[234])?))\\s+([A-Za-z_][A-Za-z_0-9]*\\s*(?:\\[[^]]*\\]\\s*)?(?:=|,)[^;{}]*);').search_all(code)
	declarations.reverse()
	for declaration: RegExMatch in declarations:
		var parsed := _arguments(declaration.get_string(2)+")",0)
		if not parsed.ok or parsed.arguments.size() < 2: continue
		var statements := PackedStringArray()
		var valid := true
		for item: String in parsed.arguments:
			if not _regex('^[A-Za-z_][A-Za-z_0-9]*(?:\\s*\\[[^]]*\\])?(?:\\s*=.*)?$').search(item): valid = false; break
			statements.append(declaration.get_string(1)+" "+item+";")
		if valid: code = code.substr(0,declaration.get_start())+" ".join(statements)+code.substr(declaration.get_end())
	return code

static func _integer_expression(value: String, integers: Dictionary) -> bool:
	if integers.has(value): return true
	if value.contains(".") or _regex('[^A-Za-z_0-9\\s()+*/%&|<>-]').search(value): return false
	var tokens := _regex('\\b[A-Za-z_][A-Za-z_0-9]*\\b').search_all(value)
	if tokens.is_empty(): return true
	for token: RegExMatch in tokens:
		if not integers.has(token.get_string()) and token.get_string() not in ["int","min","max","abs"]: return false
	return true

static func _varying_outputs(code: String) -> String:
	var varying_types := {}
	for variable: RegExMatch in _regex('\\bvarying\\s+([A-Za-z_][A-Za-z_0-9]*)\\s+([A-Za-z_][A-Za-z_0-9]*)').search_all(code): varying_types[variable.get_string(2)] = variable.get_string(1)
	var functions := {}
	var units := _units(code)
	for unit: String in units:
		var signature := _regex('^[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search(unit)
		if signature == null: continue
		var parsed := _arguments(unit,signature.get_end())
		if not parsed.ok: continue
		var outputs := {}
		for index in parsed.arguments.size():
			if _regex('\\b(?:out|inout)\\b').search(parsed.arguments[index]): outputs[index] = true
		if not outputs.is_empty(): functions[signature.get_string(1)] = outputs
	var result := PackedStringArray()
	for unit: String in units:
		if not _regex('^void\\s+main\\s*\\(').search(unit): result.append(unit); continue
		var calls := _regex('\\b([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search_all(unit)
		calls.reverse()
		for invocation: RegExMatch in calls:
			if not functions.has(invocation.get_string(1)): continue
			var parsed := _arguments(unit,invocation.get_end())
			if not parsed.ok: continue
			var declarations := PackedStringArray()
			var assignments := PackedStringArray()
			for index: int in functions[invocation.get_string(1)]:
				if index >= parsed.arguments.size(): continue
				var name: String = parsed.arguments[index]
				if not varying_types.has(name): continue
				var temporary := "ra_out_%d_%d"%[invocation.get_start(),index]
				declarations.append("%s %s = %s;"%[varying_types[name],temporary,name])
				assignments.append("%s = %s;"%[name,temporary])
				parsed.arguments[index] = temporary
			if declarations.is_empty(): continue
			var begin := invocation.get_start()
			while begin > 0 and unit[begin-1] not in [";","{","}"]: begin -= 1
			var end := unit.find(";",parsed.end)+1
			if end < 1: continue
			var statement := unit.substr(begin,invocation.get_end()-begin)+", ".join(parsed.arguments)+")"+unit.substr(parsed.end,end-parsed.end)
			unit = unit.substr(0,begin)+" ".join(declarations)+statement+" ".join(assignments)+unit.substr(end)
		result.append(unit)
	return "\n".join(result)

# Godot requires declarations before their users. Scan dependency edges once;
# rescanning every helper body for every layer is costly for deep call chains.
# Functions sharing a name stay together because GLSL permits overloads.
static func _ordered_declarations(units: PackedStringArray, roots: PackedStringArray = []) -> PackedStringArray:
	var output := PackedStringArray()
	var functions := {}
	var structures := {}
	for unit: String in units:
		var structure := _regex('^struct\\s+([A-Za-z_][A-Za-z_0-9]*)').search(unit)
		if structure != null:
			structures[structure.get_string(1)] = unit
			continue
		var signature := _regex('^(?:[A-Za-z_][A-Za-z_0-9]*)\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\(').search(unit)
		if signature != null and unit.contains("{"):
			var name := signature.get_string(1)
			if not functions.has(name):
				functions[name] = []
			functions[name].append(unit)
		else:
			output.append(unit)

	var type_dependencies := {}
	for name: String in structures:
		type_dependencies[name] = _declaration_references(
			structures[name], structures, name, false)
	for name: String in _dependency_order(type_dependencies, false):
		output.append(structures[name])

	var function_dependencies := {}
	for name: String in functions:
		var dependencies := {}
		for unit: String in functions[name]:
			dependencies.merge(_declaration_references(unit, functions, name, true))
		function_dependencies[name] = dependencies

	if not roots.is_empty():
		var reachable := {}
		var pending: Array[String] = []
		for unit: String in Array(roots) + Array(output):
			for name: String in _declaration_references(unit, functions, "", true):
				if not reachable.has(name):
					reachable[name] = true
					pending.append(name)
		while not pending.is_empty():
			var caller: String = pending.pop_back()
			for name: String in function_dependencies[caller]:
				if reachable.has(name):
					continue
				reachable[name] = true
				pending.append(name)
		for name: String in function_dependencies.keys():
			if not reachable.has(name):
				function_dependencies.erase(name)

	for name: String in _dependency_order(function_dependencies, true):
		output.append_array(functions[name])
	return output


# Match full identifiers, and count each edge once even when a function calls
# the same helper repeatedly. Self references do not affect declaration order.
static func _declaration_references(code: String, declarations: Dictionary, own_name: String, calls_only: bool) -> Dictionary:
	var references := {}
	var pattern := '\\b([A-Za-z_][A-Za-z_0-9]*)\\s*\\(' if calls_only else '\\b([A-Za-z_][A-Za-z_0-9]*)\\b'
	for match: RegExMatch in _regex(pattern).search_all(code):
		var name := match.get_string(1)
		if name != own_name and declarations.has(name):
			references[name] = true
	return references


# Stable topological layers preserve generated-code order and cache digests.
# Unresolved function cycles remain for Godot's parser to diagnose; unresolved
# structures retain the previous behavior of being omitted.
static func _dependency_order(dependencies: Dictionary, keep_cycles: bool) -> Array[String]:
	var names := dependencies.keys()
	var remaining := {}
	var dependents := {}
	for name: String in names:
		dependents[name] = []
	var ready: Array[int] = []
	for index in names.size():
		var name: String = names[index]
		var required: Dictionary = dependencies[name]
		remaining[name] = required.size()
		if required.is_empty():
			ready.append(index)
		for dependency: String in required:
			dependents[dependency].append(index)

	var ordered: Array[String] = []
	while not ready.is_empty():
		var next: Array[int] = []
		for index: int in ready:
			var name: String = names[index]
			ordered.append(name)
			remaining.erase(name)
			for dependent_index: int in dependents[name]:
				var dependent: String = names[dependent_index]
				remaining[dependent] -= 1
				if remaining[dependent] == 0:
					next.append(dependent_index)
		# Multiple completed dependencies can discover the next layer in a
		# different order; original indices keep independent declarations stable.
		next.sort()
		ready = next
	if keep_cycles:
		for name: String in remaining:
			ordered.append(name)
	return ordered


static func _route_samples(code: String, textures: Array, native_buffers: bool = false, mipmap: bool = false, input_wrap: String = "") -> Dictionary:
	var samplers := {"ra_source":"source"}
	var mipmapped_luts := {}
	for descriptor: Dictionary in textures: samplers[descriptor.uniform] = "dynamic" if descriptor.get("dynamic",false) else descriptor.wrap_mode
	for descriptor: Dictionary in textures:
		if not descriptor.get("dynamic",false) and descriptor.get("mipmap",false): mipmapped_luts[descriptor.uniform] = true
	var aliases := {}
	for match: RegExMatch in _regex('(?m)^\\s*#define\\s+([A-Za-z_][A-Za-z_0-9]*)\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*$').search_all(code): aliases[match.get_string(1)] = match.get_string(2)
	var calls := _regex('\\b(texture|textureLod|textureGrad|textureProj|texelFetch|textureSize|textureOffset|textureLodOffset|texelFetchOffset|textureGather)\\s*\\(\\s*([A-Za-z_][A-Za-z_0-9]*)\\s*,').search_all(code)
	calls.reverse()
	for match: RegExMatch in calls:
		var function := match.get_string(1)
		var sampler := match.get_string(2)
		for _iteration in 12:
			if not aliases.has(sampler): break
			sampler = aliases[sampler]
		if not samplers.has(sampler): return {"ok":false, "message":"Unsupported sampler indirection '%s': samples must name the framebuffer or a declared external texture."%sampler}
		var replacement := function
		if mipmapped_luts.has(sampler):
			replacement = "ra_mip_"+sampler+"_"+function
		elif native_buffers and samplers[sampler] in ["source","dynamic"] and (function not in ["texture","textureOffset"] or mipmap):
			var prefix := "ra_mip_"+sampler
			if function not in ["texture","textureLod","textureSize","texelFetch","textureOffset","textureLodOffset","texelFetchOffset"]: return {"ok":false,"message":"Unsupported framebuffer sampling operation: %s"%function}
			replacement = prefix+"_"+function
		elif function in ["textureOffset","textureLodOffset","texelFetchOffset"]:
			replacement = "ra_offset_"+sampler+"_"+function
		elif samplers[sampler] == "source":
			if function != "texture": return {"ok":false, "message":"Explicit framebuffer texture LOD, offsets and raw dimensions are not supported."}
			replacement = "ra_sample_source"
		elif samplers[sampler] in ["clamp_to_border", "mirrored_repeat", "dynamic"]:
			if function != "texture": return {"ok":false, "message":"Explicit external texture LOD and offsets require repeat or clamp_to_edge wrapping."}
			replacement = "ra_sample_"+sampler
		code = code.substr(0, match.get_start(1))+replacement+code.substr(match.get_end(1))
	return {"ok":true, "code":code}

static func _mip_header(sampler: String, dimensions: String, linear: bool, border: bool, srgb: bool, repeat: bool = false, hardware: bool = false, mirrored: bool = false) -> String:
	var prefix := "ra_mip_"+sampler
	var code := "uniform sampler2D %s_mips : filter_nearest, repeat_disable;\nuniform bool %s_hardware_mips = %s;\n"%[sampler,sampler,"true" if hardware else "false"]
	code += "ivec2 %s_textureSize(sampler2D source, int level) { return max(ivec2(%s) / int(exp2(float(level))),ivec2(1)); }\n"%[prefix,dimensions]
	code += "vec4 %s_texelFetch(sampler2D source, ivec2 coord, int level) { ivec2 dims = %s_textureSize(source,level); " %[prefix,prefix]
	if mirrored: code += "ivec2 period = dims * 2; coord = ((coord % period) + period) % period; coord = min(coord,period - ivec2(1) - coord); "
	elif repeat: code += "coord = ((coord % dims) + dims) % dims; "
	elif border: code += "if (coord.x < 0 || coord.y < 0 || coord.x >= dims.x || coord.y >= dims.y) return vec4(0.0); "
	else: code += "coord = clamp(coord,ivec2(0),dims-ivec2(1)); "
	code += "vec4 pixel; if (%s_hardware_mips) { pixel = texelFetch(source,coord,level); } else { int offset = 0; for (int i = 0; i < level; i++) { offset += %s_textureSize(source,i).y; } pixel = texelFetch(%s_mips,coord+ivec2(0,offset),0); } "%[sampler,prefix,sampler]
	if srgb: code += "pixel.rgb = ra_srgb_decode(pixel.rgb); "
	code += "return pixel; }\n"
	# Offsets are integer texels at each selected mip level, including both
	# levels of a trilinear lookup; shifting by the base dimensions is incorrect.
	code += "vec4 %s_level(sampler2D source, vec2 coord, int level, ivec2 offset) { vec2 pixel = coord*vec2(%s_textureSize(source,level))-vec2(0.5)+vec2(offset); ivec2 base = ivec2(floor(pixel)); " %[prefix,prefix]
	if linear: code += "vec2 weight = fract(pixel); return mix(mix(%s_texelFetch(source,base,level),%s_texelFetch(source,base+ivec2(1,0),level),weight.x),mix(%s_texelFetch(source,base+ivec2(0,1),level),%s_texelFetch(source,base+ivec2(1,1),level),weight.x),weight.y); }\n"%[prefix,prefix,prefix,prefix]
	else: code += "return %s_texelFetch(source,ivec2(floor(pixel+vec2(0.5))),level); }\n"%prefix
	code += "vec4 %s_textureLodOffset(sampler2D source, vec2 coord, float lod, ivec2 offset) { float maximum = floor(log2(max(%s.x,%s.y))); lod = clamp(lod,0.0,maximum); " %[prefix,dimensions,dimensions]
	if linear: code += "int level = int(floor(lod)); return mix(%s_level(source,coord,level,offset),%s_level(source,coord,min(level+1,int(maximum)),offset),fract(lod)); }\n"%[prefix,prefix]
	else: code += "return %s_level(source,coord,int(floor(lod+0.5)),offset); }\n"%prefix
	code += "vec4 %s_textureLod(sampler2D source, vec2 coord, float lod) { return %s_textureLodOffset(source,coord,lod,ivec2(0)); }\n"%[prefix,prefix]
	code += "vec4 %s_textureOffset(sampler2D source, vec2 coord, ivec2 offset, float bias) { vec2 dx = dFdx(coord)*%s; vec2 dy = dFdy(coord)*%s; return %s_textureLodOffset(source,coord,0.5*log2(max(max(dot(dx,dx),dot(dy,dy)),0.000001))+bias,offset); }\n"%[prefix,dimensions,dimensions,prefix]
	code += "vec4 %s_textureOffset(sampler2D source, vec2 coord, ivec2 offset) { return %s_textureOffset(source,coord,offset,0.0); }\n"%[prefix,prefix]
	code += "vec4 %s_texelFetchOffset(sampler2D source, ivec2 coord, int level, ivec2 offset) { return %s_texelFetch(source,coord+offset,level); }\n"%[prefix,prefix]
	code += "vec4 %s_texture(sampler2D source, vec2 coord, float bias) { return %s_textureOffset(source,coord,ivec2(0),bias); }\n"%[prefix,prefix]
	code += "vec4 %s_texture(sampler2D source, vec2 coord) { return %s_texture(source,coord,0.0); }\n"%[prefix,prefix]
	return code

static func _offset_header(sampler: String, dimensions: String, sample_function: String) -> String:
	var prefix := "ra_offset_"+sampler
	var code := "vec4 %s_textureOffset(sampler2D source, vec2 coord, ivec2 offset, float bias) { return %s(source,coord+vec2(offset)/vec2(%s),bias); }\n"%[prefix,sample_function,dimensions]
	code += "vec4 %s_textureOffset(sampler2D source, vec2 coord, ivec2 offset) { return %s_textureOffset(source,coord,offset,0.0); }\n"%[prefix,prefix]
	code += "vec4 %s_textureLodOffset(sampler2D source, vec2 coord, float lod, ivec2 offset) { return %s_textureOffset(source,coord,offset); }\n"%[prefix,prefix]
	code += "vec4 %s_texelFetchOffset(sampler2D source, ivec2 coord, int level, ivec2 offset) { return %s(source,(vec2(coord+offset)+vec2(0.5))/vec2(%s)); }\n"%[prefix,sample_function,dimensions]
	return code

static func _texture_header(descriptor: Dictionary) -> String:
	var sampler: String = descriptor.uniform
	if descriptor.get("dynamic",false):
		return "uniform sampler2D %s : filter_nearest, repeat_disable;\nuniform vec2 %s_size;\nuniform vec4 %s_uv_rect = vec4(0.0, 0.0, 1.0, 1.0);\n"%[sampler,sampler,sampler]+_frame_sampler(sampler,descriptor.filter_linear,descriptor.wrap_mode == "clamp_to_border",sampler+"_size",sampler+"_uv_rect","ra_sample_"+sampler,bool(descriptor.get("srgb",false)),descriptor.wrap_mode)+_offset_header(sampler,sampler+"_size","ra_sample_"+sampler)
	var filter := "linear" if descriptor.filter_linear else "nearest"
	if descriptor.mipmap: filter += "_mipmap"
	var repeat := "enable" if descriptor.wrap_mode == "repeat" else "disable"
	var header := "uniform sampler2D %s : filter_%s, repeat_%s;\n"%[sampler, filter, repeat]
	var function := "ra_sample_"+sampler
	if descriptor.wrap_mode == "mirrored_repeat":
		header += "vec4 %s(sampler2D source, vec2 coord) { return texture(source, vec2(1.0) - abs(mod(coord, vec2(2.0)) - vec2(1.0))); }\n"%function
	elif descriptor.wrap_mode == "clamp_to_border":
		var texel := "ra_texel_"+sampler
		header += "vec4 %s(sampler2D source, ivec2 coord, ivec2 dimensions) { if (coord.x < 0 || coord.y < 0 || coord.x >= dimensions.x || coord.y >= dimensions.y) return vec4(0.0); return texelFetch(source, coord, 0); }\n"%texel
		if descriptor.filter_linear:
			header += "vec4 %s(sampler2D source, vec2 coord) { ivec2 dimensions = textureSize(source, 0); vec2 pixel = coord * vec2(dimensions) - vec2(0.5); ivec2 base = ivec2(floor(pixel)); vec2 weight = fract(pixel); return mix(mix(%s(source, base, dimensions), %s(source, base + ivec2(1, 0), dimensions), weight.x), mix(%s(source, base + ivec2(0, 1), dimensions), %s(source, base + ivec2(1, 1), dimensions), weight.x), weight.y); }\n"%[function, texel, texel, texel, texel]
		else:
			header += "vec4 %s(sampler2D source, vec2 coord) { ivec2 dimensions = textureSize(source, 0); return %s(source, ivec2(floor(coord * vec2(dimensions))), dimensions); }\n"%[function, texel]
	if descriptor.wrap_mode in ["clamp_to_border", "mirrored_repeat"]:
		header += "vec4 %s(sampler2D source, vec2 coord, float _bias) { return %s(source, coord); }\n"%[function, function]
	if descriptor.mipmap:
		header += _mip_header(sampler,"vec2(textureSize("+sampler+",0))",descriptor.filter_linear,descriptor.wrap_mode == "clamp_to_border",false,descriptor.wrap_mode == "repeat",true,descriptor.wrap_mode == "mirrored_repeat")
	else:
		header += _offset_header(sampler,"textureSize("+sampler+",0)",function if descriptor.wrap_mode in ["clamp_to_border", "mirrored_repeat"] else "texture")
	return header

static func _frame_sampler(sampler: String, linear: bool, border: bool, dimensions_uniform: String, uv_uniform: String, sample_function: String, srgb: bool = false, wrap: String = "") -> String:
	var texel := "ra_texel_"+sampler
	var code := "vec4 %s(sampler2D source, ivec2 coord) { ivec2 dimensions = max(ivec2(%s), ivec2(1)); "%[texel,dimensions_uniform]
	if wrap == "mirrored_repeat": code += "ivec2 period = dimensions * 2; coord = ((coord % period) + period) % period; coord = min(coord,period - ivec2(1) - coord); "
	elif wrap == "repeat": code += "coord = ((coord % dimensions) + dimensions) % dimensions; "
	elif border: code += "if (coord.x < 0 || coord.y < 0 || coord.x >= dimensions.x || coord.y >= dimensions.y) return vec4(0.0); "
	else: code += "coord = clamp(coord, ivec2(0), dimensions - ivec2(1)); "
	code += "vec2 center = (vec2(coord) + vec2(0.5)) / vec2(dimensions); vec4 pixel = textureLod(source, %s.xy + center * %s.zw, 0.0); "%[uv_uniform,uv_uniform]
	if srgb: code += "pixel.rgb = ra_srgb_decode(pixel.rgb); "
	code += "return pixel; }\n"
	if linear:
		code += "vec4 %s(sampler2D source, vec2 coord) { vec2 dimensions = vec2(max(ivec2(%s), ivec2(1))); vec2 pixel = coord * dimensions - vec2(0.5); ivec2 base = ivec2(floor(pixel)); vec2 weight = fract(pixel); return mix(mix(%s(source, base), %s(source, base + ivec2(1, 0)), weight.x), mix(%s(source, base + ivec2(0, 1)), %s(source, base + ivec2(1, 1)), weight.x), weight.y); }\n"%[sample_function,dimensions_uniform,texel,texel,texel,texel]
	else: code += "vec4 %s(sampler2D source, vec2 coord) { return %s(source, ivec2(floor(coord * vec2(max(ivec2(%s), ivec2(1)))))); }\n"%[sample_function,texel,dimensions_uniform]
	code += "vec4 %s(sampler2D source, vec2 coord, float _bias) { return %s(source, coord); }\n"%[sample_function,sample_function]
	return code

static func _srgb_header() -> String:
	# Match sRGB8 storage and sampling while retaining the compatibility renderer's
	# RGBA8 targets. Decode each texel before interpolation; alpha stays linear.
	return """float ra_srgb_encode_channel(float value) { value = clamp(value, 0.0, 1.0); return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1.0 / 2.4) - 0.055; }
float ra_srgb_decode_channel(float value) { return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4); }
vec3 ra_srgb_encode(vec3 value) { return vec3(ra_srgb_encode_channel(value.r), ra_srgb_encode_channel(value.g), ra_srgb_encode_channel(value.b)); }
vec3 ra_srgb_decode(vec3 value) { return vec3(ra_srgb_decode_channel(value.r), ra_srgb_decode_channel(value.g), ra_srgb_decode_channel(value.b)); }
"""

static func _compat_aliases(code: String, stage: String) -> String:
	# Older collections spell the standard qualifiers/texture function through
	# IN, OUT, PRECISION and tex2D aliases rather than COMPAT_* macros.
	var macros := _regex('(?m)^\\s*#define\\s+([A-Za-z_][A-Za-z_0-9]*)[ \\t]+(in|out|varying|attribute|texture2D|texture|lowp|mediump|highp)[ \\t]*$').search_all(code)
	for definition: RegExMatch in macros:
		var replacement := definition.get_string(2)
		if replacement == "in": replacement = "attribute" if stage == "vertex" else "varying"
		elif replacement == "out": replacement = "varying" if stage == "vertex" else "out"
		elif replacement == "texture2D": replacement = "texture"
		elif replacement in ["lowp", "mediump", "highp"]: replacement = ""
		code = code.replace(definition.get_string(),"")
		code = _regex('\\b%s\\b'%definition.get_string(1)).sub(code,replacement,true)
	# Empty qualifier macros have been normalized to 1 by the preprocessor.
	var empty_precision := _regex('(?m)^\\s*#define\\s+PRECISION[ \\t]+1[ \\t]*$')
	if empty_precision.search(code):
		code = empty_precision.sub(code,"",true)
		code = _regex('\\bPRECISION\\b').sub(code,"",true)
	return code

# This is the pure translation boundary: source and declaration/binding metadata
# enter; generated code and geometry metadata leave. It creates no GPU resources.
static func _translate(source: String, parameters: Array, filter_linear: bool, border: bool, textures: Array, alias: String, screen_sampler: bool = true, dynamic_textures: Array = [], input_srgb: bool = false, output_srgb: bool = false, native_buffers: bool = false, mipmap: bool = false, input_wrap: String = "") -> Dictionary:
	return _translate_impl(source,parameters,filter_linear,border,textures,alias,screen_sampler,dynamic_textures,input_srgb,output_srgb,native_buffers,mipmap,input_wrap)

static func _translate_with_context(source: String, parameters: Array, filter_linear: bool, border: bool, textures: Array, alias: String, screen_sampler: bool = true, dynamic_textures: Array = [], input_srgb: bool = false, output_srgb: bool = false, native_buffers: bool = false, mipmap: bool = false, input_wrap: String = "", context: ImportSession = null, pass_index: int = -1) -> Dictionary:
	var cache_enabled := context == null or context.cache_enabled
	var key := ""
	if cache_enabled:
		if context != null: context.enter_phase("cache_lookup_us")
		# Selected values are excluded: they are uploaded into fresh materials.
		# All prepared source/declaration/binding inputs participate, including
		# texture sizes/paths and complete metadata rather than filenames alone.
		# Variant encoding preserves integer/float types, full float precision
		# and vector dimensions. Different dictionary order may miss safely.
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(var_to_bytes([source,parameters,filter_linear,border,textures,alias,screen_sampler,dynamic_textures,input_srgb,output_srgb,native_buffers,mipmap,input_wrap]))
		key = hash.finish().hex_encode()
		var cached: Dictionary = _translation_cache.get_translation(key)
		if context != null: context.leave_phase()
		if not cached.is_empty():
			if context != null:
				context.note_cache("hits")
				context.note_cached_pass(pass_index)
			cached["_cache_key"] = key
			return cached
		if context != null: context.note_cache("misses")
	elif context != null:
		context.note_cache("bypasses")
	if context != null: context.begin_translation(pass_index)
	var translated := _translate_impl(source,parameters,filter_linear,border,textures,alias,screen_sampler,dynamic_textures,input_srgb,output_srgb,native_buffers,mipmap,input_wrap,context)
	if context != null: context.end_translation()
	if cache_enabled and translated.ok:
		if context != null: context.enter_phase("cache_lookup_us")
		var stored: bool = _translation_cache.store_translation(key,translated)
		if context != null:
			context.leave_phase()
			context.note_cache("stores" if stored else "oversized_skips")
		translated["_cache_key"] = key
	return translated

static func _discard_translation(translated: Dictionary, context: ImportSession) -> void:
	if not translated.has("_cache_key"): return
	if context != null: context.enter_phase("cache_lookup_us")
	_translation_cache.remove_translation(str(translated._cache_key))
	if context != null: context.leave_phase()

static func _translate_impl(source: String, parameters: Array, filter_linear: bool, border: bool, textures: Array, alias: String, screen_sampler: bool = true, dynamic_textures: Array = [], input_srgb: bool = false, output_srgb: bool = false, native_buffers: bool = false, mipmap: bool = false, input_wrap: String = "", context: ImportSession = null) -> Dictionary:
	# Translation is ordered: select stages and expand macros, resolve stage
	# interfaces/bindings, lower GLSL syntax/state, then emit dependency-sorted
	# Godot declarations. Later rewrites rely on earlier normalized forms.
	textures = textures.duplicate()
	textures.append_array(dynamic_textures)
	var size_mapping := {}
	for descriptor: Dictionary in dynamic_textures:
		var prefix := str(descriptor.get("size_prefix",str(descriptor.name).trim_suffix("Texture")))
		for suffix: String in ["InputSize", "TextureSize"]: size_mapping[prefix+suffix] = descriptor.uniform+"_size"
	var clean := _without_comments(source).replace("\\\r\n", "").replace("\\\n", "")
	var vertex := _preprocess(clean, "VERTEX")
	if not vertex.ok: return vertex
	var fragment := _preprocess(clean, "FRAGMENT")
	if not fragment.ok: return fragment
	if not _regex('\\bvoid\\s+main\\s*\\(').search(fragment.code): return {"ok":false, "message":"The shader has no fragment main() entry point."}
	# A stage-less fragment shader must not be duplicated as a vertex program.
	if not _regex('\\b(VERTEX|FRAGMENT)\\b').search(clean): vertex.code = ""
	var custom_geometry := false
	for assignment: RegExMatch in _regex('\\bgl_Position\\s*=\\s*([^;]+);').search_all(vertex.code):
		if _regex('\\s+').sub(assignment.get_string(1),"",true) != "MVPMatrix*VertexCoord": custom_geometry = true
	for stage in ["vertex", "fragment"]:
		var stage_code: String = vertex.code if stage == "vertex" else fragment.code
		stage_code = stage_code.replace("COMPAT_PRECISION", "").replace("COMPAT_ATTRIBUTE", "attribute").replace("COMPAT_VARYING", "varying").replace("COMPAT_TEXTURE", "texture")
		stage_code = _compat_aliases(stage_code,stage)
		stage_code = _expand_macros(stage_code)
		if stage == "fragment" and _regex('\\b[A-Za-z_][A-Za-z_0-9]*\\s+light\\s*\\([^;{}]*\\)\\s*\\{').search(stage_code):
			stage_code = _regex('\\blight\\b').sub(stage_code,"ra_glsl_light",true)
		stage_code = _regex('\\b(?:lowp|mediump|highp)\\s+').sub(stage_code,"",true)
		stage_code = _split_declarations(stage_code)
		if stage == "vertex":
			for structure: RegExMatch in _regex('\\bstruct\\s+([A-Za-z_][A-Za-z_0-9]*)').search_all(stage_code):
				stage_code = _regex('\\b%s\\b'%structure.get_string(1)).sub(stage_code,"ra_vertex_"+structure.get_string(1),true)
			for function: RegExMatch in _regex('(?m)^\\s*[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*\\([^;{}]*\\)\\s*\\{').search_all(stage_code):
				var name := function.get_string(1)
				if name not in ["main","if","for","while","switch"]: stage_code = _regex('\\b%s\\b'%name).sub(stage_code,"ra_vertex_"+name,true)
		if stage == "vertex": vertex.code = stage_code
		else: fragment.code = stage_code
	if context != null: context.translation_phase("bindings_us")
	# GLSL has separate stage scopes. Godot merges them, so vertex-only outputs
	# must not collide with fragment locals (Hyllian uses 'color' in both).
	var varying_names := _regex('\\bvarying\\s+(?:(?:lowp|mediump|highp)\\s+)?[A-Za-z_][A-Za-z_0-9]*\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*;')
	var fragment_varyings := {}
	for match: RegExMatch in varying_names.search_all(fragment.code): fragment_varyings[match.get_string(1)] = true
	for match: RegExMatch in varying_names.search_all(vertex.code):
		var name := match.get_string(1)
		var fragment_local := _regex('\\b(?:float|int|bool|[biu]?vec[234]|mat[234])\\s+%s\\b'%name).search(fragment.code)
		if not fragment_varyings.has(name) and fragment_local != null:
			var renamed := PackedStringArray()
			for unit: String in _units(vertex.code):
				# Macro arguments have their own scope; shared macros must stay equal.
				renamed.append(unit if unit.begins_with("#") else _regex('\\b%s\\b'%name).sub(unit,"ra_vertex_"+name,true))
			vertex.code = "\n".join(renamed)
	var declarations := {}
	var declared_textures := {}
	var shared := PackedStringArray()
	var stages := PackedStringArray()
	for stage in ["vertex", "fragment"]:
		if context != null: context.translation_phase("bindings_us")
		var code: String = vertex.code if stage == "vertex" else fragment.code
		var texcoord_type := "vec4"
		for match: RegExMatch in _regex('\\battribute\\s+(vec[24])\\s+TexCoord\\s*;').search_all(code): texcoord_type = match.get_string(1)
		var color_attribute := _regex('\\battribute\\s+(?:(?:lowp|mediump|highp)\\s+)?vec4\\s+Color\\s*;').search(code) != null
		code = _regex('\\battribute\\s+[^;]+;').sub(code, "", true)
		code = _regex('\\bprecision\\s+[^;]+;').sub(code, "", true)
		code = _regex('\\bout\\s+(?:(?:lowp|mediump|highp)\\s+)?vec4\\s+FragColor\\s*;').sub(code, "", true)
		# RetroArch's unit quad is projected by an orthographic MVP. Preserve
		# custom flips/scaling in local canvas pixels, including varying reads.
		if stage == "vertex" and not code.is_empty():
			code = _regex('\\bgl_Position\\b').sub(code,"ra_clip_position",true)
			code = _regex('\\bVertexCoord\\b').sub(code,"ra_vertex_coord",true)
			code = "vec4 ra_clip_position; vec4 ra_vertex_coord;\n"+code
			code = _regex('\\bvoid\\s+main\\s*\\(\\s*\\)\\s*\\{').sub(code,"void main() { ra_vertex_coord = vec4(UV, 0.0, 1.0); ra_clip_position = vec4(UV * 2.0 - 1.0, 0.0, 1.0);")
		for match: RegExMatch in _regex('\\buniform\\s+(?:(?:lowp|mediump|highp)\\s+)?([A-Za-z_][A-Za-z_0-9]*)\\s+([^;]+);').search_all(code):
			var type := match.get_string(1)
			for raw_name: String in match.get_string(2).split(","):
				var name := raw_name.strip_edges()
				if not name.is_valid_identifier(): return {"ok":false, "message":"Uniform arrays and initialized GLSL uniforms are not supported."}
				if type.begins_with("sampler"):
					if type != "sampler2D": return {"ok":false, "message":"Only sampler2D external textures are supported: %s."%name}
					if not alias.is_empty() and name in [alias, alias+"Texture"]: return {"ok":false, "message":"The shader references its pass alias '%s'; pass dependencies are not supported."%alias}
					if name not in ["Texture", "s_p", "decal"]:
						var external := false
						for descriptor: Dictionary in textures:
							if descriptor.name == name:
								external = true
								declared_textures[name] = true
						if not external and _regex('\\b%s\\b'%name).search_all(code).size() > 1: return {"ok":false, "message":"The shader needs an additional texture '%s'; load its preset or declare the lookup image there."%name}
						continue
				if name not in STANDARD_UNIFORMS and not size_mapping.has(name):
					var parameter := false
					for descriptor: Dictionary in parameters:
						if descriptor.name == name and type == "float": parameter = true
					if not parameter and _regex('\\b%s\\b'%name).search_all(code).size() > 1: return {"ok":false, "message":"Unsupported shader uniform '%s'."%name}
		code = _regex('\\buniform\\s+[^;]+;').sub(code, "", true)
		# GLSL allows a helper's local variable to shadow the fragment output.
		# Renaming before mapping avoids Godot treating its reads as COLOR.
		var scoped_units := PackedStringArray()
		for unit: String in _units(code):
			if unit.contains("{"):
				for local_name in ["FragColor", "gl_FragColor", "TexCoord"]:
					if _regex('\\b(?:vec[234]|float)\\s+%s\\b'%local_name).search(unit): unit = _regex('\\b%s\\b'%local_name).sub(unit,"ra_local_"+local_name,true)
			scoped_units.append(unit)
		code = "\n".join(scoped_units)
		for unit: String in _units(code):
			var flag := _regex('^bool\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*=\\s*(?:true|false)\\s*;$').search(unit)
			if flag == null: continue
			var name := flag.get_string(1)
			var assignments := _regex('\\b%s\\s*=(?!=)\\s*(true|false)\\b'%name)
			# A few shipped blur passes assign flags in conditions. Preserve
			# assignment-expression values when the variable is never read.
			if assignments.search_all(code).size() == _regex('\\b%s\\b'%name).search_all(code).size():
				code = assignments.sub(code.replace(unit,""),"$1",true)
		# Dependency sorting supplies definitions before callers, so GLSL
		# forward prototypes can be removed for Godot's parser.
		code = _regex('(?m)^\\s*(?!return\\b|else\\b)[A-Za-z_][A-Za-z_0-9]*\\s+[A-Za-z_][A-Za-z_0-9]*\\s*\\([^{};]*\\)\\s*;').sub(code,"",true)
		var mapping := {"Texture":"ra_source", "TextureSize":"ra_input_size", "InputSize":"ra_input_size", "OutputSize":"ra_output_size", "FrameCount":"ra_frame_count", "FrameDirection":"1", "texture2D":"texture", "gl_FragColor":"COLOR", "FragColor":"COLOR", "gl_FragCoord":"vec4(FRAGCOORD.x - ra_output_origin.x, ra_output_size.y - (FRAGCOORD.y - ra_output_origin.y), FRAGCOORD.zw)", "TexCoord":"vec2(UV)" if texcoord_type == "vec2" else "vec4(UV, 0.0, 1.0)", "E":"ra_legacy_E", "TAU":"ra_legacy_TAU", "PI":"ra_legacy_PI"}
		mapping["s_p"] = "ra_source"
		mapping["decal"] = "ra_source"
		mapping["MVPMatrix"] = "mat4(vec4(2.0, 0.0, 0.0, 0.0), vec4(0.0, 2.0, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(-1.0, -1.0, 0.0, 1.0))"
		if not _regex('\\b(?:float|vec[234])\\s+PI\\b').search(code): mapping.erase("PI")
		if stage == "vertex" and color_attribute: mapping["Color"] = "COLOR"
		for history in 7:
			mapping["Prev%sTexCoord"%("" if history == 0 else str(history))] = "UV"
		mapping["LUTTexCoord"] = "vec4(UV, 0.0, 1.0)"
		mapping.merge(size_mapping)
		for descriptor: Dictionary in textures: mapping[descriptor.name] = descriptor.uniform
		for name: String in mapping: code = _regex('\\b%s\\b'%name).sub(code, mapping[name], true)
		var specialized := _specialize_samplers(code,textures)
		if not specialized.ok: return specialized
		code = specialized.code
		if context != null: context.translation_phase("lowering_us")
		# Normalize expressions before lifting per-invocation globals. Assignment
		# rewrites can split a statement; normalize control bodies again afterward.
		code = _matrices(code)
		code = _array_syntax(code)
		code = _control_blocks(code)
		code = _external_loops(code)
		code = _local_scopes(code)
		code = _strict_types(code,parameters)
		code = _assignment_commas(code)
		code = _assignment_values(code)
		code = _coerce_glsl(code,parameters)
		code = _control_blocks(code)
		code = _stage_state(code,stage)
		code = _runtime_globals(code,parameters)
		var routed := _route_samples(code, textures,native_buffers,mipmap)
		if not routed.ok: return routed
		code = routed.code
		if _regex('\\bMVPMatrix\\b').search(code): return {"ok":false, "message":"Custom matrix calculations are not supported."}
		if context != null: context.translation_phase("emission_us")
		for unit: String in _units(code):
			if _regex('^void\\s+main\\s*\\(').search(unit):
				unit = _regex('\\bconst\\s+').sub(unit,"",true)
				if stage == "fragment" and unit.contains("return;"):
					unit = _regex('^void\\s+main\\s*\\(\\s*\\)').sub(unit,"void ra_fragment_body(vec2 ra_uv, vec4 ra_fragcoord, inout vec4 ra_color)")
					for name: String in {"UV":"ra_uv","FRAGCOORD":"ra_fragcoord","COLOR":"ra_color"}: unit = _regex('\\b%s\\b'%name).sub(unit,{"UV":"ra_uv","FRAGCOORD":"ra_fragcoord","COLOR":"ra_color"}[name],true)
					shared.append(unit)
					stages.append("void fragment() { ra_fragment_body(UV, FRAGCOORD, COLOR); "+("COLOR.rgb = ra_srgb_encode(COLOR.rgb);" if output_srgb else "")+" }")
				else:
					if stage == "fragment" and output_srgb: unit = unit.left(unit.length()-1)+"\nCOLOR.rgb = ra_srgb_encode(COLOR.rgb);\n}"
					stages.append(_regex('^void\\s+main').sub(unit, "void "+stage))
			else:
				if unit.contains("{"): unit = _regex('\\bconst\\s+').sub(unit,"",true)
				if _regex('(?s)^(?:float|int|[biu]?vec[234])\\s+[A-Za-z_][A-Za-z_0-9]*\\[[0-9]+\\]\\s*=').search(unit): unit = "const "+unit
				var initialized := _regex('(?s)^(?:float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*=.+;$').search(unit)
				if initialized != null:
					if _regex('\\b%s\\s*(?:[+*/-]?=(?!=)|\\+\\+|--)'%initialized.get_string(1)).search_all(code).size() > 1: return {"ok":false, "message":"Mutable GLSL global variables are not supported: %s"%initialized.get_string(1)}
					unit = "const "+unit
				var global := _regex('^(?:float|int|bool|[biu]?vec[234]|mat[234])\\s+([A-Za-z_][A-Za-z_0-9]*)\\s*;$').search(unit)
				if global != null:
					if _regex('\\b%s\\b'%global.get_string(1)).search_all(code).size() == 1: continue
					var write_only := _regex('\\b%s\\s*=\\s*[^;]+;'%global.get_string(1))
					if _regex('\\b%s\\b'%global.get_string(1)).search_all(write_only.sub(code,"",true)).size() == 1:
						for index in stages.size(): stages[index] = write_only.sub(stages[index],"",true)
						continue
					return {"ok":false, "message":"Mutable GLSL global variables are not supported: %s"%global.get_string(1)}
				var key := unit
				var macro := _regex('^#(?:define|undef)\\s+([A-Za-z_][A-Za-z_0-9]*)').search(unit)
				if macro != null: key = "macro:"+macro.get_string(1)
				var varying := _regex('^varying\\s+(.+);$').search(unit)
				if varying != null:
					var value := _regex('\\s+').sub(varying.get_string(1).strip_edges()," ",true)
					key = "varying:"+value
					unit = "varying "+value+";"
				if declarations.has(key):
					if declarations[key] != unit: return {"ok":false, "message":"Conflicting vertex/fragment declarations: %s"%key.left(150)}
				else:
					declarations[key] = unit
					shared.append(unit)
	if context != null: context.translation_phase("emission_us")
	var comments := PackedStringArray()
	for descriptor: Dictionary in textures:
		if screen_sampler and not declared_textures.has(descriptor.name): return {"ok":false, "message":"Preset external texture '%s' is not declared by the active shader."%descriptor.name}
	var has_vertex := false
	for stage_code: String in stages:
		if stage_code.begins_with("void vertex"): has_vertex = true
	if not has_vertex:
		var assignments := PackedStringArray()
		for declaration: String in shared:
			var varying := _regex('^varying\\s+(vec[24])\\s+(TEX0|COL0)\\s*;').search(declaration)
			if varying != null:
				var value := "UV" if varying.get_string(1) == "vec2" else "vec4(UV, 0.0, 1.0)"
				if varying.get_string(2) == "COL0": value = "COLOR" if varying.get_string(1) == "vec4" else "COLOR.xy"
				assignments.append(varying.get_string(2)+" = "+value+";")
		if not assignments.is_empty(): stages.append("void vertex() { "+" ".join(assignments)+" }")
	for match: RegExMatch in _regex('(?s)/\\*.*?\\*/|//[^\\r\\n]*').search_all(source): comments.append(match.get_string())
	var header := "shader_type canvas_item;\nrender_mode unshaded, blend_disabled;\n"
	var uses_srgb := input_srgb or output_srgb
	for descriptor: Dictionary in dynamic_textures: uses_srgb = uses_srgb or bool(descriptor.get("srgb",false))
	if uses_srgb: header += _srgb_header()
	# The final framebuffer is already enlarged. Hardware linear filtering would
	# blend its duplicated physical pixels, not the original logical texel grid.
	header += "uniform sampler2D ra_source : %srepeat_disable, filter_nearest;\n"%("hint_screen_texture, " if screen_sampler else "")
	header += "uniform vec2 ra_input_size = vec2(640.0, 480.0);\nuniform vec2 ra_output_size = vec2(640.0, 480.0);\nuniform int ra_frame_count = 0;\nuniform int ra_import_valid = 1;\n"
	header += "uniform vec4 ra_source_uv_rect = vec4(0.0, 0.0, 1.0, 1.0);\n"
	header += "uniform vec2 ra_output_origin = vec2(0.0);\n"
	header += "vec4 ra_logical_texel(sampler2D source, ivec2 coord) { ivec2 dimensions = max(ivec2(ra_input_size), ivec2(1)); "
	if input_wrap == "mirrored_repeat": header += "ivec2 period = dimensions * 2; coord = ((coord % period) + period) % period; coord = min(coord,period - ivec2(1) - coord); "
	elif input_wrap == "repeat": header += "coord = ((coord % dimensions) + dimensions) % dimensions; "
	elif border: header += "if (coord.x < 0 || coord.y < 0 || coord.x >= dimensions.x || coord.y >= dimensions.y) return vec4(0.0); "
	else: header += "coord = clamp(coord, ivec2(0), dimensions - ivec2(1)); "
	header += "vec2 logical_center_uv = (vec2(coord) + vec2(0.5)) / vec2(dimensions); vec4 pixel = textureLod(source, ra_source_uv_rect.xy + logical_center_uv * ra_source_uv_rect.zw, 0.0); "
	if input_srgb: header += "pixel.rgb = ra_srgb_decode(pixel.rgb); "
	header += "return pixel; }\n"
	if filter_linear:
		header += "vec4 ra_sample_source(sampler2D source, vec2 coord) { vec2 dimensions = vec2(max(ivec2(ra_input_size), ivec2(1))); vec2 pixel = coord * dimensions - vec2(0.5); ivec2 base = ivec2(floor(pixel)); vec2 weight = fract(pixel); return mix(mix(ra_logical_texel(source, base), ra_logical_texel(source, base + ivec2(1, 0)), weight.x), mix(ra_logical_texel(source, base + ivec2(0, 1)), ra_logical_texel(source, base + ivec2(1, 1)), weight.x), weight.y); }\n"
	else:
		header += "vec4 ra_sample_source(sampler2D source, vec2 coord) { return ra_logical_texel(source, ivec2(floor(coord * vec2(max(ivec2(ra_input_size), ivec2(1)))))); }\n"
	# Texture bias has no effect on a source without mip levels. This also
	# preserves shaders requesting a strongly negative bias to force mip zero.
	header += "vec4 ra_sample_source(sampler2D source, vec2 coord, float _bias) { return ra_sample_source(source, coord); }\n"
	header += _offset_header("ra_source","ra_input_size","ra_sample_source")
	for descriptor: Dictionary in textures: header += _texture_header(descriptor)
	for descriptor: Dictionary in parameters: header += "uniform float %s = %s;\n"%[descriptor.name, str(descriptor.default)]
	if native_buffers:
		header += _mip_header("ra_source","ra_input_size",filter_linear,border,input_srgb,input_wrap == "repeat",false,input_wrap == "mirrored_repeat")
		for descriptor: Dictionary in dynamic_textures: header += _mip_header(descriptor.uniform,descriptor.uniform+"_size",descriptor.filter_linear,descriptor.wrap_mode == "clamp_to_border",bool(descriptor.get("srgb",false)),descriptor.wrap_mode == "repeat",false,descriptor.wrap_mode == "mirrored_repeat")
	var ordered_units := PackedStringArray(_units(header))
	ordered_units.append_array(shared)
	var translated := "\n".join(_ordered_declarations(ordered_units,stages))+"\n"+"\n".join(comments)+"\n"+"\n".join(stages)
	# Godot assigns texture units to declared samplers, including unused ones.
	# History and alias compatibility declarations can otherwise exhaust them
	# before a later feedback/mip sampler is bound, even in a tiny preset.
	var identifiers := {}
	for identifier: RegExMatch in _regex('\\b[A-Za-z_][A-Za-z_0-9]*\\b').search_all(_without_comments(translated)):
		var name := identifier.get_string()
		identifiers[name] = int(identifiers.get(name,0))+1
	for declaration: RegExMatch in _regex('\\buniform\\s+sampler2D\\s+([A-Za-z_][A-Za-z_0-9]*)[^;]*;').search_all(translated):
		if identifiers.get(declaration.get_string(1),0) == 1:
			translated = translated.replace(declaration.get_string(),"")
	return {"ok":true, "code":translated, "custom_geometry":custom_geometry}
