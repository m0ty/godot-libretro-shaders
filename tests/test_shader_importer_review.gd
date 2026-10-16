extends SceneTree
## Regressions for source encodings, exact preset references and inferred LUTs.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")
var checks := 0
var failures := 0
var folder := ""
var files: Array[String] = []

func _init() -> void:
	_run.call_deferred()

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

func _image(name: String, color: Color) -> String:
	var path := folder.path_join(name)
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(color)
	_check(image.save_png(path) == OK, "Create disposable lookup image")
	files.append(path)
	return path

func _run() -> void:
	folder = OS.get_environment("TEMP").replace("\\", "/").path_join("shader-importer-review-%d" % Time.get_ticks_usec())
	_check(DirAccess.make_dir_recursive_absolute(folder) == OK, "Create isolated importer fixtures")
	_encodings()
	_write("stock.glsl", "void main() { gl_FragColor=vec4(1.0); }\n")
	var helper := _write("helper.glsl", "uniform sampler2D mask; void main() { gl_FragColor=texture2D(mask,vec2(0.5)); }\n")
	_write("helper2.glsl", "uniform sampler2D mask2; void main() { gl_FragColor=texture2D(mask2,vec2(0.5)); }\n")
	var mask := _image("mask.png", Color.RED)
	var other := _image("other.png", Color.BLUE)
	var composed := _write("composed.glslp", "shaders=2\nshader0=stock.glsl\nshader1=helper.glsl\n")
	_write("inactive.glslp", "shaders=1\nshader0=stock.glsl\nshader1=helper.glsl\ntextures=mask\nmask=mask.png\n")
	_write("invalid.glslp", "shaders=invalid\nshader0=helper.glsl\ntextures=mask\nmask=mask.png\n")
	_write("zero.glslp", "shaders=0\nshader0=helper.glsl\ntextures=mask\nmask=mask.png\n")
	_check(Importer.find_presets(helper, folder) == [composed], "Picker excludes inactive passes and invalid declared counts")
	var result := Importer.load_file(composed)
	_check(not result.ok and result.message.contains("additional texture"), "Inactive and invalid preset references cannot supply inferred LUTs")
	var parent := _write("parent.glslp", "shaders=1\nshader0=helper.glsl\ntextures=mask\nmask=mask.png\n")
	result = Importer.load_file(composed)
	_check(result.ok, "A valid exact parent supplies its shared LUT default")
	if result.ok:
		_check(result.texture_descriptors.size() == 1 and result.texture_descriptors[0].path == mask, "Inferred LUT points to the referenced parent's image")
		_check(result.warnings.size() == 1 and result.warnings[0].contains(parent), "Inferred dependency retains its origin warning")
	result = Importer.load_file(composed.replace("/", "\\"))
	_check(result.ok and result.texture_descriptors[0].path.replace("\\", "/") == mask, "Windows preset paths infer the same sibling LUT")
	var ambiguous := _write("ambiguous.glslp", "shaders=1\nshader0=helper.glsl\ntextures=mask\nmask=other.png\n")
	result = Importer.load_file(composed)
	_check(not result.ok and result.message.contains("additional texture"), "Conflicting valid parents keep the missing dependency explicit")
	DirAccess.remove_absolute(ambiguous)
	_write("parent.glslp", "shaders=1\nshader0=helper.glsl\ntextures=mask\nmask=other.png\n")
	result = Importer.load_file(composed)
	_check(result.ok and result.texture_descriptors[0].path == other, "Editing a sibling preset is observed on the next load")
	var explicit := _write("explicit.glslp", "shaders=2\nshader0=stock.glsl\nshader1=helper.glsl\ntextures=mask\nmask=mask.png\n")
	result = Importer.load_file(explicit)
	_check(result.ok and result.texture_descriptors[0].path == mask and result.warnings.is_empty(), "Explicit LUT declarations win over discovered defaults")
	DirAccess.remove_absolute(explicit)
	_write("parent.glslp", "shaders=2\nshader0=helper.glsl\nshader1=helper2.glsl\ntextures=mask;mask2\nmask=mask.png\nmask2=other.png\n")
	var multi := _write("multi.glslp", "shaders=3\nshader0=stock.glsl\nshader1=helper.glsl\nshader2=helper2.glsl\n")
	result = Importer.load_file(multi)
	_check(result.ok, "Different passes reuse a parsed sibling preset safely")
	if result.ok:
		_check(result.texture_descriptors.size() == 2 and result.warnings.size() == 2, "Cached sibling configuration supplies each distinct required LUT once")
	result = Importer.load_file(multi.replace("/", "\\"))
	_check(result.ok and result.texture_descriptors.size() == 2, "Windows paths retain cached sibling defaults across passes")
	var shared_directories: Array[String] = [folder.path_join("shared-a"), folder.path_join("shared-b")]
	for directory: String in shared_directories:
		_check(DirAccess.make_dir_recursive_absolute(directory) == OK, "Create separate source families for shared uniform defaults")
	for family: String in ["shared-a", "shared-b"]:
		_write(family + "/pass.glsl", "uniform sampler2D mask; void main() { gl_FragColor=texture2D(mask,vec2(0.5)); }\n")
	_write("shared-a/parent.glslp", "shaders=1\nshader0=pass.glsl\ntextures=mask\nmask=../mask.png\n")
	_write("shared-b/parent.glslp", "shaders=1\nshader0=pass.glsl\ntextures=mask\nmask=../other.png\n")
	var shared_source := "shaders=2\nshader0=shared-a/pass.glsl\nshader1=shared-b/pass.glsl\n"
	var shared := _write("shared.glslp", shared_source)
	result = Importer.load_file(shared)
	_check(not result.ok and result.message.contains("additional texture"), "Different source passes with conflicting same-name LUTs remain unresolved")
	_write("shared-b/parent.glslp", "shaders=1\nshader0=pass.glsl\ntextures=mask\nmask=../mask.png\n")
	result = Importer.load_file(shared)
	_check(result.ok and result.texture_descriptors.size() == 1 and result.texture_descriptors[0].path == mask, "Agreeing same-name defaults across sources produce one global binding")
	var shared_explicit := _write("shared-explicit.glslp", shared_source + "textures=mask\nmask=other.png\n")
	result = Importer.load_file(shared_explicit)
	_check(result.ok and result.texture_descriptors[0].path == other and result.warnings.is_empty(), "Explicit global LUT overrides defaults from every source pass")
	# The second source's bounded scan must be allowed to veto an earlier
	# inferred value; otherwise unseen siblings could conceal a conflict.
	for index in 65:
		_write("shared-b/unused-%02d.glslp" % index, "shaders=1\nshader0=unused.glsl\n")
	result = Importer.load_file(shared)
	_check(not result.ok and result.message.contains("additional texture"), "An incomplete later source scan prevents a global inferred binding")
	result = Importer.load_file(shared_explicit)
	_check(result.ok and result.texture_descriptors[0].path == other, "Explicit LUTs remain usable when sibling scans would be incomplete")
	for path: String in files:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	for directory: String in shared_directories: DirAccess.remove_absolute(directory)
	DirAccess.remove_absolute(folder)
	print("Shader importer review: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _encodings() -> void:
	# Exercise both short inputs and native ASCII skipping. These boundaries
	# cover overlong forms, surrogates, the Unicode limit and interrupted bytes.
	var valid := [
		[], [0], [0x7f], [0xc2,0x80], [0xdf,0xbf], [0xe0,0xa0,0x80],
		[0xed,0x9f,0xbf], [0xee,0x80,0x80], [0xef,0xbf,0xbf],
		[0xf0,0x90,0x80,0x80], [0xf4,0x8f,0xbf,0xbf], [0xef,0xbb,0xbf],
	]
	var invalid := [
		[0x80], [0xbf], [0xc0,0x80], [0xc1,0xbf], [0xc2], [0xc2,0x7f],
		[0xe0,0x9f,0xbf], [0xed,0xa0,0x80], [0xed,0xbf,0xbf],
		[0xef,0xbf], [0xf0,0x8f,0xbf,0xbf], [0xf4,0x90,0x80,0x80],
		[0xf5,0x80,0x80,0x80], [0xff], [0xc2,0,0xa9], [0xe2,0x82,0x20],
	]
	var padding := "a".repeat(256).to_utf8_buffer()
	for values: Array in valid:
		var bytes := PackedByteArray(values)
		_check(Importer._valid_utf8(bytes), "Accept valid UTF-8 boundary: " + bytes.hex_encode())
		_check(Importer._valid_utf8(padding+bytes+padding), "Accept padded UTF-8 boundary: " + bytes.hex_encode())
	for values: Array in invalid:
		var bytes := PackedByteArray(values)
		_check(not Importer._valid_utf8(bytes), "Reject invalid UTF-8 boundary: " + bytes.hex_encode())
		_check(not Importer._valid_utf8(padding+bytes+padding), "Reject padded UTF-8 boundary: " + bytes.hex_encode())
		_check(not Importer._valid_utf8(padding+PackedByteArray([0])+bytes), "Validate bytes beyond a NUL: " + bytes.hex_encode())
	var all_bytes := PackedByteArray()
	for value in range(1,256): all_bytes.append(value)
	var latin1 := all_bytes.get_string_from_ascii()
	var offsets_match := latin1.length() == all_bytes.size()
	for index in latin1.length(): offsets_match = offsets_match and latin1.unicode_at(index) == int(all_bytes[index])
	_check(offsets_match, "Latin-1 decoding preserves the byte offsets used by native ASCII skipping")
	var mixed := ("a"+String.chr(0xe9)+String.chr(0x6f22)+String.chr(0x1f98a)).repeat(128).to_utf8_buffer()
	_check(Importer._valid_utf8(mixed), "Dense mixed UTF-8 remains valid after falling back to the byte loop")
	_check(not Importer._valid_utf8(mixed+PackedByteArray([0xf4,0x90,0x80,0x80])), "Dense fallback still rejects out-of-range Unicode")
	_check(Importer._valid_utf8("a".repeat(Importer.MAX_SOURCE_BYTES).to_utf8_buffer()), "Native ASCII scanning handles the full source-size limit")
	var dense := String.chr(0x10ffff).repeat(Importer.MAX_SOURCE_BYTES >> 2).to_utf8_buffer()
	_check(Importer._valid_utf8(dense), "One non-ASCII span can reach the full source-size limit")
	dense[dense.size()-1] = 0xff
	_check(not Importer._valid_utf8(dense), "A full-size non-ASCII span still validates its invalid final byte")
	var body := "\nvoid main() { gl_FragColor=vec4(1.0); }\n"
	var notice := "// Copyright "+String.chr(0xa9)+" Jos"+String.chr(0xe9)+" "+String.chr(0x6f22)+String.chr(0x1f98a)
	var utf8_path := _write("utf8.glsl", String.chr(0xfeff)+notice+body)
	var decoded := Importer._read_source(utf8_path)
	_check(decoded.ok and decoded.text == notice+body, "Read UTF-8 notices and strip only the leading BOM")
	var latin1_notice := "// Copyright "+String.chr(0xa9)+" Jos"+String.chr(0xe9)
	var latin1_path := _write("latin1.glsl", "")
	var file := FileAccess.open(latin1_path,FileAccess.WRITE)
	file.store_buffer("// Copyright ".to_utf8_buffer()+PackedByteArray([0xa9])+" Jos".to_utf8_buffer()+PackedByteArray([0xe9])+body.to_utf8_buffer())
	file.close()
	decoded = Importer._read_source(latin1_path)
	_check(decoded.ok and decoded.text == latin1_notice+body, "Legacy Latin-1 source notices decode without UTF-8 diagnostics")
	for path: String in [utf8_path,latin1_path]:
		var imported := Importer.load_file(path)
		_check(imported.ok and imported.shader.code.contains(latin1_notice), "Import preserves decoded author notices: " + path.get_file())
