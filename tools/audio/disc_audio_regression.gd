extends SceneTree
## Synthetic-only disc catalog, selector, playback and shutdown regression.
const Fixture = preload("res://tools/audio/synthetic_disc.gd")
const Reader = preload("res://src/audio_test/raw_disc_reader.gd")
const Catalog = preload("res://src/audio_test/disc_audio_catalog.gd")
const Inputs = preload("res://src/audio_test/audition_inputs.gd")
const Sample = preload("res://addons/exmateria_spu/runtime/spu_sample.gd")
var failures: Array[String] = []
var initialized_count := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("DISC_AUDIO_REGRESSION: " + message)

func save_bytes(path: String, data: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(data)
	file.close()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or not OS.get_user_data_dir().begins_with(args[0] + "/"):
		push_error("DISC_AUDIO_REGRESSION: refusing non-isolated user data")
		quit(1)
		return
	check(AudioServer.get_driver_name() != "Dummy", "real mixer required")
	var base := args[0]
	var pcm := PackedInt32Array()
	for i in range(448):
		pcm.append(int(12000 * sin(TAU * float(i) / 56.0)))
	var sample = Sample.from_pcm16(pcm, 0)
	var waveset := PackedByteArray()
	waveset.resize(0x40)
	waveset.encode_u32(0, 0x73647764)
	waveset.encode_u32(0x10, 0x40)
	# FFT runtime instrument 0 addresses WAVESET descriptor 1; descriptor 0 is null.
	waveset.encode_u16(0x34, sample.data.size())
	waveset[0x38] = 0 # Fast attack in the installed SPU's rate convention.
	waveset[0x39] = 15 # Slow decay/sustain keep the note audible past ADPCM's leading block.
	waveset[0x3a] = 127
	waveset[0x3c] = 15
	waveset.append_array(sample.data)
	var smd := PackedByteArray()
	smd.resize(2051)
	smd.encode_u32(0, 0x73646d73)
	smd.encode_u16(8, smd.size())
	smd[0x14] = 1
	smd[0x18] = 127
	smd.encode_u16(0x22, 2048)
	smd[2048] = 0x80
	smd[2049] = 0xff
	smd[2050] = 0x90
	var feds := PackedByteArray()
	feds.resize(0x22)
	feds.encode_u32(0, 0x73646566)
	feds.encode_u32(4, feds.size())
	feds.encode_u16(8, 2)
	feds.encode_u32(12, 0x1c)
	feds.encode_u16(0x18, 0x1c)
	feds.encode_u16(0x1a, 0x1f)
	for offset in [0x1c, 0x1f]:
		feds[offset] = 0x80
		feds[offset + 1] = 0xff
		feds[offset + 2] = 0x90
	var sed := PackedByteArray()
	sed.resize(0x48)
	sed.encode_u32(0, 0x73646566)
	sed.encode_u32(4, sed.size())
	sed.encode_u16(8, 5) # ID 0 empty, ID 1 A only, ID 2 hole, ID 3 B only, ID 4 both
	sed.encode_u32(12, 0x28)
	sed.encode_u16(0x18, 0x30)
	sed.encode_u16(0x22, 0x38)
	sed.encode_u16(0x24, 0x30)
	sed.encode_u16(0x26, 0x38)
	sed[0x29] = 64
	sed[0x2b] = 96
	sed[0x2c] = 127
	for offset in [0x30, 0x38]:
		# Original generated note: instrument 0, C at velocity 96, then EndBar.
		var note := PackedByteArray([0xac, 0, 0x60, 1, 0x90])
		for i in range(note.size()):
			sed[offset + i] = note[i]
	var global_result := Inputs.feds(sed, true)
	check(global_result.has("bank"), "global parser accepts single channels and holes")
	var bank = global_result.bank
	check(bank.raw == sed and bank.instr_byte_for(3) == 96 and bank.chan_92_for(1) == 0x3000, "original raw/gain preserved")
	check(global_result.choices[0].sound_id == 1 and global_result.choices[2].pair == 2, "original ID N maps to pair N-1")
	check(global_result.choices[0].single_track == 0 and global_result.choices[2].single_track == 1, "single-track API selectors")
	check(not global_result.choices[1].error.is_empty(), "ID hole disabled, not renumbered")
	check(bank.get_track_events_from(1).is_empty() and bank.get_track_events(4).is_empty() and bank.get_track_bytes(2).is_empty(), "zero offsets never decode FEDS header")
	var invalid := sed.duplicate()
	invalid.encode_u16(0x18, 2)
	check(not Inputs.feds(invalid, true).choices[0].error.is_empty(), "corrupt global ID disabled independently")
	invalid = sed.duplicate()
	invalid.encode_u32(12, sed.size() - 1)
	check(not Inputs.feds(invalid, true).choices[0].error.is_empty(), "out-of-range gain disabled")
	invalid = sed.duplicate()
	invalid.encode_u16(8, 65535)
	check(Inputs.feds(invalid, true).has("error"), "oversized SED table rejected")
	invalid = sed.duplicate()
	invalid.encode_u16(0x14, 0x30)
	check(not Inputs.feds(invalid, true).diagnostics.is_empty(), "nonempty global ID0 diagnosed as unsupported")
	var image := Fixture.make(waveset, smd, feds, sed)
	var path := base + "/synthetic-disc.bin"
	save_bytes(path, image)
	var reader := Reader.new()
	check(not reader.open_private("res://project.godot"), "project path refused")
	check(not reader.open_private(base + "/missing-disc"), "missing disc refused")
	check(reader.open_private(path), "raw2352 Mode2 volume accepted: " + reader.error)
	check(reader.read_file(reader.records["SOUND/MUSIC_00.SMD"]).bytes == smd, "cross-sector exact declared file read without padding")
	check(reader.read_file(reader.records["SOUND/MUSIC_00.SMD"], 2047, 4).bytes == smd.slice(2047), "unaligned cross-sector read")
	check(reader.read_file(reader.records["SOUND/MUSIC_00.SMD"], 2048, 4).has("error"), "declared file bounds enforced")
	check(reader.read_file({"lba": 0, "length": Reader.MAX_FILE + 1}, 0, 4).has("error"), "file size budget enforced even for partial reads")
	var catalog := Catalog.new()
	check(catalog.open_private(path), "audio catalog opens")
	check(catalog.music.size() == 2 and catalog.effects.size() == 3 and catalog.globals.size() == 2, "selectors discovered")
	check(catalog.reader.bytes_read < 20000, "catalog never materializes whole BATTLE or effects")
	check(not catalog.globals[1].error.is_empty(), "missing ENV reported/disabled")
	check(catalog.waveset_bytes().bytes == waveset, "exact waveset extraction")
	check(catalog.effects[0].id == 0 and catalog.effects[0].header == 0 and catalog.effects[1].id == 1 and catalog.effects[1].header == 0x7f0, "E000/001 numeric mapping and stride4 table")
	var before := catalog.reader.bytes_read
	check(catalog.load_effect(1).bank.raw == feds, "lazy effect header crosses sectors beyond heuristic scan range")
	check(catalog.reader.bytes_read - before < 256, "only header and sound section read lazily")
	check(catalog.load_effect(2).has("error") and not catalog.effects[2].error.is_empty(), "bad individual effect diagnosed lazily")
	check(catalog.load_music(1).has("error") and not catalog.music[1].error.is_empty(), "bad individual music disabled lazily")
	# Mutations are synthetic and stored only in this isolated temporary directory.
	var bad_path := base + "/malformed-disc.bin"
	invalid = image.duplicate()
	# ISO XA system-use data follows the identifier/padding and is not a file name.
	var xa_record := Fixture.record("SECOND.DAT;1".to_ascii_buffer(), 36, 7)
	var system_use := xa_record.size()
	xa_record.resize(system_use + 14)
	xa_record[0] = xa_record.size()
	xa_record[system_use + 6] = 0x58
	xa_record[system_use + 7] = 0x41
	Fixture.put(invalid, 16, Fixture.record(PackedByteArray([0]), 20, 4096, true), 156)
	# The first directory block ends in zero padding; the next record is in block 2.
	Fixture.put(invalid, 20, xa_record, 2048)
	save_bytes(bad_path, invalid)
	var xa_reader := Reader.new()
	check(xa_reader.open_private(bad_path) and xa_reader.records.has("SECOND.DAT"),
		"XA system-use extension and multi-block directory padding accepted")
	invalid = image.slice(0, image.size() - 1)
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "partial raw sector rejected")
	invalid = image.slice(0, image.size() - 2352)
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "whole-sector truncation rejected by volume size")
	invalid = image.duplicate()
	invalid[17 * 2352 + 24] = 0 # no descriptor terminator
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "missing volume terminator rejected")
	invalid = image.duplicate()
	invalid[16 * 2352 + 24 + 84] = 1
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "volume endian mismatch rejected")
	invalid = image.duplicate()
	invalid[16 * 2352 + 24 + 1] = 0
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "invalid CD001 rejected")
	invalid = image.duplicate()
	invalid[16 * 2352 + 15] = 1
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "Mode1 layout rejected")
	invalid = image.duplicate()
	invalid[16 * 2352 + 18] = 0x20
	invalid[16 * 2352 + 22] = 0x20
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "Mode2 Form2 rejected")
	invalid = PackedByteArray()
	invalid.resize(20 * 2048)
	for i in range(5):
		invalid[16 * 2048 + 1 + i] = "CD001".to_ascii_buffer()[i]
	save_bytes(bad_path, invalid)
	var cooked := Reader.new()
	check(not cooked.open_private(bad_path) and cooked.error.begins_with("Cooked"), "cooked ISO clearly rejected")
	invalid = image.duplicate()
	Fixture.put(invalid, 20, Fixture.record("LOOP".to_ascii_buffer(), 20, 2048, true), 0)
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "directory cycles rejected")
	invalid = image.duplicate()
	# A valid root record followed by a deliberately truncated record.
	var short_root := Fixture.record(PackedByteArray([0]), 20, 40, true)
	Fixture.put(invalid, 16, short_root, 156)
	Fixture.put(invalid, 20, Fixture.record(PackedByteArray([0]), 20, 40, true))
	invalid[20 * 2352 + 24 + 34] = 34
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "truncated directory record rejected before decoding")
	invalid = image.duplicate()
	var bad_root := Fixture.record(PackedByteArray([0]), 20, Reader.MAX_DIRECTORY + 2048, true)
	Fixture.put(invalid, 16, bad_root, 156)
	save_bytes(bad_path, invalid)
	check(not Reader.new().open_private(bad_path), "directory size budget enforced")
	invalid = image.duplicate()
	# Replace WAVESET's directory entry by an out-of-volume record. Other choices survive.
	var bad_record := Fixture.record("WAVESET.WD;1".to_ascii_buffer(), 999999, waveset.size())
	Fixture.put(invalid, 22, bad_record, 68)
	save_bytes(bad_path, invalid)
	var missing := Catalog.new()
	check(missing.open_private(bad_path) and missing.waveset_bytes().has("error") and not missing.diagnostics.is_empty(), "bad file extent diagnosed, missing WAVESET disables initialization")
	# Entry count and depth budgets can be checked without allocating giant fixtures.
	reader._entries = Reader.MAX_ENTRIES
	reader._visited.clear()
	check(not reader._walk({"lba": 20, "length": 2048}, "", 0), "directory entry count bounded")
	reader._visited.clear()
	check(not reader._walk({"lba": 20, "length": 2048}, "", Reader.MAX_DEPTH + 1), "recursion depth bounded")
	# Actual scene controls and public APIs, with the same orderly quit boundary.
	var engine = root.get_node("ExMateriaAudioEngine")
	engine.initialized.connect(func(): initialized_count += 1)
	var scene = load("res://src/audio_test/audio_test.tscn").instantiate()
	root.add_child(scene)
	scene._paths.disc.text = bad_path
	scene.load_disc()
	check(not engine.ready_ok and initialized_count == 0, "missing WAVESET does not initialize engine")
	scene._paths.disc.text = path
	scene.load_disc()
	check(engine.ready_ok and initialized_count == 1 and scene._disc_button.disabled, "disc UI initializes exactly once")
	check(scene._disc_music.item_count == 2 and scene._disc_sfx.item_count == 5 and scene._disc_sfx.is_item_disabled(1), "UI auto-populates and disables missing banks")
	var original = scene._catalog
	scene.load_disc()
	scene.initialize_bank()
	check(scene._catalog == original and initialized_count == 1 and scene._status.text.contains("Restart"), "disc/bank replacement rejected after init")
	check(engine.initialize_from_bytes(waveset) == ERR_ALREADY_IN_USE and initialized_count == 1, "native engine once-only contract preserved")
	scene._disc_music.select(0)
	scene.play_disc_music()
	check(scene._music != null and scene._music.is_playing(), "disc music plays")
	scene._disc_sfx.select(0)
	scene.load_disc_sfx()
	check(scene._choice.item_count == 4 and scene._choice.is_item_disabled(1) and not scene._sound_id.editable, "global original IDs/holes populated")
	scene.load_disc_sfx()
	check(scene._choice.item_count == 4 and scene._catalog.globals[0].result.choices.size() == 4,
		"reloading global bank preserves cached choices")
	scene._disc_sfx.select(3)
	scene.load_disc_sfx()
	scene._disc_sfx.select(0)
	scene.load_disc_sfx()
	check(scene._choice.item_count == 4 and scene._choice.is_item_disabled(1) and not scene._sfx_button.disabled,
		"global to effect to global retains original playable IDs and holes")
	scene.stop_music()
	var capture := AudioEffectCapture.new()
	var capture_index := AudioServer.get_bus_effect_count(0)
	AudioServer.add_bus_effect(0, capture)
	for index in [0, 2, 3]:
		capture.clear_buffer()
		scene._pair.value = index
		scene.play_pair()
		check(scene._token > 0 and int(scene._sound_id.value) == index + 1, "single/both-channel global play via original ID")
		check(await _heard_audio(capture), "generated global-bank notes reach the real mixer")
		scene.stop_sfx()
		check(scene._token == 0, "global token released")
		await create_timer(0.2).timeout
	AudioServer.remove_bus_effect(0, capture_index)
	scene._pair.value = 1
	scene.play_pair()
	check(scene._token == 0 and scene._sfx_button.disabled, "hole cannot play even via spinbox")
	scene._disc_sfx.select(4)
	scene.load_disc_sfx()
	check(scene._bank == null and scene._disc_sfx.is_item_disabled(4), "corrupt lazy effect disabled in UI")
	scene._disc_sfx.select(3)
	scene.load_disc_sfx()
	scene._sound_id.value = -1
	scene.play_pair()
	check(scene._token > 0 and not scene._global_bank, "lazy effect pair plays")
	scene.stop_all()
	check(scene._token == 0 and not scene._music.is_playing(), "disc stop all")
	scene.play_disc_music()
	scene.play_pair()
	await create_timer(0.25).timeout
	print("DISC_AUDIO_REGRESSION: " + ("PASS" if failures.is_empty() else "FAIL"))
	if args[1] == "stopped":
		scene.stop_all()
	if args[1] == "window":
		root.get_node("ApplicationShutdown").notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	else:
		root.get_node("ApplicationShutdown").request_quit(0 if failures.is_empty() else 1)

func _heard_audio(capture: AudioEffectCapture) -> bool:
	for attempt in range(60):
		await create_timer(0.025).timeout
		for frame in capture.get_buffer(capture.get_frames_available()):
			if maxf(absf(frame.x), absf(frame.y)) > 0.0001:
				return true
	return false
