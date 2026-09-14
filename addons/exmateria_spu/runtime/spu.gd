extends RefCounted

## A PSX SPU for Godot — 24 voices of ADPCM playback with the console's own
## ADSR, pitch/volume LFOs, noise, frequency modulation and reverb.
##
## This class holds NO DSP. It programs voice registers and forwards every call
## to [ExMateriaPsxSpu], the native core, which does the ADPCM decode, the
## envelopes, the LFOs, the reverb tank and the 24-voice -> interleaved-stereo
## mix. Drive it the way a PSX game's CPU drove the real chip's registers:
## upload a sample bank, then key voices on and off and write registers between
## renders.
##
## Bring your own ADPCM. Nothing here knows or cares what produced it.
##
##     var spu := ExMateriaSpu.Spu.new()
##     var idx := spu.load_samples([ExMateriaSpu.Sample.from_wav("res://kick.wav")])
##     spu.key_on(0, idx[0], 0x1000, 0x3FFF, 0x3FFF, adsr1, adsr2)
##     var pcm := spu.render_interleaved_pcm16(4410)
##
## There are two doors onto one implementation. [method load_samples] takes
## [ExMateriaSpu.Sample] resources and packs them for you; [method
## load_instruments] takes a bank you have already packed, for when the offsets
## inside it mean something — several instruments sharing one sample window, the
## way a PSX game's own bank does.
##
## For live playback, hand the SPU to an [ExMateriaSpuStream] instead of
## calling render_* yourself — see set_deferred_mode().

const SAMPLE_RATE := 44100
const NUM_VOICES := 24
const RAM_INSTRUMENT_BASE := 0x1000
const SPU_RAM_SIZE := 0x80000
const BLOCK_SIZE := 16

# How many bytes of sample data one bank can hold. NOT SPU_RAM_SIZE -
# RAM_INSTRUMENT_BASE: the native core writes the bank at 0x1010, while the
# constant above says 0x1000. That 16-byte disagreement is older than this
# method and load-bearing for an existing driver's key_on_with_addresses parity,
# so it is measured here rather than "fixed" (see #388's resolution).
const MAX_BANK_BYTES := SPU_RAM_SIZE - 0x1010

# PSX ADPCM block flags, in the block's second byte. The decoder reads these
# and nothing else to find a loop: 0x04 says "the loop starts at this block",
# 0x01 says "this block is the last", and only 0x01|0x02 together mean "jump
# back" rather than "stop".
const FLAG_LOOP_END := 0x01
const FLAG_LOOP_REPEAT := 0x02
const FLAG_LOOP_START := 0x04

var _native := ExMateriaPsxSpu.new()
var _reverb_enabled_state := true


