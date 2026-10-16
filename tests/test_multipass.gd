extends SceneTree
## Disposable presets and current-frame GPU comparisons; original shaders stay read-only.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")
const PostProcess := preload("res://addons/retroarch_shaders/post_process.gd")
var checks := 0
var failures := 0
var skipped := 0
var fixture_dir := ""
var shader_directory := ""
var capture_dir := ""
var effect: CanvasLayer
var source: SubViewport
var files: Array[String] = []

func _init() -> void: _run.call_deferred()

func _check(value: bool,message: String) -> bool:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
	return value

func _write(name: String,text: String) -> String:
	var path := fixture_dir.path_join(name)
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(text)
	file.close()
	files.append(path)
	return path

func _run() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--shader-dir="): shader_directory = argument.trim_prefix("--shader-dir=").replace("\\","/").simplify_path()
		if argument.begins_with("--capture-dir="): capture_dir = argument.trim_prefix("--capture-dir=").replace("\\","/").simplify_path()
	var temporary := OS.get_environment("TEMP").replace("\\","/").simplify_path()
	fixture_dir = temporary.path_join("fallout-multipass-%d"%Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(fixture_dir) == OK,"Create disposable multipass fixtures")
	if not capture_dir.is_empty():
		if not _check(DisplayServer.get_name() != "headless" and capture_dir.to_lower().begins_with(temporary.to_lower()+"/"),"Captures stay in OS TEMP"): quit(1); return
		DirAccess.make_dir_recursive_absolute(capture_dir)
	var first := _write("gain.glsl", '#pragma parameter GAIN "Gain" 0.5 0.0 1.0 0.1\n#if defined(FRAGMENT)\nuniform sampler2D Texture; uniform float GAIN; varying vec2 TEX0; void main() { gl_FragColor = vec4(texture2D(Texture,TEX0).rgb * GAIN, 1.0); }\n#endif\n')
	_write("combine.glsl", '#if defined(FRAGMENT)\nuniform sampler2D Texture; uniform sampler2D OrigTexture; uniform sampler2D FirstTexture; uniform sampler2D Pass1Texture; uniform vec2 OrigInputSize; uniform vec2 FirstTextureSize; uniform vec2 InputSize; uniform vec2 OutputSize; varying vec2 TEX0; void main() { gl_FragColor = vec4(texture2D(Texture,TEX0).r, texture2D(OrigTexture,TEX0).g, (texture2D(FirstTexture,TEX0).b + texture2D(Pass1Texture,TEX0).b) * 0.5, 1.0); }\n#endif\n')
	var preset := _write("two.glslp", 'shaders=2\nshader0=gain.glsl\nalias0=First\nscale_type0=source\nscale0=2\nshader1=combine.glsl\nscale_type1=viewport\nfilter_linear1=true\nparameters=GAIN\nGAIN=0.5\n')
	var result := Importer.load_file(preset)
	_check(result.ok and result.passes.size() == 2 and result.values.get("GAIN") == 0.5,"Compile two real passes with shared parameters, an alias and original input")
	if result.ok:
		_check(result.passes[0].sizing.type_x == "source" and result.passes[0].sizing.scale_x == 2.0 and result.passes[1].sizing.type_x == "viewport","Keep intermediate source scaling and final viewport output separate")
		_check(not result.passes[0].shader.code.contains("hint_screen_texture") and result.passes[1].shader.code.contains("ra_orig_size"),"Chain passes use explicitly bound current-frame textures and original dimensions")
	for entry in [
		["sizing",'shaders=2\nshader0=gain.glsl\nshader1=gain.glsl\nscale_type_x0=unknown\n',"sizing"],
		["duplicate",'shaders=2\nshader0=gain.glsl\nshader1=gain.glsl\nalias0=First\nalias1=First\n',"alias"],
		["future",'shaders=2\nshader0=combine.glsl\nshader1=gain.glsl\nalias1=First\n',"additional texture"],
		["missing",'shaders=2\nshader0=gain.glsl\nshader1=missing.glsl\n',"Cannot read"],
	]:
		var failed := Importer.load_file(_write(entry[0]+".glslp",entry[1]))
		_check(not failed.ok and str(failed.message).contains(entry[2]),"Unsupported %s dependency fails explicitly"%entry[0])
	root.size = Vector2i(320,240)
	source = SubViewport.new()
	source.size = Vector2i(320,240)
	source.disable_3d = true
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source)
	var swatch := ColorRect.new()
	swatch.size = Vector2(320,240)
	swatch.color = Color8(160,104,80)
	source.add_child(swatch)
	var marker := ColorRect.new()
	marker.position = Vector2(20,30)
	marker.size = Vector2(60,80)
	marker.color = Color8(40,210,180)
	source.add_child(marker)
	var display := TextureRect.new()
	display.size = Vector2(320,240)
	display.texture = source.get_texture()
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(display)
	effect = PostProcess.new()
	root.add_child(effect)
	effect.set_framebuffer_texture(source.get_texture())
	effect.set_input_size(Vector2(160,120))
	_check(effect.configure({"shader_enabled":true,"shader_path":preset}).ok,"Production display layer enables a two-pass chain")
	_check(effect._passes.size() == 2 and effect._passes[0].viewport.size == Vector2i(320,240) and effect._passes[1].viewport.size == Vector2i(320,240),"GPU target sizes follow the preset")
	if DisplayServer.get_name() != "headless":
		var frame := await _image(root)
		_check(_close(frame.get_pixel(200,180),Color8(80,104,40)),"Final pixels combine prior-pass red/blue with unmodified original green")
		_check(_close(frame.get_pixel(40,60),Color8(20,210,90)),"Original and alias samplers retain asymmetric image orientation and detail")
		swatch.color = Color8(80,50,160)
		frame = await _image(root)
		_check(_close(frame.get_pixel(200,180),Color8(40,50,80)),"Changing the current source updates every stage without feedback or stale original input")
	root.size = Vector2i(500,300)
	source.size = root.size
	swatch.size = Vector2(root.size)
	display.size = Vector2(root.size)
	effect.set_source_region(Rect2(40,20,400,260),Vector2(80,60))
	_check(effect._passes[0].viewport.size == Vector2i(160,120) and effect._passes[1].viewport.size == Vector2i(400,260),"Live source and viewport targets resize independently for a cropped presentation")
	_check(effect._passes[1].material.get_shader_parameter("ra_orig_size") == Vector2(80,60) and effect._passes[1].material.get_shader_parameter("ra_input_size") == Vector2(160,120),"Original and previous-pass dimensions remain distinct after resizing")
	if DisplayServer.get_name() != "headless":
		var frame := await _image(root)
		_check(_close(frame.get_pixel(300,200),Color8(40,50,80)),"Resized, offset output preserves original/earlier-pass sampling without feedback")
	root.size = Vector2i(320,240)
	source.size = root.size
	swatch.size = Vector2(root.size)
	display.size = Vector2(root.size)
	effect.set_input_size(Vector2(160,120))
	var old_chain: Node = effect._chain
	var oversized := _write("oversized.glslp",'shaders=2\nshader0=gain.glsl\nscale_type0=absolute\nscale0=100000\nshader1=gain.glsl\n')
	_check(not effect.configure({"shader_enabled":true,"shader_path":oversized}).ok and effect._chain == old_chain and effect.active,"Oversized targets fail transactionally and preserve the live chain")
	_check(not effect.configure({"shader_enabled":true,"shader_path":fixture_dir.path_join("missing.glslp")}).ok and effect._chain == old_chain,"Missing replacement preserves every live pass")
	_check(effect.configure({"shader_enabled":true,"shader_path":first}).ok and effect._passes.is_empty() and effect._chain == null,"Switching back to one pass releases all intermediate targets")
	var halation := shader_directory.path_join("crt/crt-interlaced-halation.glslp")
	if not shader_directory.is_empty() and FileAccess.file_exists(halation):
		result = Importer.load_file(halation)
		if _check(result.ok,"The exact installed four-pass halation preset compiles: "+str(result.message)):
			_check(result.passes.size() == 4,"Keep both blur passes, CRT composition and final Quilez scaling")
			_check(effect.configure({"shader_enabled":true,"shader_path":halation}).ok,"The exact requested preset enables through the production layer")
			effect.set_process(false)
			effect.frame_count = 42
			effect._update_uniforms()
			_check(effect._passes[0].viewport.size == Vector2i(160,120) and effect._passes[1].viewport.size == Vector2i(160,120) and effect._passes[2].viewport.size == Vector2i(480,360) and effect._passes[3].viewport.size == Vector2i(320,240),"Halation respects native blur sizes, 3x CRT oversampling and physical final output")
			if DisplayServer.get_name() != "headless":
				var original := await _image(source)
				var vertical := await _image(effect._passes[0].viewport)
				var horizontal := await _image(effect._passes[1].viewport)
				_check(_blur_matches(original,vertical,true,2.5,Vector2i(160,120)),"Original vertical gamma blur matches independent CPU reference pixels")
				_check(_blur_matches(vertical,horizontal,false,2.2,Vector2i(160,120)),"Original horizontal gamma blur matches independent CPU reference pixels")
				var frame := await _image(root)
				var crt := await _image(effect._passes[2].viewport)
				_check(_quilez_matches(crt,frame),"Final Quilez pass matches independent interpolation of the 3x CRT result")
				_check(frame.get_pixel(200,180).r > 0.02 and not _close(frame.get_pixel(200,180),original.get_pixel(200,180)),"Four-pass CRT shader visibly changes the completed output")
				if not capture_dir.is_empty(): _check(frame.save_png(capture_dir.path_join("crt-interlaced-halation.png")) == OK,"Capture requested shader in TEMP")
	else:
		skipped += 1
		print("SKIPPED: Original halation coverage requires --shader-dir=<collection> containing crt/crt-interlaced-halation.glslp.")
	if DisplayServer.get_name() == "headless":
		skipped += 1
		print("SKIPPED: Current-frame pixels and CPU/GPU comparisons require a renderer.")
	_check(effect.configure({"shader_enabled":false}).ok and effect._chain == null and effect._passes.is_empty(),"Disabling releases all passes and stops their rendering")
	effect.queue_free()
	source.queue_free()
	display.queue_free()
	await process_frame
	for path: String in files: DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(fixture_dir)
	print("Multipass shaders: %d checks, %d failures, %d skips"%[checks,failures,skipped])
	quit(1 if failures else 0)

