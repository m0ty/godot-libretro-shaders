extends SceneTree
## Audits original external CRT presets; no collection/config/save writes.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")
const PostProcess := preload("res://addons/retroarch_shaders/post_process.gd")
var shader_directory := ""
var report_path := ""
var audit := false
var render := false
var captures := ""
var filter := ""
var results: Array[Dictionary] = []
var source_fingerprint := ""
var collection_fingerprint := ""
var collection_unchanged := false

func _init() -> void: _run.call_deferred()

func _run() -> void:
	source_fingerprint = _source_hash()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--shader-dir="): shader_directory = argument.trim_prefix("--shader-dir=").replace("\\","/").simplify_path()
		if argument.begins_with("--report="): report_path = argument.trim_prefix("--report=").replace("\\","/").simplify_path()
		if argument == "--audit": audit = true
		if argument == "--render": render = true
		if argument.begins_with("--captures="): captures = argument.trim_prefix("--captures=").replace("\\","/").simplify_path()
		if argument.begins_with("--filter="): filter = argument.trim_prefix("--filter=")
	if shader_directory.is_empty() or not DirAccess.dir_exists_absolute(shader_directory.path_join("crt")):
		push_error("CRT library requires --shader-dir=<external GLSL collection> containing a crt directory")
		quit(1)
		return
	if render and DisplayServer.get_name() == "headless":
		push_error("CRT library --render requires a rendered display; omit --headless")
		quit(1)
		return
	if not captures.is_empty():
		if not captures.to_lower().begins_with(OS.get_environment("TEMP").replace("\\","/").to_lower()+"/"): push_error("Captures must stay inside OS TEMP"); quit(1); return
		DirAccess.make_dir_recursive_absolute(captures)
	if not report_path.is_empty():
		var absolute := ProjectSettings.globalize_path(report_path) if report_path.begins_with("res://") else report_path
		if not absolute.is_absolute_path(): absolute = ProjectSettings.globalize_path("res://").path_join(absolute).simplify_path()
		var workspace := ProjectSettings.globalize_path("res://").trim_suffix("/").to_lower()+"/"
		var temporary := OS.get_environment("TEMP").replace("\\","/").to_lower()+"/"
		if not absolute.to_lower().begins_with(workspace) and not absolute.to_lower().begins_with(temporary): push_error("Report must stay inside the workspace or OS TEMP"); quit(1); return
		report_path = absolute
	var paths: Array[String] = []
	collection_fingerprint = _collection_hash(shader_directory)
	_collect(shader_directory.path_join("crt"),paths)
	paths.sort()
	var failures := 0
	for path: String in paths:
		if not filter.is_empty() and not path.get_file().contains(filter): continue
		var loaded := Importer.load_file(path)
		var entry := {"preset":path.trim_prefix(shader_directory+"/"),"sha256":FileAccess.get_sha256(path),"ok":bool(loaded.ok),"message":str(loaded.message)}
		if loaded.ok:
			entry["passes"] = loaded.get("passes",[{}]).size()
			entry["parameters"] = loaded.parameters.size()
			if render and DisplayServer.get_name() != "headless":
				entry["render"] = await _render(path)
				if not entry.render.ok: entry.ok = false; entry.message = entry.render.message; failures += 1
			else: entry["render"] = {"status":"skipped","reason":"No rendered display requested"}
		else: failures += 1
		results.append(entry)
		print("CRT_RESULT "+JSON.stringify(entry))
		_report(failures)
	collection_unchanged = collection_fingerprint == _collection_hash(shader_directory)
	_report(failures,true)
	print("CRT library: %d checks, %d failures"%[results.size(),failures])
	quit(0 if audit else (1 if failures or results.is_empty() or source_fingerprint != _source_hash() or not collection_unchanged else 0))

func _report(failures: int, complete: bool = false) -> void:
	if not report_path.is_empty():
		var file := FileAccess.open(report_path,FileAccess.WRITE)
		if file == null: push_error("Cannot write audit report"); return
		file.store_string(JSON.stringify({"complete":complete,"presets":results.size(),"failures":failures,"godot":Engine.get_version_info().string,"display":DisplayServer.get_name(),"adapter":RenderingServer.get_video_adapter_name(),"source_sha256":source_fingerprint,"source_unchanged":source_fingerprint == _source_hash(),"collection_sha256":collection_fingerprint,"collection_unchanged":collection_unchanged,"scope":"Original CRT presets at 640x480 and 800x600; rendering smoke checks, not RetroArch pixel equivalence","results":results},"  "))
		file.close()

