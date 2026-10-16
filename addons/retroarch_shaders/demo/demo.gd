extends Control
## Synthetic source and standard Godot controls; no game data or external assets.
const PostProcess := preload("../post_process.gd")
var effect: CanvasLayer
var source: SubViewport
var moving: ColorRect
var path_edit: LineEdit
var enabled: CheckBox
var status: Label
var parameter_rows: VBoxContainer
var picker: FileDialog
var draft := {}
var last_path := ""
var elapsed := 0.0

func _ready() -> void:
	_create_source()
	effect = PostProcess.new()
	add_child(effect)
	effect.set_framebuffer_texture(source.get_texture())
	effect.set_input_size(Vector2(320,240))
	_controls()
	path_edit.text = get_script().resource_path.get_base_dir().path_join("shaders/scanlines.glsl")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--shader-path="): path_edit.text = argument.trim_prefix("--shader-path=")
	_apply()

func _create_source() -> void:
	source = SubViewport.new()
	source.size = Vector2i(320,240)
	source.disable_3d = true
	source.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(source)
	var image := Image.create(320,240,false,Image.FORMAT_RGBA8)
	for y in 240:
		for x in 320:
			var color := Color(float(x)/319.0,float(y)/239.0,0.45,1.0)
			if x < 80: color = Color.WHITE if ((x >> 2)+(y >> 2))%2 == 0 else Color.BLACK
			if y > 200: color = [Color.RED,Color.GREEN,Color.BLUE,Color.WHITE][floori(float(x)/20.0)%4]
			image.set_pixel(x,y,color)
	var pattern := TextureRect.new()
	pattern.texture = ImageTexture.create_from_image(image)
	pattern.size = Vector2(320,240)
	source.add_child(pattern)
	moving = ColorRect.new()
	moving.color = Color.WHITE
	moving.size = Vector2(16,16)
	source.add_child(moving)
	var display := TextureRect.new()
	display.texture = source.get_texture()
	display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	display.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(display)

func _controls() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 200
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16,16)
	panel.custom_minimum_size = Vector2(340,420)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color("111827f5")
	panel_style.set_content_margin_all(12.0)
	panel_style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel",panel_style)
	layer.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var title := Label.new()
	title.text = "Libretro Shaders for Godot"
	title.add_theme_font_size_override("font_size",18)
	column.add_child(title)
	path_edit = LineEdit.new()
	path_edit.placeholder_text = "External .glslp preset or .glsl source"
	path_edit.custom_minimum_size.x = 340
	column.add_child(path_edit)
	var buttons := HBoxContainer.new()
	column.add_child(buttons)
	var browse := Button.new()
	browse.text = "Browse"
	buttons.add_child(browse)
	var apply := Button.new()
	apply.text = "Apply"
	apply.pressed.connect(_apply)
	buttons.add_child(apply)
	enabled = CheckBox.new()
	enabled.text = "Enabled"
	enabled.button_pressed = true
	enabled.toggled.connect(func(_value: bool): _apply())
	buttons.add_child(enabled)
	status = Label.new()
	status.custom_minimum_size.x = 340
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340,280)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	parameter_rows = VBoxContainer.new()
	parameter_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(parameter_rows)
	picker = FileDialog.new()
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.filters = PackedStringArray(["*.glslp,*.glsl ; RetroArch GLSL"])
	picker.file_selected.connect(func(path: String): path_edit.text = path; _apply())
	add_child(picker)
	browse.pressed.connect(func(): picker.popup_centered_ratio(0.8))

func _apply() -> void:
	path_edit.tooltip_text = path_edit.text
	if path_edit.text != last_path: draft.clear()
	# Configuration can compile a whole pass chain; parameter edits only update
	# the draft until the user presses Apply.
	var configured: Dictionary = effect.configure({"shader_enabled":enabled.button_pressed,"shader_path":path_edit.text,"shader_parameters":draft})
	_clear_parameter_rows()
	status.tooltip_text = ""
	if not configured.ok:
		status.text = str(configured.message)
		_show_preset_choices(configured.get("preset_candidates",[]))
		return
	last_path = path_edit.text
	status.text = "Disabled" if not effect.active else "%d pass(es). Change parameters, then Apply."%effect.current.get("passes",[{}]).size()
	status.tooltip_text = "\n".join(effect.current.get("warnings",[]))
	if not effect.active: return
	draft = effect.current.values.duplicate()
	_show_parameters()

func _clear_parameter_rows() -> void:
	# Detach immediately: Apply can run twice before queued deletion is flushed.
	for child in parameter_rows.get_children():
		parameter_rows.remove_child(child)
		child.queue_free()

func _show_preset_choices(paths: Array) -> void:
	for path: String in paths:
		var button := Button.new()
		button.text = "Load "+path.get_file()
		button.tooltip_text = path
		button.pressed.connect(_load_preset.bind(path))
		parameter_rows.add_child(button)

func _load_preset(path: String) -> void:
	path_edit.text = path
	_apply()

func _show_parameters() -> void:
	for parameter: Dictionary in effect.current.parameters:
		var label := Label.new()
		label.text = str(parameter.get("label",parameter.name))
		parameter_rows.add_child(label)
		var value := SpinBox.new()
		value.min_value = parameter.min
		value.max_value = parameter.max
		value.step = parameter.step
		value.value = draft[parameter.name]
		var parameter_name: String = parameter.name
		value.value_changed.connect(func(number: float): draft[parameter_name] = number)
		parameter_rows.add_child(value)

func _process(delta: float) -> void:
	elapsed += delta
	if moving != null: moving.position = Vector2(150+120*sin(elapsed),100+60*cos(elapsed*0.7))
