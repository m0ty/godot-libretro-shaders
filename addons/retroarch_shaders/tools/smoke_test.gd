extends SceneTree
## Standalone lifecycle and rendered smoke checks using only bundled assets.
## Run without --headless to include the pixel assertions.
const DemoScene := preload("../demo/demo.tscn")
var checks := 0
var failures := 0
var skipped := 0
var demo_path := ""


func _init() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)
	return condition


func _settle() -> void:
	for frame in 12:
		await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw


func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--demo-scene="): demo_path = argument.trim_prefix("--demo-scene=")
	root.size = Vector2i(640,480)
	var packed: PackedScene = DemoScene if demo_path.is_empty() else load(demo_path)
	_check(packed != null,"The standalone demo scene loads without game resources")
	if packed == null:
		_finish()
		return
	var instance := packed.instantiate()
	if not _check(instance is Control, "The demo root is a Control"):
		instance.free()
		_finish()
		return
	var demo: Control = instance
	root.add_child(demo)
	await _settle()
	for property: String in ["effect", "source", "enabled", "parameter_rows", "path_edit", "status"]:
		if not _check(is_instance_valid(demo.get(property)), "The demo initializes " + property):
			_finish()
			return
	_check(demo.effect.active and demo.effect.current.get("values", {}).has("STRENGTH"),"The packaged original demo shader loads and exposes its parameter")
	_check(demo.parameter_rows.get_child_count() == 2,"Generic parameter controls are built without host-project UI")
	var processed := Color.BLACK
	var original := Color.BLACK
	if DisplayServer.get_name() != "headless":
		processed = root.get_texture().get_image().get_pixel(632,223)
		original = demo.source.get_texture().get_image().get_pixel(316,111)
	demo.enabled.button_pressed = false
	await _settle()
	_check(not demo.effect.active,"The demo can disable and release the effect")
	if DisplayServer.get_name() != "headless":
		var plain := root.get_texture().get_image().get_pixel(632,223)
		_check(processed.r < plain.r-0.05,"The default shader visibly processes the synthetic source")
		_check(demo.source.get_texture().get_image().get_pixel(316,111).is_equal_approx(original),"The effect preserves the source viewport's pixels")
	else:
		skipped += 1
		print("SKIP: independent demo pixel checks require a rendered display")
	demo.enabled.button_pressed = true
	await _settle()
	_check(demo.effect.active,"The standalone demo can re-enable processing")
	var directory := "user://retroarch-smoke-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	_check(DirAccess.make_dir_recursive_absolute(directory) == OK,"Create standalone helper selection fixtures")
	var fixtures := {
		"source.glsl":"#if defined(FRAGMENT)\nvoid main() { gl_FragColor=vec4(0.5); }\n#endif\n",
		"helper.glsl":"#if defined(FRAGMENT)\nuniform sampler2D OrigTexture; void main() { gl_FragColor=texture2D(OrigTexture,vec2(0.5)); }\n#endif\n",
		"first.glslp":"shaders=2\nshader0=source.glsl\nshader1=helper.glsl\n",
		"second.glslp":"shaders=2\nshader0=source.glsl\nshader1=helper.glsl\n"
	}
	for name: String in fixtures:
		var file := FileAccess.open(directory.path_join(name), FileAccess.WRITE)
		_check(file != null, "Create helper fixture " + name)
		if file == null:
			_cleanup(directory, fixtures)
			_finish()
			return
		file.store_string(fixtures[name])
		file.close()
	demo.path_edit.text = directory.path_join("helper.glsl")
	demo.status.tooltip_text = "Previous preset diagnostics"
	demo._apply()
	demo._apply()
	_check(demo.parameter_rows.get_child_count() == 2,"Repeated Apply in one frame replaces parameter rows immediately")
	_check(demo.status.tooltip_text.is_empty(),"A failed replacement clears the previous preset's diagnostics")
	await _settle()
	_check(demo.effect.active and demo.parameter_rows.get_child_count() == 2 and demo.parameter_rows.get_child(0) is Button,"The standalone picker preserves the effect and offers both exact parent presets")
	if not _check(_has_preset_choices(demo), "Both helper choices are buttons"):
		_cleanup(directory, fixtures)
		_finish()
		return
	(demo.parameter_rows.get_child(1) as Button).pressed.emit()
	await _settle()
	_check(demo.effect.current.get("path", "") == directory.path_join("second.glslp") and demo.effect.current.get("passes", []).size() == 2,"The second helper choice loads its own complete preset")
	demo.path_edit.text = directory.path_join("helper.glsl")
	demo._apply()
	await _settle()
	if not _check(_has_preset_choices(demo), "Both helper choices can be reopened"):
		_cleanup(directory, fixtures)
		_finish()
		return
	(demo.parameter_rows.get_child(0) as Button).pressed.emit()
	await _settle()
	_check(demo.effect.current.get("path", "") == directory.path_join("first.glslp"),"Each preset button retains the correct path in its callback")
	_cleanup(directory, fixtures)
	demo.queue_free()
	await process_frame
	_finish()


func _has_preset_choices(demo: Control) -> bool:
	return (demo.parameter_rows.get_child_count() == 2
		and demo.parameter_rows.get_child(0) is Button
		and demo.parameter_rows.get_child(1) is Button)


func _cleanup(directory: String, fixtures: Dictionary) -> void:
	for filename: String in fixtures:
		var path := directory.path_join(filename)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(directory)


func _finish() -> void:
	print("Shader add-on: %d checks, %d failures, %d skips"%[checks,failures,skipped])
	quit(1 if failures else 0)
