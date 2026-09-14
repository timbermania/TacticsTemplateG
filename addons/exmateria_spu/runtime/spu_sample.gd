extends Resource

## One sample for an [ExMateriaSpu.Spu] — PSX ADPCM bytes, a start point, a loop point and a
## root pitch. Nothing else: the envelope is a property of the INSTRUMENT that
## plays these bytes, not of the bytes, so it is passed at key-on instead.
##
## Build one from PCM you already have:
##
##     var sample := ExMateriaSpu.Sample.from_pcm16(pcm, 0)   # 0 = loop at the start
##     var idx := spu.load_samples([sample])
##     spu.key_on(0, idx[0], 0x1000, 0x3FFF, 0x3FFF, 0x000F, 0x1FDF)
##
## …or hand it ADPCM you produced elsewhere, and set the fields yourself.
##
## For a packed bank whose internal offsets already mean something — several
## instruments pointing into one image, the way a PSX game's sample bank does —
## use [method ExMateriaSpu.Spu.load_instruments] instead. The two doors sit over one
## implementation; neither is the "real" one.

const _Sample = preload("res://addons/exmateria_spu/runtime/spu_sample.gd")

## PSX ADPCM, in 16-byte blocks. Each block is a 1-byte header (predictor and
## shift), a 1-byte flag field, then 14 bytes of 4-bit samples — 28 samples per
## block. Anything not a whole number of blocks is rejected by
## [method ExMateriaSpu.Spu.load_samples].
@export var data: PackedByteArray = PackedByteArray()

## Byte offset within [member data] where playback begins. Use it to skip a
## lead-in that should only be heard once. Must be a multiple of 16.
@export var start_offset: int = 0

## Byte offset within [member data] of the loop point, or -1.
##
## The SPU reads loop points out of the ADPCM block flags at playback time —
## that is the single source of truth, and it is what the hardware does. This
## field is an AUTHOR-TIME convenience: at pack time, [method ExMateriaSpu.Spu.load_samples]
## stamps the loop flags into a copy of the bytes so they say what this field
## says. -1 means "the bytes are already right, do not touch them".
##
## Must be a multiple of 16, and must not land in the final block — see
## [method ExMateriaSpu.Spu.load_samples].
@export var loop_offset: int = -1

## How far this recording sounds from the note it should sound as, in cents.
##
## Positive raises pitch. A 22050 Hz recording played at the SPU's nominal rate
## comes out an octave high, so it carries -1200. It is a DEFAULT that travels
## with the audio, not a constraint: the caller passes the final pitch to
## [method ExMateriaSpu.Spu.key_on] and may ignore this entirely.
##
## Cents rather than any one game's tuning unit, and float rather than int:
## 1/256 of a semitone is 0.390625 cents, so integer cents could not round-trip
## a PSX sample bank losslessly.
@export var base_pitch_cents: float = 0.0

const BLOCK_SIZE := 16
const SAMPLES_PER_BLOCK := 28
const SPU_NOMINAL_RATE := 44100


## Encode 16-bit mono PCM into a sample.
##
## [param pcm] is one int per sample, clamped to int16. [param loop_at] is a
## SAMPLE index: >= 0 loops forever from there, -1 is a one-shot. The loop point
## is rounded down to a 28-sample block, because the SPU's loop marker is a flag
## on a block.
##
## [param source_rate_hz] is the rate the PCM was recorded at; it only sets
## [member base_pitch_cents] and does not resample. The default, 44100, is the
## SPU's own nominal rate and yields 0 cents.
##
## The encoder is a verbatim MIT copy of PCSX-Redux's re-creation of Sony's
## Psy-Q `encvag` — see the addon's NOTICE. It runs at roughly 1800x realtime,
## which is why this is a runtime call and not an import step.
static func from_pcm16(pcm: PackedInt32Array, loop_at: int = -1,
		source_rate_hz: int = SPU_NOMINAL_RATE) -> _Sample:
	if pcm.is_empty():
		push_error("ExMateriaSpu.Sample.from_pcm16: no samples")
		return null
	if source_rate_hz <= 0:
		push_error("ExMateriaSpu.Sample.from_pcm16: source_rate_hz must be positive, got %d" % source_rate_hz)
		return null
	var s := _Sample.new()
	s.data = ExMateriaSpuAdpcm.encode_pcm16(pcm, loop_at)
	if s.data.is_empty():
		push_error("ExMateriaSpu.Sample.from_pcm16: the encoder produced no bytes")
		return null
	# The encoder has already stamped the loop flags into the block it marked,
	# so there is nothing left for the packer to stamp. Saying otherwise here
	# would make load_samples re-stamp a DIFFERENT block whenever the encoder
	# had to move the loop point to fit.
	s.loop_offset = -1
	s.base_pitch_cents = 1200.0 * (log(float(source_rate_hz) / float(SPU_NOMINAL_RATE)) / log(2.0))
	return s