## Upload a sample bank and the instrument descriptors that index into it.
##
## The low-level door. Reach for [method load_samples] unless your bank is
## already packed and its internal offsets carry meaning — several instruments
## addressing one shared sample window, which a per-sample door would have to
## discard and rebuild.
##
## [param descriptors] is an Array of Dictionaries — or of any object with the
## same field names — one per instrument slot. [param adpcm_bank] is the raw
## PSX-ADPCM byte stream those descriptors address, in 16-byte blocks.
##
## In a Dictionary every key is optional except the two marked; an object must
## carry all of them. The published contract is these seven keys:
##
##     is_null                 true = an empty slot that never sounds
##     sample_size             REQUIRED, bytes; 0 makes the slot unplayable
##     sample_offset           REQUIRED unless 0, byte offset into the bank
##     start_offset_bytes      skip this many bytes past sample_offset
##     fine_tune               driver-side detune; the SPU only stores it
##     adsr1, adsr2            default envelope registers for the slot
##
## [b]There is no loop field here, and that is the contract, not an omission.[/b]
## Loop points live in the ADPCM bytes: the decoder walks SPU RAM block by block
## and reads each block's flag byte — 0x04 sets the loop point, 0x03 jumps back
## to it, 0x01 stops. That is what the hardware does, so it is what this does.
## [member ExMateriaSpu.Sample.loop_offset] is the author-time way to put those
## flags in the bytes; [method load_samples] stamps them for you.
##
## Three further keys — [code]loop_offset_bytes[/code],
## [code]has_explicit_loop_start[/code] and [code]has_loop_repeat[/code] —
## are still read, but they are NOT part of the published contract and new code
## must not use them: they override the key-on addresses computed from
## [code]sample_offset[/code], and exist only for a driver whose own bank format
## already carries loop bookkeeping outside the ADPCM stream. Two more,
## [code]loop_start[/code] and [code]start_sample_skip[/code], were measured to
## have no effect at all and have been removed (D7 #380 dec. 2).
##
## Both arguments are required and neither has a default. That is deliberate:
## the earlier one-argument form let a caller pass instruments with no bank at
## all, upload no sample data, and still get [code]true[/code] back — a slot
## that keys on and plays silence. A two-argument signature makes the bank
## impossible to forget.
##
## Call with the SPU's stream STOPPED; this writes SPU RAM.
func load_instruments(descriptors: Array, adpcm_bank: PackedByteArray) -> bool:
	var payload: Array = []
	payload.resize(descriptors.size())
	for i in range(descriptors.size()):
		var d = descriptors[i]
		if d is Dictionary:
			# Passed straight through — the core defaults every key it does not
			# find, so a hand-written descriptor really can omit the nine
			# optional ones. Translating here instead would re-impose all
			# ten and make the list above a lie.
			#
			# Two defaults are flipped from the core's, because a descriptor
			# somebody TYPED is a real instrument until it says otherwise,
			# whereas the core's caller is usually a sparse bank full of empty
			# slots:
			var e: Dictionary = d.duplicate()
			if not e.has("is_null"):
				e["is_null"] = false
			if not bool(e["is_null"]) and int(e.get("sample_size", 0)) <= 0:
				push_error("Spu.load_instruments: descriptor %d has no sample_size, "
						% i + "so it would key on and play silence. Give it one, "
						+ "or mark it is_null.")
				return false
			payload[i] = e
		else:
			payload[i] = {
				"is_null": d.is_null,
				"fine_tune": d.fine_tune,
				"adsr1": d.adsr1,
				"adsr2": d.adsr2,
				"sample_offset": d.sample_offset,
				"sample_size": d.sample_size,
				"loop_offset_bytes": d.loop_offset_bytes,
				"has_explicit_loop_start": d.has_explicit_loop_start,
				"has_loop_repeat": d.has_loop_repeat,
				"start_offset_bytes": d.start_offset_bytes,
			}
	return _native.load_instruments(payload, adpcm_bank)


