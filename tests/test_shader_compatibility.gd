extends SceneTree
## Pixel regressions for sized presets, relative originals and offset lookups.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")
const PostProcess := preload("res://addons/retroarch_shaders/post_process.gd")
var checks := 0
var failures := 0
var folder := ""
var files: Array[String] = []
var effect: CanvasLayer
var source: SubViewport
var pattern: Image

func _init() -> void: _run.call_deferred()

func _check(value: bool, message: String) -> bool:
	checks += 1
	if not value:
		failures += 1
		push_error(message)
	return value

func _write(name: String, content: String) -> String:
	var path := folder.path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	files.append(path)
	return path

func _shader(name: String, expression: String, declarations: String = "") -> String:
	return _write(name+".glsl", "#if defined(FRAGMENT)\nuniform sampler2D Texture; varying vec2 TEX0; "+declarations+"\nvoid main() { gl_FragColor = "+expression+"; }\n#endif\n")

func _run() -> void:
	folder = OS.get_environment("TEMP").replace("\\", "/").path_join("godot-shader-compatibility-%d"%Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(folder) == OK, "Create isolated shader fixtures")
	var stock := _shader("stock", "texture2D(Texture,TEX0)")
	var parameter_presets := _parameter_checks()
	var sized := _write("sized.glslp", "shaders=1\nshader0=stock.glsl\nscale_type_x0=source\nscale_x0=2\nscale_type_y0=absolute\nscale_y0=6\nframe_count_mod0=2.0\n")
	var loaded := Importer.load_file(sized)
	_check(loaded.ok and loaded.passes[0].frame_count_mod == 2, "Single-pass sizing and integer-valued decimal moduli import")
	for value: String in ["-1", "1.5", "NaN", "INF", "2147483648", "1e50"]:
		_check(not Importer.load_file(_write("invalid-mod.glslp", "shaders=1\nshader0=stock.glsl\nframe_count_mod0="+value+"\n")).ok, "Reject invalid modulus "+value)
	var offset := _shader("offset", "textureOffset(Texture,TEX0,ivec2(1,0))")
	_shader("linear", "textureOffset(Texture,vec2(0.0,0.375),ivec2(1,0),-20.0)")
	var linear_preset := _write("linear.glslp", "shaders=1\nshader0=linear.glsl\nfilter_linear0=true\nwrap_mode0=clamp_to_border\n")
	_shader("border", "textureOffset(Texture,vec2(0.0,0.375),ivec2(0),-20.0)")
	var border_preset := _write("border.glslp", "shaders=1\nshader0=border.glsl\nfilter_linear0=true\nwrap_mode0=clamp_to_border\n")
	_shader("gain", "texture2D(Texture,TEX0)*0.5")
	_shader("relative", "vec4(textureOffset(Pass1Texture,TEX0,ivec2(1,0)).r,textureOffset(PassPrev2Texture,TEX0,ivec2(0,1)).g,PassPrev2InputSize.x/16.0,1.0)", "uniform sampler2D Pass1Texture; uniform sampler2D PassPrev2Texture; uniform vec2 PassPrev2InputSize;")
	var relative := _write("relative.glslp", "shaders=2\nshader0=gain.glsl\nshader1=relative.glsl\n")
	var mip := _shader("mip", "(textureLodOffset(Texture,vec2(0.125,0.25),1.0,ivec2(1,0))+texelFetchOffset(Texture,ivec2(0),1,ivec2(1,0)))*0.5")
	_shader("mip-alias", "(textureLodOffset(FirstTexture,vec2(0.125,0.25),1.0,ivec2(1,0))+texelFetchOffset(PassPrev1Texture,ivec2(0),1,ivec2(1,0)))*0.5", "uniform sampler2D FirstTexture; uniform sampler2D PassPrev1Texture;")
	var mip_alias := _write("mip-alias.glslp", "shaders=2\nshader0=stock.glsl\nscale_type0=source\nscale0=1\nalias0=First\nshader1=mip-alias.glsl\nmipmap_input1=true\n")
	_shader("implicit", "textureOffset(Texture,TEX0,ivec2(1,0))")
	var implicit_preset := _write("implicit.glslp", "shaders=1\nshader0=implicit.glsl\nmipmap_input0=true\nscale_type0=absolute\nscale_x0=4\nscale_y0=2\n")
	_shader("trilinear", "textureLodOffset(Texture,vec2(0.125,0.25),0.5,ivec2(1,0))")
	var trilinear_preset := _write("trilinear.glslp", "shaders=1\nshader0=trilinear.glsl\nmipmap_input0=true\nfilter_linear0=true\n")
	var history := _shader("history-lod", "textureLodOffset(PrevTexture,vec2(0.125,0.25),1.0,ivec2(1,0))", "uniform sampler2D PrevTexture;")
	_shader("feedback-lod", "textureLodOffset(FeedbackTexture,vec2(0.125,0.25),1.0,ivec2(1,0))", "uniform sampler2D FeedbackTexture;")
	var feedback := _write("feedback-lod.glslp", "shaders=2\nshader0=stock.glsl\nfloat_framebuffer0=true\nshader1=feedback-lod.glsl\nfeedback_pass=0\n")
	pattern = Image.create(8,4,false,Image.FORMAT_RGBA8)
	for y in 4:
		for x in 8: pattern.set_pixel(x,y,Color(float(x)/7.0,float(y)/3.0,float((x+y)%2),1.0))
	var image_path := folder.path_join("lut.png")
	pattern.save_png(image_path)
	files.append(image_path)
	_remaining_config_checks()
	_shader("lut", "textureOffset(LUT,vec2(0.9375,0.375),ivec2(1,0))", "uniform sampler2D LUT;")
	var lut := _write("lut.glslp", "shaders=1\nshader0=lut.glsl\ntextures=LUT\nLUT=lut.png\nLUT_linear=false\nLUT_wrap_mode=repeat\n")
	_shader("lut-mip", "(textureLodOffset(LUT,vec2(0.125,0.25),1.0,ivec2(-1,0))+texelFetchOffset(LUT,ivec2(0),1,ivec2(-1,0)))*0.5", "uniform sampler2D LUT;")
	var lut_mip := _write("lut-mip.glslp", "shaders=1\nshader0=lut-mip.glsl\ntextures=LUT\nLUT=lut.png\nLUT_linear=false\nLUT_mipmap=true\nLUT_wrap_mode=repeat\n")
	for path: String in [offset,linear_preset,border_preset,relative,mip,mip_alias,implicit_preset,trilinear_preset,history,feedback,lut,lut_mip]:
		loaded = Importer.load_file(path)
		_check(loaded.ok, "Offset fixture imports: %s: %s"%[path.get_file(),loaded.message])
	if DisplayServer.get_name() != "headless":
		_setup()
		await _remaining_pixels()
		if await _enable(parameter_presets.single):
			_check(_close(_pixel(2,1),pattern.get_pixel(2,1)*0.4), "Whitespace and stale preset metadata retain the active parameter's pixels")
		if await _enable(parameter_presets.shared):
			_check(_close(_pixel(2,1),pattern.get_pixel(2,1)*0.5625), "Last shared default reaches both GPU passes")
		if await _enable(parameter_presets.overridden):
			_check(_close(_pixel(2,1),pattern.get_pixel(2,1)*0.64), "Preset override reaches both passes despite different declared bounds")
		if _check(effect.configure({"shader_enabled":true,"shader_path":parameter_presets.shared,"shader_parameters":{"GAIN":0.4}}).ok, "Explicit edit enables a shared parameter"):
			for frame in 12:
				await process_frame
				await RenderingServer.frame_post_draw
			_check(_close(_pixel(2,1),pattern.get_pixel(2,1)*0.16), "Explicit edit updates both GPU passes")
			var previous: Node = effect._chain
			_check(not effect.configure({"shader_enabled":true,"shader_path":parameter_presets.single,"shader_parameters":{"OLD_GAIN":0.9}}).ok and effect._chain == previous and effect.current.values.GAIN == 0.4, "Unknown explicit edit preserves the active chain and committed values")
		if await _enable(sized):
			_check(effect._passes[0].viewport.size == Vector2i(16,6), "Sized single-pass allocates independent axis dimensions")
			effect.set_process(false)
			effect.frame_count = 5
			effect._update_uniforms()
			_check(effect._passes[0].material.get_shader_parameter("ra_frame_count") == 1, "Decimal modulus wraps the running pass counter")
			effect.set_process(true)
		if await _enable(offset):
			_check(_close(_pixel(2,1),pattern.get_pixel(3,1)), "Offsets use logical texels inside an enlarged, cropped framebuffer")
		if await _enable(linear_preset):
			_check(_close(_pixel(2,1),pattern.get_pixel(0,1).lerp(pattern.get_pixel(1,1),0.5)), "Offset lookup retains bilinear interpolation")
		if await _enable(border_preset):
			_check(_close(_pixel(2,1),pattern.get_pixel(0,1)*0.5), "Bilinear border lookup includes transparent outside texels")
		if await _enable(relative):
			_check(_close(_pixel(2,1),Color(pattern.get_pixel(3,1).r*0.5,pattern.get_pixel(2,2).g,0.5,1.0)), "Relative original and earlier-pass offsets bind distinct images and sizes")
		var mip_image: Image = pattern.duplicate()
		mip_image.generate_mipmaps()
		var level1 := Image.create_from_data(4,2,false,Image.FORMAT_RGBA8,mip_image.get_data().slice(mip_image.get_mipmap_offset(1),mip_image.get_mipmap_offset(2)))
		if await _enable(mip):
			_check(_close(_pixel(2,1),level1.get_pixel(1,0)), "LOD and integer-fetch offsets use texels of the selected original-frame mip")
		if await _enable(mip_alias):
			_check(_close(_pixel(2,1),level1.get_pixel(1,0)), "LOD and fetch offsets read alias/relative mip atlases")
		if await _enable(implicit_preset):
			_check(_close(effect._passes[0].viewport.get_texture().get_image().get_pixel(0,0),level1.get_pixel(1,0)), "Implicit offset LOD follows the pass downsampling ratio")
		if await _enable(trilinear_preset):
			var base := pattern.get_pixel(1,0).lerp(pattern.get_pixel(2,0),0.5).lerp(pattern.get_pixel(1,1).lerp(pattern.get_pixel(2,1),0.5),0.5)
			_check(_close(_pixel(2,1),base.lerp(level1.get_pixel(1,0),0.5)), "Trilinear offsets move one texel independently at both mip levels")
			effect.set_source_region(Rect2(40,20,240,160),Vector2(16,8))
			_check(effect._snapshot_mips[-1].size == Vector2i(16,8), "Original mip buffers resize with the logical framebuffer")
			effect.set_source_region(Rect2(40,20,240,160),Vector2(8,4))
		if await _enable(history):
			_check(_close(_pixel(2,1),level1.get_pixel(1,0)), "Previous-frame mip offsets follow rotating original snapshots")
		if await _enable(feedback):
			_check(_close(_pixel(2,1),level1.get_pixel(1,0)), "Feedback mip offsets preserve floating-point snapshot sampling")
			_check(effect.current.passes[1].shader.get_shader_uniform_list().filter(func(u: Dictionary): return u.type == TYPE_OBJECT).size() <= 3, "Unused history/alias samplers do not consume feedback texture units")
		if await _enable(lut):
			_check(_close(_pixel(2,1),pattern.get_pixel(0,1)), "External offsets preserve repeat wrapping")
		if await _enable(lut_mip):
			_check(_close(_pixel(2,1),level1.get_pixel(3,0)), "Mipmapped external offsets wrap negative texels at the selected level")
		var chain: Node = effect._chain
		var oversized := _write("oversized.glslp", "shaders=1\nshader0=stock.glsl\nscale_type0=absolute\nscale0=100000\n")
		_check(not effect.configure({"shader_enabled":true,"shader_path":oversized}).ok and effect._chain == chain and effect.active, "Oversized single-pass replacement preserves the active effect")
		if await _enable(stock):
			_check(effect._snapshot_mips.is_empty(), "Switching to a simple shader releases snapshot mip buffers")
		effect.configure({"shader_enabled":false})
		effect.free()
		source.free()
	else:
		print("SKIP: offset pixels require a rendered display")
	for path: String in files: DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(folder)
	print("Shader compatibility: %d checks, %d failures"%[checks,failures])
	quit(1 if failures else 0)

