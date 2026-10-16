extends SceneTree
## Sequential import timings, without adding a Python/native runtime dependency.
## Godot --headless --path . --script addons/retroarch_shaders/tools/benchmark_import.gd
## -- --shader=res://addons/retroarch_shaders/demo/shaders/scanlines.glsl
## --iterations=3 --output=res://test-results/import-benchmark.json
const Importer := preload("../glsl_importer.gd")
const IMPORT_PHASES := ["read_us", "preparation_us", "texture_loading_us", "translation_us", "shader_validation_us", "cache_lookup_us"]
const TRANSLATION_PHASES := ["preprocess_us", "bindings_us", "lowering_us", "emission_us"]
const MODES := ["uncached", "cold", "hit"]
const USAGE := "Usage: Godot --headless --path <project> --script addons/retroarch_shaders/tools/benchmark_import.gd -- --shader=<.glsl/.glslp> [--shader=<another>] [--iterations=3] [--output=<new.json>]\nWithout --output the JSON report is printed. Output files must not already exist."

var shader_paths: Array[String] = []
var iterations := 3
var output_path := ""
var report: Dictionary = {}
var _written_report_sha256 := ""


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var parsed := _parse_arguments()
	if parsed.get("help", false):
		print(USAGE)
		quit(0)
		return
	if not parsed.ok:
		printerr(str(parsed.message)+"\n"+USAGE)
		quit(2)
		return
	report = {
		"schema_version":1, "complete":false, "ok":true,
		"started_utc":Time.get_datetime_string_from_system(true),
		"environment":{
			"godot":Engine.get_version_info().string, "os":OS.get_name(),
			"cpu":OS.get_processor_name(), "logical_processor_count":OS.get_processor_count(),
			"display_server":DisplayServer.get_name(),
			"rendering_method":RenderingServer.get_current_rendering_method(),
			"rendering_driver":RenderingServer.get_current_rendering_driver_name(),
			"gpu":RenderingServer.get_video_adapter_name(), "gpu_vendor":RenderingServer.get_video_adapter_vendor()},
		"settings":{"iterations":iterations, "warmup_imports_per_shader":1, "mode_order":MODES},
		"notes":[
			"This measures synchronous importer CPU wall time; it does not measure rendered FPS or establish a C++ speedup.",
			"One unmeasured cache-disabled import warms each input before measured samples. Hit mode also has one unmeasured cache-priming import.",
			"Cold means the add-on translation cache was cleared before each import. This is not a cold process, OS file cache, Godot parser or GPU driver.",
			"Uncached bypasses the translation cache. Hit mode is seeded, and each sample reports whether all translations actually hit within the bounded cache.",
			"Import phases are exclusive; per-pass translation subphases partition translation work and must not be added again to import phases.",
			"Medians are computed independently per field; their sum need not equal the median total. Raw samples retain the additive per-import evidence.",
			"Generated Shader.code digests are checked in pass order across warmup, cache priming and every measured mode. No source files are written."],
		"results":[]}
	for index in shader_paths.size():
		var path := shader_paths[index]
		printerr("Import benchmark %d/%d: %s"%[index+1,shader_paths.size(),path])
		var result := _benchmark_shader(path)
		report.results.append(result)
		if not result.ok:
			report.ok = false
			printerr(path+": "+str(result.message))
		# Keep completed evidence visible during long later cases. Only the
		# final write marks the run complete; stdout-only JSON is emitted once.
		if not output_path.is_empty() and not _write_report(false):
			quit(2)
			return
	report.complete = true
	report["finished_utc"] = Time.get_datetime_string_from_system(true)
	if not _write_report():
		quit(2)
		return
	quit(0 if report.ok else 1)


