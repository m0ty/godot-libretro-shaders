extends SceneTree
## Independent GPU references for signed HDR, sRGB mipmaps and temporal inputs.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")
const PostProcess := preload("res://addons/retroarch_shaders/post_process.gd")
var checks := 0
var failures := 0
var skipped := 0
var folder := ""
var files: Array[String] = []
var effect: CanvasLayer
var source: SubViewport
var swatch: ColorRect

func _init() -> void: _run.call_deferred()

func _check(value: bool, message: String) -> bool:
	checks += 1
	if not value: failures += 1; push_error(message)
	return value

func _write(name: String, text: String) -> String:
	var path := folder.path_join(name)
	var file := FileAccess.open(path,FileAccess.WRITE)
	file.store_string(text); file.close()
	files.append(path)
	return path

func _run() -> void:
	folder = OS.get_environment("TEMP").replace("\\","/").path_join("fallout-glsl-buffers-%d"%Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(folder) == OK,"Create disposable GPU fixtures")
	_write("hdr.glsl",'#if defined(FRAGMENT)\nvoid main() { gl_FragColor = vec4(-0.5,2.0,0.5,0.75); }\n#endif\n')
	_write("resolve.glsl",'#if defined(FRAGMENT)\nuniform sampler2D Texture; varying vec2 TEX0; void main() { vec4 p = texture2D(Texture,TEX0); gl_FragColor = vec4(p.r+0.5,p.g*0.25,p.b,p.a); }\n#endif\n')
	var hdr := _write("hdr.glslp",'shaders=2\nshader0=hdr.glsl\nfloat_framebuffer0=true\nshader1=resolve.glsl\n')
	_write("mip.glsl",'#if defined(FRAGMENT)\nvarying vec2 TEX0; void main() { float c = TEX0.x < 0.5 ? 0.01 : 0.81; gl_FragColor = vec4(c,c,c,TEX0.x < 0.5 ? 0.25 : 0.75); }\n#endif\n')
	_write("lod.glsl",'#if defined(FRAGMENT)\nuniform sampler2D Texture; uniform sampler2D PassPrev1Texture; uniform sampler2D EncodedTexture; void main() { vec4 a=textureLod(Texture,vec2(0.5),1.0); vec4 b=textureLod(PassPrev1Texture,vec2(0.5),1.0); vec4 c=textureLod(EncodedTexture,vec2(0.5),1.0); gl_FragColor=vec4(a.r,b.g,c.b,a.a); }\n#endif\n')
	var mip := _write("mip.glslp",'shaders=2\nshader0=mip.glsl\nalias0=Encoded\nsrgb_framebuffer0=true\nscale_type0=absolute\nscale0=2\nshader1=lod.glsl\nmipmap_input1=true\nfilter_linear1=true\n')
	_write("history.glsl",'#if defined(FRAGMENT)\nuniform sampler2D Texture; uniform sampler2D PrevTexture; uniform sampler2D Prev1Texture; void main() { gl_FragColor=vec4(texture2D(Texture,vec2(0.5)).g,texture2D(PrevTexture,vec2(0.5)).r,texture2D(Prev1Texture,vec2(0.5)).r,1.0); }\n#endif\n')
	var history := _write("history.glslp",'shaders=1\nshader0=history.glsl\n')
	_write("feedback.glsl",'#if defined(FRAGMENT)\nuniform sampler2D FeedbackTexture; void main() { gl_FragColor=vec4(texture2D(FeedbackTexture,vec2(0.5)).r+0.125,0.0,0.0,1.0); }\n#endif\n')
	var feedback := _write("feedback.glslp",'shaders=1\nshader0=feedback.glsl\nfeedback_pass=0\nfloat_framebuffer0=true\n')
	for path: String in [hdr,mip,history,feedback]:
		var loaded := Importer.load_file(path)
		_check(loaded.ok and loaded.get("drawable",false),"Advanced fixture imports: "+path.get_file()+" "+str(loaded.message))
	var modulo := _write("modulo.glslp",'shaders=1\nshader0=hdr.glsl\nfloat_framebuffer0=true\nframe_count_mod0=3\n')
	var parsed := Importer.load_file(modulo)
	_check(parsed.ok and parsed.passes[0].frame_count_mod == 3,"Keep per-pass frame-count modulus")
	_check(not Importer.load_file(_write("bad-modulo.glslp",'shaders=2\nshader0=hdr.glsl\nshader1=resolve.glsl\nframe_count_mod0=-1\n')).ok,"Reject invalid frame moduli")
	var budget := PostProcess.new()
	root.add_child(budget)
	budget.input_size = Vector2(640,480)
	var sizing := {"type_x":"absolute","type_y":"absolute","scale_x":4096.0,"scale_y":4096.0}
	var target := {"index":0,"sizing":sizing,"advanced":true,"float_framebuffer":true}
	_check(budget._chain_sizes([target]).ok and not budget._chain_sizes([target],0).ok,"Allocation budget includes the separate feedback snapshot")
	budget.free()
	if DisplayServer.get_name() == "headless":
		skipped += 1
		print("SKIP: HDR/mipmap/temporal pixels require a rendered display")
	else:
		root.size = Vector2i(320,240)
		source = SubViewport.new()
		source.disable_3d = true
		source.size = root.size
		source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(source)
		swatch = ColorRect.new()
		swatch.size = Vector2(root.size)
		swatch.color = Color.RED
		source.add_child(swatch)
		effect = PostProcess.new()
		effect.performance_counters = true
		root.add_child(effect)
		effect.set_framebuffer_texture(source.get_texture())
		effect.set_input_size(Vector2(160,120))
		if _check(effect.configure({"shader_enabled":true,"shader_path":hdr}).ok,"Enable HDR chain"):
			await _warm()
			var stored: Image = effect._passes[0].viewport.get_texture().get_image()
			_check(_close(stored.get_pixel(30,30),Color(-0.5,2.0,0.5,0.75)),"HDR storage preserves negatives, above-one values and alpha")
			var resolved: Image = effect._passes[1].viewport.get_texture().get_image()
			_check(_close(resolved.get_pixel(30,30),Color(0.0,0.5,0.5,0.75)),"Later passes read the HDR values without clipping or gamma conversion")
		if _check(effect.configure({"shader_enabled":true,"shader_path":mip}).ok,"Enable mipmapped sRGB chain"):
			await _warm()
			var output: Image = effect._passes[1].viewport.get_texture().get_image()
			_check(_close(output.get_pixel(30,30),Color(0.41,0.41,0.41,0.5)),"LOD reads primary, relative-pass and alias inputs; sRGB averages in linear light and alpha stays linear")
		if _check(effect.configure({"shader_enabled":true,"shader_path":history}).ok,"Enable original-frame history"):
			await _warm()
			swatch.color = Color.GREEN
			await _step()
			_check(_close(effect._drawable.history[0].get_image().get_pixel(30,30),Color.GREEN),"Newest snapshot contains the new composed frame")
			_check(_close(effect._drawable.history[1].get_image().get_pixel(30,30),Color.RED),"Previous snapshot remains the preceding original frame")
			await _step()
			_check(_close(effect._passes[0].viewport.get_texture().get_image().get_pixel(30,30),Color.WHITE),"Temporal shader reads current green and two prior red originals in order")
			await _step()
			_check(_close(effect._passes[0].viewport.get_texture().get_image().get_pixel(30,30),Color.MAGENTA),"History advances exactly one original frame per presentation")
		if _check(effect.configure({"shader_enabled":true,"shader_path":feedback}).ok,"Enable feedback ping-pong"):
			await _step()
			var previous: float = effect._passes[0].viewport.get_texture().get_image().get_pixel(30,30).r
			await _step()
			var next: float = effect._passes[0].viewport.get_texture().get_image().get_pixel(30,30).r
			_check(absf(next-previous-0.125) < 0.002,"Feedback reads only the preceding completed pass output")
			await _warm()
			_check(effect._passes[0].viewport.get_texture().get_image().get_pixel(30,30).r > 1.0,"Feedback float values survive accumulation above one")
			var layouts: int = effect.performance_stats.layout_updates
			var before_failure: float = effect._passes[0].viewport.get_texture().get_image().get_pixel(30,30).r
			var old_chain: Node = effect._chain
			_check(not effect.configure({"shader_enabled":true,"shader_path":folder.path_join("missing.glslp")}).ok and effect._chain == old_chain,"Failed replacement preserves the active advanced chain")
			await _warm()
			_check(effect._passes[0].viewport.get_texture().get_image().get_pixel(30,30).r > before_failure and effect.performance_stats.layout_updates == layouts,"Failed replacement continues feedback without repeating static bindings")
			effect.set_input_size(Vector2(100000,100000))
			_check(not effect._display.visible,"Oversized runtime layout disables the chain before allocation")
			effect.set_input_size(Vector2(80,60))
			_check(effect._display.visible and effect.error_message.is_empty(),"Valid layout recovers after an oversized runtime input")
			_check(effect._drawable.logical_size == Vector2i(80,60) and _close(effect._drawable.feedback.get_image().get_pixel(30,30),Color.TRANSPARENT),"Resizing resets feedback and history to transparent frames")
		_check(effect.configure({"shader_enabled":false}).ok and effect._drawable == null and effect._passes.is_empty(),"Disabling releases every advanced texture and pass")
		effect.queue_free(); source.queue_free()
		await process_frame
	for path: String in files: DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(folder)
	print("GLSL buffers: %d checks, %d failures, %d skips"%[checks,failures,skipped])
	quit(1 if failures else 0)

func _step() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

func _warm() -> void:
	for frame in 9: await _step()

func _close(a: Color,b: Color) -> bool:
	for channel in 4:
		if absf(a[channel]-b[channel]) > 0.012: return false
	return true
