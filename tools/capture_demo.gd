extends SceneTree
## Capture the real bundled demo at the Asset Store's 16:9 thumbnail ratio.
## godot --path . --script tools/capture_demo.gd -- --output=media/store-thumbnail.png

const Demo := preload("res://addons/retroarch_shaders/demo/demo.tscn")


func _init() -> void:
	_capture.call_deferred()


func _capture() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Demo capture requires a rendered display.")
		quit(1)
		return
	var output := "res://media/store-thumbnail.png"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
	root.size = Vector2i(1280,720)
	var demo := Demo.instantiate()
	root.add_child(demo)
	for frame in 16:
		await process_frame
	await RenderingServer.frame_post_draw
	if not demo.effect.active:
		push_error("The demo effect failed to load: " + demo.effect.error_message)
		quit(1)
		return
	var capture := root.get_texture().get_image()
	var error := capture.save_png(output)
	if error != OK:
		push_error("Cannot save the demo capture: " + error_string(error))
		quit(1)
		return
	print("Captured demo: %s (%dx%d)" % [output,capture.get_width(),capture.get_height()])
	quit()