func _parse_arguments() -> Dictionary:
	var seen := {}
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--help" or argument == "-h":
			return {"ok":true, "help":true}
		if argument.begins_with("--shader="):
			var path := argument.trim_prefix("--shader=")
			if path.is_empty(): return {"ok":false, "message":"Shader paths must not be empty."}
			shader_paths.append(path)
		elif argument.begins_with("--iterations="):
			if seen.has("iterations"): return {"ok":false, "message":"Supply --iterations once."}
			seen["iterations"] = true
			var value := argument.trim_prefix("--iterations=")
			if not value.is_valid_int() or int(value) < 1 or int(value) > 100:
				return {"ok":false, "message":"Iterations must be an integer between 1 and 100."}
			iterations = int(value)
		elif argument.begins_with("--output="):
			if seen.has("output"): return {"ok":false, "message":"Supply --output once."}
			seen["output"] = true
			output_path = argument.trim_prefix("--output=")
			if output_path.is_empty(): return {"ok":false, "message":"Output paths must not be empty."}
		else:
			return {"ok":false, "message":"Unknown argument: "+argument}
	if shader_paths.is_empty(): return {"ok":false, "message":"Supply at least one --shader path."}
	if not output_path.is_empty():
		output_path = ProjectSettings.globalize_path(output_path).replace("\\","/").simplify_path()
		if not output_path.is_absolute_path():
			output_path = ProjectSettings.globalize_path("res://").path_join(output_path).simplify_path()
		for path: String in shader_paths:
			var source_path := ProjectSettings.globalize_path(path).replace("\\","/").simplify_path()
			if not source_path.is_absolute_path():
				source_path = ProjectSettings.globalize_path("res://").path_join(source_path).simplify_path()
			if source_path.to_lower() == output_path.to_lower():
				return {"ok":false, "message":"Output must differ from every shader input: "+output_path}
		if FileAccess.file_exists(output_path) or DirAccess.dir_exists_absolute(output_path):
			return {"ok":false, "message":"Output must be a new file: "+output_path}
	return {"ok":true}


func _benchmark_shader(path: String) -> Dictionary:
	var result := {"path":path, "ok":false, "message":"", "modes":{}}
	var before := FileAccess.get_sha256(path)
	if before.is_empty():
		result.message = "Cannot read the shader/preset input."
		return result
	result["input_sha256"] = before
	Importer.clear_translation_cache()
	var warmup := _sample(path, false)
	result["warmup"] = warmup
	if not warmup.ok:
		result.message = "Warmup failed: "+str(warmup.message)
		return result
	var signature: Array = warmup.generated_sources
	result["generated_sources"] = signature
	for mode: String in MODES:
		printerr("  %s: starting %d sample(s)"%[mode,iterations])
		Importer.clear_translation_cache()
		var measurements: Array[Dictionary] = []
		var mode_result := {"samples":measurements}
		result.modes[mode] = mode_result
		if mode == "hit":
			var priming := _sample(path, true)
			mode_result["priming"] = priming
			if not priming.ok or priming.generated_sources != signature:
				result.message = "Cache priming failed or changed generated shader code: "+str(priming.message)
				return result
		for index in iterations:
			if mode == "cold": Importer.clear_translation_cache()
			var sample := _sample(path, mode != "uncached")
			sample["iteration"] = index+1
			measurements.append(sample)
			if not sample.ok:
				result.message = "%s iteration %d: %s"%[mode,index+1,sample.message]
				return result
			if sample.generated_sources != signature:
				result.message = "%s iteration %d changed generated shader code."%[mode,index+1]
				return result
			if measurements.size() > 1 and not _same_profile_passes(measurements[0].profile, sample.profile):
				result.message = "%s iteration %d changed the translation profile's pass order."%[mode,index+1]
				return result
		mode_result["medians"] = _medians(measurements)
		printerr("  %s: completed %d sample(s)"%[mode,iterations])
	result["input_unchanged"] = FileAccess.get_sha256(path) == before
	if not result.input_unchanged:
		result.message = "The input file changed during the benchmark."
		return result
	result.ok = true
	return result


func _sample(path: String, use_cache: bool) -> Dictionary:
	var before: Dictionary = Importer.translation_cache_stats()
	var started := Time.get_ticks_usec()
	var loaded: Dictionary = Importer.load_file(path, {}, {"profile":true, "cache":use_cache})
	var wall_us := Time.get_ticks_usec()-started
	var sample := {
		"ok":bool(loaded.get("ok",false)), "message":str(loaded.get("message","")),
		"wall_us":wall_us, "profile":loaded.get("profile",{}),
		"cache_before":before, "cache_after":Importer.translation_cache_stats(), "generated_sources":[]}
	if not sample.ok: return sample
	var shaders: Array = loaded.get("passes",[])
	if shaders.is_empty(): shaders = [{"index":0,"shader":loaded.get("shader")}]
	for index in shaders.size():
		var shader := shaders[index].get("shader") as Shader
		if shader == null:
			sample.ok = false
			sample.message = "The import returned no generated shader for pass %d."%index
			return sample
		sample.generated_sources.append({"pass_index":int(shaders[index].get("index",index)), "sha256":shader.code.sha256_text(), "characters":shader.code.length()})
	if not sample.profile is Dictionary:
		sample.ok = false
		sample.message = "The import returned no profile dictionary."
		return sample
	var profile_error := _validate_profile(sample.profile)
	if not profile_error.is_empty():
		sample.ok = false
		sample.message = profile_error
		return sample
	var cache: Dictionary = sample.profile.cache
	sample["cache_state"] = "bypassed" if not use_cache else ("fully_hot" if int(cache.hits) > 0 and int(cache.misses) == 0 else "partial_or_cold")
	return sample


