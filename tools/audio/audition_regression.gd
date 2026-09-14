extends SceneTree
## Synthetic files only; run through run_audition_checks.py with isolated user data.

const Inputs = preload("res://src/audio_test/audition_inputs.gd")
const Sample = preload("res://addons/exmateria_spu/runtime/spu_sample.gd")
const Spu = preload("res://addons/exmateria_spu/runtime/spu.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("AUDITION_REGRESSION: " + message)

func save_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or not OS.get_user_data_dir().begins_with(args[0] + "/"):
		push_error("AUDITION_REGRESSION: refusing non-isolated user data")
		quit(1)
		return
	# Native debug counters/core state are not atomic. Prove the public wrapper
	# blocks on the mixer lock, rather than relying on a stress test to find UB.
	var probe := Spu.new()
	var started := Semaphore.new()
	var finished := Semaphore.new()
	var thread := Thread.new()
	AudioServer.lock()
	var thread_error := thread.start(func() -> Dictionary:
		started.post()
		var snapshot := probe.get_debug_stats()
		finished.post()
		return snapshot)
	if thread_error == OK:
		started.wait()
		OS.delay_msec(50)
		check(not finished.try_wait(), "debug snapshot waits for AudioServer mixer lock")
	AudioServer.unlock()
	check(thread_error == OK, "snapshot lock probe thread starts")
	if thread_error == OK:
		var snapshot: Dictionary = thread.wait_to_finish()
		check(snapshot.has("active_voices"), "debug snapshot completes after mixer lock releases")
	probe = null
	# A music player constructs a sequencer even before it plays anything.
	var player = load("res://src/audio_test/audition_music.gd").new()
	root.add_child(player)
	var lifetime: WeakRef = weakref(player.seq)
	player.free()
	check(lifetime.get_ref() == null, "unused music sequencer released on exit")
	if args[1] == "lifetime":
		print("AUDITION_REGRESSION: " + ("PASS" if failures.is_empty() else "FAIL"))
		root.get_node("ApplicationShutdown").request_quit(0 if failures.is_empty() else 1)
		return
	check(AudioServer.get_driver_name() != "Dummy", "real mixer required")
	check(Inputs.read_private("res://project.godot").has("error"), "project-local input rejected")
	check(Inputs.read_private(args[0] + "/missing").has("error"), "missing input rejected")
	check(Inputs.feds(PackedByteArray([1, 2])).has("error"), "short FEDS rejected")
	check(not Inputs.smd_error(PackedByteArray()).is_empty(), "short SMD rejected")
	var feds := PackedByteArray()
	feds.resize(0x22)
	feds.encode_u32(0, 0x73646566)
	feds.encode_u32(4, feds.size())
	feds.encode_u16(8, 2)
	feds.encode_u32(12, 0x1c)
	feds.encode_u16(0x18, 0x1c)
	feds.encode_u16(0x1a, 0x1f)
	for offset in [0x1c, 0x1f]:
		feds[offset] = 0x80 # Rest, then EndBar; deliberately silent fixture.
		feds[offset + 1] = 0xff
		feds[offset + 2] = 0x90
	check(Inputs.feds(feds).has("bank"), "raw FEDS accepted")
	var bank = Inputs.feds(feds).bank
	check(Inputs.sound_id_error(bank, -1).is_empty(), "default sound ID accepted")
	check(Inputs.sound_id_error(bank, 5).is_empty(), "last in-bounds sound ID accepted")
	check(not Inputs.sound_id_error(bank, 6).is_empty(), "first out-of-bounds sound ID rejected")
	check(not Inputs.sound_id_error(bank, -2).is_empty(), "invalid negative sound ID rejected")
	var malformed := feds.duplicate()
	malformed.encode_u16(8, 0xffff)
	check(Inputs.feds(malformed).has("error"), "truncated pair table rejected")
	malformed = feds.duplicate()
	malformed.encode_u16(0x18, 0xffff)
	check(Inputs.feds(malformed).has("error"), "bad track pointer rejected")
	var effect := PackedByteArray()
	effect.resize(0x28)
	effect.encode_u32(0x20, 0x28)
	effect.encode_u32(0x24, 0x28 + feds.size())
	effect.append_array(feds)
	check(Inputs.feds(effect).has("bank"), "DATA effect sound section accepted")
	var code := PackedByteArray()
	code.resize(0x10)
	code.encode_u32(0, 0x27bdffe0)
	effect.encode_u32(0, 0x28)
	effect.encode_u32(4, 0x2c)
	code.append_array(effect)
	check(Inputs.feds(code).has("bank"), "CODE effect sound section accepted")
	var smd := PackedByteArray()
	smd.resize(0x27)
	smd.encode_u32(0, 0x73646d73)
	smd.encode_u16(8, smd.size())
	smd[0x14] = 1
	smd[0x18] = 127
	smd.encode_u16(0x22, 0x24)
	smd[0x24] = 0x80
	smd[0x25] = 0xff
	smd[0x26] = 0x90
	check(Inputs.smd_error(smd).is_empty(), "synthetic SMD accepted")
	malformed = smd.duplicate()
	malformed.encode_u16(0x22, 0xffff)
	check(not Inputs.smd_error(malformed).is_empty(), "bad SMD pointer rejected")
	var pcm := PackedInt32Array()
	for i in range(448):
		pcm.append(int(12000 * sin(TAU * float(i) / 56.0)))
	var sample = Sample.from_pcm16(pcm, 0)
	var waveset := PackedByteArray()
	waveset.resize(0x30)
	waveset.encode_u32(0, 0x73647764)
	waveset.encode_u32(0x10, 0x30)
	waveset.encode_u16(0x24, sample.data.size())
	waveset[0x2c] = 15
	waveset.append_array(sample.data)
	var base := args[0]
	save_bytes(base + "/synthetic.wd", waveset)
	save_bytes(base + "/synthetic.smd", smd)
	save_bytes(base + "/synthetic.feds", feds)
	var scene = load("res://src/audio_test/audio_test.tscn").instantiate()
	root.add_child(scene)
	check(scene._music_button.disabled and scene._sfx_button.disabled, "uninitialized controls disabled")
	scene.play_music()
	check(scene._music == null, "uninitialized play refused")
	scene._paths.waveset.text = base + "/synthetic.wd"
	scene.initialize_bank()
	check(root.get_node("ExMateriaAudioEngine").ready_ok, "UI initializes engine")
	check(scene._initialize_button.disabled, "bank replacement disabled")
	scene._paths.music.text = base + "/synthetic.smd"
	scene.play_music()
	check(scene._music != null and scene._music.is_playing(), "UI starts music")
	scene._paths.feds.text = base + "/synthetic.feds"
	scene.load_sfx_bank()
	check(not scene._sfx_button.disabled and scene._pair.max_value == 0, "pair range configured")
	scene.play_pair()
	check(scene._token > 0, "UI creates SFX session")
	var original_token: int = scene._token
	scene._sound_id.value = 6
	scene.play_pair()
	check(scene._token == original_token and scene._status.text.begins_with("Sound ID is outside"),
		"invalid sound ID reports error without stopping current audition")
	scene._sound_id.value = -1
	var sfx = root.get_node("ExMateriaEffectSfx")
	sfx._audio_mutex.lock()
	var entity_lifetime: WeakRef = weakref(sfx._sessions[scene._token]["play"]._entity_catchup)
	sfx._audio_mutex.unlock()
	scene.stop_all()
	# The parked scheduler can retain its last local snapshot until waking.
	# Verify the cycle is broken now; verbose exit checks assert final release.
	check(entity_lifetime.get_ref() == null or entity_lifetime.get_ref().owning_play_sound == null,
		"stopped SFX entity no longer owns its cast")
	check(scene._token == 0 and not scene._music.is_playing(), "stop clears session and music")
	scene._paths.feds.text = base + "/missing"
	scene.load_sfx_bank()
	check(scene._bank == null and scene._sfx_button.disabled, "failed replacement clears stale bank")
	scene._paths.feds.text = base + "/synthetic.feds"
	scene.load_sfx_bank()
	scene.play_pair()
	scene.play_music()
	await create_timer(0.25).timeout
	print("AUDITION_REGRESSION: " + ("PASS" if failures.is_empty() else "FAIL"))
	if args[1] == "stopped":
		scene.stop_all()
	if args[1] == "window":
		root.get_node("ApplicationShutdown").notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	else:
		root.get_node("ApplicationShutdown").request_quit(0 if failures.is_empty() else 1)