## Pack [ExMateriaSpu.Sample] resources into SPU RAM and return their indices.
##
## The per-sample door. Each sample's ADPCM is laid end to end into one bank,
## given an address, and turned into an instrument slot; the returned
## [PackedInt32Array] holds the [code]instrument_idx[/code] to pass to
## [method key_on], in the order the samples were given.
##
## This REPLACES whatever was loaded before — like [method load_instruments], it
## rewrites the whole bank. Pass every sample you need in one call.
##
## [b]Loop points.[/b] When a sample's [member ExMateriaSpu.Sample.loop_offset]
## is >= 0, this stamps the loop flags into a COPY of its bytes — 0x04 on the
## block at that offset, 0x03 on the last block — so the decoder finds them
## where the hardware looks. The sample resource is not modified. When it is -1
## the bytes are uploaded untouched, so whatever markers they already carry are
## what plays.
##
## Returns an empty array, and pushes an error naming the sample, if any of them
## is unusable. It never partially loads: a rejected batch leaves the SPU's
## previous bank alone.
##
## Call with the SPU's stream STOPPED; this writes SPU RAM.
func load_samples(samples: Array) -> PackedInt32Array:
	var bank := PackedByteArray()
	var descriptors: Array = []
	descriptors.resize(samples.size())

	for i in range(samples.size()):
		var s = samples[i]
		if s == null:
			push_error("Spu.load_samples: sample %d is null" % i)
			return PackedInt32Array()
		var data: PackedByteArray = s.data
		if data.is_empty() or (data.size() % BLOCK_SIZE) != 0:
			push_error("Spu.load_samples: sample %d holds %d bytes; PSX ADPCM comes in whole %d-byte blocks."
					% [i, data.size(), BLOCK_SIZE])
			return PackedInt32Array()

		var start_offset := int(s.start_offset)
		if start_offset < 0 or start_offset >= data.size() or (start_offset % BLOCK_SIZE) != 0:
			push_error("Spu.load_samples: sample %d has start_offset %d; it must be a multiple of %d inside the %d bytes of data."
					% [i, start_offset, BLOCK_SIZE, data.size()])
			return PackedInt32Array()

		var loop_offset := int(s.loop_offset)
		if loop_offset >= 0:
			if (loop_offset % BLOCK_SIZE) != 0 or loop_offset >= data.size():
				push_error("Spu.load_samples: sample %d has loop_offset %d; it must be a multiple of %d inside the %d bytes of data, or -1."
						% [i, loop_offset, BLOCK_SIZE, data.size()])
				return PackedInt32Array()
			if loop_offset >= data.size() - BLOCK_SIZE:
				# The last block has to carry the jump-back marker and the loop
				# point has to carry the loop marker, and one block cannot hold
				# both: the decoder jumps back only on flags == 3 exactly, so a
				# block asked to be both is a block that stops. Say so, rather
				# than stamping something that silently plays once.
				push_error("Spu.load_samples: sample %d puts loop_offset %d in its LAST block. "
						% [i, loop_offset]
						+ "A loop needs at least one block after its loop point; give the sample "
						+ "another block, or encode it with ExMateriaSpu.Sample.from_pcm16(), which "
						+ "handles this case.")
				return PackedInt32Array()
			data = data.duplicate()
			data[loop_offset + 1] = data[loop_offset + 1] | FLAG_LOOP_START
			data[data.size() - BLOCK_SIZE + 1] = FLAG_LOOP_END | FLAG_LOOP_REPEAT

		if bank.size() + data.size() > MAX_BANK_BYTES:
			push_error("Spu.load_samples: sample %d does not fit — SPU RAM holds %d bytes of samples and this batch reached %d."
					% [i, MAX_BANK_BYTES, bank.size() + data.size()])
			return PackedInt32Array()

		descriptors[i] = {
			"is_null": false,
			# The published unit is cents; the descriptor's unit is the PSX
			# driver convention of 1/256 of a semitone, so the conversion
			# happens here, at the boundary, and only here.
			"fine_tune": int(round(float(s.base_pitch_cents) * 256.0 / 100.0)),
			# No envelope: an envelope belongs to the instrument that plays the
			# bytes, not to the bytes (D7 #380 dec. 4). key_on() takes one.
			"adsr1": 0,
			"adsr2": 0,
			"sample_offset": bank.size(),
			"sample_size": data.size(),
			"start_offset_bytes": start_offset,
		}
		bank.append_array(data)

	if not _native.load_instruments(descriptors, bank):
		return PackedInt32Array()
	var indices := PackedInt32Array()
	indices.resize(samples.size())
	for i in range(samples.size()):
		indices[i] = i
	return indices


func reset() -> void:
	_native.reset()


func key_on(voice_idx: int, instrument_idx: int, pitch: int, vol_l: int, vol_r: int,
		adsr1: int, adsr2: int, p_reverb: bool = false) -> void:
	_native.key_on(voice_idx, instrument_idx, pitch, vol_l, vol_r, adsr1, adsr2, p_reverb)


