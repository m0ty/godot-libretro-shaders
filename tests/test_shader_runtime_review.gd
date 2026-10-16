extends SceneTree
## Runtime regressions for reparenting, live temporal bindings and shared mip
## programs. Pixel checks use synthetic textures and never read game data.
const PostProcess := preload("res://addons/retroarch_shaders/post_process.gd")
const MipAtlas := preload("res://addons/retroarch_shaders/glsl_mip_atlas.gd")
const DrawableChain := preload("res://addons/retroarch_shaders/glsl_drawable_chain.gd")
var checks := 0
var failures := 0
var folder := ""


func _init() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> bool:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
	return value


func _write(name: String, contents: String) -> String:
	var path := folder.path_join(name)
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(contents)
	file.close()
	return path


func _run() -> void:
	folder = OS.get_environment("TEMP").replace("\\","/").path_join("shader-runtime-review-%d"%Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(folder) == OK,"Create isolated runtime fixtures")
	_write("history.glsl","""#if defined(FRAGMENT)
uniform sampler2D Texture;
uniform sampler2D PrevTexture;
uniform sampler2D Prev2Texture;
void main() {
	gl_FragColor = vec4(texture2D(Texture,vec2(0.5)).r,
		texture2D(PrevTexture,vec2(0.5)).g,
		texture2D(Prev2Texture,vec2(0.5)).b,1.0);
}
#endif
""")
	var preset := _write("history.glslp","shaders=1\nshader0=history.glsl\n")
	root.size = Vector2i(64,48)
	var source := SubViewport.new()
	source.disable_3d = true
	source.size = root.size
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source)
	var swatch := ColorRect.new()
	swatch.size = Vector2(source.size)
	swatch.color = Color.RED
	source.add_child(swatch)
	var effect := PostProcess.new()
	var callback := Callable(effect,"_render_drawable")
	root.add_child(effect)
	_check(not effect.is_processing() and _connections(callback) == 0,"Disabled effects schedule no frame processing or snapshot callbacks")
	effect.set_framebuffer_texture(source.get_texture())
	effect.set_input_size(Vector2(0.5,8.9))
	if _check(effect.configure({"shader_enabled":true,"shader_path":preset}).ok,"Enable temporal regression preset"):
		var pass_data: Dictionary = effect._passes[0]
		_check(effect.input_size == Vector2(1,8) and effect._drawable.logical_size == Vector2i(1,8) and effect._drawable.history[0].get_size() == Vector2(1,8),"Subpixel logical input dimensions create whole nonzero snapshot pixels")
		_check(effect._material.get_shader_parameter("ra_input_size") == Vector2(1,8) and effect._material.get_shader_parameter("ra_history_2_size") == Vector2(1,8),"Initial logical input and history uniforms match normalized snapshot dimensions")
		effect.set_source_region(Rect2(8,4,48,40),Vector2(0.25,3.9))
		_check(effect.input_size == Vector2(1,3) and effect._drawable.logical_size == Vector2i(1,3) and effect._material.get_shader_parameter("ra_input_size") == Vector2(1,3) and effect._material.get_shader_parameter("ra_history_2_size") == Vector2(1,3),"Source region logical dimensions floor to whole pixels with matching sampler uniforms")
		effect.set_source_region(Rect2(8,4,0.5,0.75),Vector2.ZERO)
		_check(effect.input_size == Vector2.ZERO and effect._drawable.logical_size == Vector2i.ONE and effect._material.get_shader_parameter("ra_input_size") == Vector2.ONE and effect._material.get_shader_parameter("ra_history_2_size") == Vector2.ONE,"A subpixel source region fallback retains one snapshot texel and consistent uniforms")
		_check(effect._display.size == Vector2(0.5,0.75),"Logical pixel normalization preserves the physical presentation rectangle")
		_check(effect.configure_imported(effect.current).ok and effect._drawable.logical_size == Vector2i.ONE,"Reconfiguring a subpixel region fallback never allocates zero-sized snapshots")
		effect.set_input_size(Vector2(16,8))
		pass_data = effect._passes[0]
		_check(pass_data.info.dynamic_textures.size() == 8 and pass_data.snapshot_bindings.size() == 2,"Cache only two live temporal samplers from eight compatibility descriptors")
		_check(effect._drawable.history.size() == 4,"Retain the current snapshot and three previous frames required by Prev2Texture")
		_check(pass_data.source_snapshot and not pass_data.source_snapshot_mips,"Primary source updates exclude its unused mip sampler")
		var history_before: Array = effect._drawable.history.duplicate()
		for width in range(24,56):
			effect.set_source_region(Rect2(0,0,width,32),Vector2(16,8))
		_check(effect._drawable.history == history_before,"Thirty-two output resizes allocate zero replacement history textures while logical input stays fixed")
		effect.set_input_size(Vector2(16,8))
		_check(_connections(callback) == 1,"Connect one frame-completion callback on first entry")
		root.remove_child(effect)
		_check(_connections(callback) == 0,"Disconnect frame-completion callback while detached")
		root.add_child(effect)
		_check(_connections(callback) == 1,"Reconnect frame-completion callback without another ready notification")
		root.remove_child(effect)
		root.add_child(effect)
		_check(_connections(callback) == 1,"Repeated reparenting keeps exactly one frame-completion callback")
		if DisplayServer.get_name() != "headless":
			await _warm()
			root.remove_child(effect)
			swatch.color = Color.GREEN
			await _warm()
			root.add_child(effect)
			await _warm()
			_check(_close(effect._drawable.history[0].get_image().get_pixel(1,1),Color.GREEN),"Reattached effects resume GPU original-frame snapshots")
			_check(_close(effect._passes[0].viewport.get_texture().get_image().get_pixel(1,1),Color.GREEN),"Live historical samplers follow snapshots after reparenting")
			effect.set_source_region(Rect2(8,4,48,40),Vector2(16,8))
			_check(_close(effect._drawable.history[3].get_image().get_pixel(1,1),Color.GREEN),"An output-only resize preserves the oldest rendered frame without refilling history")
			effect.set_source_region(Rect2(8,4,48,40),Vector2(8,4))
			_check(effect._drawable.logical_size == Vector2i(8,4) and effect._material.get_shader_parameter("ra_history_2_size") == Vector2(8,4),"Cached sampler bindings preserve history dimensions during a crop/size change")
			await _warm()
			_check(_close(effect._passes[0].viewport.get_texture().get_image().get_pixel(1,1),Color.GREEN),"Resized temporal buffers refill and retain source cropping")
	_write("stock.glsl","#if defined(FRAGMENT)\nuniform sampler2D Texture; varying vec2 TEX0; void main() { gl_FragColor=texture2D(Texture,TEX0); }\n#endif\n")
	var stock_preset := _write("stock.glslp","shaders=1\nshader0=stock.glsl\nfloat_framebuffer0=true\n")
	if _check(effect.configure({"shader_enabled":true,"shader_path":stock_preset}).ok,"Enable HDR snapshot without historical samplers"):
		_check(effect._drawable.history.size() == 1,"A shader without previous-frame reads keeps one original snapshot instead of eight")
		effect.set_input_size(Vector2(32,16))
		_check(effect._drawable.history.size() == 1 and effect._drawable.logical_size == Vector2i(32,16),"Resizing retains only the required original-frame snapshot")
		if DisplayServer.get_name() != "headless":
			await _warm()
			_check(_close(effect._passes[0].viewport.get_texture().get_image().get_pixel(1,1),Color.GREEN),"A single original snapshot remains current across repeated frames")
	_write("oldest.glsl","#if defined(FRAGMENT)\nuniform sampler2D Prev6Texture; void main() { gl_FragColor=texture2D(Prev6Texture,vec2(0.5)); }\n#endif\n")
	var oldest_preset := _write("oldest.glslp","shaders=1\nshader0=oldest.glsl\n")
	if _check(effect.configure({"shader_enabled":true,"shader_path":oldest_preset}).ok,"Enable the oldest supported temporal sampler"):
		_check(effect._drawable.history.size() == 8,"Prev6Texture still retains the complete seven-frame history")
		if DisplayServer.get_name() != "headless":
			await _warm()
			_check(_close(effect._passes[0].viewport.get_texture().get_image().get_pixel(1,1),Color.GREEN),"The oldest supported snapshot still renders after its history fills")
	_write("mips.glsl","#if defined(FRAGMENT)\nuniform sampler2D Texture; void main() { gl_FragColor=textureLod(Texture,vec2(0.5),2.0); }\n#endif\n")
	var mip_preset := _write("mips.glslp","shaders=1\nshader0=mips.glsl\nmipmap_input0=true\n")
	if _check(effect.configure({"shader_enabled":true,"shader_path":mip_preset}).ok,"Enable original snapshot mipmaps"):
		effect.set_input_size(Vector2(100000,100000))
		var suspended := true
		for child: Node in effect._chain.get_children():
			if child is SubViewport:
				suspended = suspended and child.render_target_update_mode == SubViewport.UPDATE_DISABLED
		_check(suspended and not effect._display.visible,"Oversized layouts suspend every pass and mip dependency")
		effect.set_input_size(Vector2(16,8))
		_check(effect._display.visible and effect._snapshot_mips[-1].atlas.render_target_update_mode == SubViewport.UPDATE_ALWAYS,"A valid layout resumes the mip atlas")
		_check(_active_mip_levels(effect._snapshot_mips[-1]) == 4,"Recovery enables only the four useful downsampling levels")
	effect.configure({"shader_enabled":false})
	_check(not effect.is_processing() and _connections(callback) == 0,"Disabling releases frame processing and snapshot callbacks immediately")
	if _check(effect.configure({"shader_enabled":true,"shader_path":folder.path_join("stock.glsl")}).ok,"Enable a direct screen shader after a drawable chain"):
		_check(effect.is_processing() and _connections(callback) == 0,"Screen shaders advance frame uniforms without snapshot callbacks")
	effect.free()
	_check(_connections(callback) == 0,"Freeing an effect removes its frame-completion callback")
	source.free()
	await _snapshot_resize()
	await _mip_programs()
	await _mip_growth()
	DirAccess.remove_absolute(folder.path_join("history.glsl"))
	DirAccess.remove_absolute(preset)
	for name: String in ["stock.glsl","stock.glslp","oldest.glsl","oldest.glslp","mips.glsl","mips.glslp"]:
		DirAccess.remove_absolute(folder.path_join(name))
	DirAccess.remove_absolute(folder)
	print("Shader runtime review: %d checks, %d failures"%[checks,failures])
	quit(0 if failures == 0 else 1)


