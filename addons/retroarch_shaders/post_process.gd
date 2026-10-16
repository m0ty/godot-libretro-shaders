class_name RetroArchPostProcess
extends CanvasLayer
## Display-only RetroArch effects. Supply a composed source texture for multipass
## presets; the source viewport and its unprocessed pixels remain untouched.
const Importer := preload("./glsl_importer.gd")
const DrawableChain := preload("./glsl_drawable_chain.gd")
const MipAtlas := preload("./glsl_mip_atlas.gd")

var active := false
var error_message := ""
var current: Dictionary = {}
var input_size := Vector2.ZERO
var source_region := Rect2()
var frame_count := 0
var _use_source_region := false
var _capture: BackBufferCopy
var _display: ColorRect
var _material: ShaderMaterial
var _framebuffer_texture: Texture2D
var _chain: Node
var _passes: Array[Dictionary] = []
var _drawable: RefCounted
var _snapshot_mips := {}
var _layout_dirty := true
var _last_root := Vector2.ZERO
var _last_region := Rect2()
var _last_input := Vector2.ZERO
var _cached_layout := {}
var _uniform_frame := -1
var performance_counters := false
var performance_stats := {"layout_updates":0,"frame_updates":0}
const MAX_PASS_PIXELS := 16 * 1024 * 1024
const MAX_CHAIN_PIXELS := 64 * 1024 * 1024


func _init() -> void:
	layer = 110
	visible = false


func _enter_tree() -> void:
	# Nodes can leave and rejoin the tree without running _ready() again.
	# Reconnect here so temporal snapshots resume after scene reparenting.
	_update_processing()
	_layout_dirty = true


func _ready() -> void:
	_ensure_nodes()
	_update_processing()
	_update_uniforms()


func _exit_tree() -> void:
	if RenderingServer.frame_post_draw.is_connected(_render_drawable):
		RenderingServer.frame_post_draw.disconnect(_render_drawable)


func _update_processing() -> void:
	# Most installed effects are disabled or use a single screen shader. Only
	# drawable chains need the global frame-completion signal for snapshots.
	set_process(active)
	var needs_snapshots := active and _drawable != null and is_inside_tree()
	var connected := RenderingServer.frame_post_draw.is_connected(_render_drawable)
	if needs_snapshots and not connected:
		RenderingServer.frame_post_draw.connect(_render_drawable)
	elif not needs_snapshots and connected:
		RenderingServer.frame_post_draw.disconnect(_render_drawable)


## Loading is transactional: an invalid replacement leaves the current effect
## visible. Disabling explicitly releases both the shader and framebuffer copy.
func configure(options: Dictionary) -> Dictionary:
	_ensure_nodes()
	if not bool(options.get("shader_enabled",false)):
		active = false
		_clear_chain()
		visible = false
		_capture.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
		_display.material = null
		_material = null
		current = {}
		frame_count = 0
		error_message = ""
		_update_processing()
		return {"ok":true,"message":"","active":false}
	var path_value: Variant = options.get("shader_path","")
	var parameter_values: Variant = options.get("shader_parameters",{})
	if not path_value is String or str(path_value).is_empty():
		return _failure("Choose a GLSL shader or preset first.")
	if not parameter_values is Dictionary:
		return _failure("Shader parameters must contain named values.")
	var loaded: Dictionary = Importer.load_file(str(path_value),parameter_values)
	if not bool(loaded.get("ok",false)):
		var failed := _failure(str(loaded.get("message","The shader could not be loaded.")))
		if loaded.has("preset_candidates"): failed["preset_candidates"] = loaded.preset_candidates
		return failed
	return configure_imported(loaded)

