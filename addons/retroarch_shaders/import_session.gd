extends RefCounted
## Per-call import options and exclusive phase timings. Main-thread use only.
## Disabled profiling never queries the clock or allocates timing records.

var profiling: bool
var cache_enabled: bool
var _started_us := 0
var _phase_started_us := 0
var _phase := "preparation_us"
var _stack: Array[String] = []
var _profile := {}
var _translation := {}
var _translation_started_us := 0
var _translation_phase := ""
var _translation_mark_us := 0


func _init(options: Dictionary = {}) -> void:
	profiling = bool(options.get("profile", false))
	cache_enabled = bool(options.get("cache", true))
	if not profiling:
		return
	_profile = {
		"total_us": 0,
		"read_us": 0,
		"preparation_us": 0,
		"texture_loading_us": 0,
		"translation_us": 0,
		"shader_validation_us": 0,
		"cache_lookup_us": 0,
		"translation_passes": [],
		"cache": {"hits": 0, "misses": 0, "bypasses": 0, "stores": 0, "oversized_skips": 0},
	}
	_started_us = Time.get_ticks_usec()
	_phase_started_us = _started_us


## Suspend the current phase until leave_phase(), so nested work is not counted twice.
func enter_phase(phase: String) -> void:
	if not profiling:
		return
	var now := Time.get_ticks_usec()
	_profile[_phase] += now - _phase_started_us
	_stack.append(_phase)
	_phase = phase
	_phase_started_us = now


func leave_phase() -> void:
	if not profiling:
		return
	var now := Time.get_ticks_usec()
	_profile[_phase] += now - _phase_started_us
	_phase = _stack.pop_back()
	_phase_started_us = now


func note_cache(counter: String) -> void:
	if profiling:
		_profile.cache[counter] += 1


## Translation subphases partition this pass's work inside translation_us.
func begin_translation(pass_index: int) -> void:
	if not profiling:
		return
	enter_phase("translation_us")
	_translation_started_us = Time.get_ticks_usec()
	_translation_mark_us = _translation_started_us
	_translation_phase = "preprocess_us"
	_translation = _pass_record(pass_index, false)
	_profile.translation_passes.append(_translation)


func translation_phase(phase: String) -> void:
	if not profiling:
		return
	var now := Time.get_ticks_usec()
	_translation[_translation_phase] += now - _translation_mark_us
	_translation_phase = phase
	_translation_mark_us = now


func end_translation() -> void:
	if not profiling:
		return
	var now := Time.get_ticks_usec()
	_translation[_translation_phase] += now - _translation_mark_us
	_translation.total_us = now - _translation_started_us
	leave_phase()


func note_cached_pass(pass_index: int) -> void:
	if profiling:
		_profile.translation_passes.append(_pass_record(pass_index, true))


## Finalize once, after all nested phases have completed, and return an owned copy.
func finish() -> Dictionary:
	if not profiling:
		return {}
	var now := Time.get_ticks_usec()
	_profile[_phase] += now - _phase_started_us
	_profile.total_us = now - _started_us
	return _profile.duplicate(true)


func _pass_record(pass_index: int, cache_hit: bool) -> Dictionary:
	return {
		"pass_index": pass_index,
		"cache_hit": cache_hit,
		"total_us": 0,
		"preprocess_us": 0,
		"bindings_us": 0,
		"lowering_us": 0,
		"emission_us": 0,
	}