func _connections(callback: Callable) -> int:
	var count := 0
	for connection: Dictionary in RenderingServer.frame_post_draw.get_connections():
		if connection.callable == callback:
			count += 1
	return count


func _snapshot_resize() -> void:
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; void fragment() { COLOR = vec4(1.0); }"
	var drawable := DrawableChain.new({"feedback_pass":0,"passes":[{"shader":shader,"float_framebuffer":false}]})
	var initial_sizes: Array[Vector2i] = [Vector2i(8,4),Vector2i(64,48)]
	drawable.resize(initial_sizes,Vector2i(8,4))
	var original: DrawableTexture2D = drawable.history[0]
	var feedback: DrawableTexture2D = drawable.feedback
	if DisplayServer.get_name() != "headless":
		var image := Image.create(8,4,false,Image.FORMAT_RGBA8)
		image.fill(Color.BLUE)
		var source := ImageTexture.create_from_image(image)
		drawable.render(source,Vector4(0,0,1,1),source)
		await _warm()
	var resized_output: Array[Vector2i] = [Vector2i(8,4),Vector2i(96,72)]
	drawable.resize(resized_output,Vector2i(8,4))
	_check(drawable.history[0] == original and drawable.feedback == feedback,"Resizing a later output pass preserves fixed-size original and feedback GPU textures")
	if DisplayServer.get_name() != "headless":
		_check(_close(drawable.history[0].get_image().get_pixel(0,0),Color.BLUE) and _close(drawable.feedback.get_image().get_pixel(0,0),Color.BLUE),"Fixed-size source and feedback pixels survive an unrelated pass resize")
	var resized_feedback: Array[Vector2i] = [Vector2i(16,8),Vector2i(96,72)]
	drawable.resize(resized_feedback,Vector2i(8,4))
	_check(drawable.history[0] == original and drawable.feedback != feedback and drawable.feedback.get_size() == Vector2(16,8),"Resizing a feedback target replaces only its own texture")
	feedback = drawable.feedback
	drawable.resize(resized_feedback,Vector2i(4,2))
	_check(drawable.history[0] != original and drawable.feedback != feedback,"Changing logical input dimensions resets original history and feedback together")
	if DisplayServer.get_name() != "headless":
		_check(drawable.history[0].get_image().get_pixel(0,0) == Color.TRANSPARENT and drawable.feedback.get_image().get_pixel(0,0) == Color.TRANSPARENT,"New logical source dimensions start with cleared temporal pixels")


