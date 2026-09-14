## Load the sound-related artifacts godot-learning's parser emits per effect:
##   {effect_dir}/sound_containers.json — the per-effect [SoundContainer]s
##                                         (TIER-2 resolver entries)
##   {effect_dir}/sound.json            — sound-subsystem keyframes (phase1/phase2/for_each)
##   {effect_dir}/timeline.json         — header with phase1_duration/spawn_delay/phase2_delay
##   {effect_dir}/feds.bin              — raw feds blob (this branch's new addition)
##
## Schema is locked to godot-learning's parser output (see
## tools/transform_for_godot.py + tools/parse_all_effects_py.py in that repo).

const _FedsBank = preload("res://addons/exmateria_sound/runtime/feds_bank.gd")


class LoadedEffect:
	var effect_name: String = ""
	var sound_containers: Dictionary = {}   # { "containers": [ {mode, id_a, id_b, id_c, index}, ... ] }
	var sound_tracks: Dictionary = {}       # { "phase1": [...], "phase2": [...], "for_each": [...] }
	var timeline_header: Dictionary = {}    # { phase1_duration, spawn_delay, phase2_delay, ... }
	var feds_bank: _FedsBank = null

	func has_sound() -> bool:
		return feds_bank != null and feds_bank.num_pairs > 0

	func script_is_three_phase() -> bool:
		## A 3-phase effect populates both phase1 and for_each tracks;
		## a 1-phase effect only has for_each.
		var p1 = sound_tracks.get("phase1", [])
		return p1 is Array and not (p1 as Array).is_empty()


static func load_dir(effect_dir: String) -> LoadedEffect:
	var le := LoadedEffect.new()
	le.effect_name = effect_dir.get_file()
	le.sound_containers = _read_json(effect_dir.path_join("sound_containers.json"))
	le.sound_tracks = _read_json(effect_dir.path_join("sound.json"))
	var tl := _read_json(effect_dir.path_join("timeline.json"))
	if tl.has("header"):
		le.timeline_header = tl["header"]
	var feds_path := effect_dir.path_join("feds.bin")
	if FileAccess.file_exists(feds_path):
		le.feds_bank = _FedsBank.load_from_file(feds_path)
	return le


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}
