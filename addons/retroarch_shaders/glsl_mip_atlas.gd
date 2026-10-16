extends RefCounted
## GPU mip levels remain viewport dependencies, so consumers see levels from
## the same frame as their base pass. sRGB texels decode before averaging.
const Importer := preload("./glsl_importer.gd")
const LEVEL_COUNT := 16
const COPY_SHADER_CODE := """shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform sampler2D source : filter_nearest, repeat_disable;
void fragment() { COLOR = texture(source, UV); }
"""
var atlas: SubViewport
var levels: Array[Dictionary] = []
var size := Vector2i.ZERO
var _source: Texture2D
var _enabled := true
var _last_level := 0
var _downsample_program: Shader
var _copy_program: Shader
var _use_hdr := false

func _init(parent: Node, source: Texture2D, original_size: Vector2i, info: Dictionary) -> void:
	atlas = SubViewport.new()
	atlas.disable_3d = true
	atlas.transparent_bg = true
	atlas.use_hdr_2d = info.float_framebuffer
	atlas.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(atlas)
	# Keep two shared programs as the mip pool grows. Materials stay separate
	# because their sources and dimensions differ at each level.
	_downsample_program = _downsample_shader(info)
	_copy_program = Shader.new()
	_copy_program.code = COPY_SHADER_CODE
	_use_hdr = info.float_framebuffer
	_source = source
	resize(original_size)


func _append_level() -> void:
	var index := levels.size()
	var previous: Texture2D = _source if index <= 1 else levels[index-1].viewport.get_texture()
	var level_viewport: SubViewport
	var level_rect: ColorRect
	var material: ShaderMaterial
	if index > 0:
		level_viewport = SubViewport.new()
		level_viewport.disable_3d = true
		level_viewport.transparent_bg = true
		level_viewport.use_hdr_2d = _use_hdr
		level_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		atlas.get_parent().add_child(level_viewport)
		level_rect = ColorRect.new()
		level_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		material = ShaderMaterial.new()
		material.shader = _downsample_program
		material.set_shader_parameter("mip_source",previous)
		level_rect.material = material
		level_viewport.add_child(level_rect)
		previous = level_viewport.get_texture()
	var copy := ColorRect.new()
	copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var copy_material := ShaderMaterial.new()
	copy_material.shader = _copy_program
	copy_material.set_shader_parameter("source",previous)
	copy.material = copy_material
	atlas.add_child(copy)
	levels.append({"viewport":level_viewport,"rect":level_rect,"material":material,"copy":copy})


func _downsample_shader(info: Dictionary) -> Shader:
	var code := """shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform sampler2D mip_source : filter_nearest, repeat_disable;
uniform vec2 mip_dimensions;
uniform vec2 mip_output_dimensions;
uniform vec4 crop = vec4(0.0, 0.0, 1.0, 1.0);
"""
	if info.srgb_framebuffer:
		code += Importer._srgb_header()
	code += Importer._frame_sampler("mip_source",true,false,"mip_dimensions","crop","sample_source",info.srgb_framebuffer)
	code += """void fragment() {
	vec2 center = (floor(UV * mip_output_dimensions) + vec2(0.5)) / mip_output_dimensions;
	COLOR = sample_source(mip_source, center);
"""
	if info.srgb_framebuffer:
		code += "\tCOLOR.rgb = ra_srgb_encode(COLOR.rgb);\n"
	code += "}\n"
	var shader := Shader.new()
	shader.code = code
	return shader


func set_source(source: Texture2D) -> void:
	# Original/history snapshots rotate without changing the mip layout.
	# Feedback uses one persistent texture whose pixels change in place.
	if _source == source:
		return
	_source = source
	levels[0].copy.material.set_shader_parameter("source",source)
	if levels.size() > 1:
		levels[1].material.set_shader_parameter("mip_source",source)

func resize(original_size: Vector2i) -> void:
	if size == original_size: return
	size = original_size
	atlas.size = Vector2i(size.x,size.y*2+LEVEL_COUNT)
	var extent := size
	var required_levels := 1
	while extent != Vector2i.ONE and required_levels < LEVEL_COUNT:
		extent = Vector2i(maxi(extent.x >> 1,1),maxi(extent.y >> 1,1))
		required_levels += 1
	# The first 1x1 level fills every remaining atlas slot. Allocate only the
	# dependencies needed to reach it, then keep that pool for later resizes.
	while levels.size() < required_levels:
		_append_level()
	extent = size
	var offset := 0
	_last_level = LEVEL_COUNT-1
	for index in levels.size():
		var data: Dictionary = levels[index]
		var copy: ColorRect = data.copy
		copy.position = Vector2(0,offset)
		copy.size = Vector2(extent)
		copy.visible = index <= _last_level
		if extent == Vector2i.ONE and index <= _last_level:
			_last_level = index
			# Every remaining atlas slot is the same 1x1 texel. Stretch one
			# nearest-filtered copy over those rows instead of downsampling and
			# drawing that texel repeatedly. Keep the 16-slot layout intact for
			# explicit texelFetch calls as well as clamped textureLod reads.
			copy.size.y = LEVEL_COUNT-index
		offset += extent.y
		if data.viewport != null:
			data.viewport.size = Vector2i(maxi(extent.x,2),maxi(extent.y,2))
			data.rect.size = Vector2(data.viewport.size)
			data.material.set_shader_parameter("mip_dimensions",Vector2(maxi(size.x >> (index-1),1),maxi(size.y >> (index-1),1)))
			data.material.set_shader_parameter("mip_output_dimensions",Vector2(extent))
		extent = Vector2i(maxi(extent.x >> 1,1),maxi(extent.y >> 1,1))
	set_enabled(_enabled)


## Pause every atlas dependency when its owning chain cannot render.
func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	atlas.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	for index in range(1,levels.size()):
		levels[index].viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled and index <= _last_level else SubViewport.UPDATE_DISABLED