func _mip_programs() -> void:
	var parent := Node.new()
	root.add_child(parent)
	var image := Image.create(8,4,false,Image.FORMAT_RGBA8)
	image.fill(Color(0.2,0.4,0.6,1.0))
	var first := ImageTexture.create_from_image(image)
	var mip := MipAtlas.new(parent,first,Vector2i(8,4),{"float_framebuffer":false,"srgb_framebuffer":false})
	var downsample_shader: Shader = mip.levels[1].material.shader
	var copy_shader: Shader = mip.levels[0].copy.material.shader
	var programs := {}
	var materials := {}
	for data: Dictionary in mip.levels:
		programs[data.copy.material.shader.get_instance_id()] = true
		materials[data.copy.material.get_instance_id()] = true
		if data.material != null:
			programs[data.material.shader.get_instance_id()] = true
			materials[data.material.get_instance_id()] = true
	_check(programs.size() == 2 and downsample_shader != copy_shader,"Allocated mip levels share exactly two shader resources")
	_check(mip.levels.size() == 4 and materials.size() == 7 and parent.get_child_count() == 4,"An 8x4 source allocates three downsampling viewports and seven materials instead of fifteen and 31")
	_check(_active_mip_levels(mip) == 3,"An 8x4 source renders three downsampling passes instead of fifteen")
	_check(mip.levels[3].copy.visible and mip.levels[3].copy.size == Vector2(1,13),"The terminal mip fills repeated atlas rows with one copy")
	var original_level: SubViewport = mip.levels[3].viewport
	mip.resize(Vector2i(16,8))
	_check(_active_mip_levels(mip) == 4 and mip.levels.size() == 5 and parent.get_child_count() == 5 and mip.levels[3].viewport == original_level,"Growing the source allocates exactly one additional mip level and reuses existing dependencies")
	_check(mip.levels[2].material.get_shader_parameter("mip_dimensions") == Vector2(8,4) and mip.levels[2].material.get_shader_parameter("mip_output_dimensions") == Vector2(4,2),"Shared programs retain independent dimensions after resizing")
	image.fill(Color(0.6,0.2,0.4,1.0))
	var second := ImageTexture.create_from_image(image)
	mip.set_source(second)
	mip.set_source(second)
	_check(mip.levels[0].copy.material.get_shader_parameter("source") == second and mip.levels[1].material.get_shader_parameter("mip_source") == second,"Replacing or repeating the atlas source binds both base and downsampling inputs")
	if DisplayServer.get_name() != "headless":
		mip.resize(Vector2i(8,4))
		await _warm()
		var pixels: Image = mip.atlas.get_texture().get_image()
		_check(_close(pixels.get_pixel(0,0),Color(0.6,0.2,0.4,1.0)) and _close(pixels.get_pixel(0,4),Color(0.6,0.2,0.4,1.0)),"Shared mip programs render the replacement source into base and next level")
		image.fill(Color.BLUE)
		for y in 4:
			for x in 4:
				image.set_pixel(x,y,Color.RED)
		mip.set_source(ImageTexture.create_from_image(image))
		await _warm()
		pixels = mip.atlas.get_texture().get_image()
		_check(_close(pixels.get_pixel(0,7),Color(0.5,0,0.5)) and _close(pixels.get_pixel(0,19),Color(0.5,0,0.5)),"The final mip averages asymmetric input and fills the highest atlas slot identically")
	mip.set_enabled(false)
	mip.resize(Vector2i(1,1))
	_check(mip.atlas.render_target_update_mode == SubViewport.UPDATE_DISABLED and _active_mip_levels(mip) == 0,"Resizing a suspended atlas keeps every dependency disabled")
	mip.set_enabled(true)
	_check(_active_mip_levels(mip) == 0 and mip.levels[0].copy.size == Vector2(1,16),"A 1x1 input needs no downsampling and fills all atlas slots directly")
	parent.free()


