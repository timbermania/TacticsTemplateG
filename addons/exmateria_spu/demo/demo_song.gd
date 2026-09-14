extends RefCounted

## The demo's song — four synthesised samples and a schedule of register writes.
##
## There is no Node here, no scene and no audio device. That is deliberate: the
## same score that plays live through an [ExMateriaSpuStream] also renders
## offline through [method ExMateriaSpu.Spu.render_deferred_pcm16], so what a listener hears
## and what a test asserts are the same bytes.
##
##     var song := load("res://addons/exmateria_spu/demo/demo_song.gd").new()
##     song.upload(spu)                      # synthesise + load_samples
##     for ev in song.events():              # stamp the writes
##         spu.set_schedule_frame(ev.frame)
##         song.apply(spu, ev)
##
## Nothing is loaded from disk. Every byte of audio below is computed at boot,
## in about a hundredth of a second, which is why this demo ships no assets and
## raises no licensing question.

const _Sample = preload("res://addons/exmateria_spu/runtime/spu_sample.gd")
const _Spu = preload("res://addons/exmateria_spu/runtime/spu.gd")

const SAMPLE_RATE := 44100

## 105 BPM, chosen so a beat is a whole number of frames: 44100 * 60 / 105.
const BEAT_FRAMES := 25200
const STEP_FRAMES := BEAT_FRAMES / 4      ## a sixteenth note
const STEPS_PER_BAR := 16
const BARS := 8
const LOOP_FRAMES := BARS * STEPS_PER_BAR * STEP_FRAMES   ## 8 bars ≈ 18.3 s

## Which musical part an event belongs to, so a listener can mute one and hear
## what the others are doing. [constant Part.NONE] is the housekeeping the
## driver must never skip.
enum Part { NONE = 0, BASS = 1, PAD = 2, LEAD = 3, DRUMS = 4 }

# ---------------------------------------------------------------------------
# Voices. The SPU has 24; this uses eight, one part per contiguous group.
# ---------------------------------------------------------------------------
const V_BASS := 0
const V_PAD := [1, 2, 3]
const V_LEAD := 4
const V_HAT := 5
const V_SNARE := 6
const V_KICK := 7

# ---------------------------------------------------------------------------
# Envelopes. Every pair below was measured against this core rather than copied
# from a hardware doc, because one of them is a trap: `adsr1 = 0x000F` — the
# pair most PSX examples reach for — sets sustain level 15 AND decay rate 0, and
# a decay rate of 0 takes one enormous step before the sustain check can stop
# it. The envelope lands on HALF scale and holds there. Raising the decay nibble
# to 0xF makes that first step negligible, so 0x00FF is the pair that actually
# sustains at full.
#
# adsr1 = attack_rate << 8 | decay_rate << 4 | sustain_level
# adsr2 = sustain_decreases << 14 | sustain_rate << 6 | release_rate
# ---------------------------------------------------------------------------

## Instant attack, hold at full, release in about 110 ms. The workhorse.
const ADSR_HOLD := [0x00FF, (0x7F << 6) | 0x08]

## A pad: ~200 ms of attack ramp, then hold; a long tail when released.
const ADSR_PAD := [(0x30 << 8) | 0xFF, (0x7F << 6) | 0x0C]

## A pluck: full immediately, gone in about 200 ms without any key-off.
const ADSR_PLUCK := [0x00C0, (1 << 14) | (0x20 << 6) | 0x08]

## A closed hat: a 20 ms tick.
const ADSR_TICK := [0x0080, (1 << 14) | (0x20 << 6) | 0x04]

## A snare: 100 ms of noise with a tail.
const ADSR_CRACK := [0x00A0, (1 << 14) | (0x20 << 6) | 0x08]

# ---------------------------------------------------------------------------
# Samples. Each is a band-limited harmonic stack whose period divides both 28
# (the ADPCM block) and the total length, so the loop joins on a zero crossing
# and the encoder never has to fake a partial block.
# ---------------------------------------------------------------------------
const _WAVE_FRAMES := 4480                       ## 160 whole ADPCM blocks

const _PERIOD_BASS := 224                        ## 196.875 Hz
const _PERIOD_PAD := 112                         ## 393.75 Hz
const _PERIOD_LEAD := 56                         ## 787.5 Hz

