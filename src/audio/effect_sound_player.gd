extends Node
## Realtime FFT effect-sound (FEDS) player driving the addon's actual SFX path
## (EffectPlaySound + pool + Runtime), NOT the music Sequencer. Adapted from
## godot-learning's EffectSoundPlayer to source feds blobs from RomReader bytes
## (this project) instead of from feds.bin / *.feds files on disk.
##
## The SFX path needs an entity-state "seed". A SYNTHETIC fresh seed (FFT
## FUN_800137d8 fresh-allocation defaults) lets any effect play without a
## captured PCSX session. Pass seed=null to A/B the no-seed case.
##
## Internal VM modules + Spu/FedsBank/WavesetParser come from the vendored
## exmateria_sound addon. The shared sfx SPU + waveset come from AudioEngine.

const _Pool := preload("res://addons/exmateria_sound/runtime/effect_sound/pool.gd")
const _Play := preload("res://addons/exmateria_sound/runtime/effect_sound/play_sound.gd")
const _Flush := preload("res://addons/exmateria_sound/runtime/shared/flush_tick.gd")
const _Walker := preload("res://addons/exmateria_sound/runtime/shared/spu_irq_walker.gd")
const _RuntimeC := preload("res://addons/exmateria_sound/runtime/runtime.gd")

# 44100 / 30 Hz / 8 sub-ticks, matching FFT's per-IRQ render granularity.
const SAMPLES_PER_SUB := 183
# A fresh effect entity (channel_count > 2 marks it the active one); every other
# field defaults to FUN_800137d8 init inside the SFX path's seed handling.
const SYNTHETIC_SEED := {"entities": [{"channel_count": 8}]}
# ~1s of release tail rendered after the entity goes quiet, then we stop.
const TAIL_SUBS := 240
# Cap sub-ticks rendered per frame so the first frame after play() doesn't
# render the whole 1s buffer in one burst (the per-click stutter).
const MAX_SUBS_PER_FRAME := 16

var mixer: Spu
var pool
var play
var flush
var walker
var rt

var _generator: AudioStreamGenerator
var _audio: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _buffer_capacity: int = 0
var _abs_sub: int = 0
var _active: bool = false
var _done: bool = false
var _tail_subs: int = 0


func _ready() -> void:
	_generator = AudioStreamGenerator.new()
	_generator.mix_rate = Spu.SAMPLE_RATE
	_generator.buffer_length = 1.0
	_audio = AudioStreamPlayer.new()
	_audio.stream = _generator
	_audio.bus = "Master"
	add_child(_audio)
	_buffer_capacity = int(_generator.mix_rate * _generator.buffer_length)


## Play one FEDS pair through the SFX path. `feds_bytes` is a raw "feds" blob
## (an E### sound section, sliced via RomReader.get_feds_bank / FedsBankData).
func play_feds_bytes(feds_bytes: PackedByteArray, pair_idx: int = 0, entity_seed: Variant = SYNTHETIC_SEED) -> bool:
	if not _build_engine():
		return false

	_Play._entity_state_seed = entity_seed

	var feds_bank: FedsBank = FedsBank.parse(feds_bytes)
	if feds_bank == null or pair_idx < 0 or pair_idx >= feds_bank.num_pairs:
		push_error("EffectSoundPlayer: bad feds or pair %d." % pair_idx)
		return false
	return _start_pair(feds_bank, pair_idx, -1)


