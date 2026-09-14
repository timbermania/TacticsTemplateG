## Parse WAVESET.WD into the descriptor + ADPCM-bank pair an [ExMateriaSpu.Spu] takes.
##
## This is ONE implementation of the SPU's input contract — the one that speaks
## WAVESET.WD. The SPU knows nothing about this class; hand it
## [method descriptors] and [member adpcm_data] and it would take the same pair
## from anywhere. A generic caller with a single sound instead reaches for
## [ExMateriaSpu.Sample] and [method ExMateriaSpu.Spu.load_samples] (D7 #380 dec. 1).
##
## The ADPCM stays RAW. This parser used to decode every instrument to PCM as
## well, which cost 555.6 ms at every boot and produced nothing anybody read —
## `pcm_data`, `shared_pcm` and `pcm_offset` were measured to have zero readers
## in the whole monorepo. What that loop actually derived was four loop fields,
## and those come out of the block flag bytes alone: the header-only scan below
## reads every one of them without decoding a sample.
##
## Loop behavior follows the SPU: a voice stops at LOOP_END unless LOOP_REPEAT
## is set too (flags == 3), and the flags are read at PLAYBACK time from SPU RAM
## — these fields are bookkeeping for the key-on address, not the loop itself.
##
## Vault: [[WAVESET Instrument Bank]]

const BLOCK_SIZE := 16
const FLAG_LOOP_END := 0x01
const FLAG_LOOP_REPEAT := 0x02
const FLAG_LOOP_START := 0x04


class Instrument:
	var index: int = 0
	var fine_tune: int = 0
	var adsr1: int = 0
	var adsr2: int = 0
	# FFT instrument-load (PC 0x80016FFC-0x80017014) writes inst byte
	# 0xd → slot+0x58 (HIGH mode), byte 0xe → slot+0x5c (LOW mode),
	# byte 0xf → slot+0x60 (CA mode). These are full 0-7 mode bytes
	# the walker reads for ADSR2 mode-bit table lookup. Prior parsing
	# extracted only bit 2 of ab[6]/ab[7], losing the input value the
	# walker needs. iter-24: preserve full bytes.
	# See docs/MUSIC_ITER24_WAVESET_MODE_BYTES_DROPPED.md.
	var mode_byte_58: int = 0
	var mode_byte_5c: int = 0
	var mode_byte_60: int = 0
	# Raw release_rate (5 bits, 0-31) from waveset byte 3 low 5 bits.
	# Iter-32: FFT's instrument-load fan-out populates slot+0x6A with
	# this value; the walker's ADSR2-LOW writer reads slot+0x6A as the
	# rate input independent of the standing ADSR2 register's low bits.
	# See docs/MUSIC_ITER32_ADSR2_LOW_RELEASE_BYTE_FIELD_SOURCE.md.
	var release_rate_byte: int = 0
	var is_null: bool = true
	var sample_offset: int = 0
	var sample_size: int = 0
	var loop_offset_bytes: int = -1  # ADPCM byte offset of LOOP_START, -1 if absent
	var has_explicit_loop_start: bool = false
	var has_loop_repeat: bool = false
	var start_offset_bytes: int = 0
	# The published unit for a sample's root pitch is cents, so this is the
	# form of `fine_tune` that crosses the addon boundary — see
	# ExMateriaSpu.Sample.base_pitch_cents. Exact rather than rounded: 100/256
	# is 25/64, dyadic, so a float carries it losslessly and the bit-exact pitch
	# parity at play_sound.gd stays intact. The FFT pipeline itself keeps using
	# the raw `fine_tune` above and never round-trips through this.
	var base_pitch_cents: float = 0.0


var instruments: Array[Instrument] = []
var adpcm_data: PackedByteArray = PackedByteArray()


## Translate this waveset's instruments into the descriptor dictionaries an
## [ExMateriaSpu.Spu] takes. The SPU's door is a plain (descriptors, bank) pair and knows
## nothing about WAVESET.WD, so translating its own format is this parser's job:
##
##     spu.load_instruments(waveset.descriptors(), waveset.adpcm_data)
func descriptors() -> Array:
	var out: Array = []
	out.resize(instruments.size())
	for i in range(instruments.size()):
		var inst := instruments[i]
		out[i] = {
			"is_null": inst.is_null,
			"fine_tune": inst.fine_tune,
			"adsr1": inst.adsr1,
			"adsr2": inst.adsr2,
			"sample_offset": inst.sample_offset,
			"sample_size": inst.sample_size,
			"loop_offset_bytes": inst.loop_offset_bytes,
			"has_explicit_loop_start": inst.has_explicit_loop_start,
			"has_loop_repeat": inst.has_loop_repeat,
			"start_offset_bytes": inst.start_offset_bytes,
		}
	return out


func load_from_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Cannot open WAVESET: " + path)
		return false
	var data := file.get_buffer(file.get_length())
	file.close()
	return parse(data)


