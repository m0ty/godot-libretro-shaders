extends SceneTree
## Runtime translation and faithful rejection of unsupported RetroArch features.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")
const PostProcess := preload("res://addons/retroarch_shaders/post_process.gd")
var checks := 0
var failures := 0
var skipped := 0
var folder := ""
var files := PackedStringArray()
const BASIC := """
// Public-domain synthetic import fixture; preserve this notice.
#pragma parameter AMOUNT "Effect amount" 0.5 0.0 1.0 0.1
#ifdef PARAMETER_UNIFORM
uniform float AMOUNT;
#else
#define AMOUNT 0.25
#endif
uniform vec2 TextureSize;
varying vec2 TEX0;
varying vec2 inverse_size;
#if defined(VERTEX)
attribute vec2 TexCoord;
attribute vec4 VertexCoord;
uniform mat4 MVPMatrix;
void main() { gl_Position = MVPMatrix * VertexCoord; TEX0 = TexCoord * 1.0001; inverse_size = 1.0 / TextureSize; }
#elif defined(FRAGMENT)
uniform sampler2D Texture;
uniform vec2 InputSize;
uniform vec2 OutputSize;
uniform int FrameCount;
void main() { gl_FragColor = texture2D(Texture, TEX0) * AMOUNT + vec4(inverse_size, float(FrameCount) * 0.000001, InputSize.x / OutputSize.x); }
#endif
"""

func _init() -> void: _run.call_deferred()

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func _write(name: String, text: String) -> String:
	var path := folder.path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	files.append(path)
	return path