## Retain an accepted effect for settings rollback even if its file disappears.
func configure_imported(loaded: Dictionary) -> Dictionary:
	_ensure_nodes()
	if loaded.has("passes"): return _configure_chain(loaded)
	var shader: Shader = loaded.get("shader") as Shader
	if shader == null:
		return _failure("The shader importer did not return a usable shader.")
	# The compatibility renderer parses on first inspection. A failed parse must
	# not replace the previous material. Headless rendering cannot validate GPU
	# shaders; its importer/lifecycle checks are intentionally separate.
	if DisplayServer.get_name() != "headless" and shader.get_shader_uniform_list().is_empty():
		return _failure("The imported shader could not be compiled by Godot.")
	var candidate := ShaderMaterial.new()
	candidate.shader = shader
	var values: Dictionary = loaded.get("values",{})
	for parameter_name: String in values:
		candidate.set_shader_parameter(parameter_name,values[parameter_name])
	# Preset lookup images use their own coordinates, filtering and wrap modes.
	# Keep these resources in the candidate material so a failed import leaves
	# both the previous shader and its texture bindings intact.
	var textures: Dictionary = loaded.get("textures",{})
	for uniform_name: String in textures:
		candidate.set_shader_parameter(uniform_name,textures[uniform_name])
	_clear_chain()
	_material = candidate
	_display.material = candidate
	_display.show()
	_capture.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	current = loaded.duplicate()
	error_message = ""
	frame_count = 0
	active = true
	visible = true
	_update_processing()
	_update_uniforms()
	return {"ok":true,"message":"","active":true,"current":current}

func set_framebuffer_texture(texture: Texture2D) -> void:
	if _framebuffer_texture == texture: return
	_layout_dirty = true
	_framebuffer_texture = texture
	_update_uniforms()

func _clear_chain() -> void:
	_layout_dirty = true
	_cached_layout = {}
	_uniform_frame = -1
	_drawable = null
	_snapshot_mips.clear()
	if _chain != null:
		remove_child(_chain)
		_chain.queue_free()
	_chain = null
	_passes.clear()

func _configure_chain(loaded: Dictionary) -> Dictionary:
	if _framebuffer_texture == null: return _failure("Multipass effects need a separate composed framebuffer.")
	var layout := _chain_sizes(loaded.passes,loaded.get("feedback_pass",-1))
	if not layout.ok: return _failure(layout.message)
	var candidate := Node.new()
	var passes: Array[Dictionary] = []
	var mip_indices := _mip_indices(loaded.passes)
	for info: Dictionary in loaded.passes:
		var viewport := SubViewport.new()
		viewport.disable_3d = true
		viewport.transparent_bg = true
		viewport.use_hdr_2d = info.float_framebuffer
		viewport.size = layout.sizes[info.index]
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		candidate.add_child(viewport)
		var display := ColorRect.new()
		display.size = Vector2(viewport.size)
		display.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var material := ShaderMaterial.new()
		material.shader = info.shader
		for parameter_name: String in loaded.values: material.set_shader_parameter(parameter_name,loaded.values[parameter_name])
		for uniform_name: String in loaded.textures: material.set_shader_parameter(uniform_name,loaded.textures[uniform_name])
		display.material = material
		viewport.add_child(display)
		var mip: RefCounted = MipAtlas.new(candidate,viewport.get_texture(),layout.sizes[info.index],info) if loaded.get("drawable",false) and mip_indices.has(info.index) else null
		var pass_data := _snapshot_binding_config(info)
		pass_data.merge({"viewport":viewport,"display":display,"material":material,"info":info,"mip":mip})
		passes.append(pass_data)
	var presentation_shader := Shader.new()
	presentation_shader.code = "shader_type canvas_item; render_mode unshaded, blend_disabled; uniform sampler2D final_frame : filter_linear, repeat_disable; void fragment() { COLOR = texture(final_frame, UV); }"
	var presentation_material := ShaderMaterial.new()
	presentation_material.shader = presentation_shader
	presentation_material.set_shader_parameter("final_frame",passes.back().viewport.get_texture())
	_clear_chain()
	_chain = candidate
	_passes = passes
	add_child(candidate)
	_capture.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	_display.material = presentation_material
	_material = passes.back().material
	current = loaded.duplicate()
	if loaded.get("drawable",false):
		_drawable = DrawableChain.new(loaded)
		var original_size := Vector2i(_pixel_size(input_size if input_size != Vector2.ZERO else (source_region.size if _use_source_region else get_viewport().get_visible_rect().size)))
		_drawable.resize(layout.sizes,original_size)
		for key: int in _snapshot_mip_keys(loaded.passes):
			var size: Vector2i = layout.sizes[loaded.feedback_pass] if key == -2 else original_size
			var info: Dictionary = loaded.passes[loaded.feedback_pass] if key == -2 else {"float_framebuffer":false,"srgb_framebuffer":false}
			_snapshot_mips[key] = MipAtlas.new(candidate,_snapshot_texture(key),size,info)
	error_message = ""
	frame_count = 0
	active = true
	visible = true
	_update_processing()
	_update_uniforms()
	return {"ok":true, "message":"", "active":true, "current":current}