func _mip_growth() -> void:
	var parent := Node.new()
	root.add_child(parent)
	var image := Image.create(1,1,false,Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	var mip := MipAtlas.new(parent,ImageTexture.create_from_image(image),Vector2i.ONE,{"float_framebuffer":false,"srgb_framebuffer":false})
	_check(mip.levels.size() == 1 and parent.get_child_count() == 1,"A 1x1 source allocates only the atlas, one copy and no downsampling viewports")
	image.fill(Color.BLUE)
	var blue := ImageTexture.create_from_image(image)
	mip.set_source(blue)
	_check(mip.levels[0].copy.material.get_shader_parameter("source") == blue,"A one-level atlas accepts rotating source textures before any downsample level exists")
	if DisplayServer.get_name() != "headless":
		await _warm()
		_check(_close(mip.atlas.get_texture().get_image().get_pixel(0,15),Color.BLUE),"A one-level atlas renders the current source through its highest mip slot")
	image = Image.create(16,8,false,Image.FORMAT_RGBA8)
	image.fill(Color.GREEN)
	for y in 8:
		for x in 8:
			image.set_pixel(x,y,Color.RED)
	var large := ImageTexture.create_from_image(image)
	mip.set_source(large)
	mip.set_enabled(false)
	mip.resize(Vector2i(16,8))
	_check(mip.levels.size() == 5 and _active_mip_levels(mip) == 0 and mip.atlas.render_target_update_mode == SubViewport.UPDATE_DISABLED,"Growing a suspended atlas keeps newly allocated dependencies disabled")
	_check(mip.levels[1].material.get_shader_parameter("mip_source") == large,"New downsampling levels bind the latest source after growth from 1x1")
	mip.set_enabled(true)
	_check(_active_mip_levels(mip) == 4,"Resuming a grown atlas enables all four required downsampling dependencies")
	if DisplayServer.get_name() != "headless":
		await _warm()
		_check(_close(mip.atlas.get_texture().get_image().get_pixel(0,26),Color(0.5,0.5,0)),"Dependencies created after the atlas render the grown source into the highest mip slot")
		var fresh := Image.create(16,8,false,Image.FORMAT_RGBA8)
		fresh.fill(Color.CYAN)
		mip.set_source(ImageTexture.create_from_image(fresh))
		# Preserve the baseline material-update/readback latency: all levels
		# must show the new source within two draws, including appended levels.
		for frame in 2:
			await process_frame
			await RenderingServer.frame_post_draw
		_check(_close(mip.atlas.get_texture().get_image().get_pixel(0,26),Color.CYAN),"Newly allocated dependencies propagate a changed source through the highest mip within the baseline two draws")
	image = Image.create(4,2,false,Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	for y in 2:
		for x in 2:
			image.set_pixel(x,y,Color.BLUE)
	mip.set_source(ImageTexture.create_from_image(image))
	mip.resize(Vector2i(4,2))
	_check(mip.levels.size() == 5 and _active_mip_levels(mip) == 2 and not mip.levels[3].copy.visible,"Shrinking preserves the allocated pool while disabling surplus levels and hiding their copies")
	if DisplayServer.get_name() != "headless":
		await _warm()
		_check(_close(mip.atlas.get_texture().get_image().get_pixel(0,16),Color(0.5,0.5,1)),"A smaller replacement source fills the highest mip slot after shrinking")
	mip.set_source(large)
	mip.resize(Vector2i(16,8))
	_check(mip.levels.size() == 5 and _active_mip_levels(mip) == 4,"Regrowing reuses the complete existing mip pool")
	if DisplayServer.get_name() != "headless":
		await _warm()
		_check(_close(mip.atlas.get_texture().get_image().get_pixel(0,26),Color(0.5,0.5,0)),"Reused dependencies render the restored larger source correctly")
	parent.free()


func _active_mip_levels(mip: RefCounted) -> int:
	var count := 0
	for data: Dictionary in mip.levels:
		if data.viewport != null and data.viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
			count += 1
	return count


func _warm() -> void:
	# Eight snapshots need a subsequent draw before the oldest one is visible.
	for frame in 9:
		await process_frame
		await RenderingServer.frame_post_draw


func _close(a: Color,b: Color) -> bool:
	return absf(a.r-b.r) < 0.012 and absf(a.g-b.g) < 0.012 and absf(a.b-b.b) < 0.012
