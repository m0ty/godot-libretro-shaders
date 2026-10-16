extends SceneTree
## One isolated audit case. The Python runner supplies paths, timeouts and logs.
const Importer := preload("../glsl_importer.gd")
const PostProcess := preload("../post_process.gd")
var shader_path := ""
var result_path := ""
var rendered := false
var render_sizes: Array[Vector2i] = [Vector2i(640,480),Vector2i(800,600)]
var warmup_frames := 12
var source: SubViewport
var display: TextureRect
var effect: CanvasLayer

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--shader="): shader_path = argument.trim_prefix("--shader=")
		if argument.begins_with("--result="): result_path = argument.trim_prefix("--result=")
		if argument == "--render": rendered = true
		if argument.begins_with("--sizes="):
			render_sizes.clear()
			for size: String in argument.trim_prefix("--sizes=").split(","):
				var dimensions := size.split("x")
				if dimensions.size() != 2 or not dimensions[0].is_valid_int() or not dimensions[1].is_valid_int():
					push_error("Invalid rendered dimensions."); quit(2); return
				var value := Vector2i(int(dimensions[0]),int(dimensions[1]))
				if value.x < 1 or value.y < 1 or value.x > 8192 or value.y > 8192:
					push_error("Rendered dimensions must be between 1 and 8192."); quit(2); return
				render_sizes.append(value)
		if argument.begins_with("--warmup-frames="):
			var value := argument.trim_prefix("--warmup-frames=")
			if not value.is_valid_int() or int(value) < 1 or int(value) > 600:
				push_error("Warmup must be between 1 and 600 frames."); quit(2); return
			warmup_frames = int(value)
	if shader_path.is_empty() or result_path.is_empty():
		push_error("Supply --shader=<path> and --result=<path>.")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var result := {"path":shader_path,"godot":Engine.get_version_info().string,"display":DisplayServer.get_name(),"adapter":RenderingServer.get_video_adapter_name(),"status":"rejected","message":"","render":{"status":"skipped","reason":"Headless translation audit"}}
	if rendered:
		var sizes := []
		for size: Vector2i in render_sizes: sizes.append([size.x,size.y])
		result["render_conditions"] = {"sizes":sizes,"warmup_frames":warmup_frames,"input_size":[320,240]}
	var loaded: Dictionary
	if rendered:
		if DisplayServer.get_name() == "headless":
			result.message = "Rendered validation requires a display."
			_write(result)
			quit(2)
			return
		_setup()
		var configured: Dictionary = effect.configure({"shader_enabled":true,"shader_path":shader_path})
		loaded = effect.current if configured.ok else configured
	else:
		loaded = Importer.load_file(shader_path)
	result["configure_ms"] = Time.get_ticks_msec()-started
	result.message = str(loaded.get("message",""))
	for key: String in ["warnings","ignored_preset_parameters"]:
		if not loaded.get(key,[]).is_empty(): result[key] = loaded[key]
	if not loaded.get("preset_candidates",[]).is_empty():
		result["preset_candidates"] = loaded.preset_candidates
		result.status = "preset_required"
	if bool(loaded.get("ok",false)):
		result["passes"] = loaded.get("passes",[{}]).size()
		result["parameters"] = loaded.get("parameters",[]).size()
		result.status = "translated"
		if rendered:
			result.render = await _render()
			result.status = result.render.status
			result.message = result.render.message
	result["elapsed_ms"] = Time.get_ticks_msec()-started
	_write(result)
	if effect != null: effect.configure({"shader_enabled":false})
	quit(0)

func _write(result: Dictionary) -> void:
	var file := FileAccess.open(result_path,FileAccess.WRITE)
	if file == null:
		push_error("Cannot write audit case result.")
		quit(2)
		return
	file.store_string(JSON.stringify(result,"  "))
	file.close()

func _setup() -> void:
	root.size = render_sizes[0]
	source = SubViewport.new()
	source.disable_3d = true
	source.size = root.size
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source)
	var pattern := Image.create(320,240,false,Image.FORMAT_RGBA8)
	for y in 240:
		for x in 320:
			var value := Color(float(x)/319.0,float(y)/239.0,float((x+y)%64)/63.0,1.0)
			if x < 80: value = Color.WHITE if ((x >> 2)+(y >> 2))%2 == 0 else Color.BLACK
			if y > 200: value = [Color.RED,Color.GREEN,Color.BLUE,Color.WHITE][floori(float(x)/20.0)%4]
			pattern.set_pixel(x,y,value)
	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(pattern)
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	source.add_child(rect)
	display = TextureRect.new()
	display.texture = source.get_texture()
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(display)
	effect = PostProcess.new()
	root.add_child(effect)
	effect.set_framebuffer_texture(source.get_texture())
	effect.set_input_size(Vector2(320,240))

func _render() -> Dictionary:
	var result := {"status":"rendered","message":"","sizes":[]}
	for size: Vector2i in render_sizes:
		root.size = size
		source.size = size
		for frame in warmup_frames: await process_frame
		await RenderingServer.frame_post_draw
		var output := root.get_texture().get_image()
		if output == null or output.is_empty():
			return {"status":"error","message":"Cannot read the rendered viewport.","sizes":result.sizes}
		var low := 1.0
		var high := 0.0
		var finite := true
		var energy := 0.0
		for y in range(0,output.get_height(),7):
			for x in range(0,output.get_width(),7):
				var pixel := output.get_pixel(x,y)
				finite = finite and is_finite(pixel.r) and is_finite(pixel.g) and is_finite(pixel.b)
				var luminance := (pixel.r+pixel.g+pixel.b)/3.0
				low = minf(low,luminance)
				high = maxf(high,luminance)
				energy += luminance
		result.sizes.append({"width":size.x,"height":size.y,"finite":finite,"range":high-low,"energy":energy})
		if not finite or not effect.error_message.is_empty():
			result.status = "error"
			result.message = "Nonfinite pixels or a runtime error: "+effect.error_message
		# Preserve the strongest failure across sizes. A later flat image must
		# not downgrade an earlier runtime/nonfinite error to visual review.
		elif result.status != "error" and (high-low <= 0.05 or energy <= 1.0):
			result.status = "review"
			result.message = "Flat/blank test output; inspect visually before declaring support."
	return result
