extends RefCounted
## Bounded in-memory LRU for pure successful translation results.
## Main-thread use only. Never stores shaders, textures or selected values.

const DEFAULT_MAX_ENTRIES := 64
const DEFAULT_MAX_BYTES := 16 * 1024 * 1024

var _max_entries: int
var _max_bytes: int
var _entries := {}
var _bytes := 0
var _clock := 0
var _hits := 0
var _misses := 0
var _stores := 0
var _evictions := 0
var _oversized_skips := 0


func _init(max_entries: int = DEFAULT_MAX_ENTRIES, max_bytes: int = DEFAULT_MAX_BYTES) -> void:
	_max_entries = maxi(max_entries, 1)
	_max_bytes = maxi(max_bytes, 1)


## Return a copy so attaching per-import metadata cannot mutate the cached entry.
func get_translation(key: String) -> Dictionary:
	if not _entries.has(key):
		_misses += 1
		return {}
	_hits += 1
	_clock += 1
	_entries[key].touched = _clock
	return _entries[key].value.duplicate(true)


## Retain only successful pure translation fields, never runtime resource state.
func store_translation(key: String, result: Dictionary) -> bool:
	if not result.get("ok", false) or not result.get("code") is String:
		return false
	# Godot retains Strings as UTF-32. Include both terminating codepoints;
	# the entry limit separately bounds dictionary/metadata overhead.
	var payload_bytes := 4 * (key.length() + str(result.code).length() + 2)
	if payload_bytes > _max_bytes:
		_oversized_skips += 1
		return false
	if _entries.has(key):
		_remove(key)
	while _entries.size() >= _max_entries or _bytes + payload_bytes > _max_bytes:
		_remove(_oldest_key())
		_evictions += 1
	_clock += 1
	_entries[key] = {
		"value": {
			"ok": true,
			"code": result.code,
			"custom_geometry": bool(result.get("custom_geometry", false)),
		},
		"bytes": payload_bytes,
		"touched": _clock,
	}
	_bytes += payload_bytes
	_stores += 1
	return true


func clear() -> void:
	_entries.clear()
	_bytes = 0
	_clock = 0
	_hits = 0
	_misses = 0
	_stores = 0
	_evictions = 0
	_oversized_skips = 0


## Discard code rejected by the fresh Godot parser validation.
func remove_translation(key: String) -> void:
	if _entries.has(key):
		_remove(key)


## Bytes bounds retained key + code String payloads, excluding container overhead.
func stats() -> Dictionary:
	return {
		"entries": _entries.size(),
		"bytes": _bytes,
		"max_entries": _max_entries,
		"max_bytes": _max_bytes,
		"hits": _hits,
		"misses": _misses,
		"stores": _stores,
		"evictions": _evictions,
		"oversized_skips": _oversized_skips,
	}


# The small fixed entry limit bounds this scan; avoid linked-list bookkeeping
# on every hit when eviction is needed only for a new translation.
func _oldest_key() -> String:
	var oldest := ""
	var oldest_tick := _clock + 1
	for candidate: String in _entries:
		var touched := int(_entries[candidate].touched)
		if touched < oldest_tick:
			oldest = candidate
			oldest_tick = touched
	return oldest


func _remove(key: String) -> void:
	_bytes -= int(_entries[key].bytes)
	_entries.erase(key)