func _remaining_pixels() -> void:
	var vertex := "#if defined(VERTEX)\nattribute vec4 VertexCoord; attribute vec2 TexCoord; uniform mat4 MVPMatrix; varying vec2 TEX0; void main() { TRANSFORM TEX0 = TexCoord; }\n#elif defined(FRAGMENT)\nuniform sampler2D Texture; varying vec2 TEX0; void main() { gl_FragColor = texture2D(Texture,TEX0); }\n#endif\n"
	var flip := _write("flip.glsl",vertex.replace("TRANSFORM","vec4 pos = VertexCoord; pos.x = 1.0-pos.x; gl_Position = MVPMatrix*pos;"))
	if await _enable(flip):
		_check(_close(_pixel(1,1),pattern.get_pixel(6,1)), "Custom vertex flip preserves interpolated source coordinates inside a cropped output")
	var scale := _write("geometry-scale.glsl",vertex.replace("TRANSFORM","gl_Position = MVPMatrix*VertexCoord/vec4(2.0,2.0,1.0,1.0);"))
	if await _enable(scale):
		_check(_close(_pixel(0,0),Color.BLACK), "Smaller quad clears the uncovered pass framebuffer")
		_check(_close(_pixel(2,1),pattern.get_pixel(1,1)), "Custom clip scaling maps to local canvas pixels")
	var assignments := _write("vertex-assignment.glsl", "#if defined(VERTEX)\nattribute vec4 VertexCoord; uniform mat4 MVPMatrix; varying vec4 offsets; void main() { gl_Position = MVPMatrix*VertexCoord; vec4 value; value.xy = -(value.zw = vec2(0.2,0.4)); offsets = value; }\n#elif defined(FRAGMENT)\nvarying vec4 offsets; void main() { gl_FragColor = vec4(-offsets.x,-offsets.y,offsets.z+offsets.w,1.0); }\n#endif\n")
	if await _enable(assignments):
		_check(_close(_pixel(2,1),Color(0.2,0.4,0.6)), "Nested vertex assignments retain their value, sign and inner swizzle writes on the GPU")
	var uniforms := _shader("comma-uniforms", "vec4(texture2D(Texture,TEX0).rgb*GAIN+BIAS,1.0)", "\n#pragma parameter GAIN \"Gain\" 0.5 0.0 1.0\n#pragma parameter BIAS \"Bias\" 0.1 0.0 1.0\nuniform float GAIN, BIAS;")
	if await _enable(uniforms):
		var expected := pattern.get_pixel(2,1)*0.5+Color(0.1,0.1,0.1,0.0)
		_check(_close(_pixel(2,1),expected), "Splitting comma declarations retains the uniform qualifier for every parameter")
	var state := _shader("state", "vec4(accumulate(texture2D(Texture,TEX0).rgb),1.0)", "vec3 total = vec3(0.1); vec3 accumulate(vec3 value) { total += value*0.5; return finish(); } vec3 finish() { total += vec3(0.1); return total; }")
	if await _enable(state):
		_check(_close(_pixel(2,1),Color(0.2,0.2,0.2)+pattern.get_pixel(2,1)*0.5), "Nested helpers share invocation state and reset it for each fragment")
	var coords := _shader("coordinate-helper", "position()", "uniform vec2 OutputSize; vec4 position() { return vec4(gl_FragCoord.xy/OutputSize,0.0,1.0); }")
	if await _enable(coords):
		_check(_close(_pixel(2,1),Color(0.3125,0.625,0.0)), "Fragment coordinate helpers retain crop origin and bottom-up Y")
	var matrix := _shader("rectangular", "vec4(evaluate(),1.0)", "vec3 evaluate() { mat4x3 a = mat4x3(vec3(0.1),vec3(0.2),vec3(0.3),vec3(0.4)); mat4x3 b = a*2.0-a; vec3 x = b*vec4(0.25); vec4 y = vec3(1.0)*mat4x3(vec3(0.1),vec3(0.2),vec3(0.3),vec3(0.4)); return vec3(x.r,b[1].g,y.z*0.5); }")
	if await _enable(matrix):
		_check(_close(_pixel(2,1),Color(0.25,0.2,0.45)), "Rectangular matrices retain arithmetic, column indexing and both vector products")
	var loop := _shader("outer-loop", "vec4(float(sum)/10.0,float(i)/10.0,0.0,1.0)", "")
	_write("outer-loop.glsl",FileAccess.get_file_as_string(loop).replace("gl_FragColor =", "int sum = 0; int i; for (i=0;i<4;i++) { if (i==1) continue; sum+=i; } gl_FragColor ="))
	files.erase(loop)
	if await _enable(loop):
		_check(_close(_pixel(2,1),Color(0.5,0.4,0.0)), "External loop counters retain their final value and continue executes the increment")
	for wrap_mode: String in ["repeat","mirrored_repeat"]:
		_shader("wrapped-source", "texture2D(Texture,vec2(-0.125,0.375))")
		var preset := _write("wrapped-"+wrap_mode+".glslp", "shaders=1\nshader0=wrapped-source.glsl\nwrap_mode0="+wrap_mode+"\n")
		if await _enable(preset): _check(_close(_pixel(2,1),pattern.get_pixel(7 if wrap_mode == "repeat" else 0,1)), "Pass texels use negative "+wrap_mode+" coordinates")
	_shader("border-mip-pixel", "textureLod(LUT,vec2(0.0,0.25),1.0)", "uniform sampler2D LUT;")
	var border_mip := _write("border-mip-pixel.glslp", "shaders=1\nshader0=border-mip-pixel.glsl\ntextures=LUT\nLUT=lut.png\nLUT_mipmap=true\nLUT_linear=true\nLUT_wrap_mode=clamp_to_border\n")
	var mip_image: Image = pattern.duplicate()
	mip_image.generate_mipmaps()
	var level1 := Image.create_from_data(4,2,false,Image.FORMAT_RGBA8,mip_image.get_data().slice(mip_image.get_mipmap_offset(1),mip_image.get_mipmap_offset(2)))
	if await _enable(border_mip): _check(_close(_pixel(2,1),level1.get_pixel(0,0)*0.5), "Mipmapped LUT border filtering includes transparent texels at the requested level")
	_shader("mirror-mip-pixel", "textureLod(LUT,vec2(-0.125,0.25),1.0)", "uniform sampler2D LUT;")
	var mirror_mip := _write("mirror-mip-pixel.glslp", "shaders=1\nshader0=mirror-mip-pixel.glsl\ntextures=LUT\nLUT=lut.png\nLUT_mipmap=true\nLUT_linear=false\nLUT_wrap_mode=mirrored_repeat\n")
	if await _enable(mirror_mip): _check(_close(_pixel(2,1),level1.get_pixel(0,0)), "Mipmapped LUT mirrored wrapping folds negative texels independently at each level")