func _run() -> void:
	folder = OS.get_environment("TEMP").replace("\\", "/").path_join("fallout-glsl-import-%d"%Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(folder) == OK, "Shader fixtures use a disposable temporary directory")
	var source := _write("basic.glsl", BASIC)
	var result := Importer.load_file(source)
	_check(result.ok, "Computed vertex varyings and a parameterized fragment compile: %s"%result.message)
	if result.ok:
		_check(result.parameters.size() == 1 and result.parameters[0].default == 0.5 and result.values.AMOUNT == 0.5, "Parameter pragma default wins over inactive fallback macros")
		_check(result.shader.code.contains("preserve this notice") and result.shader.code.contains("inverse_size = 1.0 / ra_input_size"), "Translation preserves source notices and vertex varying calculations")
		_check(result.shader.code.contains("TEX0 = vec2(UV) * 1.0001"), "The declared two-component texture attribute maps to fullscreen UV")
		_check(not result.filter_linear and result.shader.code.contains("filter_nearest"), "Bare GLSL defaults to nearest filtering")
		var uniforms := []
		for uniform: Dictionary in result.shader.get_shader_uniform_list(): uniforms.append(str(uniform.name))
		_check(result.shader.code.contains("uniform sampler2D ra_source : hint_screen_texture") and "ra_input_size" in uniforms and "ra_output_size" in uniforms and "ra_frame_count" in uniforms and "ra_source_uv_rect" in uniforms, "Imported shaders expose the exact runtime size, sampler, source-region and frame uniforms")
	var preset := _write("basic.glslp", 'shaders = "1"\nshader0 = "basic.glsl"\nfilter_linear0 = "true"\nparameters = "AMOUNT"\nAMOUNT = "0.7"\n')
	result = Importer.load_file(preset)
	_check(result.ok and result.filter_linear and result.values.get("AMOUNT") == 0.7, "Presets resolve relative paths, filtering and parameter overrides")
	result = Importer.load_file(preset, {"AMOUNT":2.0})
	_check(result.ok and result.values.get("AMOUNT") == 1.0, "Explicit parameter values override the preset and clamp to declared bounds")
	_check(not Importer.load_file(source, {"BOGUS":0.5}).ok, "Unknown parameter names are reported instead of silently ignored")
	_check(not Importer.load_file(source, {"AMOUNT":"NaN"}).ok, "Nonfinite parameter inputs are rejected")
	var border := _write("border.glslp", 'shaders=1\nshader0=basic.glsl\nwrap_mode0=clamp_to_border\nfloat_framebuffer0=false\nsrgb_framebuffer0=false\nmipmap_input0=false\nalias0=""\n')
	result = Importer.load_file(border)
	_check(result.ok and result.shader.code.contains("coord.x >= dimensions.x || coord.y >= dimensions.y) return vec4(0.0)"), "Harmless false/empty preset options work and border sampling is preserved")
	result = Importer.load_file(_write("resize.glslp", "shaders=1\nshader0=basic.glsl\nscale_type0=source\nscale0=2.0\n"))
	_check(result.ok and result.passes.size() == 1 and result.passes[0].sizing.scale_x == 2.0, "Sized single-pass presets use an explicit render target")
	for entry in [
		["bad-resize", "shaders=1\nshader0=basic.glsl\nscale_type0=source\nscale0=-2.0\n", "sizing"],
		["lut", "shaders=1\nshader0=basic.glsl\ntextures=mask\nmask=mask.png\n", "external texture"],
		["wrap", "shaders=1\nshader0=basic.glsl\nwrap_mode0=unsupported\n", "wrap"],
		["alias", "shaders=1\nshader0=basic.glsl\nalias0=not a valid alias\n", "aliases"],
		["duplicate", "shaders=1\nshader0=basic.glsl\nshader0=other.glsl\n", "Duplicate"]
	]:
		result = Importer.load_file(_write(entry[0]+".glslp", entry[1]))
		_check(not result.ok and str(result.message).contains(entry[2]), "Unsupported %s preset returns an actionable reason"%entry[0])
	result = Importer.load_file(_write("multipass.glslp", "shaders=2\nshader0=basic.glsl\nshader1=basic.glsl\n"))
	_check(result.ok and result.passes.size() == 2 and result.parameters.size() == 1,"Multiple passes compile and expose shared parameters once")
	result = Importer.load_file(_write("srgb.glslp", "shaders=1\nshader0=basic.glsl\nsrgb_framebuffer0=true\n"))
	_check(result.ok and result.passes.size() == 1 and result.passes[0].srgb_framebuffer,"Single-pass sRGB presets compile through an explicitly encoded target")
	for entry in [
		["include", BASIC+"\n#include \"shared.h\"\n", "includes"],
		["unclosed", BASIC+"\n#if defined(FRAGMENT)\n", "Unclosed"],
		["no_fragment", "#if defined(VERTEX)\nvoid main() {}\n#endif\n", "fragment"],
		["bounds", BASIC.replace("0.5 0.0 1.0 0.1", "0.5 1.0 0.0 0.1"), "bounds"]
	]:
		result = Importer.load_file(_write(entry[0]+".glsl", entry[1]))
		_check(not result.ok and str(result.message).contains(entry[2]), "Unsupported %s shader returns an actionable reason"%entry[0])
	_check(not Importer.load_file(folder.path_join("missing.glsl")).ok and not Importer.load_file(source+".txt").ok, "Missing files and unsupported extensions fail safely")
	_check(Importer.load_file(_write("unused-history.glsl",BASIC.replace("uniform sampler2D Texture;","uniform sampler2D Texture; uniform sampler2D PrevTexture;"))).ok,"Unused legacy sampler declarations do not block an otherwise valid shader")
	var standalone := _write("standalone.glsl", "uniform sampler2D Texture; void main() { gl_FragColor = texture2D(Texture, vec2(0.5)); }")
	result = Importer.load_file(standalone)
	_check(result.ok and not result.shader.code.contains("void vertex()"), "Stage-less fragment shaders do not create a duplicate vertex main")
	var fragment_only := _write("fragment-only.glsl", "#if defined(FRAGMENT)\nuniform sampler2D Texture; varying vec2 TEX0; void main() { gl_FragColor = texture2D(Texture, TEX0); }\n#endif\n")
	result = Importer.load_file(fragment_only)
	_check(result.ok and result.shader.code.contains("TEX0 = UV"), "A fragment-only primary texture varying is initialized instead of sampling one corner everywhere")
	var nested := _write("nested.glsl", BASIC.replace("#ifdef PARAMETER_UNIFORM", "#if defined(PARAMETER_UNIFORM) && __VERSION__ >= 130 && !defined(GL_ES)"))
	_check(Importer.load_file(nested).ok, "Combined standard preprocessor conditions preserve the selected shader branch")
	var color_parameter := _write("color-parameter.glsl",BASIC.replace("AMOUNT","Color").replace("inverse_size = 1.0 / TextureSize","inverse_size = Color / TextureSize"))
	_check(Importer.load_file(color_parameter).ok,"A parameter named Color remains distinct from a legacy vertex color attribute")
	var lut_presets := _texture_checks()
	_compiler_checks()
	if DisplayServer.get_name() != "headless":
		await _render_check(Importer.load_file(fragment_only), "fragment-only")
		await _render_smoothing(fragment_only)
		await _render_texture_checks(lut_presets)
	else:
		skipped += 1
		print("SKIP: GPU pixel checks require a rendered Godot display")
	var root_path := ""
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--shader-dir="): root_path = argument.trim_prefix("--shader-dir=")
	if not root_path.is_empty() and DirAccess.dir_exists_absolute(root_path):
		for relative in ["stock.glsl", "nearest.glslp", "bilinear.glslp", "crt/crt-lottes.glslp", "crt/crt-lottes-fast.glslp", "crt/crt-pi.glslp", "crt/zfast-crt.glslp", "crt/crt-easymode.glslp", "scanlines/shaders/scanline-fract.glsl", "scanlines/shaders/res-independent-scanlines.glsl", "interpolation/quilez.glslp", "xbrz/xbrz-freescale.glslp", "crt/crt-potato-warm.glslp", "crt/crt-potato-cool.glslp"]:
			result = Importer.load_file(root_path.path_join(relative))
			_check(result.ok, "Installed %s compiles: %s"%[relative, result.message])
			if result.ok and relative.contains("potato"):
				_check(result.textures.size() == 1 and result.texture_descriptors[0].size == Vector2i(2, 5) and result.texture_descriptors[0].wrap_mode == "repeat", "Installed %s preserves its external two-by-five RGB mask"%relative)
			if result.ok and DisplayServer.get_name() != "headless": await _render_check(result, relative)
		for relative in ["crt/crt-royale.glslp"]:
			result = Importer.load_file(root_path.path_join(relative))
			_check(result.ok, "Installed %s supports its pass and history dependencies: %s"%[relative,result.message])
		result = Importer.load_file(root_path.path_join("motionblur/motionblur-simple.glslp"))
		_check(result.ok,"Legacy motion blur imports with vertex coordinates and original-frame history")
	else:
		skipped += 1
		print("SKIP: external collection requires --shader-dir=<collection>; synthetic import coverage still ran")
	for path: String in files: DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(folder)
	print("GLSL importer: %d checks, %d failures, %d skips"%[checks, failures, skipped])
	quit(1 if failures else 0)

