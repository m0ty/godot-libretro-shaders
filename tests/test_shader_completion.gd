extends SceneTree
## GPU regressions for the final collection translation and dependency gaps.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")
const Profiles := preload("res://addons/retroarch_shaders/source_profiles.gd")
const PostProcess := preload("res://addons/retroarch_shaders/post_process.gd")
var checks := 0
var failures := 0
var folder := ""
var files: Array[String] = []
var effect: CanvasLayer
var pattern: Image

func _init(): _run.call_deferred()

func _check(value: bool, message: String) -> bool:
	checks += 1
	if not value: failures += 1; push_error(message)
	return value

func _write(name: String, code: String) -> String:
	var path := folder.path_join(name)
	FileAccess.open(path,FileAccess.WRITE).store_string(code)
	files.append(path)
	return path

func _shader(name: String, body: String, declarations: String = "") -> String:
	return _write(name+".glsl","#if defined(FRAGMENT)\n"+declarations+"\nvoid main() { "+body+" }\n#endif\n")

func _run():
	folder = OS.get_environment("TEMP").replace("\\","/").path_join("shader-completion-%d"%Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(folder) == OK,"Create isolated shader fixtures")
	var fixtures := [
		[_shader("scientific","gl_FragColor=vec4(1e-1+1e-1,1E-1-1e-2,3.0*float (2)/10.0,1.0);"),Color(0.2,0.09,0.6,1)],
		[_shader("vector-tail","vec3 a=vec3(0.2,0.4,vec2(0.6,0.8)); vec3 b=vec3(vec2(0.2,0.4),vec2(0.6,0.8)); int k=2; vec2 c=vec2(int(k/2),0.25); gl_FragColor=vec4((a+b)*0.5*c.x,1.0);"),Color(0.2,0.4,0.6,1)],
		[_shader("mixed-matrices","mat2 m=mat2(next(),0.25,0.75); mat3 n=mat3(1.,0.,0.,0.,1.,0.,vec3(0.2,0.4,0.6)); gl_FragColor=vec4(m[0]*0.2,count*0.5+n[2].x*0.5,1.0);","float count=0.0; vec2 next() { ++count; return vec2(count,count+0.5); }"),Color(0.2,0.3,0.6,1)],
		[_shader("runtime-array","gl_FragColor=vec4(domain[0],domain[1],domain[2],1.0);","#pragma parameter GAIN \"Gain\" 0.5 0.0 1.0 0.01\nuniform float GAIN; float sigma=GAIN*GAIN; float domain[3]=float[3](sigma,\nsigma+0.1,sigma+0.2);"),Color(0.25,0.35,0.45,1)],
		[_shader("comma-reads","d,d1,d2=0.6; gl_FragColor=vec4(d,d1,d2,1.0);","float d,d1,d2;"),Color(0,0,0.6,1)],
		[_shader("light","gl_FragColor=vec4(light(vec3(0.2,0.4,0.6)),1.0);","vec3 light(vec3 color) { return color; }"),Color(0.2,0.4,0.6,1)],
		[_shader("mix-coercion","gl_FragColor=vec4(mix(ivec3(0),vec3(0.4,0.8,1.0),0.5),1.0);"),Color(0.2,0.4,0.5,1)],
	]
	for fixture: Array in fixtures:
		var loaded := Importer.load_file(fixture[0])
		_check(loaded.ok,"Translate "+str(fixture[0])+": "+loaded.message)
	var helper := _shader("helper","gl_FragColor=texture2D(OrigTexture,vec2(0.5));","uniform sampler2D OrigTexture;")
	var stock := _shader("stock","gl_FragColor=vec4(0.2,0.4,0.6,1.0);")
	var parent := _write("parent.glslp","shaders=2\nshader0=stock.glsl\nshader1=helper.glsl\n")
	_write("unrelated.glslp","shaders=1\nshader0=stock.glsl\nshader1=helper.glsl\n")
	var required := Importer.load_file(helper)
	_check(not required.ok and required.get("preset_candidates",[]) == [parent],"Dependency error offers only presets referencing the exact source")
	_check(Importer.find_presets(helper,folder) == [parent],"Explicit collection search finds the helper's parent")
	_check(Importer.find_presets(helper.replace("/","\\"),folder.replace("/","\\")) == [parent],"Windows path separators find the same exact preset reference")
	_check(Importer.load_file(parent).ok,"Parent preset supplies the helper's original-frame dependency")
	var box_path: String = get_script().resource_path.get_base_dir().path_join("fixtures/retroarch_box_center.glsl")
	var box_text := FileAccess.get_file_as_string(box_path)
	_check(not Profiles.get_profile(box_text).is_empty(),"Box-center repair matches the complete known upstream source")
	_check(Profiles.get_profile(box_text+"\n").is_empty(),"Changed shader content does not receive an upstream repair")
	_check(Profiles.get_profile(box_text.replace("\r\n","\n").replace("\n","\r\n")).size() > 0,"Repair fingerprints normalize newline style")
	var box := Importer.load_file(box_path)
	_check(box.ok and box.warnings.size() == 1,"Box-center imports with an explicit repair warning")
	if DisplayServer.get_name() != "headless":
		_setup()
		for fixture: Array in fixtures:
			if await _enable(fixture[0]): _check(_close(_pixel(160,120),fixture[1]),"GPU values: "+str(fixture[0]).get_file())
		if await _enable(fixtures[3][0],{"GAIN":0.6}): _check(_close(_pixel(160,120),Color(0.36,0.46,0.56,1)),"Runtime array initializer responds to parameter edits")
		if await _enable(stock):
			var previous: Dictionary = effect.current
			var failed: Dictionary = effect.configure({"shader_enabled":true,"shader_path":helper})
			_check(not failed.ok and failed.get("preset_candidates",[]) == [parent] and effect.current == previous,"Dependency suggestions preserve the active GPU effect")
		if await _enable(parent): _check(_close(_pixel(160,120),pattern.get_pixel(4,2)),"Selecting the parent renders the original-frame helper correctly")
		if await _enable(box_path):
			_check(_close(_pixel(160,120),pattern.get_pixel(4,2)),"Box-center preserves the center at one source texel per output pixel")
			_check(_close(_pixel(0,0),Color.BLACK) and _close(_pixel(319,239),Color.BLACK),"Box-center clips transformed coordinates outside the input rectangle")
		for name: String in ["retroarch_box.glsl","retroarch_box_max.glsl"]:
			var path: String = box_path.get_base_dir().path_join(name)
			var loaded := Importer.load_file(path)
			_check(loaded.ok and loaded.warnings.size() == 1,"Known auto-box variant receives its own fingerprint-scoped repair")
			if await _enable(path): _check(_close(_pixel(160,120),pattern.get_pixel(4,2)),"Auto-box variant retains the centered source image")
		effect.configure({"shader_enabled":false})
		await process_frame
	for path: String in files: DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(folder)
	print("Shader completion: %d checks, %d failures"%[checks,failures])
	quit(0 if failures == 0 else 1)