var _f0 := {}          ## instrument index -> the pitch its bytes sound at
var _idx_bass := -1
var _idx_pad := -1
var _idx_lead := -1
var _idx_kick := -1
var _loaded := false


## Synthesise the four samples and upload them. Call with the stream stopped.
func upload(spu: _Spu) -> bool:
	var bass := _Sample.from_pcm16(
			_harmonics(_PERIOD_BASS, _WAVE_FRAMES, _saw_amps(24), 26000.0), 0)
	var pad := _Sample.from_pcm16(
			_harmonics(_PERIOD_PAD, _WAVE_FRAMES, PackedFloat32Array([1.0, 0.55, 0.12, 0.06, 0.03]), 24000.0), 0)
	var lead := _Sample.from_pcm16(
			_harmonics(_PERIOD_LEAD, _WAVE_FRAMES, _hollow_amps(12), 26000.0), 0)
	var kick := _Sample.from_pcm16(_kick(_WAVE_FRAMES), -1)
	if bass == null or pad == null or lead == null or kick == null:
		push_error("demo_song: could not encode the synthesised samples")
		return false

	var indices := spu.load_samples([bass, pad, lead, kick])
	if indices.size() != 4:
		push_error("demo_song: load_samples returned %s" % str(indices))
		return false
	_idx_bass = indices[0]
	_idx_pad = indices[1]
	_idx_lead = indices[2]
	_idx_kick = indices[3]
	_f0 = {
		_idx_bass: float(SAMPLE_RATE) / float(_PERIOD_BASS),
		_idx_pad: float(SAMPLE_RATE) / float(_PERIOD_PAD),
		_idx_lead: float(SAMPLE_RATE) / float(_PERIOD_LEAD),
		_idx_kick: float(SAMPLE_RATE),
	}
	_loaded = true
	return true


func is_loaded() -> bool:
	return _loaded


## The instrument index [method ExMateriaSpu.Spu.load_samples] gave each synthesised sample,
## by name: `bass`, `pad`, `lead`, `kick`. Handy for playing one of them on its
## own — which is what the demo's test does to isolate pitch, envelope and noise.
func instruments() -> Dictionary:
	return {"bass": _idx_bass, "pad": _idx_pad, "lead": _idx_lead, "kick": _idx_kick}


## Apply one event from [method events] to an SPU. The driver stamps the frame;
## this only knows how to make the call.
func apply(spu: _Spu, ev: Dictionary) -> void:
	spu.callv(ev["method"], ev["args"])


# ---------------------------------------------------------------------------
# Sample synthesis
# ---------------------------------------------------------------------------