func _compiler_checks() -> void:
	var fixtures := {
		"local-output": """#if defined(FRAGMENT)
out vec4 FragColor;
vec4 color_helper() { vec4 FragColor = vec4(0.25); FragColor.rgb *= 2.0; return FragColor; }
void main() { FragColor = color_helper(); }
#endif
""",
		"macro": """uniform vec2 OutputSize;
#define OutputSize vec4(OutputSize, 1.0 / OutputSize)
#define ADD(x,y) ((x) + (y))
void main() { gl_FragColor = vec4(ADD(OutputSize.y, 0.0) / OutputSize.x); }
""",
		"sampler-overload": """uniform sampler2D Texture;
vec4 sample_image(sampler2D image, vec2 uv) { return texture2D(image, uv); }
vec4 sample_image(sampler2D image, vec2 uv, float gain) { return sample_image(image, uv) * gain; }
void main() { gl_FragColor = sample_image(Texture, vec2(0.5), 1.0); }
""",
		"global-cache": """#pragma parameter GAIN "Gain" 0.5 0.0 1.0 0.1
uniform float GAIN;
float coefficient;
void prepare() { coefficient = GAIN * GAIN; }
void main() { prepare(); gl_FragColor = vec4(coefficient); }
""",
		"types": """uniform int FrameCount;
float convert(float value) { return value; }
void main() { float frame_count = float(FrameCount); float input_size = 0.5; int i = 0;
if (i < input_size) { frame_count += convert(i); }
gl_FragColor = vec4(frame_count, input_size, float(i), 1.0); }
""",
		"matrices": """void main() {
mat2 basis = mat2(1.0, 2.0, 3.0, 4.0);
mat2 scaled = mat2(vec4(basis * 0.1));
vec3 mixed = mat2x3(vec3(0.1), vec3(0.2)) * vec2(1.0, 2.0);
gl_FragColor = vec4(scaled[0], mixed.xy); }
"""
	}
	for name: String in fixtures:
		var result := Importer.load_file(_write(name+".glsl",fixtures[name]))
		_check(result.ok,"CRT language regression %s compiles: %s"%[name,result.message])
		if result.ok and name == "macro":
			_check(result.shader.code.contains("ra_output_size"),"Recursive size macros retain the runtime uniform")
		if result.ok and name == "types":
			_check(not result.shader.code.contains("float(i)nput"),"Integer promotion preserves identifiers beginning with the integer variable name")