## Play one sound_id from a global SFX bank (SYSTEM.SED / ENV.SED). A bank's
## stride-2 offset table makes FFT sound_id N map to FedsBank pair_idx N-1; the
## real sound_id is passed through so the chan+0x92 static gain is read from the
## bank's volume table (FedsBank.chan_92_for).
func play_bank_sound_bytes(bank_bytes: PackedByteArray, sound_id: int, entity_seed: Variant = SYNTHETIC_SEED) -> bool:
	if not _build_engine():
		return false

	_Play._entity_state_seed = entity_seed

	var feds_bank: FedsBank = FedsBank.parse(bank_bytes)
	if feds_bank == null:
		push_error("EffectSoundPlayer: cannot parse SFX bank.")
		return false
	var pair_idx: int = sound_id - 1
	if pair_idx < 0 or pair_idx >= feds_bank.num_pairs:
		push_error("EffectSoundPlayer: sound_id %d out of range (num_pairs=%d)." % [sound_id, feds_bank.num_pairs])
		return false
	return _start_pair(feds_bank, pair_idx, sound_id)


func stop() -> void:
	_active = false
	_done = true
	if _audio:
		_audio.stop()
	_playback = null


func is_playing() -> bool:
	return _active


func _start_pair(feds_bank: FedsBank, pair_idx: int, sound_id: int) -> bool:
	var alloc: Dictionary = pool.find_free_pair_slot(2)
	var slot_idx: int = int(alloc.get("slot_idx", -1))
	if slot_idx < 0:
		push_error("EffectSoundPlayer: no free pool slot.")
		return false
	if not play.play_feds_pair(feds_bank, pair_idx, slot_idx, sound_id):
		push_error("EffectSoundPlayer: play_feds_pair failed (pair %d, sound_id %d)." % [pair_idx, sound_id])
		return false

	_abs_sub = 0
	_done = false
	_tail_subs = 0
	_audio.play()
	_playback = _audio.get_stream_playback()
	_active = true
	return true


func _process(_delta: float) -> void:
	if not _active or _playback == null:
		return

	var available: int = _playback.get_frames_available()
	var subs_this_frame: int = 0
	while available >= SAMPLES_PER_SUB and not _done and subs_this_frame < MAX_SUBS_PER_FRAME:
		rt.tick_irq_start(_abs_sub)
		var alive: bool = rt.tick(_abs_sub)
		_abs_sub += 1
		_playback.push_buffer(_pcm_to_frames(mixer.render_interleaved_pcm16(SAMPLES_PER_SUB)))
		available -= SAMPLES_PER_SUB
		subs_this_frame += 1
		if alive:
			_tail_subs = 0
		else:
			_tail_subs += 1
			if _tail_subs >= TAIL_SUBS:
				_done = true

	# When the source is finished and the generator buffer has drained, stop.
	if _done and _playback != null and _playback.get_frames_available() >= _buffer_capacity - SAMPLES_PER_SUB:
		stop()


func _build_engine() -> bool:
	## Reuse the shared, ROM-built sfx SPU (AudioEngine.sfx_spu). reset() clears
	## voice + reverb state between plays but KEEPS the loaded instrument bank, so
	## there is no per-play instrument re-upload. The pool/driver objects are
	## cheap and rebuilt fresh each play so no slot/voice residue leaks across
	## sounds.
	if not AudioEngine.ensure_ready():
		push_error("EffectSoundPlayer: AudioEngine not ready (load a ROM first).")
		return false
	stop()
	mixer = AudioEngine.sfx_spu
	mixer.reset()
	mixer.set_irq_period_samples(512)
	pool = _Pool.new()
	play = _Play.new(pool, AudioEngine.waveset)
	flush = _Flush.new(pool, mixer)
	play.set_flush_tick(flush)
	pool.set_flush_tick(flush)
	walker = _Walker.new(pool, mixer)
	rt = _RuntimeC.new(mixer, flush, walker)
	return true


func _pcm_to_frames(pcm: PackedInt32Array) -> PackedVector2Array:
	var frame_count: int = pcm.size() / 2
	var frames: PackedVector2Array = PackedVector2Array()
	frames.resize(frame_count)
	var inverse: float = 1.0 / 32767.0
	for frame_index: int in frame_count:
		frames[frame_index] = Vector2(float(pcm[frame_index * 2]) * inverse, float(pcm[frame_index * 2 + 1]) * inverse)
	return frames