func _remaining_config_checks() -> void:
	_shader("default-texture-pass", "texture2D(AUX,TEX0)", "uniform sampler2D AUX;")
	var declaration := "shaders=1\nshader0=default-texture-pass.glsl\ntextures=AUX\nAUX=lut.png\nAUX_linear=false\nAUX_wrap_mode=clamp_to_edge\n"
	_write("default-texture-canonical.glslp",declaration)
	var composed := _write("default-texture-composed.glslp", "shaders=1\nshader0=default-texture-pass.glsl\nscale_type0=source\nscale0=1\n")
	var result := Importer.load_file(composed)
	_check(result.ok and result.texture_descriptors.size() == 1 and result.warnings.size() == 1, "Omitted LUTs inherit an unambiguous sibling declaration for the same pass with a diagnostic")
	_write("default-texture-ambiguous.glslp",declaration.replace("clamp_to_edge","repeat"))
	_check(not Importer.load_file(composed).ok, "Conflicting sibling LUT defaults remain an explicit missing-texture error")
	_check(Importer.load_file(_write("default-texture-explicit.glslp",declaration+"scale_type0=source\nscale0=1\n")).ok, "Explicit LUT settings override conflicting sibling defaults")
	_check(Importer._preset('shaders=1\ntextures="AUX;\nAUX=lut.png\n').values.textures == "AUX;", "Legacy texture lists retain content when the end-of-line quote is omitted")
	_check(Importer._preset('GAIN=2.2\nGAIN="2.200000"\n').ok, "Equivalent numeric duplicate settings normalize without a conflict")
	_check(not Importer._preset('GAIN=2.2\nGAIN=2.3\n').ok, "Conflicting duplicate settings still reject")
	_check(Importer.load_file(_write("unused-pass-setting.glslp", "shaders=1\nshader0=stock.glsl\nscale_type0=source\nscale0=1\nshader1=missing.glsl\n")).warnings.size() == 1, "Settings beyond the declared pass count are ignored with a diagnostic")