func _render_check(result: Dictionary, label: String) -> void:
	if not result.ok: return
	await process_frame
	# Stay above the native Windows title-bar minimum width.
	root.size = Vector2i(320, 240)
	var scene := Control.new()
	root.add_child(scene)
	var source := SubViewport.new()
	source.size = root.size
	source.disable_3d = true
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	scene.add_child(source)
	var background := ColorRect.new()
	background.size = Vector2(320, 240)
	background.color = Color(0.2, 0.3, 0.5, 1.0)
	source.add_child(background)
	var marker := ColorRect.new()
	marker.position = Vector2(4, 4)
	marker.size = Vector2(24, 56)
	marker.color = Color(0.9, 0.5, 0.2, 1.0)
	source.add_child(marker)
	var display := TextureRect.new()
	display.size = Vector2(root.size)
	display.texture = source.get_texture()
	scene.add_child(display)
	var effect := PostProcess.new()
	scene.add_child(effect)
	effect.set_framebuffer_texture(source.get_texture())
	effect.set_input_size(Vector2(160,120))
	var configured: Dictionary = effect.configure({"shader_enabled":true,"shader_path":result.path,"shader_parameters":result.values})
	_check(configured.ok,"Production layer enables "+label)
	if not configured.ok:
		scene.queue_free()
		await process_frame
		return
	effect.set_process(false)
	effect.frame_count = 42
	effect._update_uniforms()
	for frame in 12:
		await process_frame
		await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	_check(image != null and image.get_width() == 320 and image.get_height() == 240, "Installed shader produces a complete rendered frame: %s (image %s, window %s)"%[label, str(image.get_size()) if image != null else "none", root.size])
	if image != null:
		var detail := false
		# Scanline shaders intentionally black out selected rows.
		for y in range(28, 40):
			var left := image.get_pixel(12, y)
			var right := image.get_pixel(70, y)
			if left.r > right.r + 0.05 or left.b + 0.05 < right.b: detail = true
		_check(detail, "Imported shader retains spatial image detail: %s"%label)
	scene.queue_free()
	await process_frame

func _render_smoothing(source: String) -> void:
	var images: Array[Image] = []
	for linear: bool in [false, true]:
		var path := _write("filter-%s.glslp"%str(linear), "shaders=1\nshader0=%s\nfilter_linear0=%s\n"%[source.get_file(), str(linear)])
		var result := Importer.load_file(path)
		_check(result.ok, "Logical-grid filter fixture compiles")
		if not result.ok: return
		var scene := Control.new()
		root.add_child(scene)
		for index in 2:
			var rectangle := ColorRect.new()
			rectangle.position = Vector2(index*160, 0)
			rectangle.size = Vector2(160, 240)
			rectangle.color = Color.RED if index == 0 else Color.BLUE
			scene.add_child(rectangle)
		var effect := ColorRect.new()
		effect.size = Vector2(320, 240)
		var material := ShaderMaterial.new()
		material.shader = result.shader
		material.set_shader_parameter("ra_input_size", Vector2(160, 120))
		material.set_shader_parameter("ra_output_size", Vector2(320, 240))
		effect.material = material
		scene.add_child(effect)
		await process_frame
		await RenderingServer.frame_post_draw
		images.append(root.get_texture().get_image())
		scene.queue_free()
		await process_frame
	_check(images[0].get_pixel(159, 120).r > 0.95 and images[0].get_pixel(159, 120).b < 0.05, "Nearest filtering preserves the enlarged logical texel boundary")
	var blended := images[1].get_pixel(159, 120)
	_check(blended.r > 0.6 and blended.r < 0.9 and blended.b > 0.1 and blended.b < 0.4, "Linear filtering blends logical neighbors despite existing two-times nearest enlargement")