func key_on_with_addresses(voice_idx: int, instrument_idx: int, pitch: int, vol_l: int, vol_r: int,
		adsr1: int, adsr2: int, start_addr: int, loop_addr: int, p_reverb: bool = false) -> void:
	_native.key_on_with_addresses(
		voice_idx,
		instrument_idx,
		pitch,
		vol_l,
		vol_r,
		adsr1,
		adsr2,
		start_addr,
		loop_addr,
		p_reverb
	)


func key_off(voice_idx: int) -> void:
	_native.key_off(voice_idx)


func release_all() -> void:
	## Key-off every voice so currently-sounding notes enter their ADSR release
	## and fade out naturally (reverb tail too), instead of being hard-cut like
	## reset(). Used at song-switch for a seamless transition — the previous
	## song's notes ring out as the new one starts — while still guaranteeing
	## they terminate (release → 0), so no voice can stick on forever.
	for v in range(NUM_VOICES):
		_native.key_off(v)


func seed_voice_residue(voice_idx: int, start_addr: int, loop_addr: int, curr_addr: int,
		adsr1: int, adsr2: int, env_state: int, env_vol: int,
		vol_l: int, vol_r: int, raw_pitch: int, reverb: bool) -> void:
	# Restore a voice's register state VERBATIM — without resetting the
	# envelope to ATTACK or rewinding curr_addr to start_addr — so it carries
	# on from wherever it was, rather than starting a fresh note. This is what
	# you want when resuming from a snapshot that caught a voice mid-note; a
	# plain key_on() would restart it.
	_native.seed_voice_residue(voice_idx, start_addr, loop_addr, curr_addr,
			adsr1, adsr2, env_state, env_vol, vol_l, vol_r, raw_pitch, reverb)


func set_voice_pitch(voice_idx: int, raw_pitch: int) -> void:
	_native.set_voice_pitch(voice_idx, raw_pitch)


func set_voice_fmod(voice_idx: int, mode: int) -> void:
	# FMod mode: 0=off, 1=this voice modulated by the previous voice's
	# emitted sample, 2=this voice provides FM to the next voice. The classic
	# use is a silent modulator on voice N driving an audible carrier on N+1.
	_native.set_voice_fmod(voice_idx, mode)


func set_voice_noise(voice_idx: int, on: bool) -> void:
	# Noise mode. When on, this voice's source sample is replaced by the
	# global LFSR noise output; envelope and volume still apply normally.
	_native.set_voice_noise(voice_idx, on)


func set_noise_clock(noise_clock: int) -> void:
	# SPU global noise clock (spuCtrl bits 8-13, range 0..63). 0 = broadband.
	#
	# NOTE: the LFSR behind this is one generator for the whole process, not one
	# per Spu — faithful to the console, which has a single SPU. Instantiate
	# several Spus and they share noise phase; seed it with set_noise_state() if
	# a run has to be reproducible.
	_native.set_noise_clock(noise_clock)


func set_noise_state(noise_val: int, noise_clock: int, noise_count: int) -> void:
	# Seed the noise LFSR so a run is reproducible from this point forward —
	# the generator is process-global (see set_noise_clock), so a fresh Spu
	# inherits whatever phase the last one left behind. Also the hook for
	# matching an emulator's m_noiseVal bit-for-bit.
	_native.set_noise_state(noise_val, noise_clock, noise_count)


func set_voice_pre_pitch(voice_idx: int, pre_pitch: int) -> void:
	_native.set_voice_pre_pitch(voice_idx, pre_pitch)


func set_voice_adsr1_low(voice_idx: int, nibble: int) -> void:
	_native.set_voice_adsr1_low(voice_idx, nibble)


func set_voice_adsr2(voice_idx: int, adsr2: int) -> void:
	_native.set_voice_adsr2(voice_idx, adsr2)


# Partial-register setters. A driver that updates one field of a voice's
# volume or envelope registers — rather than rewriting the whole word — needs
# read-modify-write against the voice's cached adsr1/adsr2/vol_L/vol_R, which
# is what these do. Writing the full register still works; use key_on() or
# set_voice_adsr2().
func set_voice_volume_lr(voice_idx: int, vol_l: int, vol_r: int) -> void:
	_native.set_voice_volume_lr(voice_idx, vol_l, vol_r)