func _snapshot_binding_config(info: Dictionary) -> Dictionary:
	# Translation removes unused compatibility samplers. Cache the remaining
	# temporal bindings once, instead of scanning every alias/history slot and
	# sending values for nonexistent uniforms on each completed frame.
	var uniforms := {}
	for uniform: Dictionary in info.shader.get_shader_uniform_list():
		uniforms[str(uniform.name)] = true
	var bindings: Array[Dictionary] = []
	for descriptor: Dictionary in info.dynamic_textures:
		if descriptor.pass_index >= 0 and not descriptor.get("feedback",false) and not descriptor.has("history_index"):
			continue
		var texture_uniform := uniforms.has(descriptor.uniform)
		var mips_uniform := uniforms.has(descriptor.uniform+"_mips")
		if texture_uniform or mips_uniform:
			bindings.append({"uniform":descriptor.uniform,"key":_snapshot_key(descriptor),"texture":texture_uniform,"mips":mips_uniform})
	return {"snapshot_bindings":bindings,"source_snapshot":uniforms.has("ra_source"),"source_snapshot_mips":uniforms.has("ra_source_mips")}


func _render_drawable() -> void:
	if not active or _drawable == null or not _cached_layout.get("ok",false) or _framebuffer_texture == null: return
	var root_size := get_viewport().get_visible_rect().size
	var region := source_region if _use_source_region else Rect2(Vector2.ZERO,root_size)
	var feedback: Texture2D = _passes[current.feedback_pass].viewport.get_texture() if current.has("feedback_pass") else null
	_drawable.render(_framebuffer_texture,Vector4(region.position.x/root_size.x,region.position.y/root_size.y,region.size.x/root_size.x,region.size.y/root_size.y),feedback)
	# Without historical reads the original and feedback textures are updated
	# in place. Their bindings (including mip atlases) remain valid after a blit.
	if _drawable.history.size() > 1:
		_update_dynamic_uniforms(true)

func _chain_sizes(infos: Array, feedback_index: int = -1) -> Dictionary:
	var output := source_region.size if _use_source_region else get_viewport().get_visible_rect().size
	var previous := _pixel_size(input_size if input_size != Vector2.ZERO else output)
	var sizes: Array[Vector2i] = []
	var total := 0
	var bytes := 0
	var mip_indices := _mip_indices(infos)
	var advanced := false
	for info: Dictionary in infos:
		advanced = advanced or info.get("advanced",false)
		var extent := Vector2.ZERO
		for axis in 2:
			var key := "x" if axis == 0 else "y"
			var type: String = info.sizing["type_"+key]
			var base := previous[axis] if type == "source" else (output[axis] if type == "viewport" else 1.0)
			extent[axis] = maxf(2.0,floorf(base*float(info.sizing["scale_"+key])))
		if not extent.is_finite() or extent.x > 16384 or extent.y > 16384 or extent.x*extent.y > MAX_PASS_PIXELS: return {"ok":false, "message":"Pass %d exceeds the 16 megapixel render-target limit."%info.index}
		var size := Vector2i(extent)
		total += size.x*size.y
		if total > MAX_CHAIN_PIXELS: return {"ok":false, "message":"The shader chain exceeds the 64 megapixel render-target budget."}
		var pixel_bytes := 8 if info.get("float_framebuffer",false) else 4
		bytes += size.x*size.y*pixel_bytes
		if mip_indices.has(info.index):
			if size.y*2+16 > 16384: return {"ok":false,"message":"Pass %d exceeds the mipmap atlas dimension limit."%info.index}
			bytes += size.x*(size.y*2+16)*pixel_bytes
			for level in range(1,16): bytes += maxi(2,size.x >> level)*maxi(2,size.y >> level)*pixel_bytes
		if info.index == feedback_index: bytes += size.x*size.y*pixel_bytes
		if bytes > 256*1024*1024: return {"ok":false,"message":"The shader chain exceeds the 256 MiB render-target budget."}
		sizes.append(size)
		previous = Vector2(size)
	if advanced:
		var original := _pixel_size(input_size if input_size != Vector2.ZERO else output)
		bytes += int(original.x)*int(original.y)*4*DrawableChain.required_history_count(infos)
		for key: int in _snapshot_mip_keys(infos):
			var size := sizes[feedback_index] if key == -2 else Vector2i(original)
			if size.y*2+16 > 16384: return {"ok":false,"message":"The shader snapshot exceeds the mipmap atlas dimension limit."}
			var pixel_bytes := 8 if key == -2 and infos[feedback_index].get("float_framebuffer",false) else 4
			bytes += size.x*(size.y*2+16)*pixel_bytes
			for level in range(1,16): bytes += maxi(2,size.x >> level)*maxi(2,size.y >> level)*pixel_bytes
		if original.x > 16384 or original.y > 16384 or original.x*original.y > MAX_PASS_PIXELS or bytes > 256*1024*1024: return {"ok":false,"message":"The shader history exceeds the render-target budget."}
	return {"ok":true, "sizes":sizes}