func _validate_profile(profile: Dictionary) -> String:
	for key: String in ["total_us"]+IMPORT_PHASES:
		if not profile.has(key) or not _nonnegative_number(profile[key]): return "Missing or invalid profile timing: "+key
	var import_total := 0.0
	for key: String in IMPORT_PHASES: import_total += float(profile[key])
	if import_total != float(profile.total_us): return "Exclusive import phases do not sum to total_us."
	if not profile.get("cache") is Dictionary or not profile.get("translation_passes") is Array:
		return "Profile must include cache counts and translation_passes."
	for key: String in ["hits","misses","bypasses","stores","oversized_skips"]:
		if not profile.cache.has(key) or not _nonnegative_number(profile.cache[key]): return "Missing or invalid cache count: "+key
	var translation_total := 0.0
	for pass_value: Variant in profile.translation_passes:
		if not pass_value is Dictionary: return "Invalid translation pass profile."
		var pass_profile: Dictionary = pass_value
		if not pass_profile.get("pass_index") is int or not pass_profile.get("cache_hit") is bool:
			return "Translation profiles must identify pass_index and cache_hit."
		var total := 0.0
		for key: String in TRANSLATION_PHASES:
			if not pass_profile.has(key) or not _nonnegative_number(pass_profile[key]): return "Missing or invalid translation timing: "+key
			total += float(pass_profile[key])
		if not pass_profile.has("total_us") or not _nonnegative_number(pass_profile.total_us) or total != float(pass_profile.total_us):
			return "Exclusive translation subphases do not sum to pass total_us."
		translation_total += float(pass_profile.total_us)
	if translation_total > float(profile.translation_us): return "Pass translation totals exceed import translation_us."
	return ""


func _same_profile_passes(first: Dictionary, second: Dictionary) -> bool:
	if first.translation_passes.size() != second.translation_passes.size(): return false
	for index in first.translation_passes.size():
		if first.translation_passes[index].pass_index != second.translation_passes[index].pass_index: return false
	return true


func _nonnegative_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0


func _medians(samples: Array[Dictionary]) -> Dictionary:
	var result := {"wall_us":_median_field(samples,"wall_us"), "profile":{}, "translation_passes":[]}
	for key: String in ["total_us"]+IMPORT_PHASES:
		var values: Array[float] = []
		for sample: Dictionary in samples: values.append(float(sample.profile[key]))
		result.profile[key] = _median(values)
	var passes: Array = samples[0].profile.translation_passes
	for index in passes.size():
		var summary := {"pass_index":passes[index].pass_index}
		for key: String in ["total_us"]+TRANSLATION_PHASES:
			var values: Array[float] = []
			for sample: Dictionary in samples: values.append(float(sample.profile.translation_passes[index][key]))
			summary[key] = _median(values)
		result.translation_passes.append(summary)
	return result


func _median_field(samples: Array[Dictionary], key: String) -> float:
	var values: Array[float] = []
	for sample: Dictionary in samples: values.append(float(sample[key]))
	return _median(values)


func _median(values: Array[float]) -> float:
	values.sort()
	var middle := values.size() >> 1
	return values[middle] if values.size()%2 == 1 else (values[middle-1]+values[middle])*0.5


func _write_report(announce: bool = true) -> bool:
	var contents := JSON.stringify(report,"  ")+"\n"
	if output_path.is_empty():
		print(contents)
		return true
	if _written_report_sha256.is_empty():
		if FileAccess.file_exists(output_path):
			printerr("Refusing to overwrite an existing report: "+output_path)
			return false
	elif not FileAccess.file_exists(output_path) or FileAccess.get_sha256(output_path) != _written_report_sha256:
		# A report edited/replaced/deleted by another process is no longer ours
		# to update. Checkpoints never take ownership of preexisting content.
		printerr("The benchmark report changed externally; refusing to overwrite it: "+output_path)
		return false
	var error := DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	if error != OK:
		printerr("Cannot create report directory: "+error_string(error))
		return false
	var file := FileAccess.open(output_path,FileAccess.WRITE)
	if file == null:
		printerr("Cannot write import benchmark report: "+error_string(FileAccess.get_open_error()))
		return false
	file.store_string(contents)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		printerr("Cannot finish writing import benchmark report: "+error_string(write_error))
		return false
	_written_report_sha256 = contents.sha256_text()
	if announce: printerr("Import benchmark: "+output_path)
	return true
