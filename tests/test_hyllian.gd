extends SceneTree
## sRGB8 transfer, filtering and original Hyllian passes; fixtures stay in TEMP.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")
const PostProcess := preload("res://addons/retroarch_shaders/post_process.gd")
var checks := 0
var failures := 0
var skipped := 0
var fixture_dir := ""
var files: Array[String] = []
var shader_directory := ""
var capture_dir := ""
var effect: CanvasLayer
var source: SubViewport

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
	fixture_dir = temporary.path_join("fallout-hyllian-%d"%Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(fixture_dir) == OK,"Create disposable sRGB fixtures")
	if not capture_dir.is_empty():
		if not _check(DisplayServer.get_name() != "headless" and capture_dir.to_lower().begins_with(temporary.to_lower()+"/"),"Captures stay inside OS TEMP"): quit(1); return
		DirAccess.make_dir_recursive_absolute(capture_dir)
	_write("encode.glsl", '#if defined(FRAGMENT)\nvarying vec2 TEX0; void main() { if (TEX0.x > 0.5) { gl_FragColor=vec4(0.9,0.5,0.0008,0.75); } else { gl_FragColor=vec4(0.002,0.004,0.25,0.25); } }\n#endif\n')
	_write("decode.glsl", '#if defined(FRAGMENT)\nuniform sampler2D Texture; uniform sampler2D Pass1Texture; uniform sampler2D EncodedTexture; void main() { vec4 a=texture2D(Texture,vec2(0.5,0.25)); vec4 b=texture2D(Pass1Texture,vec2(0.5,0.25)); vec4 c=texture2D(EncodedTexture,vec2(0.5,0.25)); gl_FragColor=vec4(a.r,b.g,c.b,a.a); }\n#endif\n')
	var preset := _write("srgb.glslp",'shaders=2\nshader0=encode.glsl\nalias0=Encoded\nsrgb_framebuffer0=true\nscale_type0=absolute\nscale0=2\nshader1=decode.glsl\nfilter_linear1=true\n')
	var imported := Importer.load_file(preset)
	if _check(imported.ok,"sRGB intermediate targets import: "+str(imported.message)):
		_check(imported.passes[0].srgb_framebuffer and not imported.passes[1].srgb_framebuffer,"Keep sRGB encoding independent for each target")
		_check(imported.passes[0].shader.code.contains("ra_srgb_encode(COLOR.rgb)") and imported.passes[1].shader.code.contains("pixel.rgb = ra_srgb_decode(pixel.rgb)"),"Encode on write and decode individual primary/earlier/alias texels before filtering")
	var single := _write("single.glslp",'shaders=1\nshader0=encode.glsl\nsrgb_framebuffer0=true\n')
	_check(Importer.load_file(single).ok,"A one-pass sRGB preset uses an explicitly encoded target")
	var invalid := Importer.load_file(_write("invalid.glslp",'shaders=2\nshader0=encode.glsl\nshader1=decode.glsl\nsrgb_framebuffer0=sometimes\n'))
	_check(not invalid.ok and str(invalid.message).contains("Invalid preset setting"),"Invalid sRGB flags fail explicitly")
	root.size = Vector2i(320,240)
	source = SubViewport.new()
	source.size = root.size
	source.disable_3d = true
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source)
	var swatch := ColorRect.new()
	swatch.size = Vector2(root.size)
	swatch.color = Color8(80,150,200)
	source.add_child(swatch)
	var marker := ColorRect.new()
	marker.position = Vector2(20,30)
	marker.size = Vector2(60,80)
	marker.color = Color8(190,40,70)
	source.add_child(marker)
	effect = PostProcess.new()
	root.add_child(effect)
	effect.set_framebuffer_texture(source.get_texture())
	effect.set_input_size(Vector2(160,120))
	if _check(effect.configure({"shader_enabled":true,"shader_path":preset}).ok,"Production chain enables sRGB storage") and DisplayServer.get_name() != "headless":
		var stored := await _image(effect._passes[0].viewport)
		var low := _stored(Color(0.002,0.004,0.25,0.25))
		var high := _stored(Color(0.9,0.5,0.0008,0.75))
		_check(_close(stored.get_pixel(0,0),low,true) and _close(stored.get_pixel(1,0),high,true),"RGBA8 storage matches the piecewise sRGB8 transfer including dark values and unchanged alpha")
		var decoded := _decoded(low).lerp(_decoded(high),0.5)
		var output := await _image(effect._passes[1].viewport)
		_check(_close(output.get_pixel(100,80),decoded,true),"Primary, numbered and alias samplers decode before linear interpolation and preserve linear alpha")
		var frame := await _image(root)
		_check(_close(frame.get_pixel(100,80),decoded),"Presentation adds no extra gamma conversion")
	_check(effect.configure({"shader_enabled":true,"shader_path":single}).ok and effect._passes.size() == 1,"Switching to one sRGB pass rebuilds a single target")
	if DisplayServer.get_name() != "headless":
		var frame := await _image(root)
		_check(_close(frame.get_pixel(40,60),_stored(Color(0.002,0.004,0.25,0.25))),"A final sRGB pass presents encoded RGB rather than decoding it again")
	var hyllian := shader_directory.path_join("crt/crt-hyllian-multipass.glslp")
	if not shader_directory.is_empty() and FileAccess.file_exists(hyllian):
		imported = Importer.load_file(hyllian)
		if _check(imported.ok,"The exact requested Hyllian preset compiles: "+str(imported.message)):
			_check(imported.passes.size() == 2 and imported.parameters.size() == 12 and is_equal_approx(imported.values.InputGamma,2.5) and is_equal_approx(imported.values.OutputGamma,2.2),"Both original passes expose all 12 parameters with their original defaults")
			if _check(effect.configure({"shader_enabled":true,"shader_path":hyllian}).ok,"Enable the original Hyllian preset through the production display layer"):
				_check(effect._passes[0].viewport.size == Vector2i(320,120) and effect._passes[1].viewport.size == Vector2i(320,240),"Hyllian uses physical horizontal resolution and native vertical resolution in its first target")
				if DisplayServer.get_name() != "headless":
					var original := await _image(source)
					var first := await _image(effect._passes[0].viewport)
					var frame := await _image(root)
					if not capture_dir.is_empty():
						original.save_png(capture_dir.path_join("source.png"))
						first.save_png(capture_dir.path_join("hyllian-horizontal.png"))
					_check(_horizontal_matches(original,first,imported.values),"Original Hyllian cubic reconstruction and sRGB8 storage match independent CPU pixels")
					_check(_vertical_matches(first,frame,imported.values),"Original Hyllian scanline/phosphor pass matches independent CPU pixels after sRGB decoding")
					if not capture_dir.is_empty(): _check(frame.save_png(capture_dir.path_join("crt-hyllian-multipass.png")) == OK,"Capture the requested preset in OS TEMP")
	else:
		skipped += 1
		print("SKIPPED: Original Hyllian coverage requires --shader-dir=<collection> containing crt/crt-hyllian-multipass.glslp.")
	if DisplayServer.get_name() == "headless":
		skipped += 1
		print("SKIPPED: Transfer/filtering and original CPU/GPU pixel comparisons require a renderer.")
	_check(effect.configure({"shader_enabled":false}).ok and effect._passes.is_empty(),"Disabling releases the encoded targets")
	effect.queue_free()
	source.queue_free()
	await process_frame
	for path: String in files: DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(fixture_dir)
	print("Hyllian sRGB: %d checks, %d failures, %d skips"%[checks,failures,skipped])
	quit(1 if failures else 0)

