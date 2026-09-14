extends Node
## Content-free integration check: real native backend, real autoloads, real mixer.

const Spu = preload("res://addons/exmateria_spu/runtime/spu.gd")
const Sample = preload("res://addons/exmateria_spu/runtime/spu_sample.gd")
var failures: Array[String] = []
var initialized_count := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("AUDIO_SMOKE: " + message)


func _ready() -> void:
	# Also usable in the full host project, exercising its unchanged helper.
	call_deferred("_run")


func _run() -> void:
	var engine = get_node("/root/ExMateriaAudioEngine")
	var sfx = get_node("/root/ExMateriaEffectSfx")
	_check_scripts("res://addons/exmateria_sound")
	_check_scripts("res://addons/exmateria_spu")
	check(AudioServer.get_driver_name() != "Dummy", "real audio driver required")
	check(ClassDB.class_exists("ExMateriaPsxSpu"), "native SPU registered")
	check(not ClassDB.class_exists("FFTSmdSequencerNative"), "optional accelerator absent")
	check(not engine.ready_ok and not sfx.ready_ok, "no-content startup stays idle")
	check(sfx.unit_count() == 0 and sfx.get_child_count() == 0, "no idle streams allocated")
	check(sfx.begin_effect() == 0, "unready SFX declines playback")
	var outside = engine.get_script().new()
	check(outside.initialize_from_bytes(PackedByteArray()) == ERR_UNCONFIGURED, "outside-tree initialization rejected")
	outside.free()
	var thread := Thread.new()
	var thread_error := thread.start(func(): return engine.initialize_from_bytes(PackedByteArray()))
	check(thread_error == OK, "worker thread started")
	if thread_error == OK:
		check(thread.wait_to_finish() == ERR_UNAUTHORIZED, "off-main-thread initialization rejected")
	check(engine.initialize_from_bytes(PackedByteArray()) == ERR_INVALID_DATA, "empty input rejected")
	check(not engine.ready_ok and engine.music_spu == null, "failure leaves no partial SPUs")

	# Encode an original synthetic sine; no FFT data or file discovery involved.
	var pcm := PackedInt32Array()
	for i in range(448):
		pcm.append(int(12000.0 * sin(TAU * float(i) / 56.0)))
	var sample = Sample.from_pcm16(pcm, 0)
	var spu := Spu.new()
	var indices := spu.load_samples([sample])
	check(indices.size() == 1, "synthetic sample loaded")
	spu.key_on(0, indices[0], 0x1000, 0x1800, 0x1800, 0x00ff, 0x1fdf)
	var peak := 0
	for value in spu.render_interleaved_pcm16(4410):
		peak = maxi(peak, absi(value))
	check(peak > 100, "native SPU renders nonzero PCM")

	# Minimal valid WAVESET container around our own ADPCM; exercises the actual
	# parser/init path without importing any game's instrument descriptors.
	var data := PackedByteArray()
	data.resize(0x30)
	data[0] = 0x64
	data[1] = 0x77
	data[2] = 0x64
	data[3] = 0x73
	data.encode_u32(0x10, 0x30)
	data.encode_u16(0x24, sample.data.size())
	data[0x2c] = 15
	data.append_array(sample.data)
	var malformed := data.duplicate()
	malformed.encode_u32(0x10, 0xffffffff)
	check(engine.initialize_from_bytes(malformed) == ERR_INVALID_DATA, "oversized header rejected")
	malformed = data.duplicate()
	malformed.encode_u32(0x10, 0x2f)
	check(engine.initialize_from_bytes(malformed) == ERR_INVALID_DATA, "unaligned header rejected")
	malformed = data.duplicate()
	malformed.encode_u32(0x20, data.size())
	check(engine.initialize_from_bytes(malformed) == ERR_INVALID_DATA, "out-of-bank sample rejected")
	malformed = data.duplicate()
	malformed.resize(0x30 + Spu.MAX_BANK_BYTES + 16)
	malformed.encode_u32(0x20, Spu.MAX_BANK_BYTES)
	malformed.encode_u16(0x24, 16)
	check(engine.initialize_from_bytes(malformed) == ERR_INVALID_DATA, "SPU RAM overflow rejected before upload")
	check(not engine.ready_ok, "oversized bank leaves initialization retryable")
	engine.initialized.connect(func(): initialized_count += 1)
	check(engine.initialize_from_bytes(data) == OK, "valid bytes initialize after failures")
	check(engine.ready_ok and sfx.ready_ok, "SFX starts on deferred initialization")
	var original_spu = engine.sfx_spu
	var original_units: int = sfx.unit_count()
	check(engine.initialize_from_bytes(data) == ERR_ALREADY_IN_USE, "live reinitialization refused")
	check(engine.sfx_spu == original_spu and sfx.unit_count() == original_units, "no replacement or duplicate streams")
	check(initialized_count == 1, "initialized emitted once")

	# Independent SPU stream and ordinary AudioStreamWAV coexist on Master.
	# Capture the shared bus; inspect energy rather than treating play() as proof.
	var capture := AudioEffectCapture.new()
	AudioServer.add_bus_effect(0, capture)
	var effect_index := AudioServer.get_bus_effect_count(0) - 1
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 44100
	var wav_bytes := PackedByteArray()
	wav_bytes.resize(44100 * 2)
	for i in range(44100):
		wav_bytes.encode_s16(i * 2, int(1800.0 * sin(TAU * 330.0 * float(i) / 44100.0)))
	wav.data = wav_bytes
	var ordinary := AudioStreamPlayer.new()
	ordinary.stream = wav
	add_child(ordinary)
	ordinary.play()
	check(await _wait_for_audio(capture), "ordinary WAV reaches Godot mixer")
	ordinary.stop()
	await get_tree().create_timer(0.12).timeout
	capture.clear_buffer()

	spu.set_deferred_mode(true)
	var stream := ExMateriaSpuStream.new()
	stream.set_mixer(spu.get_native())
	var player := AudioStreamPlayer.new()
	player.stream = stream
	add_child(player)
	player.play()
	check(await _wait_for_audio(capture), "SPU stream reaches Godot mixer")
	ordinary.play()
	await get_tree().create_timer(0.12).timeout
	check(ordinary.playing and player.playing, "ordinary and SPU streams play concurrently")
	check(_capture_peak(capture) > 0.001, "concurrent streams reach shared bus")
	var utilities := get_node_or_null("/root/Utilities")
	if utilities != null:
		utilities.play_audio_one_shot(wav)
		print("AUDIO_SMOKE: exercised unchanged Utilities.play_audio_one_shot")
		await get_tree().create_timer(1.1).timeout
	AudioServer.lock()
	ordinary.stop()
	player.stop()
	spu.set_deferred_mode(false, 0)
	stream.set_mixer(null)
	AudioServer.unlock()
	AudioServer.remove_bus_effect(0, effect_index)
	sfx.queue_free()
	ordinary.queue_free()
	player.queue_free()
	# Godot 4.6.1 retains stopped playbacks for an audio-thread fade-out block.
	# Drain the fixture before quitting; an immediate stop()+quit() also leaks
	# a plain WAV-only control and may crash with native playbacks. This is not
	# a claim that abrupt application-exit behavior has been fixed by the addon.
	await get_tree().create_timer(0.2).timeout
	print("AUDIO_SMOKE: %s (native peak=%d)" % ["PASS" if failures.is_empty() else "FAIL", peak])
	get_tree().quit(0 if failures.is_empty() else 1)


func _check_scripts(path: String) -> void:
	for filename in DirAccess.get_files_at(path):
		if filename.ends_with(".gd"):
			var script = load(path.path_join(filename))
			check(script != null and script.can_instantiate(), "script loads: " + filename)
	for directory in DirAccess.get_directories_at(path):
		_check_scripts(path.path_join(directory))


func _wait_for_audio(capture: AudioEffectCapture) -> bool:
	for attempt in range(40):
		await get_tree().create_timer(0.05).timeout
		if _capture_peak(capture) > 0.001:
			return true
	return false


func _capture_peak(capture: AudioEffectCapture) -> float:
	var peak := 0.0
	for frame in capture.get_buffer(capture.get_frames_available()):
		peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	return peak
