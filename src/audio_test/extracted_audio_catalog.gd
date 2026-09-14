extends "res://src/audio_test/disc_audio_catalog.gd"
## Adapter for the existing private export/import directory, not a second cache.
## Raw-only donor caches are supported. Our index is authoritative when present.

const INDEX := "catalog.json"
const MAX_INDEX := 256 * 1024
const MAX_ENTRIES := 2048
const MAX_TOTAL := 256 * 1024 * 1024
var directory := ""
var _files: Dictionary = {}
var _loaded: Dictionary = {}
var _loaded_size := 0
var _indexed := false

static func private_path(path: String) -> Dictionary:
	if path.strip_edges().is_empty():
		return {"error": "No private cache directory configured."}
	var absolute := ProjectSettings.globalize_path(path.strip_edges()).simplify_path().trim_suffix("/")
	var project := ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	# Conservatively reject case aliases on every platform so the same cache
	# configuration cannot leak private assets when moved to Windows/macOS.
	var containment_path := absolute.to_lower()
	var containment_project := project.to_lower()
	if not absolute.is_absolute_path() or containment_path == containment_project or containment_path.begins_with(containment_project + "/"):
		return {"error": "Audio cache must be outside the project."}
	# Reject symlinks in every existing component, including the selected root.
	# This also prevents writing through a sound/file symlink outside the cache.
	var current := absolute
	while not current.is_empty() and current != current.get_base_dir():
		var parent := DirAccess.open(current.get_base_dir())
		if parent != null and parent.is_link(current.get_file()):
			return {"error": "Audio cache paths must not contain symbolic links: " + current}
		current = current.get_base_dir()
	return {"path": absolute}

static func _valid_name(name: String) -> bool:
	if name in ["WAVESET.WD", "SYSTEM.SED", "ENV.SED"]:
		return true
	var pattern := RegEx.new()
	pattern.compile("^(MUSIC_[A-Z0-9_]+\\.SMD|feds/E[0-9]{3}\\.feds)$")
	return pattern.search(name) != null

func open_private(path: String) -> bool:
	music = []
	globals = []
	effects = []
	diagnostics = []
	_files = {}
	_loaded = {}
	_loaded_size = 0
	_indexed = false
	error = ""
	var checked := private_path(path)
	if checked.has("error"):
		error = checked.error
		return false
	directory = checked.path.path_join("sound")
	checked = private_path(directory.path_join(INDEX))
	if checked.has("error"):
		error = checked.error
		return false
	if not DirAccess.dir_exists_absolute(directory):
		error = "No sound cache in IMPORT_PATH; re-export assets with audio support."
		return false
	if FileAccess.file_exists(directory.path_join(INDEX)) or DirAccess.dir_exists_absolute(directory.path_join(INDEX)):
		_indexed = true
		var file := FileAccess.open(directory.path_join(INDEX), FileAccess.READ)
		if file == null or file.get_length() <= 0 or file.get_length() > MAX_INDEX:
			return _bad_index()
		var json := JSON.new()
		if json.parse(file.get_buffer(MAX_INDEX).get_string_from_utf8()) != OK:
			return _bad_index()
		var parsed = json.data
		if not parsed is Dictionary or parsed.get("version") != 1 or not parsed.get("files") is Dictionary or not parsed.get("diagnostics") is Array:
			return _bad_index()
		if parsed.files.size() > MAX_ENTRIES or parsed.diagnostics.size() > MAX_ENTRIES:
			return _bad_index()
		for name in parsed.files:
			var entry = parsed.files[name]
			if not name is String or not _valid_name(name) or not entry is Dictionary:
				return _bad_index()
			if entry.has("error"):
				if not entry.error is String or entry.error.is_empty() or entry.has("sha256"):
					return _bad_index()
			elif not entry.get("sha256") is String or not _is_hash(entry.sha256):
				return _bad_index()
		for message in parsed.diagnostics:
			if not message is String:
				return _bad_index()
			diagnostics.append(message)
		_files = parsed.files
	else:
		# Bounded nonrecursive discovery, only the known raw sound layout.
		for subdir in ["", "feds"]:
			checked = private_path(directory.path_join(subdir))
			if checked.has("error"):
				error = checked.error
				return false
			var dir := DirAccess.open(directory.path_join(subdir))
			if dir == null:
				continue
			dir.list_dir_begin()
			var count := 0
			var name := dir.get_next()
			while not name.is_empty():
				count += 1
				if count > MAX_ENTRIES:
					error = "Too many entries in audio cache."
					return false
				var relative: String = name if subdir.is_empty() else subdir + "/" + name
				if _valid_name(relative):
					_files[relative] = {}
				name = dir.get_next()
		diagnostics.append("Legacy raw-only sound cache: no integrity index; re-export to add one.")
	var names := _files.keys()
	names.sort()
	for name: String in names:
		if name.begins_with("MUSIC_"):
			music.append({"name": name, "error": _files[name].get("error", "")})
		elif name.begins_with("feds/"):
			effects.append({"name": name.get_file(), "file": name, "error": _files[name].get("error", "")})
	for name in ["SYSTEM.SED", "ENV.SED"]:
		var result := _read_cached(name)
		if result.has("bytes"):
			result = Inputs.feds(result.bytes, true)
		globals.append({"name": name, "result": result, "error": result.get("error", "")})
		if result.has("error"):
			diagnostics.append(name + ": " + result.error)
	return true