func _image(viewport: Viewport) -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func _close(first: Color,second: Color) -> bool:
	return absf(first.r-second.r) <= 2.0/255.0 and absf(first.g-second.g) <= 2.0/255.0 and absf(first.b-second.b) <= 2.0/255.0

func _blur_matches(input: Image,output: Image,vertical: bool,gamma: float,logical: Vector2i) -> bool:
	var tested := 0
	var norm := 0.0
	for offset in range(-4,5): norm += exp(-float(offset*offset)/4.0)
	for point: Vector2i in [Vector2i(0,0),Vector2i(10,15),Vector2i(9,19),Vector2i(39,54),Vector2i(42,54),Vector2i(100,90),Vector2i(159,119)]:
		var expected := Vector3.ZERO
		for offset in range(-4,5):
			var location := point+Vector2i(0,offset) if vertical else point+Vector2i(offset,0)
			if location.x < 0 or location.y < 0 or location.x >= logical.x or location.y >= logical.y: continue
			var pixel := input.get_pixelv(Vector2i((Vector2(location)+Vector2(0.5,0.5))*Vector2(input.get_size())/Vector2(logical)))
			expected += Vector3(pow(pixel.r,gamma),pow(pixel.g,gamma),pow(pixel.b,gamma))*exp(-float(offset*offset)/4.0)/norm
		var reference := Color(pow(expected.x,1.0/2.2),pow(expected.y,1.0/2.2),pow(expected.z,1.0/2.2))
		if not _close(output.get_pixelv(point),reference): return false
		tested += 1
	return tested == 7

func _quilez_matches(input: Image,output: Image) -> bool:
	var dimensions := Vector2(input.get_size())
	for point: Vector2i in [Vector2i(40,60),Vector2i(75,90),Vector2i(100,30),Vector2i(200,180)]:
		var coordinate := (Vector2(point)+Vector2(0.5,0.5))/Vector2(output.get_size())*dimensions+Vector2(0.5,0.5)
		var base := coordinate.floor()
		var fraction := coordinate-base
		fraction = fraction*fraction*fraction*(fraction*(fraction*6.0-Vector2(15,15))+Vector2(10,10))
		var texel := base+fraction-Vector2.ONE
		base = texel.floor()
		fraction = texel-base
		var color := Color(0,0,0,0)
		for y in 2:
			for x in 2:
				var location := Vector2i(base)+Vector2i(x,y)
				if location.x < 0 or location.y < 0 or location.x >= input.get_width() or location.y >= input.get_height(): continue
				color += input.get_pixelv(location)*(fraction.x if x else 1.0-fraction.x)*(fraction.y if y else 1.0-fraction.y)
		if not _close(output.get_pixelv(point),color): return false
	return true