func set_voice_volume_lr_with_mode(voice_idx: int, vol_l: int, vol_r: int, mode_l: int, mode_r: int) -> void:
	_native.set_voice_volume_lr_with_mode(voice_idx, vol_l, vol_r, mode_l, mode_r)


func set_voice_adsr1_high(voice_idx: int, attack_rate: int, lin_or_exp_mode: int) -> void:
	_native.set_voice_adsr1_high(voice_idx, attack_rate, lin_or_exp_mode)


func set_voice_adsr1_mid(voice_idx: int, mid_nibble: int) -> void:
	_native.set_voice_adsr1_mid(voice_idx, mid_nibble)


func set_voice_adsr2_low(voice_idx: int, low_bits: int, mode: int) -> void:
	_native.set_voice_adsr2_low(voice_idx, low_bits, mode)


# Repoint a sounding voice's sample/loop address. Pure register writes — no
# key-on re-arm, so the voice keeps its envelope and carries on from the new
# address at its next block boundary.
func set_voice_start_addr(voice_idx: int, start_addr: int) -> void:
	_native.set_voice_start_addr(voice_idx, start_addr)


func set_voice_repeat_addr(voice_idx: int, repeat_addr: int) -> void:
	_native.set_voice_repeat_addr(voice_idx, repeat_addr)


func init_voice_pitch_lfo(voice_idx: int, count: int, signed_step: int, rate_reload: int) -> void:
	_native.init_voice_pitch_lfo(voice_idx, count, signed_step, rate_reload)


func clear_voice_pitch_lfo(voice_idx: int) -> void:
	_native.clear_voice_pitch_lfo(voice_idx)


func set_voice_pitch_lfo_depth(voice_idx: int, depth: int, depth_delta: int) -> void:
	_native.set_voice_pitch_lfo_depth(voice_idx, depth, depth_delta)


func init_voice_volume_lfo(voice_idx: int, count: int, signed_step: int, rate_reload: int) -> void:
	_native.init_voice_volume_lfo(voice_idx, count, signed_step, rate_reload)


func clear_voice_volume_lfo(voice_idx: int) -> void:
	_native.clear_voice_volume_lfo(voice_idx)


func set_voice_volume_lfo_depth(voice_idx: int, depth: int, depth_delta: int) -> void:
	_native.set_voice_volume_lfo_depth(voice_idx, depth, depth_delta)


func set_voice_lfo_subslot(voice_idx: int, subslot_idx: int,
		accum: int, step_current: int, step_source: int,
		countdown: int, inner_reload: int,
		depth: int, depth_reload: int,
		mode: int, active_dir_flags: int) -> void:
	# Seed one LFO subslot's internal state directly. Companion to
	# seed_voice_residue: a voice resumed mid-note also needs its LFOs resumed
	# mid-cycle, and a subslot that starts zeroed diverges immediately — which
	# FM then amplifies onto whatever voice it modulates.
	_native.set_voice_lfo_subslot(voice_idx, subslot_idx,
			accum, step_current, step_source,
			countdown, inner_reload,
			depth, depth_reload,
			mode, active_dir_flags)


func set_lfo_pitch_bias_enabled(enabled: bool) -> void:
	_native.set_lfo_pitch_bias_enabled(enabled)


func set_lfo_tick_samples(samples: int) -> void:
	_native.set_lfo_tick_samples(samples)


## The native SPU handle. An [ExMateriaSpuStream] needs it directly: the stream
## renders this SPU on the audio thread, and C++ cannot hold a GDScript class.
func get_native() -> ExMateriaPsxSpu:
	return _native


