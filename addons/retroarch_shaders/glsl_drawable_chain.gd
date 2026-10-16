extends RefCounted
## GPU snapshots of composed original frames and the feedback pass. CRT passes
## stay in canvas shaders, where derivatives and interpolation are available.
const COPY_SHADER_CODE := """shader_type texture_blit;
render_mode blend_disabled;
uniform sampler2D source : hint_blit_source0, filter_nearest, repeat_disable;
uniform vec4 crop = vec4(0.0, 0.0, 1.0, 1.0);
void blit() { COLOR0 = texture(source, crop.xy + UV * crop.zw); }
"""

var current: Dictionary
var history: Array[DrawableTexture2D] = []
var feedback: DrawableTexture2D
var logical_size := Vector2i.ZERO
var sizes: Array[Vector2i] = []
var copy_material: ShaderMaterial
var feedback_material: ShaderMaterial
var history_count := 1
var _crop := Vector4(0, 0, 1, 1)

static func required_history_count(passes: Array) -> int:
	# Translation prunes unused samplers. Retain the current original plus only
	# the oldest previous frame that a live sampler can actually read.
	var count := 1
	for info: Dictionary in passes:
		if not info.has("shader"): continue
		var uniforms := {}
		for uniform: Dictionary in info.shader.get_shader_uniform_list():
			uniforms[str(uniform.name)] = true
		for descriptor: Dictionary in info.get("dynamic_textures",[]):
			if descriptor.has("history_index") and (uniforms.has(descriptor.uniform) or uniforms.has(descriptor.uniform+"_mips")):
				count = maxi(count,int(descriptor.history_index)+2)
	return count

func _init(loaded: Dictionary) -> void:
	current = loaded
	history_count = required_history_count(loaded.passes)
	var shader := Shader.new()
	shader.code = COPY_SHADER_CODE
	copy_material = ShaderMaterial.new()
	copy_material.shader = shader
	# Blits execute on the rendering thread. A feedback copy must not overwrite
	# the original copy's crop uniform while that command is still queued.
	feedback_material = ShaderMaterial.new()
	feedback_material.shader = shader

func resize(next_sizes: Array[Vector2i], original_size: Vector2i) -> void:
	if next_sizes == sizes and original_size == logical_size: return
	sizes = next_sizes.duplicate()
	var reset_history := original_size != logical_size
	# A window resize often changes viewport-scaled passes while the game's
	# logical source remains fixed. Keep its history pixels and GPU textures;
	# resetting them causes a visible temporal flash and unnecessary uploads.
	if reset_history:
		logical_size = original_size
		history.clear()
		for index in history_count:
			var texture := DrawableTexture2D.new()
			# LOD reads use explicit mip atlases, not hardware mipmaps.
			texture.setup(logical_size.x,logical_size.y,DrawableTexture2D.DRAWABLE_FORMAT_RGBA8,Color.TRANSPARENT,false)
			history.append(texture)
	if current.has("feedback_pass"):
		var index: int = current.feedback_pass
		if reset_history or feedback == null or Vector2i(feedback.get_size()) != sizes[index]:
			feedback = DrawableTexture2D.new()
			feedback.setup(sizes[index].x,sizes[index].y,DrawableTexture2D.DRAWABLE_FORMAT_RGBAH if current.passes[index].float_framebuffer else DrawableTexture2D.DRAWABLE_FORMAT_RGBA8,Color.TRANSPARENT,false)

func render(source: Texture2D, crop: Vector4, feedback_source: Texture2D = null) -> void:
	if history.is_empty() or source == null: return
	var original: DrawableTexture2D = history.pop_back()
	if _crop != crop:
		_crop = crop
		copy_material.set_shader_parameter("crop",crop)
	original.blit_rect(Rect2i(Vector2i.ZERO,logical_size),source,Color.WHITE,0,copy_material)
	history.push_front(original)
	if feedback != null and feedback_source != null:
		feedback.blit_rect(Rect2i(Vector2i.ZERO,sizes[current.feedback_pass]),feedback_source,Color.WHITE,0,feedback_material)
