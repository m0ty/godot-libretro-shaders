extends SceneTree
## Synthetic GLSL through the production final-display layer. No game files or
## user preferences are modified; fixtures and optional captures stay in TEMP.
const PostProcess := preload("res://addons/retroarch_shaders/post_process.gd")
const FIXTURE := """#pragma parameter AMOUNT "Amount" 1.0 0.0 1.0 0.1
#if defined(FRAGMENT)
uniform sampler2D Texture;
uniform vec2 InputSize;
uniform vec2 OutputSize;
uniform vec2 TextureSize;
uniform int FrameCount;
uniform float AMOUNT;
varying vec2 TEX0;
void main() {
    vec4 source = texture2D(Texture, TEX0);
    gl_FragColor = vec4(mix(source.rgb, vec3(1.0) - source.rgb, AMOUNT), source.a);
}
#endif
"""
const LUT_FIXTURE := """#if defined(FRAGMENT)
uniform sampler2D Texture;
uniform sampler2D MASK;
uniform vec2 InputSize;
uniform vec2 OutputSize;
varying vec2 TEX0;
void main() {
    vec2 mask_size = vec2(2.0, floor(OutputSize.y / InputSize.y + 0.000001));
    // Unbounded coordinates require the preset's repeat sampler. This is
    // equivalent to crt-potato's fract() coordinates with nearest filtering.
    gl_FragColor = texture2D(MASK, gl_FragCoord.xy / mask_size) * texture2D(Texture, TEX0);
}
#endif
"""
# Deliberately asymmetric in both axes: a row flip, lost channel, color-space
# conversion, linear filtering or logical-source wrapper cannot pass by chance.
const LUT_ROWS := [
	[Color8(37,211,83), Color8(179,53,241)],
	[Color8(229,71,127), Color8(43,193,109)],
	[Color8(151,233,61), Color8(89,137,227)],
	[Color8(67,113,251), Color8(223,157,41)],
	[Color8(197,47,163), Color8(101,239,73)],
]
var checks := 0
var failures := 0
var skipped := 0
var elapsed := 0.0
var fixture_directory := ""
var capture_directory := ""
var effect: CanvasLayer
var source: SubViewport
var click_target: Button


func _init() -> void: _run.call_deferred()


func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > 45.0:
		push_error("Post-processing verification timed out")
		quit(1)
	return false


