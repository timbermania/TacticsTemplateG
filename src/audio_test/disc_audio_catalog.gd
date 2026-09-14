extends RefCounted
## Selective audio-only port of timbermania's TacticsTemplateG PR #3,
## 0ebc36fcbaac56dd30e02bf1b2707c71140bc2d0 (MIT; root LICENSE.txt,
## Copyright (c) 2025 mrgudenheim). Adapted discovery, SED ID semantics and
## effect section extraction, not RomReader.process_rom or its persistent cache.

const Reader = preload("res://src/audio_test/raw_disc_reader.gd")
const Inputs = preload("res://src/audio_test/audition_inputs.gd")
const TABLE_OFFSET := 0x14d8d0
const EFFECT_COUNT := 511
const EFFECT_BASE := 0x801c2500
var reader := Reader.new()
var music: Array[Dictionary] = []
var globals: Array[Dictionary] = []
var effects: Array[Dictionary] = []
var diagnostics: Array[String] = []
var error := ""
var _waveset: Dictionary = {}

func open_private(path: String) -> bool:
	music.clear()
	globals.clear()
	effects.clear()
	diagnostics.clear()
	_waveset = {}
	error = ""
	if not reader.open_private(path):
		error = reader.error
		return false
	diagnostics.assign(reader.diagnostics)
	_waveset = reader.records.get("SOUND/WAVESET.WD", {})
	if _waveset.is_empty():
		diagnostics.append("Missing SOUND/WAVESET.WD; disc initialization unavailable.")
	var names: Array = reader.records.keys()
	names.sort()
	var battle: Dictionary = {}
	var ambiguous_battle := false
	for name: String in names:
		var record: Dictionary = reader.records[name]
		if name.get_file() == "BATTLE.BIN":
			if not battle.is_empty():
				ambiguous_battle = true
			battle = record
		if name.begins_with("SOUND/MUSIC_") and name.ends_with(".SMD"):
			music.append({"name": name.get_file(), "record": record, "error": _size_error(record)})
		if name.begins_with("EFFECT/") and name.get_file().length() == 8:
			var stem := name.get_file().get_basename()
			if stem.begins_with("E") and stem[1] in "0123456789" and stem[2] in "0123456789" and stem[3] in "0123456789" and name.ends_with(".BIN"):
				var id := int(stem.substr(1)) # E000 -> 0, matching VisualEffectData._init.
				effects.append({"name": name.get_file(), "record": record, "id": id, "header": -1, "error": _size_error(record)})
	for name in ["SYSTEM.SED", "ENV.SED"]:
		var record: Dictionary = reader.records.get("SOUND/" + name, {})
		var result := {"error": "Missing SOUND/" + name} if record.is_empty() else reader.read_file(record)
		if result.has("bytes"):
			result = Inputs.feds(result.bytes, true)
		globals.append({"name": name, "result": result, "error": result.get("error", "")})
		if result.has("error"):
			diagnostics.append(name + ": " + result.error)
		else:
			for message: String in result.diagnostics:
				diagnostics.append(name + ": " + message)
	var table := {"error": "Missing/ambiguous BATTLE.BIN; effect layout unavailable."}
	if not battle.is_empty() and not ambiguous_battle:
		# Executable BattleBinData uses 511 contiguous u32s (stride 4), despite
		# its stale '8 bytes each' comment. Do not guess tables for other revisions.
		table = reader.read_file(battle, TABLE_OFFSET, EFFECT_COUNT * 4)
	if table.has("error"):
		diagnostics.append(table.error)
	for entry in effects:
		if not entry.error.is_empty():
			continue
		if table.has("error") or entry.id < 0 or entry.id >= EFFECT_COUNT:
			entry.error = "Unsupported effect index/BATTLE.BIN layout."
			continue
		entry.header = int(table.bytes.decode_u32(entry.id * 4)) - EFFECT_BASE
		if entry.header < 0 or entry.header % 4 != 0 or entry.header + 0x28 > int(entry.record.length):
			entry.error = "Unsupported/corrupt effect header pointer in known BATTLE.BIN table."
	return true

static func _size_error(record: Dictionary) -> String:
	return "Empty/oversized file (32 MiB limit)." if record.length <= 0 or record.length > Reader.MAX_FILE else ""

func waveset_bytes() -> Dictionary:
	if _waveset.is_empty():
		return {"error": "Missing SOUND/WAVESET.WD."}
	return reader.read_file(_waveset)

func load_music(index: int) -> Dictionary:
	if index < 0 or index >= music.size():
		return {"error": "Select a disc music sequence."}
	var entry: Dictionary = music[index]
	if not entry.error.is_empty():
		return {"error": entry.error}
	var result := reader.read_file(entry.record)
	if result.has("bytes"):
		var problem := Inputs.smd_error(result.bytes)
		if not problem.is_empty():
			result = {"error": problem}
	if result.has("error"):
		entry.error = result.error
		diagnostics.append(entry.name + ": " + result.error)
	return result

func load_effect(index: int) -> Dictionary:
	if index < 0 or index >= effects.size():
		return {"error": "Select a disc effect."}
	var entry: Dictionary = effects[index]
	if not entry.error.is_empty():
		return {"error": entry.error}
	# Only the ten-word header and declared sound span are read. Neither the
	# full E### file nor its visual sections are materialized or cached.
	var result := reader.read_file(entry.record, entry.header, 0x28)
	if result.has("bytes"):
		var sound := int(result.bytes.decode_u32(0x20))
		var texture := int(result.bytes.decode_u32(0x24))
		if sound < 0x28 or texture <= sound or entry.header + texture > int(entry.record.length):
			result = {"error": "No valid bounded effect sound section at known header."}
		else:
			result = reader.read_file(entry.record, entry.header + sound, texture - sound)
			if result.has("bytes"):
				# No CODE-header heuristic on disc imports: BATTLE is authoritative.
				if result.bytes.slice(0, 4).get_string_from_ascii() != "feds":
					result = {"error": "No FEDS at known effect sound offset; unsupported revision or absent sound."}
				else:
					result = Inputs.feds(result.bytes)
	if result.has("error"):
		entry.error = result.error
		diagnostics.append(entry.name + ": " + result.error)
	return result
