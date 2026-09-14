extends RefCounted
## Synthetic private-cache contract checks, called before disc engine initialization.
const Cache = preload("res://src/audio_test/extracted_audio_catalog.gd")
const Fixture = preload("res://tools/audio/synthetic_disc.gd")

static func save_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()

static func run(base: String, disc: String, waveset: PackedByteArray, smd: PackedByteArray, feds: PackedByteArray, sed: PackedByteArray, check: Callable) -> void:
	var destination := base + "/cache"
	DirAccess.make_dir_recursive_absolute(destination + "/sound")
	save_bytes(destination + "/keep.txt", "unrelated".to_utf8_buffer())
	save_bytes(destination + "/sound/keep.txt", "unrelated".to_utf8_buffer())
	# Stale files from an older export must not become playable via fallback.
	save_bytes(destination + "/sound/ENV.SED", sed)
	save_bytes(destination + "/sound/MUSIC_999.SMD", smd)
	var exported := Cache.export_disc(disc, destination)
	check.call(not exported.has("error"), "exports audio into existing asset destination")
	if exported.has("error"):
		return
	check.call(not exported.diagnostics.is_empty(), "missing and malformed optional assets diagnosed on export")
	var malformed_global := sed.duplicate()
	malformed_global.encode_u16(0x18, 2) # Nonzero pointer inside the header, not an empty ID.
	var malformed_disc := base + "/malformed-global.bin"
	save_bytes(malformed_disc, Fixture.make(waveset, smd, feds, malformed_global))
	var malformed_export := Cache.export_disc(malformed_disc, base + "/malformed-global-cache")
	check.call(not malformed_export.has("error"), "partially usable global bank still exports")
	if not malformed_export.has("error"):
		check.call(malformed_export.diagnostics.has("SYSTEM.SED: Sound ID 1: FEDS track pointer is outside its opcode data."), "malformed global ID reaches export button diagnostics")
		var unique_warnings := {}
		for warning: String in malformed_export.diagnostics:
			unique_warnings[warning] = true
		check.call(unique_warnings.size() == malformed_export.diagnostics.size(), "catalog and file export warnings are deduplicated")
	# A genuine zero-byte E###.BIN placeholder is not an extraction failure.
	# Keep a stale raw file to verify omission is authoritative on re-import.
	var empty_disc := base + "/empty-effect.bin"
	var empty_destination := base + "/empty-effect-cache"
	save_bytes(empty_disc, Fixture.make(waveset, smd, feds, sed, true, true))
	DirAccess.make_dir_recursive_absolute(empty_destination + "/sound/feds")
	save_bytes(empty_destination + "/sound/feds/E003.feds", feds)
	var empty_export := Cache.export_disc(empty_disc, empty_destination)
	check.call(not empty_export.has("error"), "zero-byte effect placeholder does not fail export")
	if not empty_export.has("error"):
		var warnings := "\n".join(empty_export.diagnostics)
		check.call(not warnings.contains("E003"), "zero-byte source effect emits no unavailable warning")
		check.call(warnings.contains("E002.feds"), "malformed nonempty source effect retains unavailable warning")
		var empty_index: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(empty_destination + "/sound/catalog.json"))
		check.call(not empty_index.files.has("feds/E003.feds") and empty_index.files.has("feds/E002.feds"), "index omits zero-byte source but retains malformed nonempty effect")
		var empty_cache := Cache.new()
		check.call(empty_cache.open_private(empty_destination) and empty_cache.effects.size() == 3, "skipped placeholder never becomes stale raw fallback choice")
		check.call(FileAccess.get_file_as_bytes(empty_destination + "/sound/feds/E003.feds") == feds, "skipping empty source does not delete old raw files")
	check.call(FileAccess.get_file_as_string(destination + "/keep.txt") == "unrelated" and FileAccess.get_file_as_string(destination + "/sound/keep.txt") == "unrelated", "export preserves unrelated existing files")
	var cache := Cache.new()
	check.call(cache.open_private(destination), "opens indexed extracted cache")
	check.call(cache.music.size() == 2 and cache.effects.size() == 3, "index prevents stale music discovery and retains unavailable choices")
	check.call(not cache.globals[1].error.is_empty(), "indexed missing ENV never falls back to stale raw file")
	check.call(cache.waveset_bytes().bytes == waveset and cache.load_music(0).bytes == smd and cache.load_effect(1).bank.raw == feds, "raw cache roundtrip matches extracted bytes without disc reads")
	check.call(cache.load_music(1).has("error") and cache.load_effect(2).has("error"), "exported invalid entries remain unavailable")
	var choices: Array = cache.globals[0].result.choices
	check.call(choices.size() == 4 and choices[2].sound_id == 3 and not choices[1].error.is_empty(), "cache preserves original global IDs and holes")
	# Already loaded bytes remain usable if the export disappears during this run.
	DirAccess.remove_absolute(destination + "/sound/MUSIC_00.SMD")
	check.call(cache.load_music(0).bytes == smd, "loaded cache bytes are reused without reopening files")
	var missing := Cache.new()
	check.call(missing.open_private(destination) and missing.load_music(0).has("error"), "fresh import diagnoses missing indexed bytes")
	exported = Cache.export_disc(disc, destination)
	check.call(not exported.has("error"), "repeat export replaces managed files")
	var index_path := destination + "/sound/catalog.json"
	var metadata := FileAccess.get_file_as_bytes(index_path)
	for invalid in ["{", "{}", "{\"version\":99,\"files\":{},\"diagnostics\":[]}", "{\"version\":1,\"files\":{\"../escape\":{}},\"diagnostics\":[]}"]:
		save_bytes(index_path, invalid.to_utf8_buffer())
		var rejected := Cache.new()
		check.call(not rejected.open_private(destination) and rejected.error.contains("re-export"), "invalid/unsupported/unsafe index refuses legacy fallback")
	var oversized := PackedByteArray()
	oversized.resize(Cache.MAX_INDEX + 1)
	save_bytes(index_path, oversized)
	check.call(not Cache.new().open_private(destination), "metadata size bounded before parsing")
	save_bytes(index_path, metadata)
	var changed := smd.duplicate()
	changed[0x18] = 1
	save_bytes(destination + "/sound/MUSIC_00.SMD", changed)
	var mismatch := Cache.new()
	check.call(mismatch.open_private(destination) and mismatch.load_music(0).get("error", "").contains("integrity mismatch"), "lazy byte hash catches interrupted/externally changed export")
	# An interrupted re-export must not let the old index bless changed WAVESET.
	var changed_waveset := waveset.duplicate()
	changed_waveset[changed_waveset.size() - 1] ^= 1
	var changed_disc := base + "/changed-disc.bin"
	save_bytes(changed_disc, Fixture.make(changed_waveset, smd, feds, sed))
	DirAccess.remove_absolute(destination + "/sound/MUSIC_00.SMD")
	DirAccess.make_dir_absolute(destination + "/sound/MUSIC_00.SMD")
	exported = Cache.export_disc(changed_disc, destination)
	check.call(exported.has("error") and FileAccess.get_file_as_bytes(index_path) == metadata, "failed write does not publish new index")
	mismatch = Cache.new()
	check.call(mismatch.open_private(destination) and mismatch.waveset_bytes().get("error", "").contains("integrity mismatch"), "old index rejects files replaced before interrupted publication")
	DirAccess.remove_absolute(destination + "/sound/MUSIC_00.SMD")
	check.call(not Cache.export_disc(disc, destination).has("error"), "re-export recovers inconsistent cache")
	var first_failed := base + "/first-failed"
	DirAccess.make_dir_recursive_absolute(first_failed + "/sound/WAVESET.WD")
	check.call(Cache.export_disc(disc, first_failed).has("error"), "first export write failure is returned")
	check.call(not Cache.new().open_private(first_failed), "incomplete first export cannot masquerade as legacy cache")
	check.call(Cache.export_disc(base + "/missing-disc", base + "/not-created").has("error") and not DirAccess.dir_exists_absolute(base + "/not-created"), "unreadable source produces no cache writes")
	check.call(Cache.export_disc(disc, "res://").has("error") and not Cache.new().open_private("res://"), "project cache paths refused")
	var project_path := ProjectSettings.globalize_path("res://").trim_suffix("/")
	check.call(Cache.private_path(project_path.to_upper()).has("error"), "case-aliased project root refused")
	check.call(Cache.private_path(project_path.to_upper() + "/private-cache").has("error"), "case-aliased project descendant refused")
	check.call(not Cache.private_path(project_path + "-external-cache").has("error"), "sibling sharing project prefix is not contained")
	check.call(Cache.export_disc(disc, "").has("error"), "unconfigured export directory refused")
	var link_dir := DirAccess.open(base)
	check.call(link_dir.create_link(destination, "linked-cache") == OK, "synthetic directory symlink created")
	check.call(not Cache.new().open_private(base + "/linked-cache") and Cache.export_disc(disc, base + "/linked-cache").has("error"), "symlinked cache root refused for read/write")
	DirAccess.remove_absolute(destination + "/sound/WAVESET.WD")
	var sound_dir := DirAccess.open(destination + "/sound")
	check.call(sound_dir.create_link(destination + "/keep.txt", "WAVESET.WD") == OK, "synthetic file symlink created")
	var linked := Cache.new()
	check.call(linked.open_private(destination) and linked.waveset_bytes().has("error"), "symlinked raw file refused on lazy read")
	check.call(Cache.export_disc(disc, destination).has("error") and FileAccess.get_file_as_string(destination + "/keep.txt") == "unrelated", "export never follows raw file symlink")
	DirAccess.remove_absolute(destination + "/sound/WAVESET.WD")
	check.call(not Cache.export_disc(disc, destination).has("error"), "fixture restored for host import")
	# Existing host export method uses the same adapter without initializing audio.
	var tree := Engine.get_main_loop() as SceneTree
	var rom := tree.root.get_node("RomReader")
	rom._audio_rom_path = disc # Avoid unrelated heavyweight gameplay parsing of a synthetic audio-only image.
	check.call(not rom.export_sound(destination).has("error"), "RomReader audio export seam writes indexed cache")
	var game := tree.root.get_node("GameData")
	game.external_data_paths["IMPORT_PATH"] = destination
	# Exercise upstream's actual indexing entrypoint, not just the audio helper.
	# Gameplay definitions remain lazy and the normal index is still populated.
	save_bytes(destination + "/synthetic.action.json", "{}".to_utf8_buffer())
	game.action_paths["old-entry"] = "stale"
	await game.index_data(destination)
	check.call(game.is_ready and game.action_paths.has("synthetic") and not game.action_paths.has("old-entry"), "upstream indexing clears stale paths and indexes gameplay alongside audio")
	check.call(game.actions.is_empty() and not game.map_tile_meshes.is_empty(), "audio indexing preserves upstream lazy loading and tile mesh setup")
	check.call(not tree.root.get_node("ExMateriaAudioEngine").ready_ok, "indexing assets does not initialize playback")
	var imported = game.audio_catalog
	check.call(imported != null and game.get_audio_catalog() == imported, "GameData reuses imported catalog")
	check.call(imported.load_effect(1).bank.raw == feds, "GameData lazy effect read")
	game.external_data_paths["IMPORT_PATH"] = base + "/missing-cache"
	check.call(game.get_audio_catalog() == null and not game.audio_import_error.is_empty(), "changed import path clears stale catalog on failure")
	game.external_data_paths["IMPORT_PATH"] = ""
	game.clear_data()
	var with_env := base + "/with-env.bin"
	save_bytes(with_env, Fixture.make(waveset, smd, feds, sed, true))
	check.call(not Cache.export_disc(with_env, base + "/with-env").has("error"), "both global banks exported")
	DirAccess.remove_absolute(with_env)
	var without_disc := Cache.new()
	check.call(without_disc.open_private(base + "/with-env") and without_disc.globals[1].result.bank.raw == sed, "Environment cache available after source disc removed")