## Hand this SPU to the audio thread.
##
## While deferred mode is on, every register write below is STAMPED with
## [method set_schedule_frame] and queued instead of applied; the audio thread
## applies each one at its own frame inside the stream's `_mix`, rendering the
## SPU between writes. The two modes run the same core calls in the same order,
## which is why streamed output is bit-identical to a lockstep render.
##
## Only the register writes are safe to call live. reset(), load_instruments(),
## seed_voice_residue(), set_voice_lfo_subslot(), set_noise_state(), the reverb
## address setters, the trace setters and every render_* call need the stream
## STOPPED — they touch SPU state the audio thread is reading.
##
## `queue_capacity` is rounded up to a power of two and allocated once, here.
## Size it for the scheduler's lead: a write is 64 bytes, and the scheduler
## stops running ahead when get_deferred_free_slots() gets low, so an overflow
## in get_deferred_stats() means the lead outgrew the ring.
func set_deferred_mode(enabled: bool, queue_capacity: int = 8192) -> void:
	_native.set_deferred_mode(enabled, queue_capacity)


func is_deferred_mode() -> bool:
	return _native.is_deferred_mode()


## Drop every queued write and rewind both clocks. Song switch / stream stop.
func clear_deferred_commands() -> void:
	_native.clear_deferred_commands()


## The frame the NEXT register write belongs at.
func set_schedule_frame(frame: int) -> void:
	_native.set_schedule_frame(frame)


func get_schedule_frame() -> int:
	return _native.get_schedule_frame()


## Frames the audio thread has actually rendered since the stream started.
## The scheduler's lead is get_schedule_frame() - get_audio_frame().
func get_audio_frame() -> int:
	return _native.get_audio_frame()


## Active voices as of the audio thread's last block. Read this instead of
## get_active_voice_count() while streaming — that one reads SPU state the
## audio thread is writing.
func get_audio_active_voices() -> int:
	return _native.get_audio_active_voices()


## Park this SPU's stream without stopping its [AudioStreamPlayer].
##
## With one stream per SFX unit, most units are silent most of the time. An idle
## stream still advances its audio clock — the scheduler paces off it, so it has
## to keep running — but emits silence without entering the mix loop, so an idle
## unit costs no SPU render. Safe to flip from the game thread while the stream
## is live; the audio thread only reads it. Arming deferred mode clears the claim,
## so re-assert it after set_deferred_mode(true).
func set_stream_idle(idle: bool) -> void:
	_native.set_stream_idle(idle)


func is_stream_idle() -> bool:
	return _native.is_stream_idle()


func get_deferred_free_slots() -> int:
	return _native.get_deferred_free_slots()


## capacity / pending / free_slots / high_water / overflow / overdue /
## schedule_frame / audio_frame. `overflow` counts DROPPED register writes and
## `overdue` counts writes the audio thread reached after their frame had
## passed; both should stay 0.
func get_deferred_stats() -> Dictionary:
	return _native.get_deferred_stats()


## Zero `overdue` / `overflow` / `high_water` for a fresh monitoring window,
## leaving the ring and both clocks untouched (unlike clear_deferred_commands,
## which drops pending writes). Call with the audio thread held off.
func reset_deferred_stats() -> void:
	_native.reset_deferred_stats()


func render_interleaved_pcm16(num_frames: int) -> PackedInt32Array:
	return _native.render_interleaved_pcm16(num_frames)


func render(num_frames: int) -> PackedVector2Array:
	return _native.render_frames(num_frames)


## The audio thread's own render loop, run synchronously: applies every queued
## register write at its stamped frame and renders the SPU between them. Same
## code path the stream takes, which makes it the oracle for a parity test: it
## is the only way to compare streamed output against a lockstep render without
## an audio device. Requires deferred mode; do not call while a stream plays.
func render_deferred_pcm16(num_frames: int) -> PackedInt32Array:
	return _native.render_deferred_pcm16(num_frames)


func render_voice_pcm16(num_frames: int, voice_idx: int) -> PackedInt32Array:
	return _native.render_voice_pcm16(num_frames, voice_idx)