func _run() -> void:
	var temp := OS.get_environment("TEMP").replace("\\","/").simplify_path()
	if not _check(not temp.is_empty(),"Fixtures have an OS temporary directory"):
		_finish()
		return
	fixture_directory = temp.path_join("fallout-post-process-%s"%Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(fixture_directory)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="):
			capture_directory = argument.trim_prefix("--capture-dir=").replace("\\","/").simplify_path()
	if not capture_directory.is_empty():
		if not _check(DisplayServer.get_name() != "headless" and capture_directory.to_lower().begins_with(temp.to_lower()+"/"),"Rendered captures remain in OS TEMP"):
			_finish()
			return
		DirAccess.make_dir_recursive_absolute(capture_directory)
	var shader_path := fixture_directory.path_join("invert.glsl")
	_write(shader_path,FIXTURE)
	effect = PostProcess.new()
	root.add_child(effect)
	_check(not effect.active and not effect.visible,"Post-processing starts disabled")
	var result: Dictionary = effect.configure({"shader_enabled":true,"shader_path":""})
	_check(not result.ok and not effect.active and not effect.error_message.is_empty(),"An empty shader choice reports a diagnostic without enabling an effect")
	result = effect.configure({"shader_enabled":true,"shader_path":shader_path,"shader_parameters":[]})
	_check(not result.ok and not effect.active,"Malformed parameter containers are rejected")
	result = effect.configure({"shader_enabled":true,"shader_path":shader_path,"shader_parameters":{}})
	if not _check(result.ok and effect.active and effect.visible,"A supported GLSL shader enables the display layer: "+str(result.message)):
		_finish()
		return
	_check(effect.layer > 100 and effect._capture.copy_mode == BackBufferCopy.COPY_MODE_VIEWPORT,"The shader explicitly captures the frame after native brightness")
	_check(effect._display.mouse_filter == Control.MOUSE_FILTER_IGNORE,"The post-processing surface ignores mouse input")
	effect.set_input_size(Vector2(64,48))
	_check(effect._material.get_shader_parameter("ra_input_size") == Vector2(64,48),"Logical input dimensions reach the adapter")
	var previous_material: ShaderMaterial = effect._material
	result = effect.configure({"shader_enabled":true,"shader_path":fixture_directory.path_join("missing.glsl")})
	_check(not result.ok and effect.active and effect._material == previous_material,"A missing replacement preserves the active material")
	var invalid_path := fixture_directory.path_join("invalid.glsl")
	_write(invalid_path,"This is not a GLSL shader.")
	result = effect.configure({"shader_enabled":true,"shader_path":invalid_path})
	_check(not result.ok and effect._material == previous_material and not effect.error_message.is_empty(),"An importer failure preserves the active effect and explains the failure")
	var lut_preset := _lut_fixtures()
	_lut_lifecycle(lut_preset)
	if DisplayServer.get_name() == "headless":
		skipped += 1
		print("SKIPPED: pixel, resize and physical input checks require a renderer.")
	else:
		await _render(shader_path)
		await _lut_render(lut_preset)
	result = effect.configure({"shader_enabled":false})
	_check(result.ok and not effect.active and not effect.visible and effect.current.is_empty(),"Disabling clears the effect and metadata")
	_check(effect._capture.copy_mode == BackBufferCopy.COPY_MODE_DISABLED and effect._display.material == null and effect._material == null,"Disabled effects perform no framebuffer copy or shader draw")
	_check(effect.error_message.is_empty(),"Disabling clears prior import diagnostics")
	_finish()


func _render(shader_path: String) -> void:
	root.size = Vector2i(512,384)
	root.min_size = Vector2i(1,1)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	source = SubViewport.new()
	source.size = Vector2i(64,48)
	source.disable_3d = true
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(source)
	var swatch := ColorRect.new()
	swatch.size = Vector2(64,48)
	swatch.color = Color8(48,104,176)
	source.add_child(swatch)
	var marker := ColorRect.new()
	marker.position = Vector2(24,18)
	marker.size = Vector2(24,18)
	marker.color = Color8(160,216,64)
	source.add_child(marker)
	var image := TextureRect.new()
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	image.texture = source.get_texture()
	image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(image)
	click_target = Button.new()
	click_target.position = Vector2(8,8)
	click_target.size = Vector2(64,24)
	click_target.text = "Input"
	host.add_child(click_target)
	var native_display := CanvasLayer.new()
	native_display.layer = 100
	host.add_child(native_display)
	var brightness := ColorRect.new()
	brightness.mouse_filter = Control.MOUSE_FILTER_IGNORE
	brightness.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	native_display.add_child(brightness)
	var native_shader := Shader.new()
	native_shader.code = """shader_type canvas_item;
uniform sampler2D native_source : hint_screen_texture, filter_nearest;
void fragment() { COLOR = textureLod(native_source, SCREEN_UV, 0.0); COLOR.rgb *= 0.5; }
"""
	var native_material := ShaderMaterial.new()
	native_material.shader = native_shader
	brightness.material = native_material
	effect.configure({"shader_enabled":false})
	await _settle()
	var source_before := source.get_texture().get_image().get_data()
	var baseline := _root_pixel()
	var control_baseline := root.get_texture().get_image().get_pixel(12,12)
	_capture("disabled")
	effect.performance_counters = true
	var result: Dictionary = effect.configure({"shader_enabled":true,"shader_path":shader_path})
	_check(result.ok,"The rendered shader reloads after disable")
	effect.set_input_size(Vector2(64,48))
	await _settle()
	_check(_close(_root_pixel(),Color(1.0-baseline.r,1.0-baseline.g,1.0-baseline.b,baseline.a)),"Post-processing samples the final frame including native brightness")
	_check(_close(root.get_texture().get_image().get_pixel(12,12),Color(1.0-control_baseline.r,1.0-control_baseline.g,1.0-control_baseline.b,control_baseline.a)),"Screen coordinates preserve distinct frontend controls and source regions")
	_check(source_before == source.get_texture().get_image().get_data(),"The child gameplay framebuffer remains byte-for-byte unchanged")
	_check(effect._material.get_shader_parameter("ra_output_size") == Vector2(512,384) and int(effect._material.get_shader_parameter("ra_frame_count")) > 0,"Physical output size and advancing frame count reach the shader")
	var layouts: int = effect.performance_stats.layout_updates
	var previous_frame: int = effect.frame_count
	for ignored in 4: effect.set_input_size(Vector2(64,48))
	await _settle()
	_check(effect.performance_stats.layout_updates == layouts and effect.frame_count > previous_frame,"Stable layouts skip static shader bindings while frame counters advance")
	_capture("enabled")
	var clicked := [false]
	click_target.pressed.connect(func(): clicked[0] = true)
	for pressed: bool in [true,false]:
		var mouse := InputEventMouseButton.new()
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.position = Vector2(30,20)
		mouse.global_position = mouse.position
		mouse.pressed = pressed
		root.push_input(mouse,true)
	_check(bool(clicked[0]),"Underlying controls receive clicks while the fullscreen effect is enabled")
	previous_frame = int(effect._material.get_shader_parameter("ra_frame_count"))
	var replacement: ShaderMaterial = effect._material
	result = effect.configure({"shader_enabled":true,"shader_path":fixture_directory.path_join("missing.glsl")})
	await _settle()
	_check(not result.ok and effect._material == replacement and _close(_root_pixel(),Color(1.0-baseline.r,1.0-baseline.g,1.0-baseline.b,baseline.a)),"A failed replacement keeps the rendered effect visible")
	_check(int(effect._material.get_shader_parameter("ra_frame_count")) > previous_frame,"Failed replacement preserves animated shader uniforms")
	result = effect.configure({"shader_enabled":true,"shader_path":shader_path,"shader_parameters":{"AMOUNT":0.5}})
	await _settle()
	_check(result.ok and _close(_root_pixel(),Color(0.5,0.5,0.5,baseline.a)),"Imported parameter values change the rendered result")
	root.size = Vector2i(320,240)
	await _settle()
	_check(effect._material.get_shader_parameter("ra_output_size") == Vector2(320,240),"Resizing updates output dimensions without reloading the shader")
	_check(_close(_root_pixel(),Color(0.5,0.5,0.5,baseline.a)) and effect._display.size == Vector2(320,240),"The effect covers the complete resized display")
	_check(source_before == source.get_texture().get_image().get_data(),"Display resize and parameter changes preserve source pixels")
	effect.set_input_size(Vector2(-1,0))
	_check(effect._material.get_shader_parameter("ra_input_size") == Vector2(320,240),"Invalid input dimensions fall back to the current framebuffer")
	effect.configure({"shader_enabled":false})
	await _settle()
	_check(_close(_root_pixel(),baseline),"Disabling restores the unprocessed display")
	_capture("disabled-restored")
	await _regions(host,image,swatch,marker,shader_path)
	host.queue_free()
	await process_frame


func _regions(host: Control,image: TextureRect,swatch: ColorRect,marker: ColorRect,shader_path: String) -> void:
	var background := ColorRect.new()
	background.color = Color.BLACK
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(background)
	host.move_child(background,0)
	var region := Rect2(73,47,128,96)
	image.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	image.position = region.position
	image.size = region.size
	await _settle()
	var baseline := root.get_texture().get_image()
	var result: Dictionary = effect.configure({"shader_enabled":true,"shader_path":shader_path,"shader_parameters":{"AMOUNT":0.0}})
	effect.set_source_region(region,Vector2(64,48))
	await _settle()
	_check(result.ok and baseline.get_data() == root.get_texture().get_image().get_data(),"Identity sampling preserves every native pixel with asymmetric letterboxing")
	_check(effect._display.position == region.position and effect._display.size == region.size,"Only the physical source rectangle receives the effect")
	_check(effect._material.get_shader_parameter("ra_input_size") == Vector2(64,48) and effect._material.get_shader_parameter("ra_output_size") == region.size,"Source-region sampling keeps logical input and physical output dimensions separate")
	_check(effect._material.get_shader_parameter("ra_source_uv_rect") == Vector4(73.0/320.0,47.0/240.0,128.0/320.0,96.0/240.0),"The logical grid maps to its exact root framebuffer rectangle")
	_capture("letterbox-identity")
	result = effect.configure({"shader_enabled":true,"shader_path":shader_path})
	await _settle()
	var image_after := root.get_texture().get_image()
	var sample_before := baseline.get_pixel(137,95)
	_check(result.ok and _close(image_after.get_pixel(137,95),Color(1.0-sample_before.r,1.0-sample_before.g,1.0-sample_before.b,sample_before.a)),"Effects sample the centered source rather than the full root image")
	_check(image_after.get_pixel(5,100) == Color.BLACK and image_after.get_pixel(250,150) == Color.BLACK,"Letterbox margins remain black")
	_check(image_after.get_pixel(12,12) == baseline.get_pixel(12,12),"Controls outside the source region remain unchanged")
	_capture("letterbox-enabled")
	swatch.color = Color.RED
	marker.position = Vector2(32,0)
	marker.size = Vector2(32,48)
	marker.color = Color.BLUE
	result = effect.configure({"shader_enabled":true,"shader_path":shader_path,"shader_parameters":{"AMOUNT":0.0}})
	await _settle()
	var nearest := root.get_texture().get_image().get_pixel(137,95)
	_check(result.ok and _close(nearest,Color(0,0,0.5,1)),"Nearest sampling retains a sharp logical red-blue boundary")
	var source_pixels := source.get_texture().get_image().get_data()
	var linear_path := fixture_directory.path_join("linear.glslp")
	_write(linear_path,"shaders = 1\nshader0 = \"invert.glsl\"\nfilter_linear0 = true\n")
	result = effect.configure({"shader_enabled":true,"shader_path":linear_path,"shader_parameters":{"AMOUNT":0.0}})
	await _settle()
	var linear := root.get_texture().get_image().get_pixel(137,95)
	_check(result.ok and _close(linear,Color(0.125,0,0.375,1)),"Linear sampling blends logical neighbors despite nearest-scaled source presentation")
	_check(source_pixels == source.get_texture().get_image().get_data(),"Logical interpolation preserves the original source framebuffer")
	_check(root.get_texture().get_image().get_pixel(5,100) == Color.BLACK,"Linear sampling leaves letterbox margins untouched")
	_capture("letterbox-linear")
	effect.set_source_region(Rect2(1,2,0,0),Vector2.ZERO)
	_check(effect._display.position == Vector2.ZERO and effect._display.size == Vector2(320,240) and effect._material.get_shader_parameter("ra_input_size") == Vector2(320,240),"Invalid regions fall back to the complete current framebuffer")
	effect.set_source_region(region,Vector2(64,48))
	effect.set_input_size(Vector2(320,240))
	_check(effect._display.position == Vector2.ZERO and effect._display.size == Vector2(320,240) and effect._material.get_shader_parameter("ra_source_uv_rect") == Vector4(0,0,1,1),"The full-frame input API clears an earlier source-region override")


func _lut_fixtures() -> String:
	_write(fixture_directory.path_join("mask.glsl"),LUT_FIXTURE)
	var mask := Image.create_empty(2,5,false,Image.FORMAT_RGB8)
	for row in 5:
		for column in 2: mask.set_pixel(column,row,LUT_ROWS[row][column])
	_check(mask.save_png(fixture_directory.path_join("mask.png")) == OK,"The asymmetric RGB mask is generated in TEMP")
	var preset := fixture_directory.path_join("mask.glslp")
	_write(preset,_lut_preset("mask.png"))
	_write(fixture_directory.path_join("missing-mask.glslp"),_lut_preset("missing-mask.png"))
	_write(fixture_directory.path_join("corrupt-mask.png"),"This is not a PNG image.")
	_write(fixture_directory.path_join("corrupt-mask.glslp"),_lut_preset("corrupt-mask.png"))
	return preset


func _lut_preset(mask_name: String) -> String:
	return "shaders = 1\nshader0 = \"mask.glsl\"\nfilter_linear0 = false\nscale_type0 = viewport\nscale0 = 1.0\nalias0 = \"PASS0\"\ntextures = \"MASK\"\nMASK = \"%s\"\nMASK_linear = false\nMASK_wrap_mode = \"repeat\"\n"%mask_name


func _lut_lifecycle(preset: String) -> void:
	var result: Dictionary = effect.configure({"shader_enabled":true,"shader_path":preset})
	if not _check(result.ok and effect.active,"A single-pass preset binds its external RGB mask: "+str(result.message)): return
	var resources: Dictionary = effect.current.get("textures",{})
	var uniform := _mask_uniform(effect.current)
	if not _check(not uniform.is_empty() and resources.get(uniform) is ImageTexture,"External mask resources are retained by the active effect"): return
	var texture: ImageTexture = resources[uniform]
	_check(effect._material.get_shader_parameter(uniform) == texture,"The imported mask reaches the production shader material")
	var decoded := texture.get_image()
	_check(decoded.get_size() == Vector2i(2,5) and _close(decoded.get_pixel(0,0),LUT_ROWS[0][0]) and _close(decoded.get_pixel(1,4),LUT_ROWS[4][1]),"PNG channels and row order survive external texture decoding")
	var previous_material: ShaderMaterial = effect._material
	var previous_path: String = effect.current.path
	for bad_name: String in ["missing-mask.glslp","corrupt-mask.glslp"]:
		result = effect.configure({"shader_enabled":true,"shader_path":fixture_directory.path_join(bad_name)})
		var preserved: Dictionary = effect.current.get("textures",{})
		_check(not result.ok and effect.active and effect._material == previous_material and effect.current.path == previous_path and preserved.get(uniform) == texture and effect._material.get_shader_parameter(uniform) == texture,"A %s replacement preserves the active material and mask resource"%bad_name)
		_check(not effect.error_message.is_empty(),"An unreadable external mask reports its import failure: "+bad_name)


func _lut_render(preset: String) -> void:
	effect.configure({"shader_enabled":false})
	root.size = Vector2i(160,100)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color8(11,19,31)
	host.add_child(background)
	var input := SubViewport.new()
	input.size = Vector2i(8,6)
	input.disable_3d = true
	input.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(input)
	var source_image := Image.create_empty(8,6,false,Image.FORMAT_RGB8)
	source_image.fill(Color.WHITE)
	var source_texture := ImageTexture.create_from_image(source_image)
	var source_rect := TextureRect.new()
	source_rect.size = Vector2(8,6)
	source_rect.texture = source_texture
	source_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	input.add_child(source_rect)
	var display := TextureRect.new()
	display.texture = input.get_texture()
	display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	host.add_child(display)
	var result: Dictionary = effect.configure({"shader_enabled":true,"shader_path":preset})
	if not _check(result.ok,"The rendered production layer enables the mask preset: "+str(result.message)):
		host.queue_free()
		await process_frame
		return
	var origin := Vector2i(13,7)
	for scale: int in [1,2,5]:
		var output := Vector2i(8,6)*scale
		display.position = Vector2(origin)
		display.size = Vector2(output)
		effect.set_source_region(Rect2(Vector2(origin),Vector2(output)),Vector2(8,6))
		await _settle()
		_check(effect._material.get_shader_parameter("ra_output_origin") == Vector2(origin),"The physical %dx mask receives its odd source-region origin"%scale)
		_check(_lut_pixels(root.get_texture().get_image(),origin,output,source_image,scale),"Every %dx output pixel matches lower-left nearest/repeat mask sampling"%scale)
		_check(_close(root.get_texture().get_image().get_pixel(0,0),background.color) and _close(root.get_texture().get_image().get_pixel(159,99),background.color),"The %dx mask leaves surrounding letterbox pixels unchanged"%scale)
		_capture("mask-%dx"%scale)
	# A patterned source ensures the mask and original source independently use
	# their own texel grids; a white source alone could conceal source corruption.
	for row in 6:
		for column in 8:
			source_image.set_pixel(column,row,Color8(32+column*27,40+row*35,55+(column+row)*13))
	source_texture.update(source_image)
	var patterned_output := Vector2i(40,30)
	display.size = Vector2(patterned_output)
	effect.set_source_region(Rect2(Vector2(origin),Vector2(patterned_output)),Vector2(8,6))
	await _settle()
	var input_before := input.get_texture().get_image().get_data()
	var masked_before := root.get_texture().get_image()
	_check(_lut_pixels(masked_before,origin,patterned_output,source_image,5),"The output mask multiplies each independently sampled logical source pixel")
	var input_image := input.get_texture().get_image()
	input_image.convert(Image.FORMAT_RGB8)
	_check(source_image.get_data() == input_image.get_data(),"External texture sampling preserves the original source pixels")
	var material_before: ShaderMaterial = effect._material
	var uniform := _mask_uniform(effect.current)
	var mask_before: ImageTexture = effect.current.textures[uniform]
	for bad_name: String in ["missing-mask.glslp","corrupt-mask.glslp"]:
		result = effect.configure({"shader_enabled":true,"shader_path":fixture_directory.path_join(bad_name)})
		await _settle()
		_check(not result.ok and effect._material == material_before and effect.current.textures[uniform] == mask_before and root.get_texture().get_image().get_data() == masked_before.get_data(),"A rendered %s replacement preserves every pixel and the loaded mask"%bad_name)
	_check(input_before == input.get_texture().get_image().get_data(),"Rejected LUT replacements preserve the original source framebuffer")
	_capture("mask-patterned-source")
	effect.configure({"shader_enabled":false})
	host.queue_free()
	await process_frame


func _lut_pixels(actual: Image,origin: Vector2i,output: Vector2i,input: Image,scale: int) -> bool:
	for row in output.y:
		# GLSL fragment pixel centers count upward from the output's bottom edge.
		var mask_row := int(floor(fposmod(float(output.y-row)-0.5,float(scale))/float(scale)*5.0))
		for column in output.x:
			var mask: Color = LUT_ROWS[mask_row][column%2]
			var source_color := input.get_pixel(int(float(column)/scale),int(float(row)/scale))
			var expected := mask*source_color
			var pixel := actual.get_pixel(origin.x+column,origin.y+row)
			if absf(pixel.r-expected.r) > 1.01/255.0 or absf(pixel.g-expected.g) > 1.01/255.0 or absf(pixel.b-expected.b) > 1.01/255.0 or absf(pixel.a-expected.a) > 1.01/255.0:
				print("Mask reference mismatch: local=(%d,%d), scale=%d, mask_row=%d, expected=%s, actual=%s"%[column,row,scale,mask_row,expected,pixel])
				return false
	return true


func _mask_uniform(imported: Dictionary) -> String:
	for descriptor: Dictionary in imported.get("texture_descriptors",[]):
		if descriptor.get("name","") == "MASK": return str(descriptor.get("uniform",""))
	return ""


func _settle() -> void:
	for ignored in 3:
		await process_frame
		await RenderingServer.frame_post_draw


func _root_pixel() -> Color:
	var image := root.get_texture().get_image()
	return image.get_pixel(int(float(image.get_width())/2.0),int(float(image.get_height())/2.0))


func _close(actual: Color,expected: Color) -> bool:
	return absf(actual.r-expected.r) <= 3.0/255.0 and absf(actual.g-expected.g) <= 3.0/255.0 and absf(actual.b-expected.b) <= 3.0/255.0 and absf(actual.a-expected.a) <= 3.0/255.0


func _capture(name: String) -> void:
	if capture_directory.is_empty(): return
	_check(root.get_texture().get_image().save_png(capture_directory.path_join(name+".png")) == OK,"Capture "+name)


func _write(path: String,value: String) -> void:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file != null: file.store_string(value)
	_check(file != null,"Temporary fixture is writable: "+path.get_file())


func _check(value: bool,message: String) -> bool:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
	return value


func _finish() -> void:
	if effect != null: effect.queue_free()
	print("Post-processing: %d checks, %d failures, %d skipped"%[checks,failures,skipped])
	quit(1 if failures else 0)