func _mip_indices(infos: Array) -> Dictionary:
	var required := {}
	for info: Dictionary in infos:
		if not info.has("shader"): continue
		var code: String = info.shader.code
		if info.index > 0 and code.contains("ra_mip_ra_source_"): required[info.index-1] = true
		for descriptor: Dictionary in info.get("dynamic_textures",[]):
			if descriptor.pass_index >= 0 and not descriptor.get("feedback",false) and code.contains("ra_mip_"+descriptor.uniform+"_"): required[descriptor.pass_index] = true
	return required

func _snapshot_mip_keys(infos: Array) -> Dictionary:
	var required := {}
	for info: Dictionary in infos:
		if not info.has("shader"): continue
		var code: String = info.shader.code
		if info.index == 0 and code.contains("ra_mip_ra_source_"): required[-1] = true
		for descriptor: Dictionary in info.get("dynamic_textures",[]):
			if (descriptor.pass_index < 0 or descriptor.get("feedback",false)) and code.contains("ra_mip_"+descriptor.uniform+"_"):
				required[_snapshot_key(descriptor)] = true
	return required

func _snapshot_key(descriptor: Dictionary) -> int:
	return -2 if descriptor.get("feedback",false) else (-3-int(descriptor.history_index) if descriptor.has("history_index") else -1)

func _snapshot_texture(key: int) -> Texture2D:
	return _drawable.feedback if key == -2 else _drawable.history[0 if key == -1 else -key-2]


## Logical texel dimensions are whole pixels, floored with a minimum of one.
## Invalid dimensions retain the output-size fallback.
func set_input_size(value: Vector2) -> void:
	var next := _pixel_size(value) if value.is_finite() and value.x > 0.0 and value.y > 0.0 else Vector2.ZERO
	if not _use_source_region and input_size == next: return
	input_size = next
	_use_source_region = false
	source_region = Rect2()
	_layout_dirty = true
	_update_uniforms()

## Region coordinates are physical pixels in the root viewport. Matching the
## effect's quad to the source image avoids resampling the surrounding bars or
## shifting a logical texel grid when a window centers the gameplay viewport.
func set_source_region(region: Rect2,logical_size: Vector2) -> void:
	var valid := region.position.is_finite() and region.size.is_finite() and region.size.x > 0.0 and region.size.y > 0.0
	var next_region := region if valid else Rect2()
	var next_input := _pixel_size(logical_size) if logical_size.is_finite() and logical_size.x > 0.0 and logical_size.y > 0.0 else Vector2.ZERO
	if _use_source_region == valid and source_region == next_region and input_size == next_input: return
	_use_source_region = valid
	source_region = next_region
	input_size = next_input
	_layout_dirty = true
	_update_uniforms()


