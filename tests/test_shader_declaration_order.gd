extends SceneTree
## Stable dependency ordering and reachability for generated shader declarations.
const Importer := preload("res://addons/retroarch_shaders/glsl_importer.gd")

var checks := 0
var failures := 0


func _init() -> void:
	_function_order()
	_structure_order()
	_cycle_fallback()
	if "--benchmark" in OS.get_cmdline_user_args():
		_benchmark()
	print("Shader declaration order: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)


func _function_order() -> void:
	var caller := "float caller() { return leaf() + leaf(); }"
	var independent := "float independent() { return 0.0; }"
	var leaf := "float leaf() { return 1.0; }"
	var overload := "vec2 leaf(vec2 value) { return value; }"
	var unused := "float unused() { return independent(); }"
	var global := "const float initial = independent();"
	var roots := PackedStringArray(["void fragment() { COLOR = vec4(caller()); }"])
	var units := PackedStringArray([caller, independent, leaf, overload, unused, global])
	var ordered := Importer._ordered_declarations(units, roots)
	_check(ordered == PackedStringArray([global, independent, leaf, overload, caller]),
		"Dependencies precede callers, overloads stay together, global initializers are roots, and unused functions are pruned")
	_check(Importer._ordered_declarations(units) == PackedStringArray([global, independent, leaf, overload, caller, unused]),
		"Without roots, every function is retained and each dependency layer preserves source order")
	var self_call := "float recursive() { return recursive(); }"
	_check(Importer._ordered_declarations(PackedStringArray([self_call])) == PackedStringArray([self_call]),
		"Self references do not block declaration ordering; Godot validates recursion later")


func _structure_order() -> void:
	var outer := "struct Outer { Inner value; };"
	var independent := "struct Independent { float value; };"
	var inner := "struct Inner { float value; };"
	var global := "uniform float gain = 1.0;"
	var helper := "float helper(Outer item) { return item.value.value; }"
	var units := PackedStringArray([outer, independent, inner, global, helper])
	_check(Importer._ordered_declarations(units) == PackedStringArray([global, independent, inner, outer, helper]),
		"Structure dependencies precede their users with stable ordering of independent structures")
	var longer_name := "struct InnerSuffix { float value; };"
	_check(Importer._ordered_declarations(PackedStringArray([longer_name, inner])) == PackedStringArray([longer_name, inner]),
		"Identifier prefixes do not create false structure dependencies")


func _cycle_fallback() -> void:
	var first := "float first() { return second(); }"
	var second := "float second() { return first(); }"
	var blocked := "float blocked() { return first(); }"
	var ready := "float ready() { return 1.0; }"
	var units := PackedStringArray([blocked, first, ready, second])
	_check(Importer._ordered_declarations(units) == PackedStringArray([ready, blocked, first, second]),
		"Function cycles retain unresolved declarations in original order for parser diagnostics")
	var types := PackedStringArray(["struct A { B value; };", "struct B { A value; };", "struct C { float value; };"])
	_check(Importer._ordered_declarations(types) == PackedStringArray([types[2]]),
		"Invalid cyclic structures preserve the existing unresolved-type behavior")


func _benchmark() -> void:
	# A deep helper chain exposes repeated body scanning without GPU or disk I/O.
	var units := PackedStringArray()
	for index in 96:
		var body := "float value = input_value; " + "value = value * 0.9 + 0.1; ".repeat(8)
		body += "return helper_%d(value);" % (index + 1) if index < 95 else "return value;"
		units.append("float helper_%d(float input_value) { %s }" % [index, body])
	var roots := PackedStringArray(["void fragment() { COLOR = vec4(helper_0(1.0)); }"])
	Importer._ordered_declarations(units, roots)
	var samples: Array[int] = []
	for iteration in 7:
		var started := Time.get_ticks_usec()
		var ordered := Importer._ordered_declarations(units, roots)
		samples.append(Time.get_ticks_usec() - started)
		_check(ordered.size() == units.size() and ordered[0] == units[-1] and ordered[-1] == units[0],
			"Deep helper chain is fully retained and ordered")
	samples.sort()
	print("96-helper declaration order median: %d us; samples: %s" % [samples[samples.size() >> 1], samples])