## Sawtooth partial amplitudes: 1/n for n harmonics. Band-limited by
## construction, so nothing aliases no matter what pitch it is played at.
static func _saw_amps(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	for h in range(1, n + 1):
		a.append(1.0 / float(h))
	return a


## Odd harmonics only — a square-ish, hollow tone that cuts through a pad.
static func _hollow_amps(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	for h in range(1, n + 1):
		a.append(0.0 if h % 2 == 0 else 1.0 / float(h))
	return a


## One periodic wave, `total` samples long, normalised to `peak`.
static func _harmonics(period: int, total: int, amps: PackedFloat32Array, peak: float) -> PackedInt32Array:
	var raw := PackedFloat32Array()
	raw.resize(total)
	var biggest := 0.0
	for i in range(total):
		var phase := TAU * float(i) / float(period)
		var v := 0.0
		for h in range(amps.size()):
			if amps[h] != 0.0:
				v += amps[h] * sin(phase * float(h + 1))
		raw[i] = v
		biggest = maxf(biggest, absf(v))
	var out := PackedInt32Array()
	out.resize(total)
	var gain := (peak / biggest) if biggest > 0.0 else 0.0
	for i in range(total):
		out[i] = int(round(raw[i] * gain))
	return out


## A kick drum: a sine whose pitch falls from 150 Hz to 45 Hz while its
## amplitude decays. One-shot — the sample IS the envelope, which is why the
## voice that plays it holds its ADSR wide open.
static func _kick(total: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(total)
	var phase := 0.0
	for i in range(total):
		var t := float(i) / float(SAMPLE_RATE)
		var hz := 45.0 + 105.0 * exp(-t / 0.035)
		phase += TAU * hz / float(SAMPLE_RATE)
		out[i] = int(round(29000.0 * exp(-t / 0.10) * sin(phase)))
	return out


# ---------------------------------------------------------------------------
# Notes
# ---------------------------------------------------------------------------

## MIDI note -> the SPU's raw pitch register for a given instrument's bytes.
## The register is a playback-rate ratio, not a note: 0x1000 plays the sample at
## the rate it was written at, and the ceiling is 0x3FFF — two octaves up.
func pitch_for(midi: float, instrument_idx: int) -> int:
	var hz := 440.0 * pow(2.0, (midi - 69.0) / 12.0)
	return clampi(int(round(4096.0 * hz / float(_f0[instrument_idx]))), 1, 0x3FFF)


# ---------------------------------------------------------------------------
# The score
#
# Eight bars in A minor over Am - F - C - G - Am - F - C - E, at one sixteenth
# of resolution. All of it is data; the loop below turns it into register
# writes and nothing else.
# ---------------------------------------------------------------------------

## Bass root per bar: A1 F1 C2 G1 A1 F1 C2 E1.
const _BASS_ROOTS := [33, 29, 36, 31, 33, 29, 36, 28]

## Pad triad per bar, voiced around middle C.
const _PAD_CHORDS := [
	[57, 60, 64],   # Am
	[57, 60, 65],   # F
	[55, 60, 64],   # C
	[55, 59, 62],   # G
	[57, 60, 64],   # Am
	[57, 60, 65],   # F
	[55, 60, 64],   # C
	[56, 59, 64],   # E
]

## [step, midi, length_in_steps] across all 128 sixteenths.
##
## The length is not read. ADSR_PLUCK ends each note on its own, so the lead
## never keys off — the field is here because it says what the phrasing means,
## and because an envelope that sustained would need it.
const _MELODY := [
	[0, 69, 4], [4, 72, 4], [8, 76, 8],
	[16, 74, 4], [20, 72, 4], [24, 69, 8],
	[32, 72, 4], [36, 76, 4], [40, 79, 8],
	[48, 74, 4], [52, 71, 4], [56, 67, 8],
	[64, 69, 2], [66, 72, 2], [68, 76, 4], [72, 81, 8],
	[80, 79, 4], [84, 76, 4], [88, 72, 8],
	[96, 76, 4], [100, 79, 4], [104, 84, 8],
	[112, 79, 4], [116, 76, 4], [120, 68, 8],
]

## The one note that slides into place instead of arriving. Step 72 is the top
## of the phrase in bar 5.
const _GLIDE_STEP := 72
const _GLIDE_FROM := 76.0
const _GLIDE_STEPS := 24        ## register writes across the slide
const _GLIDE_FRAMES := 9000     ## about 200 ms

const _BASS_PATTERN := [[0, 0, 6], [6, 0, 2], [8, 12, 4], [14, 0, 2]]
const _KICK_STEPS := [0, 10]
const _SNARE_STEPS := [4, 12]

const _VOL_BASS := 0x1200
const _VOL_PAD := [[0x0700, 0x0400], [0x0580, 0x0580], [0x0400, 0x0700]]
const _VOL_LEAD := 0x0E00
const _VOL_HAT := 0x0380
const _VOL_HAT_ACCENT := 0x0600
const _VOL_SNARE := 0x0A00
const _VOL_KICK := 0x1600

## The global noise clock the hats and the snare start on. 0 is broadband and
## 63 is the slowest, most pitched rasp; the demo's slider walks the whole
## range while it plays.
const DEFAULT_NOISE_CLOCK := 34


## Every register write in one 8-bar loop, sorted by frame.
##
## Each entry is `{frame, part, method, args}`. `frame` is relative to the start
## of the loop, so a driver playing it forever just adds
## [constant LOOP_FRAMES] each time round.
func events() -> Array:
	if not _loaded:
		push_error("demo_song: call upload() before events()")
		return []
	var out: Array = []

	# Housekeeping, at the top of the loop. The noise voices are the only two
	# whose source is the SPU's LFSR rather than a sample; every other register
	# they use is the same as a pitched voice's.
	#
	# These three are [constant Part.NONE] and they are IDEMPOTENT SETUP: none of
	# them is undone anywhere in the score, so a driver playing the loop over and
	# over should apply them on the first pass only. Re-applying them every time
	# round would stamp DEFAULT_NOISE_CLOCK back over whatever the listener had
	# dialled in, roughly every eighteen seconds.
	out.append(_ev(0, Part.NONE, &"set_noise_clock", [DEFAULT_NOISE_CLOCK]))
	out.append(_ev(0, Part.NONE, &"set_voice_noise", [V_HAT, true]))
	out.append(_ev(0, Part.NONE, &"set_voice_noise", [V_SNARE, true]))

	for bar in range(BARS):
		var bar0 := bar * STEPS_PER_BAR

		# --- bass -----------------------------------------------------------
		var root: int = _BASS_ROOTS[bar]
		for hit in _BASS_PATTERN:
			var at: int = bar0 + hit[0]
			out.append(_key_on(at, Part.BASS, V_BASS, _idx_bass, root + hit[1],
					_VOL_BASS, _VOL_BASS, ADSR_HOLD, false))
			out.append(_ev(_f(at + hit[2]), Part.BASS, &"key_off", [V_BASS]))

		# --- pad ------------------------------------------------------------
		var chord: Array = _PAD_CHORDS[bar]
		for i in range(3):
			out.append(_key_on(bar0, Part.PAD, V_PAD[i], _idx_pad, chord[i],
					_VOL_PAD[i][0], _VOL_PAD[i][1], ADSR_PAD, true))
			out.append(_ev(_f(bar0 + STEPS_PER_BAR - 1), Part.PAD, &"key_off", [V_PAD[i]]))

		# --- drums ----------------------------------------------------------
		for s in _KICK_STEPS:
			out.append(_key_on(bar0 + s, Part.DRUMS, V_KICK, _idx_kick, 60,
					_VOL_KICK, _VOL_KICK, ADSR_HOLD, false))
			out.append(_ev(_f(bar0 + s + 4), Part.DRUMS, &"key_off", [V_KICK]))
		for s in _SNARE_STEPS:
			out.append(_key_on(bar0 + s, Part.DRUMS, V_SNARE, _idx_pad, 60,
					_VOL_SNARE, _VOL_SNARE, ADSR_CRACK, true))
		for s in range(0, STEPS_PER_BAR, 2):
			var accent: int = _VOL_HAT_ACCENT if s % 4 == 0 else _VOL_HAT
			out.append(_key_on(bar0 + s, Part.DRUMS, V_HAT, _idx_pad, 60,
					accent, accent + 0x0300, ADSR_TICK, false))

	# --- lead ---------------------------------------------------------------
	for note in _MELODY:
		var step: int = note[0]
		var midi: int = note[1]
		out.append(_key_on(step, Part.LEAD, V_LEAD, _idx_lead, midi,
				_VOL_LEAD, _VOL_LEAD, ADSR_PLUCK, true))
		if step == _GLIDE_STEP:
			# Land the note a fifth below and walk the pitch register up to it.
			# Pitch is a plain register write, so a slide is nothing more than
			# writing it again — the same thing a PSX driver did on the CPU
			# side, and here each write is stamped with the frame it lands on.
			out[-1]["args"][2] = pitch_for(_GLIDE_FROM, _idx_lead)
			for k in range(1, _GLIDE_STEPS + 1):
				var frac := float(k) / float(_GLIDE_STEPS)
				var midi_now: float = _GLIDE_FROM + (float(midi) - _GLIDE_FROM) * frac
				out.append(_ev(_f(step) + int(_GLIDE_FRAMES * frac), Part.LEAD,
						&"set_voice_pitch", [V_LEAD, pitch_for(midi_now, _idx_lead)]))

	out.sort_custom(func(a, b): return a["frame"] < b["frame"])
	return out


func _f(step: int) -> int:
	return step * STEP_FRAMES


func _ev(frame: int, part: int, method: StringName, args: Array) -> Dictionary:
	return {"frame": frame, "part": part, "method": method, "args": args}


func _key_on(step: int, part: int, voice: int, instrument: int, midi: int,
		vol_l: int, vol_r: int, adsr: Array, p_reverb: bool) -> Dictionary:
	return _ev(_f(step), part, &"key_on",
			[voice, instrument, pitch_for(midi, instrument), vol_l, vol_r, adsr[0], adsr[1], p_reverb])