func _pixel_size(value: Vector2) -> Vector2:
	# Keep snapshot dimensions, allocation accounting and shader texel grids in
	# agreement, including a subpixel physical region used as the fallback.
	return value.floor().max(Vector2.ONE)


func _process(_delta: float) -> void:
	if not active: return
	frame_count = (frame_count+1) % 2147483647
	_update_uniforms()


func _ensure_nodes() -> void:
	if _capture != null: return
	_capture = BackBufferCopy.new()
	_capture.name = "PostProcessCapture"
	_capture.copy_mode = BackBufferCopy.COPY_MODE_DISABLED
	add_child(_capture)
	_display = ColorRect.new()
	_display.name = "PostProcessDisplay"
	_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_display.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	add_child(_display)


func _update_uniforms() -> void:
	if not active or _material == null or not is_inside_tree(): return
	var root_size := get_viewport().get_visible_rect().size
	var region := source_region if _use_source_region else Rect2(Vector2.ZERO,root_size)
	if not _layout_dirty and _last_root == root_size and _last_region == region and _last_input == input_size:
		_update_dynamic_uniforms()
		return
	_layout_dirty = false
	_last_root = root_size
	_last_region = region
	_last_input = input_size
	if performance_counters: performance_stats.layout_updates += 1
	_display.position = region.position
	_display.size = region.size
	if not _passes.is_empty():
		_cached_layout = _chain_sizes(current.passes,current.get("feedback_pass",-1))
		if not _cached_layout.ok:
			error_message = _cached_layout.message
			_display.hide()
			_set_chain_enabled(false)
			return
		if _drawable != null: _drawable.resize(_cached_layout.sizes,Vector2i(_pixel_size(input_size if input_size != Vector2.ZERO else region.size)))
		_update_chain(region,root_size)
	else:
		_material.set_shader_parameter("ra_input_size",_pixel_size(input_size if input_size != Vector2.ZERO else region.size))
		_material.set_shader_parameter("ra_output_size",region.size)
		_material.set_shader_parameter("ra_output_origin",region.position)
		_material.set_shader_parameter("ra_source_uv_rect",Vector4(region.position.x/root_size.x,region.position.y/root_size.y,region.size.x/root_size.x,region.size.y/root_size.y))
	_update_dynamic_uniforms(true)

## Frame counters change once per frame. Only drawable history/feedback textures
## rotate after drawing; ordinary pass texture bindings remain stable.
func _update_dynamic_uniforms(history_changed: bool = false) -> void:
	if not _passes.is_empty() and not _cached_layout.get("ok",false): return
	if _uniform_frame != frame_count:
		if _passes.is_empty(): _material.set_shader_parameter("ra_frame_count",frame_count)
		else:
			for data: Dictionary in _passes:
				data.material.set_shader_parameter("ra_frame_count",frame_count % int(data.info.frame_count_mod) if data.info.frame_count_mod > 0 else frame_count)
		_uniform_frame = frame_count
		if performance_counters: performance_stats.frame_updates += 1
	if not history_changed or _drawable == null or _drawable.history.is_empty(): return
	for key: int in _snapshot_mips:
		var mip: RefCounted = _snapshot_mips[key]
		mip.set_source(_snapshot_texture(key))
	var first: ShaderMaterial = _passes[0].material
	if _passes[0].source_snapshot:
		first.set_shader_parameter("ra_source",_drawable.history[0])
	if _passes[0].source_snapshot_mips and not _snapshot_mips.has(-1):
		first.set_shader_parameter("ra_source_mips",_drawable.history[0])
	for data: Dictionary in _passes:
		for binding: Dictionary in data.snapshot_bindings:
			var texture := _snapshot_texture(binding.key)
			if binding.texture and binding.key != -2:
				data.material.set_shader_parameter(binding.uniform,texture)
			# Atlas resources and the feedback texture never rotate. Layout
			# updates already bind them; only unatlased history needs rebinding.
			if binding.mips and binding.key != -2 and not _snapshot_mips.has(binding.key):
				data.material.set_shader_parameter(binding.uniform+"_mips",texture)