func _image(viewport: Viewport) -> Image:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func _close(first: Color,second: Color,alpha: bool = false) -> bool:
	return absf(first.r-second.r) <= 2.0/255.0 and absf(first.g-second.g) <= 2.0/255.0 and absf(first.b-second.b) <= 2.0/255.0 and (not alpha or absf(first.a-second.a) <= 2.0/255.0)

func _stored(value: Color) -> Color:
	var result := value
	for channel in 3:
		var linear := clampf(value[channel],0,1)
		var encoded := linear*12.92 if linear <= 0.0031308 else 1.055*pow(linear,1.0/2.4)-0.055
		result[channel] = floorf(encoded*255.0+0.5)/255.0
	result.a = floorf(clampf(value.a,0,1)*255.0+0.5)/255.0
	return result

func _decoded(value: Color) -> Color:
	var result := value
	for channel in 3: result[channel] = value[channel]/12.92 if value[channel] <= 0.04045 else pow((value[channel]+0.055)/1.055,2.4)
	return result

func _sample(image: Image,coordinate: Vector2) -> Color:
	var location := Vector2i((coordinate*Vector2(image.get_size())).floor())
	if location.x < 0 or location.y < 0 or location.x >= image.get_width() or location.y >= image.get_height(): return Color(0,0,0,0)
	return image.get_pixelv(location)