func _bad_index() -> bool:
	error = "Invalid/unsupported sound/catalog.json; re-export assets. Raw-file fallback is disabled when an index exists."
	return false

static func _is_hash(value: String) -> bool:
	if value.length() != 64:
		return false
	for ch in value:
		if ch not in "0123456789abcdef":
			return false
	return true

static func _hash(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

func _read_cached(name: String) -> Dictionary:
	if _loaded.has(name):
		return _loaded[name]
	if not _files.has(name):
		return {"error": "Missing " + name + " in audio cache; re-export assets."}
	if _files[name].has("error"):
		return {"error": _files[name].error}
	var checked := private_path(directory.path_join(name))
	var result := checked if checked.has("error") else Inputs.read_private(checked.path)
	if result.has("bytes") and _indexed and _hash(result.bytes) != _files[name].sha256:
		result = {"error": "Audio cache integrity mismatch for " + name + "; interrupted/changed export. Re-export assets."}
	if result.has("bytes"):
		if _loaded_size + result.bytes.size() > MAX_TOTAL:
			return {"error": "Audio cache exceeds the 256 MiB memory budget."}
		_loaded_size += result.bytes.size()
	_loaded[name] = result
	return result

func waveset_bytes() -> Dictionary:
	return _read_cached("WAVESET.WD")

func load_music(index: int) -> Dictionary:
	if index < 0 or index >= music.size():
		return {"error": "Select a music sequence."}
	var result := _read_cached(music[index].name)
	if result.has("bytes"):
		var problem := Inputs.smd_error(result.bytes)
		if not problem.is_empty():
			result = {"error": problem}
	if result.has("error"):
		music[index].error = result.error
	return result

func load_effect(index: int) -> Dictionary:
	if index < 0 or index >= effects.size():
		return {"error": "Select an effect."}
	var result := _read_cached(effects[index].file)
	if result.has("bytes"):
		result = Inputs.feds(result.bytes)
	if result.has("error"):
		effects[index].error = result.error
	return result

static func export_disc(disc_path: String, export_path: String) -> Dictionary:
	var checked := private_path(export_path)
	if checked.has("error"):
		return checked
	var target: String = checked.path.path_join("sound")
	checked = private_path(target.path_join("feds"))
	if checked.has("error"):
		return checked
	var catalog = load("res://src/audio_test/disc_audio_catalog.gd").new()
	if not catalog.open_private(disc_path):
		return {"error": catalog.error}
	var mkdir := DirAccess.make_dir_recursive_absolute(target.path_join("feds"))
	if mkdir != OK:
		return {"error": "Cannot create sound cache: " + error_string(mkdir)}
	var index := {"version": 1, "files": {}, "diagnostics": catalog.diagnostics.duplicate()}
	var jobs: Array[Dictionary] = [{"name": "WAVESET.WD", "kind": "waveset"}]
	for i in range(catalog.globals.size()):
		jobs.append({"name": catalog.globals[i].name, "kind": "global", "index": i})
	for i in range(catalog.music.size()):
		jobs.append({"name": catalog.music[i].name, "kind": "music", "index": i})
	for i in range(catalog.effects.size()):
		# Only confirmed zero-byte source E###.BIN placeholders are intentional
		# omissions. Nonempty extraction failures remain indexed and diagnosed.
		# The authoritative index also prevents stale raw FEDS fallback.
		if catalog.effects[i].record.length == 0:
			continue
		jobs.append({"name": "feds/" + catalog.effects[i].name.get_basename() + ".feds", "kind": "effect", "index": i})
	if jobs.size() > MAX_ENTRIES:
		return {"error": "Too many audio cache entries."}
	# An interrupted first export must not masquerade as a legacy raw-only cache.
	checked = private_path(target.path_join(INDEX))
	if checked.has("error"):
		return checked
	if not FileAccess.file_exists(target.path_join(INDEX)):
		var marker_error := _atomic_write(target.path_join(INDEX), "{\"incomplete\":true}".to_utf8_buffer())
		if not marker_error.is_empty():
			return {"error": marker_error}
	var total := 0
	for job in jobs:
		if not _valid_name(job.name):
			return {"error": "Unsupported cache filename: " + job.name}
		var result: Dictionary
		match job.kind:
			"waveset": result = catalog.waveset_bytes()
			"global": result = catalog.globals[job.index].result
			"music": result = catalog.load_music(job.index)
			"effect": result = catalog.load_effect(job.index)
		if result.has("error"):
			index.files[job.name] = {"error": result.error}
			continue
		var bytes: PackedByteArray = result.bank.raw if result.has("bank") else result.bytes
		total += bytes.size()
		if total > MAX_TOTAL:
			return {"error": "Audio export exceeds the 256 MiB budget."}
		var problem := _atomic_write(target.path_join(job.name), bytes)
		if not problem.is_empty():
			return {"error": problem}
		index.files[job.name] = {"sha256": _hash(bytes)}
	var metadata := JSON.stringify(index, "\t").to_utf8_buffer()
	if metadata.size() > MAX_INDEX:
		return {"error": "Audio cache index exceeds its size budget."}
	var problem := _atomic_write(target.path_join(INDEX), metadata)
	if not problem.is_empty():
		return {"error": problem}
	var warnings: Array[String] = []
	# Global banks can be partially usable: their invalid IDs are catalog
	# diagnostics rather than whole-file errors. Surface these to export UI too.
	for diagnostic: String in index.diagnostics:
		if not warnings.has(diagnostic):
			warnings.append(diagnostic)
	for name: String in index.files:
		if index.files[name].has("error"):
			var diagnostic: String = name + ": " + index.files[name].error
			if not warnings.has(diagnostic):
				warnings.append(diagnostic)
	return {"diagnostics": warnings, "files": jobs.size(), "bytes": total}

static func _atomic_write(path: String, bytes: PackedByteArray) -> String:
	var checked := private_path(path)
	if checked.has("error"):
		return checked.error
	# Unique temporary file; never truncate a user's existing staging file.
	var temporary := path + ".tmp-" + Crypto.new().generate_random_bytes(12).hex_encode()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return "Cannot write audio cache: " + error_string(FileAccess.get_open_error())
	file.store_buffer(bytes)
	file.flush()
	var code := file.get_error()
	file.close()
	if code == OK:
		code = DirAccess.rename_absolute(temporary, path)
	if code != OK:
		DirAccess.remove_absolute(temporary)
		return "Cannot publish audio cache file " + path.get_file() + ": " + error_string(code)
	return ""