func _update_chain(region: Rect2,root_size: Vector2) -> void:
	var layout: Dictionary = _cached_layout
	error_message = ""
	_display.show()
	_set_chain_enabled(true)
	# Atlas extents change with layout, while their source textures rotate after
	# drawing. Keep resizing out of the per-frame snapshot-binding path.
	for key: int in _snapshot_mips:
		_snapshot_mips[key].resize(_drawable.sizes[current.feedback_pass] if key == -2 else _drawable.logical_size)
	var original_size := _pixel_size(input_size if input_size != Vector2.ZERO else region.size)
	var original_uv := Vector4(region.position.x/root_size.x,region.position.y/root_size.y,region.size.x/root_size.x,region.size.y/root_size.y)
	for index in _passes.size():
		var data: Dictionary = _passes[index]
		var material: ShaderMaterial = data.material
		data.viewport.size = layout.sizes[index]
		data.display.size = Vector2(layout.sizes[index])
		if data.mip != null: data.mip.resize(layout.sizes[index])
		material.set_shader_parameter("ra_source",_pass_texture(index-1))
		material.set_shader_parameter("ra_input_size",original_size if index == 0 else Vector2(layout.sizes[index-1]))
		material.set_shader_parameter("ra_source_uv_rect",original_uv if index == 0 and _drawable == null else Vector4(0,0,1,1))
		if _drawable != null:
			material.set_shader_parameter("ra_source_hardware_mips",false)
			material.set_shader_parameter("ra_source_mips",_pass_mip_texture(index-1))
		material.set_shader_parameter("ra_output_size",Vector2(layout.sizes[index]))
		material.set_shader_parameter("ra_output_origin",Vector2.ZERO)
		for descriptor: Dictionary in data.info.dynamic_textures:
			_bind_dynamic_texture(material,descriptor,original_size,original_uv)


## Negative pass indices refer to the composed original frame. Drawable chains
## read a cropped snapshot; ordinary multipass chains read the host framebuffer.
func _pass_texture(index: int) -> Texture2D:
	if index >= 0:
		return _passes[index].viewport.get_texture()
	return _drawable.history[0] if _drawable != null else _framebuffer_texture


func _pass_mip_texture(index: int) -> Texture2D:
	if index < 0 and _snapshot_mips.has(-1):
		return _snapshot_mips[-1].atlas.get_texture()
	if index >= 0 and _passes[index].mip != null:
		return _passes[index].mip.atlas.get_texture()
	return _pass_texture(index)


func _bind_dynamic_texture(material: ShaderMaterial, descriptor: Dictionary, original_size: Vector2, original_uv: Vector4) -> void:
	var index: int = descriptor.pass_index
	var original := index < 0
	var is_feedback: bool = descriptor.get("feedback",false)
	var texture := _pass_texture(index)
	if _drawable != null:
		if is_feedback:
			texture = _drawable.feedback
		elif descriptor.has("history_index") and descriptor.history_index+1 < _drawable.history.size():
			texture = _drawable.history[descriptor.history_index+1]
	material.set_shader_parameter(descriptor.uniform,texture)
	material.set_shader_parameter(descriptor.uniform+"_size",original_size if original else Vector2(_cached_layout.sizes[index]))
	material.set_shader_parameter(descriptor.uniform+"_uv_rect",original_uv if original and _drawable == null else Vector4(0,0,1,1))
	if _drawable == null:
		return
	var mip_texture := texture
	if original or is_feedback:
		var key := _snapshot_key(descriptor)
		if _snapshot_mips.has(key):
			mip_texture = _snapshot_mips[key].atlas.get_texture()
	else:
		mip_texture = _pass_mip_texture(index)
	material.set_shader_parameter(descriptor.uniform+"_hardware_mips",false)
	material.set_shader_parameter(descriptor.uniform+"_mips",mip_texture)


func _set_chain_enabled(enabled: bool) -> void:
	for data: Dictionary in _passes:
		data.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
		if data.mip != null:
			data.mip.set_enabled(enabled)
	for mip: RefCounted in _snapshot_mips.values():
		mip.set_enabled(enabled)


func _failure(message: String) -> Dictionary:
	error_message = message
	return {"ok":false,"message":message,"active":active}