func _horizontal_matches(input: Image,output: Image,values: Dictionary) -> bool:
	var dimensions := Vector2(160.0*values.SHARPNESS,120.0)
	# The original samples exactly on vertical texel boundaries. Stay away from
	# the fixture's top/bottom color transition where GPU rounding can choose either row.
	for point: Vector2i in [Vector2i(0,0),Vector2i(19,19),Vector2i(20,19),Vector2i(79,50),Vector2i(81,50),Vector2i(100,90),Vector2i(319,119)]:
		var pixel := (Vector2(point)+Vector2(0.5,0.5))/Vector2(output.get_size())*dimensions+Vector2(-0.5,0)
		var tc := (pixel.floor()+Vector2(0.5,0))/dimensions
		var f := fposmod(pixel.x,1.0)
		var coefficients := [-0.5*f*f*f+f*f-0.5*f,1.5*f*f*f-2.5*f*f+1,-1.5*f*f*f+2*f*f+0.5*f,0.5*f*f*f-0.5*f*f]
		var samples: Array[Color] = []
		for offset in range(-1,3):
			var color := _sample(input,tc+Vector2(float(offset)/dimensions.x,0))
			for channel in 4: color[channel] = pow(color[channel],values.InputGamma)
			samples.append(color)
		var expected := Color(0,0,0,0)
		for index in 4: expected += samples[index]*coefficients[index]
		for channel in 4:
			var clipped := clampf(expected[channel],minf(samples[1][channel],samples[2][channel]),maxf(samples[1][channel],samples[2][channel]))
			expected[channel] = lerpf(expected[channel],clipped,values.CRT_ANTI_RINGING)
		if not _close(output.get_pixelv(point),_stored(expected),true):
			print("Horizontal mismatch at %s: actual %s; expected %s"%[point,output.get_pixelv(point),_stored(expected)])
			return false
	return true

func _vertical_matches(input: Image,output: Image,values: Dictionary) -> bool:
	var dimensions := Vector2(input.get_size())
	for point: Vector2i in [Vector2i(40,60),Vector2i(75,91),Vector2i(100,30),Vector2i(200,180),Vector2i(319,239)]:
		var uv := (Vector2(point)+Vector2(0.5,0.5))/Vector2(output.get_size())
		var pixel := uv*dimensions+Vector2(0,0.5)
		var tc := (pixel.floor()+Vector2(0,0.5))/dimensions
		var first := _decoded(_sample(input,tc-Vector2(0,1.0/dimensions.y)))
		var second := _decoded(_sample(input,tc))
		var position := fposmod(pixel.y,1.0)
		var expected := Color(0,0,0,1)
		var mask_column := floori(fposmod(uv.x*output.get_width(),2.0))
		for channel in 3:
			var width0 := lerpf(values.BEAM_MIN_WIDTH,values.BEAM_MAX_WIDTH,first[channel])
			var width1 := lerpf(values.BEAM_MIN_WIDTH,values.BEAM_MAX_WIDTH,second[channel])
			var distance0 := clampf(position/(width0+0.0000001),0,1)
			var distance1 := clampf((1.0-position)/(width1+0.0000001),0,1)
			var value := clampf(first[channel]*exp(-10.0*values.SCANLINES_STRENGTH*distance0*distance0)+second[channel]*exp(-10.0*values.SCANLINES_STRENGTH*distance1*distance1),0,1)
			value *= values.COLOR_BOOST*values[["RED_BOOST","GREEN_BOOST","BLUE_BOOST"][channel]]
			var mask := 0.7 if (channel == 1 and mask_column == 0) or (channel != 1 and mask_column == 1) else 1.0
			value *= lerpf(1.0,mask,values.PHOSPHOR)
			expected[channel] = clampf(pow(value,1.0/values.OutputGamma),0,1)
		if not _close(output.get_pixelv(point),expected): return false
	return true