func _parameter_checks() -> Dictionary:
	var declaration := '#pragma parameter GAIN "Gain" 0.25 0.0 0.5 0.1\n'
	var shader := _shader("parameter-first", "vec4(texture2D(Texture,TEX0).rgb * GAIN,1.0)", "uniform float GAIN;")
	_write("parameter-first.glsl", declaration+FileAccess.get_file_as_string(shader))
	# _write tracks cleanup paths; writing an existing fixture needs only one.
	files.erase(shader)
	var second := FileAccess.get_file_as_string(shader).replace(declaration, '#pragma parameter GAIN "Last gain" 0.75 0.1 0.9 0.05\n')
	_write("parameter-last.glsl", second)
	var single := _write("parameter-single.glslp", 'shaders=1\nshader0=parameter-first.glsl\nparameters=" GAIN ; OLD_GAIN ; GAIN ; OLD_GAIN ; ; "\nGAIN="0.4 ; "\nOLD_GAIN="stale value"\n')
	var result := Importer.load_file(single)
	_check(result.ok and result.parameters.size() == 1 and result.values.get("GAIN") == 0.4, "Normalize advisory parameter lists without exposing obsolete controls")
	_check(result.get("ignored_preset_parameters",[]) == ["OLD_GAIN"] and result.get("warnings",[]).size() == 1 and not result.values.has("OLD_GAIN"), "Report each ignored preset parameter once without creating a value or uniform")
	_check(not Importer.load_file(single,{"OLD_GAIN":0.8}).ok, "Stale preset metadata does not authorize an unknown explicit edit")
	_check(Importer.load_file(single,{"GAIN":0.3}).values.get("GAIN") == 0.3, "Explicit edits still take precedence over normalized preset values")
	var shared := _write("parameter-shared.glslp", 'shaders=2\nshader0=parameter-first.glsl\nshader1=parameter-last.glsl\n')
	result = Importer.load_file(shared)
	_check(result.ok and result.parameters.size() == 1 and result.values.get("GAIN") == 0.75, "Shared parameters use the last declaration instead of rejecting different defaults")
	if result.ok:
		_check(result.parameters[0].label == "Last gain" and result.parameters[0].min == 0.1 and result.parameters[0].max == 0.9 and result.parameters[0].step == 0.05 and result.warnings.size() == 1, "Last declaration supplies shared label, bounds, step and a diagnostic")
	var overridden := _write("parameter-overridden.glslp", FileAccess.get_file_as_string(shared)+'parameters=" GAIN ; OLD_GAIN "\nGAIN=0.8\nOLD_GAIN=123\n')
	result = Importer.load_file(overridden)
	_check(result.ok and result.values.get("GAIN") == 0.8 and result.ignored_preset_parameters == ["OLD_GAIN"], "Multipass overrides and stale metadata follow the same rules as single-pass")
	_check(Importer.load_file(shared,{"GAIN":2.0}).values.get("GAIN") == 0.9, "Shared edits clamp to the effective last declaration's bounds")
	_check(Importer.load_file(shared,{"GAIN":-1.0}).values.get("GAIN") == 0.1, "Shared lower bounds clamp consistently")
	_check(not Importer.load_file(shared,{"OLD_GAIN":0.5}).ok, "Multipass explicit unknown parameters still fail")
	for invalid: Variant in ["NaN","INF",true,[],{}]:
		for path: String in [single,shared]:
			_check(not Importer.load_file(path,{"GAIN":invalid}).ok, "Reject nonfinite or nonnumeric edits in both import paths")
	var optional := _write("parameter-optional.glsl", second.replace('0.75 0.1 0.9 0.05','0.75 0.1 0.9').replace('#pragma parameter','# \tpragma\tparameter'))
	result = Importer.load_file(optional)
	_check(result.ok and is_equal_approx(result.parameters[0].step,0.08), "Optional pragma step defaults to one tenth of the range and accepts directive whitespace")
	var fixed := _write("parameter-fixed.glsl", second.replace('0.75 0.1 0.9 0.05','0.75 0.75 0.75'))
	result = Importer.load_file(fixed,{"GAIN":0.1})
	_check(result.ok and result.values.get("GAIN") == 0.75 and result.parameters[0].step > 0.0, "Fixed-value parameters retain usable metadata when the step is omitted")
	for bounds: String in ['0.75 0.1 0.9 0','0.75 0.9 0.1 0.1','NaN 0.1 0.9','0.75 0.1 0.9 nope']:
		_check(not Importer.load_file(_write("parameter-invalid.glsl",second.replace('0.75 0.1 0.9 0.05',bounds))).ok, "Malformed bounds still fail explicitly")
	var base := 'shaders=1\nshader0=parameter-first.glsl\n'
	_check(Importer.load_file(_write("parameter-unlisted.glslp",base+'UNLISTED=1\n')).ignored_preset_parameters == ["UNLISTED"], "Undeclared numeric preset values are diagnosed and ignored like RetroArch")
	_check(not Importer.load_file(_write("parameter-reserved.glslp",base+'parameters=shader99\nshader99=missing.glsl\n')).ok, "Advisory names cannot hide unsupported preset options")
	_check(not Importer.load_file(_write("parameter-bad-name.glslp",base+'parameters="bad name"\n')).ok, "Invalid parameter identifiers still fail")
	_check(Importer.load_file(_write("parameter-unlisted-known.glslp",base+'GAIN=0.4\n')).values.get("GAIN") == 0.4, "Declared values work without an advisory parameters list")
	return {"single":single,"shared":shared,"overridden":overridden}