func _texture_checks() -> Dictionary:
	var path := folder.path_join("mask.png")
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color.RED)
	image.set_pixel(1, 0, Color.BLUE)
	image.set_pixel(0, 1, Color.GREEN)
	image.set_pixel(1, 1, Color.WHITE)
	_check(image.save_png(path) == OK, "External texture fixtures are disposable PNG images")
	files.append(path)
	var source := '#if defined(FRAGMENT)\nuniform sampler2D Texture; uniform sampler2D MASK; varying vec2 TEX0;\n#define Source Texture\n#define Lut MASK\n#define SOURCE_SAMPLE(c) texture2D(Source, c)\n#define LUT_SAMPLE(c) texture2D(Lut, c)\nvoid main() { gl_FragColor = SOURCE_SAMPLE(TEX0) * LUT_SAMPLE(vec2(1.25, 0.25)); }\n#endif\n'
	_write("lut.glsl", source)
	var presets := {}
	for wrap_mode: String in ["repeat", "mirrored_repeat", "clamp_to_edge", "clamp_to_border"]:
		var preset := _write("lut-%s.glslp"%wrap_mode, "shaders=1\nshader0=lut.glsl\nalias0=PASS0\ntextures=MASK\nMASK=mask.png\nMASK_linear=false\nMASK_wrap_mode=%s\n"%wrap_mode)
		presets[wrap_mode] = preset
		var result := Importer.load_file(preset)
		_check(result.ok, "External nearest texture compiles with %s wrapping: %s"%[wrap_mode, result.message])
		if result.ok:
			_check(result.textures.has("ra_lut_MASK") and result.texture_descriptors[0].size == Vector2i(2, 2), "Runtime receives an independently bound external image for %s"%wrap_mode)
			_check(result.shader.code.contains("ra_sample_source(ra_source, TEX0)") and not result.shader.code.contains("ra_sample_source(ra_lut_MASK"), "Expanded sampler aliases retain native image coordinates for %s"%wrap_mode)
	var linear_source := source.replace("vec2(1.25, 0.25)", "vec2(0.5, 0.25)")
	_write("lut-linear.glsl", linear_source)
	presets.linear = _write("lut-linear.glslp", "shaders=1\nshader0=lut-linear.glsl\ntextures=MASK\nMASK=mask.png\nMASK_linear=true\nMASK_wrap_mode=repeat\n")
	var linear := Importer.load_file(presets.linear)
	_check(linear.ok and linear.shader.code.contains("ra_lut_MASK : filter_linear, repeat_enable"), "External filtering is independent from the nearest framebuffer sampler")
	var default_filter := Importer.load_file(_write("lut-default.glslp", "shaders=1\nshader0=lut-linear.glsl\ntextures=MASK\nMASK=mask.png\nMASK_wrap_mode=repeat\n"))
	_check(default_filter.ok and default_filter.texture_descriptors[0].filter_linear and default_filter.shader.code.contains("ra_lut_MASK : filter_linear, repeat_enable"), "Omitted LUT filtering follows the native OpenGL default of linear")
	var mipmap := _write("lut-mipmap.glslp", "shaders=1\nshader0=lut.glsl\ntextures=MASK\nMASK=mask.png\nMASK_linear=true\nMASK_mipmap=true\nMASK_wrap_mode=repeat\n")
	var mipmapped := Importer.load_file(mipmap)
	_check(mipmapped.ok and mipmapped.textures.ra_lut_MASK.get_image().has_mipmaps() and mipmapped.shader.code.contains("filter_linear_mipmap"), "Requested external mipmaps are generated and use matching sampling hints")
	_write("bad-mask.png", "this is not an image")
	for entry in [
		["missing-mask", "textures=MASK\nMASK=missing-mask.png\n", "Cannot read external texture"],
		["bad-mask", "textures=MASK\nMASK=bad-mask.png\n", "Cannot decode external texture"],
		["duplicate-mask", "textures=MASK;MASK\nMASK=mask.png\n", "Duplicate external texture"],
		["invalid-filter", "textures=MASK\nMASK=mask.png\nMASK_linear=sometimes\n", "Invalid external texture setting"],
		["invalid-wrap", "textures=MASK\nMASK=mask.png\nMASK_wrap_mode=other\n", "wrap mode"],
		["reserved-mask", "textures=Texture\nTexture=mask.png\n", "Invalid external texture name"],
		["history-mask", "textures=PrevTexture\nPrevTexture=mask.png\n", "History"],
		["missing-path", "textures=MASK\n", "no image path"],
	]:
		var result := Importer.load_file(_write(entry[0]+".glslp", "shaders=1\nshader0=lut.glsl\n"+entry[1]))
		_check(not result.ok and str(result.message).contains(entry[2]), "External texture failure %s returns an actionable reason"%entry[0])
	var advisory_sampler := Importer.load_file(_write("sampler-parameter.glslp", "shaders=1\nshader0=lut.glsl\ntextures=MASK\nMASK=mask.png\nparameters=MASK\n"))
	_check(advisory_sampler.ok and advisory_sampler.ignored_preset_parameters == ["MASK"] and not advisory_sampler.values.has("MASK") and advisory_sampler.textures.has("ra_lut_MASK"), "A stale parameter list cannot turn an external sampler into a scalar parameter")
	_write("alias-dependency.glsl", source.replace("sampler2D MASK", "sampler2D PASS0Texture"))
	var dependency := Importer.load_file(_write("alias-dependency.glslp", "shaders=1\nshader0=alias-dependency.glsl\nalias0=PASS0\n"))
	_check(not dependency.ok and str(dependency.message).contains("pass alias"), "Benign single-pass aliases do not permit sampling the unfinished pass")
	return presets

