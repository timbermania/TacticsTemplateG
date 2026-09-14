extends Node

const _Spu = preload("res://addons/exmateria_spu/runtime/spu.gd")
const _FedsBank = preload("res://addons/exmateria_sound/runtime/feds_bank.gd")
const _SMDParser = preload("res://addons/exmateria_sound/runtime/smd_parser.gd")
const _Sequencer = preload("res://addons/exmateria_sound/runtime/sequencer.gd")
const _WavesetParser = preload("res://addons/exmateria_sound/runtime/waveset_parser.gd")

signal playback_finished
signal debug_stats_updated(summary: String)

var waveset := _WavesetParser.new()
var mixer := _Spu.new()
var seq: _Sequencer
var smd_file: _SMDParser.SMDFile
var _engine_attached := false

var _audio_player: AudioStreamPlayer
var _stream: ExMateriaSpuStream
var _playing := false
var _total_ticks: int = 0
var _last_report_time: float = 0.0
# Frame the NEXT sequencer tick's register writes belong at. The scheduler runs
# this ahead of what the audio thread has rendered; the gap is the lead.
var _sched_frame: int = 0
var _source_exhausted := false
# Frame the last tick of the song ended on. The tail (ADSR release + reverb)
# keeps sounding past it, which is why finishing waits on the voice count too.
var _end_frame: int = 0
var _last_active_voices := 0
var _debug_enabled := true

## How far ahead of the audio clock the sequencer schedules. This is a lead in
## REGISTER WRITES, not in rendered audio — the SPU renders on the audio thread
## now — so it only has to cover a main-thread stall. Music has no
## responsiveness requirement (D3 decision 7, #376), so the lead is set by the
## worst stall the game actually produces rather than by latency.
##
## 2.0 s is measured, not chosen: booting GPUArena with a 1.0 s lead left 52
## register writes OVERDUE (`late=` in the readout below) in the first second —
## the scene load blocks the main thread for longer than one second while the
## score is already playing — and 0 at 2.0 s. Nothing after boot came close;
## twelve concurrently-typing prayer overlays hold the lead at 978 ms of 1000
## (MusicTypewriterStressTest).
const TARGET_LEAD_SECONDS := 2.0
## Command-ring size, in register writes (64 bytes each = 512 KB here). Sized
## off the measured high-water mark: 320 writes for a 2.0 s lead in the real
## game, so this is ~25x headroom. get_deferred_stats()["high_water"] is in the
## readout below, and ["overflow"] counts writes DROPPED for want of room.
const QUEUE_CAPACITY := 8192
## Stop scheduling when the ring gets this close to full. Back-pressure, so a
## song that writes far more registers per tick than the average shortens its
## lead instead of losing writes.
const QUEUE_RESERVE := 512
## The Godot bus this player's stream lands on — `Master <- {Music, SFX, Ambient}`
## (D3 decision 6, #376 / #385 task 2). Music gets its own fader so a host can duck or
## mute the score without touching effect SFX; the two used to share `"Master"`, which
## gave a consumer exactly one knob for everything.
##
## Safe in a project that declares no such bus: `AudioStreamPlayer.bus`'s GETTER resolves
## an unknown name to `&"Master"` (`audio_stream_player_internal.cpp:353-361`), so the
## addon still plays standalone — naming the bus only *offers* the routing to a host that
## has one. The bus carries no effects; the limiter rack stays on Master (D3 dec. 6).
const OUTPUT_BUS := &"Music"


func _init() -> void:
	seq = _Sequencer.new(mixer, waveset)
	# Use the GDScript sequencer (the documented game-side FFT music driver),
	# not the native C++ core. The C++ sequencer (src/shared/fft_smd_sequencer_
	# core.cpp) is the DAW's port and never received the FFT end-of-note ADSR2
	# release-rate force (PC 0x800152A8 — Sequencer.tick:569-573), so retriggers
	# step the envelope from sustain straight to 0 on key-on and click/pop. The
	# GDScript path forces ADSR2 release=0x06 on a note's last tick, releasing
	# the SPU envelope to ~0 before the next key-on. Keep music on GDScript.
	seq.set_use_native_core(false)


func _ready() -> void:
	# The SPU IS the stream (D3 decisions 1+2, #376). `_mix` renders the 24
	# voices on the audio thread; nothing hand-feeds a ring buffer, and there is
	# no producer thread. The mixer is bound at play time, not here, because
	# attach_shared_engine can still swap it.
	_stream = ExMateriaSpuStream.new()
	_audio_player = AudioStreamPlayer.new()
	_audio_player.stream = _stream
	_audio_player.bus = OUTPUT_BUS
	add_child(_audio_player)


func _exit_tree() -> void:
	stop_music()


func attach_shared_engine(shared_spu: _Spu, shared_waveset: _WavesetParser) -> void:
	## Replace this player's self-owned SPU + waveset with shared, already-loaded
	## instances (see godot-learning's ExMateriaAudioEngine autoload). Lets several players
	## share one static SPU + instrument set instead of each constructing an SPU
	## and re-uploading the instrument bank. Call once before load_smd/play_music.
	mixer = shared_spu
	waveset = shared_waveset
	seq = _Sequencer.new(mixer, waveset)
	seq.set_use_native_core(false)  # keep music on the GDScript driver (see _init)
	_engine_attached = true


func load_waveset(path: String) -> bool:
	if _engine_attached:
		return true  # shared engine already has the instrument bank loaded
	var ok := waveset.load_from_file(path)
	if ok:
		ok = mixer.load_instruments(waveset.descriptors(), waveset.adpcm_data)
	return ok