func _setup() -> void:
	root.size = Vector2i(320,240)
	source = SubViewport.new()
	source.disable_3d = true
	source.size = root.size
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(source)
	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(pattern)
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.position = Vector2(40,20)
	rect.size = Vector2(240,160)
	source.add_child(rect)
	var display := TextureRect.new()
	display.texture = source.get_texture()
	display.size = Vector2(root.size)
	root.add_child(display)
	effect = PostProcess.new()
	root.add_child(effect)
	effect.set_framebuffer_texture(source.get_texture())
	effect.set_source_region(Rect2(40,20,240,160),Vector2(8,4))

func _enable(path: String) -> bool:
	if not _check(effect.configure({"shader_enabled":true,"shader_path":path}).ok,"Enable "+path.get_file()): return false
	for frame in 12:
		await process_frame
		await RenderingServer.frame_post_draw
	return true

func _pixel(x: int, y: int) -> Color:
	return root.get_texture().get_image().get_pixel(40+x*30+15,20+y*40+20)

func _close(a: Color, b: Color) -> bool:
	var close := absf(a.r-b.r) < 0.015 and absf(a.g-b.g) < 0.015 and absf(a.b-b.b) < 0.015
	if not close: print("Pixel mismatch: actual=%s expected=%s"%[a,b])
	return close