func parse(data: PackedByteArray) -> bool:
	if data.size() < 0x20:
		return false
	if char(data[0]) != 'd' or char(data[1]) != 'w' or char(data[2]) != 'd' or char(data[3]) != 's':
		return false

	var data_offset := _read_u32(data, 0x10)
	# Local modification, 2026-09-13: validate caller-supplied data before any
	# allocation or reads. A failed deferred initialization must be retryable.
	if data_offset < 0x30 or data_offset > data.size() or (data_offset - 0x20) % 16 != 0:
		return false
	var num_entries := (data_offset - 0x20) / 16
	var bank_size := data.size() - data_offset
	var has_sample := false
	for i in range(num_entries):
		var offset := _read_u32(data, 0x20 + i * 16)
		var size := _read_u16(data, 0x24 + i * 16)
		if offset == 0 and size == 0:
			continue
		if size < BLOCK_SIZE or size % BLOCK_SIZE != 0 or offset + size > bank_size:
			return false
		has_sample = true
	if not has_sample:
		return false
	adpcm_data = data.slice(data_offset, data.size())

	instruments.clear()
	instruments.resize(num_entries)

	for i in range(num_entries):
		var inst := Instrument.new()
		inst.index = i
		var ent_off := 0x20 + i * 16
		var sample_offset := _read_u32(data, ent_off)
		var sample_size := _read_u16(data, ent_off + 4)
		inst.sample_offset = sample_offset
		inst.sample_size = sample_size
		inst.fine_tune = _read_s16(data, ent_off + 6)
		inst.base_pitch_cents = float(inst.fine_tune) * 100.0 / 256.0

		var ab := data.slice(ent_off + 8, ent_off + 16)
		# Mode bits for sustain / release come from bytes 6 and 7 of the
		# waveset entry. `ab[6] bit 2` → sustain_mode_exp, `ab[7] bit 2` →
		# release_mode_exp. Entries with ab[6]=0x03/ab[7]=0x03 produce
		# linear modes; entries with ab[6]=0x07/ab[7]=0x07 produce
		# exponential.
		var ar := ab[0] & 0x7F
		var dr := ab[1] & 0xF
		var sr := ab[2] & 0x7F
		var rr := ab[3] & 0x1F
		var sl := ab[4] & 0xF
		var sm := (ab[6] >> 2) & 1
		var rm := (ab[7] >> 2) & 1
		inst.adsr1 = (ar << 8) | (dr << 4) | sl
		inst.adsr2 = (sm << 15) | (1 << 14) | (sr << 6) | (rm << 5) | rr
		# iter-24: preserve FULL mode bytes (FFT walker reads these
		# as 0-7 mode selectors for ADSR2 HIGH/LOW writer tables).
		# ab[5] = inst byte 0xd → slot+0x58 (HIGH); ab[6] = byte 0xe
		# → slot+0x5c (LOW); ab[7] = byte 0xf → slot+0x60 (0xCA mode).
		inst.mode_byte_58 = ab[5] & 0xFF
		inst.mode_byte_5c = ab[6] & 0xFF
		inst.mode_byte_60 = ab[7] & 0xFF
		inst.release_rate_byte = rr

		if sample_offset == 0 and sample_size == 0:
			inst.is_null = true
			instruments[i] = inst
			continue

		inst.is_null = false
		var adpcm_start := data_offset + sample_offset
		var adpcm_end := adpcm_start + sample_size
		if adpcm_end > data.size():
			adpcm_end = data.size()
		var adpcm_slice := data.slice(adpcm_start, adpcm_end)
		if adpcm_slice.size() >= BLOCK_SIZE and adpcm_slice.slice(0, BLOCK_SIZE) == PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]):
			inst.start_offset_bytes = BLOCK_SIZE
		var result := _scan_loop_flags(adpcm_slice)
		inst.loop_offset_bytes = result[0]
		inst.has_explicit_loop_start = result[1]
		inst.has_loop_repeat = result[2]
		instruments[i] = inst

	print("WavesetParser: loaded ", instruments.size(), " instruments (",
		  instruments.filter(func(i): return not i.is_null).size(), " active)")
	return true


## Walk one instrument's ADPCM blocks and read the flag byte of each — byte 1
## of every 16 — stopping at the first LOOP_END exactly as the SPU's own walker
## does. Nothing is decoded: the flags are all this ever needed.
func _scan_loop_flags(data: PackedByteArray) -> Array:
	var loop_offset_bytes := -1
	var has_explicit_loop_start := false
	var has_loop_repeat := false

	for block_idx in range(data.size() / BLOCK_SIZE):
		var offset := block_idx * BLOCK_SIZE
		var flags := data[offset + 1]

		if flags & FLAG_LOOP_START:
			loop_offset_bytes = offset
			has_explicit_loop_start = true
		if flags & FLAG_LOOP_REPEAT:
			has_loop_repeat = true
		# LOOP_END terminates the scan whether or not the voice will loop
		# there; playback decides that from the flags in SPU RAM.
		if flags & FLAG_LOOP_END:
			break

	return [loop_offset_bytes, has_explicit_loop_start, has_loop_repeat]


static func char(b: int) -> String:
	return String.chr(b)

static func _read_u32(data: PackedByteArray, offset: int) -> int:
	return data[offset] | (data[offset+1] << 8) | (data[offset+2] << 16) | (data[offset+3] << 24)

static func _read_u16(data: PackedByteArray, offset: int) -> int:
	return data[offset] | (data[offset+1] << 8)

static func _read_s16(data: PackedByteArray, offset: int) -> int:
	var v := data[offset] | (data[offset+1] << 8)
	if v & 0x8000:
		v -= 0x10000
	return v