func load_smd(path: String) -> bool:
	# Take the SPU back from the audio thread BEFORE touching seq. Otherwise the
	# previous song's queued register writes are still being applied while we
	# reload the sequencer here — the race that could orphan a key_on (voice
	# never keyed off → note stuck on forever). stop_music() flips ownership
	# under AudioServer.lock(), so on return nothing else is driving this SPU.
	stop_music()
	smd_file = _SMDParser.load_from_file(path)
	if smd_file == null:
		return false
	seq.load_trackset(smd_file.to_trackset())
	return true


func load_feds_pair(path: String, pair_idx: int) -> bool:
	## Load an effect-sound pair from a feds blob (raw ENV.SED, or feds.bin
	## produced by godot-learning's parser). The pair's two tracks become
	## tracks 1 and 2 of a [Trackset] (track 0 = empty conductor); music and
	## effects use the same Sequencer/SPU pipeline.
	stop_music()  # take the SPU back from the audio thread before mutating seq
	var fb := _FedsBank.load_from_file(path)
	if fb == null:
		push_error("SMDPlayer: failed to load feds from %s" % path)
		return false
	if pair_idx < 0 or pair_idx >= fb.num_pairs:
		push_error("SMDPlayer: pair %d out of range (num_pairs=%d)" % [pair_idx, fb.num_pairs])
		return false
	seq.load_trackset(fb.pair_to_trackset(pair_idx))
	return true


func play_music() -> void:
	if smd_file == null:
		return

	stop_music()

	# Let the previous song's lingering notes fade out naturally (ADSR release)
	# as this song starts — a seamless transition — instead of hard-cutting them.
	# release_all() still guarantees they terminate, so no voice sticks on (the
	# stuck-note failure mode the song-switch race used to trigger).
	# Applies immediately: deferred mode is off until set_deferred_mode below.
	mixer.release_all()

	_total_ticks = 0
	_source_exhausted = false
	_end_frame = 0
	_sched_frame = 0
	_last_report_time = 0.0
	_last_active_voices = 0

	# Hand the SPU to the audio thread. This also clears the command ring and
	# rewinds both clocks, so frame 0 below means frame 0 of this song.
	_stream.set_mixer(mixer.get_native())
	mixer.set_deferred_mode(true, QUEUE_CAPACITY)

	# Schedule the opening lead BEFORE the first block is mixed, so the stream
	# never renders a frame the sequencer has not written registers for.
	_schedule_ahead()

	_audio_player.play()
	_playing = true


func stop_music() -> void:
	_playing = false
	if _audio_player == null:
		return
	# Godot keeps mixing a stopped playback for one more block to fade it out
	# (AudioServer::stop_playback_stream marks FADE_OUT_TO_DELETION rather than
	# unlinking it), so stop() alone does NOT mean the audio thread is done with
	# this SPU. Taking the audio lock does: it is the mutex the mixer thread
	# holds, so no _mix can be in flight while ownership flips back. The late
	# fade-out block then finds deferred mode off and renders silence.
	AudioServer.lock()
	_audio_player.stop()
	mixer.set_deferred_mode(false, 0)
	AudioServer.unlock()


func is_playing() -> bool:
	return _playing


## Run the sequencer far enough ahead of the audio clock, staging each tick's
## register writes at the frame that tick begins on.
##
## This is the whole scheduling half of D3 decision 3 (#376). The sequencer is
## unchanged — it still ticks in the same order and writes the same registers —
## but instead of rendering the tick's samples itself it stamps the writes and
## lets the audio thread render between them. Two bounds stop the loop: the
## lead in FRAMES (how far ahead of the audio clock to run) and the free space
## in the command ring, so a tick that writes unusually many registers shortens
## the lead rather than dropping writes.
func _schedule_ahead() -> void:
	var target_lead := int(_Spu.SAMPLE_RATE * TARGET_LEAD_SECONDS)
	var audio_frame := mixer.get_audio_frame()
	while not _source_exhausted and (_sched_frame - audio_frame) < target_lead:
		if mixer.get_deferred_free_slots() < QUEUE_RESERVE:
			break
		mixer.set_schedule_frame(_sched_frame)
		if not seq.tick():
			# Out of song. The SPU keeps rendering past _end_frame — that is the
			# ADSR release and the reverb tail, which used to need an explicit
			# has_active_audio() render loop and now just happens.
			_source_exhausted = true
			_end_frame = _sched_frame
			break
		_sched_frame += seq.advance_tick_frames()
		_total_ticks += 1


func _process(delta: float) -> void:
	if not _playing:
		return

	_schedule_ahead()
	_last_active_voices = mixer.get_audio_active_voices()

	var audio_frame := mixer.get_audio_frame()
	if _source_exhausted and audio_frame >= _end_frame and _last_active_voices <= 0:
		_playing = false
		playback_finished.emit()
		return

	_last_report_time += delta
	if _last_report_time >= 1.0:
		var stats := mixer.get_deferred_stats()
		var lead_ms := float(_sched_frame - audio_frame) / _Spu.SAMPLE_RATE * 1000.0
		var summary := "lead=%sms queue=%d/%d hi=%d over=%d late=%d ticks=%d active=%d fps=%d" % [
			snapped(lead_ms, 0.1),
			int(stats.get("pending", 0)),
			int(stats.get("capacity", 0)),
			int(stats.get("high_water", 0)),
			int(stats.get("overflow", 0)),
			int(stats.get("overdue", 0)),
			_total_ticks,
			_last_active_voices,
			Engine.get_frames_per_second(),
		]
		if _debug_enabled:
			print(summary)
		debug_stats_updated.emit(summary)
		_last_report_time = 0.0