func _render_texture_checks(presets: Dictionary) -> void:
	var expected := {"repeat":Color.RED, "mirrored_repeat":Color.BLUE, "clamp_to_edge":Color.BLUE, "clamp_to_border":Color(0, 0, 0, 0), "linear":Color(0.5, 0, 0.5, 1)}
	for key: String in expected:
		var result := Importer.load_file(presets[key])
		if not result.ok: continue
		var scene := Control.new()
		root.add_child(scene)
		var background := ColorRect.new()
		background.size = Vector2(320, 240)
		background.color = Color.WHITE
		scene.add_child(background)
		var effect := ColorRect.new()
		effect.size = Vector2(320, 240)
		var material := ShaderMaterial.new()
		material.shader = result.shader
		# LUT samples must be independent of framebuffer grid size and crop.
		material.set_shader_parameter("ra_input_size", Vector2(7, 5))
		material.set_shader_parameter("ra_source_uv_rect", Vector4(0.3, 0.4, 0.5, 0.6))
		for name: String in result.textures: material.set_shader_parameter(name, result.textures[name])
		effect.material = material
		scene.add_child(effect)
		await process_frame
		await RenderingServer.frame_post_draw
		var pixel := root.get_texture().get_image().get_pixel(160, 120)
		_check(pixel.is_equal_approx(expected[key]) or absf(pixel.r-expected[key].r) < 0.01 and absf(pixel.g-expected[key].g) < 0.01 and absf(pixel.b-expected[key].b) < 0.01, "External %s LUT pixels preserve original image/filter/wrap values: %s"%[key, pixel])
		scene.queue_free()
		await process_frame