func _source_hash() -> String:
	var hashes := PackedStringArray()
	for path in ["glsl_importer.gd","post_process.gd","glsl_drawable_chain.gd","glsl_mip_atlas.gd","source_profiles.gd","import_session.gd","translation_cache.gd"]:
		hashes.append(path+FileAccess.get_sha256("res://addons/retroarch_shaders/"+path))
	hashes.append(FileAccess.get_sha256("res://tests/test_crt_library.gd"))
	return "\n".join(hashes).sha256_text()

func _collection_hash(directory: String) -> String:
	var hashes := PackedStringArray()
	var access := DirAccess.open(directory)
	if access == null: return ""
	var entries := Array(access.get_files())+Array(access.get_directories())
	entries.sort()
	for entry: String in entries:
		if entry.begins_with("."): continue
		var path := directory.path_join(entry)
		hashes.append(entry+(_collection_hash(path) if DirAccess.dir_exists_absolute(path) else FileAccess.get_sha256(path)))
	return "\n".join(hashes).sha256_text()

func _render(path: String) -> Dictionary:
	root.size = Vector2i(640,480)
	var source := SubViewport.new()
	source.disable_3d = true
	source.size = root.size
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source)
	var pattern := Image.create(320,240,false,Image.FORMAT_RGBA8)
	for y in 240:
		for x in 320:
			var value := Color(float(x)/319.0,float(y)/239.0,float((x+y)%64)/63.0,1.0)
			if x < 80: value = Color.WHITE if ((x >> 2)+(y >> 2))%2 == 0 else Color.BLACK
			if y > 200: value = [Color.RED,Color.GREEN,Color.BLUE,Color.WHITE][(floori(float(x)/20.0))%4]
			pattern.set_pixel(x,y,value)
	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(pattern)
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.size = Vector2(root.size)
	source.add_child(rect)
	var display := TextureRect.new()
	display.texture = source.get_texture()
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.size = Vector2(root.size)
	root.add_child(display)
	var effect := PostProcess.new()
	root.add_child(effect)
	effect.set_framebuffer_texture(source.get_texture())
	effect.set_input_size(Vector2(320,240))
	var configured := effect.configure({"shader_enabled":true,"shader_path":path})
	var result := {"ok":bool(configured.ok),"status":"passed" if configured.ok else "failed","message":str(configured.message),"sizes":[]}
	if configured.ok:
		for size: Vector2i in [Vector2i(640,480),Vector2i(800,600)]:
			root.size = size
			source.size = size
			rect.size = Vector2(size)
			display.size = Vector2(size)
			for frame in 8: await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var minimum := 1.0
			var maximum := 0.0
			var energy := 0.0
			var finite := true
			for y in range(0,image.get_height(),7):
				for x in range(0,image.get_width(),7):
					var pixel := image.get_pixel(x,y)
					finite = finite and is_finite(pixel.r) and is_finite(pixel.g) and is_finite(pixel.b)
					var luminance := (pixel.r+pixel.g+pixel.b)/3.0
					minimum = minf(minimum,luminance); maximum = maxf(maximum,luminance); energy += luminance
			var valid := finite and maximum-minimum > 0.05 and energy > 1.0 and effect.error_message.is_empty()
			result.sizes.append({"width":size.x,"height":size.y,"ok":valid,"range":maximum-minimum,"energy":energy})
			if not valid: result.ok = false; result.status = "failed"; result.message = "Rendered output is blank/flat, nonfinite, or has a runtime error: "+effect.error_message
			if not captures.is_empty(): image.save_png(captures.path_join(path.get_file().get_basename()+"-%dx%d.png"%[size.x,size.y]))
	effect.configure({"shader_enabled":false})
	effect.queue_free(); display.queue_free(); source.queue_free()
	await process_frame
	return result

func _collect(directory: String,paths: Array[String]) -> void:
	for name: String in DirAccess.get_files_at(directory):
		if name.get_extension().to_lower() == "glslp": paths.append(directory.path_join(name))
	for name: String in DirAccess.get_directories_at(directory): _collect(directory.path_join(name),paths)