func render_replay_mix_frames(num_frames: int, per_voice_samples: Array, per_voice_events: Array,
		ground_truth_rvb_input: PackedInt32Array = PackedInt32Array()) -> PackedInt32Array:
	return _native.render_replay_mix_frames(num_frames, per_voice_samples, per_voice_events, ground_truth_rvb_input)


func set_reverb_debug(enabled: bool, path: String = "") -> void:
	if path != "":
		_native.set_reverb_debug_path(path)
	_native.set_reverb_debug_enabled(enabled)


func get_active_voice_count() -> int:
	return _native.get_active_voice_count()


func get_debug_stats() -> Dictionary:
	return _native.get_debug_stats()


## Zero this SPU's in-core rail-saturation counters (rail_pre_clamp_peak /
## rail_hits / rail_samples in get_debug_stats). Cheap per-window reset for the
## clipping-metrics suite — unlike reset() it leaves voices/reverb untouched.
func reset_rail_metrics() -> void:
	_native.reset_rail_metrics()


## Retrigger de-click knob (typewriter-blip pop fix). Fade length in ms for
## re-keying an already-audible voice on THIS SPU; 0 = disabled (instant reset,
## historical behavior). Set only on the reserved typewriter-click mixer so
## music/SFX cores stay bit-identical. Tunable live for A/B (3 ms default).
func set_click_retrigger_fade_ms(ms: float) -> void:
	_native.set_click_retrigger_fade_ms(ms)


func get_click_retrigger_fade_ms() -> float:
	return _native.get_click_retrigger_fade_ms()


## Carry the outgoing click voice's residual onto the incoming pair so a
## retriggered blip has no amplitude step at the reuse seam even when it lands on
## a DIFFERENT voice pair (the on-gated de-click above can't catch that case).
## No-op unless the fade is enabled on this SPU (see
## set_click_retrigger_fade_ms), so it costs nothing on a core that has not
## armed one.
func carry_voice_declick(src_voice_idx: int, dst_voice_idx: int) -> void:
	_native.carry_voice_declick(src_voice_idx, dst_voice_idx)


func get_voice_debug_info(voice_idx: int) -> Dictionary:
	return _native.get_voice_debug_info(voice_idx)


func set_sampled_voice_trace_enabled(enabled: bool) -> void:
	_native.set_sampled_voice_trace_enabled(enabled)


func set_sampled_voice_trace_dense(enabled: bool) -> void:
	_native.set_sampled_voice_trace_dense(enabled)


func set_sampled_voice_trace_voices(voice_indices: PackedInt32Array) -> void:
	_native.set_sampled_voice_trace_voices(voice_indices)


func clear_sampled_voice_trace() -> void:
	_native.clear_sampled_voice_trace()


func get_sampled_voice_trace() -> Array:
	return _native.get_sampled_voice_trace()


func set_reverb_enabled(enabled: bool) -> void:
	_reverb_enabled_state = enabled
	_native.set_reverb_enabled(enabled)


func set_reverb_algorithm(algorithm: String) -> void:
	_native.set_reverb_algorithm(algorithm.to_lower())


func get_reverb_algorithm() -> String:
	return _native.get_reverb_algorithm()


func set_reverb_buffer_start(addr: int) -> void:
	_native.set_reverb_buffer_start(addr)


func get_reverb_buffer_start() -> int:
	return _native.get_reverb_buffer_start()


func set_reverb_curr_addr(addr: int) -> void:
	_native.set_reverb_curr_addr(addr)


func get_reverb_curr_addr() -> int:
	return _native.get_reverb_curr_addr()


# Async-commit walker IRQ cadence (FUN_80014590 analog).
func set_irq_period_samples(n: int) -> void:
	_native.set_irq_period_samples(n)


func drain_irq_passes() -> int:
	return _native.drain_irq_passes()


func get_irq_pass_counter() -> int:
	return _native.get_irq_pass_counter()