func _setup():
	root.size = Vector2i(320,240)
	pattern = Image.create(8,4,false,Image.FORMAT_RGBA8)
	for y in 4:
		for x in 8: pattern.set_pixel(x,y,Color(float(x)/7.0,float(y)/3.0,0.6,1))
	var source := SubViewport.new()
	source.size = Vector2i(320,240)
	source.disable_3d = true
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source)
	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(pattern)
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.size = Vector2(320,240)
	source.add_child(rect)
	var display := TextureRect.new()
	display.texture = source.get_texture()
	display.size = Vector2(320,240)
	root.add_child(display)
	effect = PostProcess.new()
	root.add_child(effect)
	effect.set_framebuffer_texture(source.get_texture())
	effect.set_input_size(Vector2(8,4))

func _enable(path: String, values: Dictionary = {}) -> bool:
	var result: Dictionary = effect.configure({"shader_enabled":true,"shader_path":path,"shader_parameters":values})
	if not _check(result.ok,"Enable "+path.get_file()+": "+result.message): return false
	for frame in 12: await process_frame
	await RenderingServer.frame_post_draw
	return true

func _pixel(x: int,y: int) -> Color: return root.get_texture().get_image().get_pixel(x,y)

func _close(a: Color,b: Color) -> bool:
	var close := absf(a.r-b.r) < 0.015 and absf(a.g-b.g) < 0.015 and absf(a.b-b.b) < 0.015
	if not close: print("Pixel mismatch: ",a," expected ",b)
	return close