## Read a 16-bit PCM RIFF/WAVE file and encode it.
##
## Mono or stereo (stereo is downmixed), any sample rate — the rate is carried
## as [member base_pitch_cents] rather than resampled, so playback pitch stays
## the caller's decision. 8-bit, 24-bit, 32-bit and float WAVs are refused
## rather than silently mangled; convert them first.
##
## [param loop_at] is a sample index, as in [method from_pcm16].
static func from_wav(path: String, loop_at: int = -1) -> _Sample:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("ExMateriaSpu.Sample.from_wav: cannot read " + path)
		return null
	var wav := _parse_wav(bytes, path)
	if wav.is_empty():
		return null
	return from_pcm16(wav["pcm"], loop_at, int(wav["rate"]))


## RIFF/WAVE, walked chunk by chunk. Returns {} and pushes an error rather than
## guessing: a WAV this cannot represent should fail here, not come out as
## noise at the far end of the SPU.
static func _parse_wav(bytes: PackedByteArray, path: String) -> Dictionary:
	if bytes.size() < 12 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" \
			or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		push_error("ExMateriaSpu.Sample.from_wav: not a RIFF/WAVE file: " + path)
		return {}
	var pos := 12
	var channels := 0
	var rate := 0
	var bits := 0
	var fmt_code := 0
	var pcm := PackedInt32Array()
	var saw_data := false
	while pos + 8 <= bytes.size():
		var id := bytes.slice(pos, pos + 4).get_string_from_ascii()
		var size := bytes.decode_u32(pos + 4)
		var body := pos + 8
		if body + size > bytes.size():
			size = bytes.size() - body
		if id == "fmt ":
			if size < 16:
				push_error("ExMateriaSpu.Sample.from_wav: truncated fmt chunk in " + path)
				return {}
			fmt_code = bytes.decode_u16(body)
			channels = bytes.decode_u16(body + 2)
			rate = bytes.decode_u32(body + 4)
			bits = bytes.decode_u16(body + 14)
		elif id == "data":
			saw_data = true
			if channels <= 0 or rate <= 0:
				push_error("ExMateriaSpu.Sample.from_wav: data chunk before fmt in " + path)
				return {}
			if fmt_code != 1 or bits != 16:
				push_error("ExMateriaSpu.Sample.from_wav: %s is format %d / %d-bit; only 16-bit PCM is supported. Convert it first."
						% [path, fmt_code, bits])
				return {}
			var frames := size / (2 * channels)
			pcm.resize(frames)
			for f in range(frames):
				var acc := 0
				for c in range(channels):
					acc += bytes.decode_s16(body + (f * channels + c) * 2)
				pcm[f] = acc / channels
		# Chunks are word-aligned: an odd size is followed by a pad byte.
		pos = body + size + (size & 1)
	if not saw_data:
		push_error("ExMateriaSpu.Sample.from_wav: no data chunk in " + path)
		return {}
	if pcm.is_empty():
		push_error("ExMateriaSpu.Sample.from_wav: data chunk holds no frames in " + path)
		return {}
	return {"pcm": pcm, "rate": rate, "channels": channels}
