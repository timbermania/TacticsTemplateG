extends RefCounted
## The per-effect MIPS callback tables — `E###/callbacks/CB##/callback_data.json`.
##
## Eight of the 401 effects are CODE format with bespoke MIPS that reads embedded data tables
## the normal section layout knows nothing about. `addons/exmateria_effects`' `EffectCallback`
## loads those tables by name, so they are part of the extract even though no reader in
## `effect_bin/` can find them: there is no table of contents pointing at them, only addresses
## recovered by disassembling each effect once. This is a transcription of upstream's
## `tools/parse_effect_callbacks.py`, which is where that recovery is recorded.
##
## 🔴 THE OFFSETS ARE FINDINGS, NOT DERIVATIONS. Every address below was read out of one
## effect's disassembly and holds for that effect only — E005/E006/E007 share `0x14F8` because
## they share code, while E015's otherwise identical WorldTube table sits at `0x3238`. Nothing
## here can be generalised to a ninth effect without disassembling it, and a wrong offset
## yields a plausible-looking table rather than an error, which is why the row loop validates
## its values instead of trusting the address.
##
## ⚠️ FILE OFFSETS, NOT HEADER-RELATIVE ONES. These are raw positions in the `.BIN`, already
## converted from the PSX load address `0x801C2500`. They do NOT shift with the header offset
## the rest of the extract works in.

## The PSX RAM address every one of these effects loads at.
const VFX_LOAD_BASE: int = 0x801C2500

## Upper bound on a brightness table's rows — the loop stops on out-of-range values well
## before this, but a corrupt file must not walk to EOF.
const MAX_ROWS: int = 16

## A brightness value outside this range means the walk has left the table.
const VALUE_MIN: int = 0
const VALUE_MAX: int = 4096

## Effect -> the plain "read rows until they stop looking like brightness" tables.
## `{cb_id, offset, ints_per_row}`. Effects needing more than this are handled below.
const SIMPLE_TABLES: Dictionary = {
	"E005": [{"cb": 4, "offset": 0x14F8, "ints": 9}],
	"E006": [{"cb": 5, "offset": 0x14F8, "ints": 9}],
	"E007": [{"cb": 6, "offset": 0x14F8, "ints": 9}],
	# CB09 (ScreenGrid) has no table of its own — it draws from vertex colours. The EMPTY
	# table is written anyway, because the addon distinguishes "no file" from "no rows".
	"E015": [{"cb": 8, "offset": 0x3238, "ints": 9}, {"cb": 9, "offset": -1, "ints": 0}],
	"E033": [{"cb": 11, "offset": 0x2390, "ints": 9}],
	"E065": [
		{"cb": 16, "offset": 0x33E8, "ints": 5},
		{"cb": 18, "offset": 0x351C, "ints": 9},
	],
}

## The effects this module can answer for at all.
const SUPPORTED: PackedStringArray = ["E005", "E006", "E007", "E015", "E033", "E065", "E071",
	"E317"]


## `{ "callbacks/CB##/callback_data.json" -> Dictionary }`, empty for the 393 effects that
## have no bespoke callback. `emitters` is the parsed `emitters.json` block — E071 reads
## fields back out of it, the way the Python reads the file it just wrote.
static func build(effect_name: String, buf: PackedByteArray, emitters: Array) -> Dictionary:
	var out: Dictionary = {}
	if SIMPLE_TABLES.has(effect_name):
		for entry: Dictionary in SIMPLE_TABLES[effect_name]:
			out[_leaf(entry["cb"])] = {
				"callback_id": entry["cb"],
				"brightness_table": _rows(buf, entry["offset"], entry["ints"]),
			}
	match effect_name:
		"E065":
			out[_leaf(17)] = _e065_cb17(buf)
		"E071":
			out[_leaf(26)] = _e071_cb26(buf, emitters)
		"E317":
			out[_leaf(92)] = _e317_cb92(buf)
	return out


## E065 CB17 — the spiral/helix mesh callback: a 6-wide table plus raw emitter fields that
## `emitters.json` does not carry, because the callback reads those bytes as a different shape
## than the emitter record declares.
static func _e065_cb17(buf: PackedByteArray) -> Dictionary:
	# From header.json: ParticleSystem at 19056, 20-byte particle header, so emitter 0 at
	# 19076. Transcribed as the constant the Python uses rather than recomputed — this is a
	# finding about E065, not a layout rule.
	const EMITTER_BASE: int = 19076
	const EMITTER_STRIDE: int = 196
	var overrides: Dictionary = {}
	for emitter_idx in [10, 14]:
		var off: int = EMITTER_BASE + emitter_idx * EMITTER_STRIDE
		overrides[str(emitter_idx)] = {
			"size_start": _s16(buf, off + 0x38),
			"size_end": _s16(buf, off + 0x3A),
			"size_spread_start": _s16(buf, off + 0x3C),
			"size_spread_end": _s16(buf, off + 0x3E),
			"rotation_start": _s16(buf, off + 0x40),
			"rotation_end": _s16(buf, off + 0x42),
			"rot_vel_start": _s16(buf, off + 0x44),
			"rot_vel_end": _s16(buf, off + 0x46),
			# 0x48 is colour_r start/end, which this callback reads as one s16 — a bag of
			# bytes, deliberately not the field the emitter record names.
			"color_as_s16_0x48": _s16(buf, off + 0x48),
			"depth_0x54": _s16(buf, off + 0x54),
			# Reserved radial fields, used here as rotation acceleration.
			"radial_reserved_1": _s16(buf, off + 0x9C),
			"radial_reserved_2": _s16(buf, off + 0xA2),
			"curve_nibbles_0c": _nibbles(buf, off + 0x0C),
		}
	return {
		"callback_id": 17,
		"brightness_table": _rows(buf, 0x3474, 6),
		"emitter_overrides": overrides,
	}


## E071 (Bahamut) CB26 — shared by CB26 and CB27, the hemisphere/dome mesh callback.
static func _e071_cb26(buf: PackedByteArray, emitters: Array) -> Dictionary:
	const EMITTER_BASE: int = 11960
	const EMITTER_STRIDE: int = 196
	# ⚠️ This one does NOT require a full row before range-checking it, matching the Python.
	# At EOF a short row is range-checked as far as it goes; no corpus effect reaches that.
	var rows: Array = _rows(buf, 0x1B00, 9, false)
	var overrides: Dictionary = {}
	for emitter_idx in [3, 8]:
		var off: int = EMITTER_BASE + emitter_idx * EMITTER_STRIDE
		var em: Dictionary = emitters[emitter_idx] if emitter_idx < emitters.size() else {}
		var raw: Dictionary = em.get("raw", {})
		var vel_spread: Array = raw.get("vel_spread_start", [0, 0, 0])
		var pos_end: Array = raw.get("position_end", [0, 0, 0])
		# The row index arrives as PSX fixed point when it overruns the table — shift, then
		# fall back to row 0 rather than indexing past the end.
		var brightness_idx: int = int(vel_spread[2]) if vel_spread.size() > 2 else 0
		if brightness_idx >= rows.size():
			brightness_idx = brightness_idx >> 8
		if brightness_idx >= rows.size():
			brightness_idx = 0
		overrides[str(emitter_idx)] = {
			"brightness_row_index": brightness_idx,
			"spread_start_w": _s16(buf, off + 0xAC),
			"curve_indices_raw": em.get("curve_indices_raw", [0, 0, 0, 0, 0, 0, 0, 0]),
			"raw_position_end_x": int(pos_end[0]) if pos_end.size() > 0 else 0,
		}
	return {
		"callback_id": 26,
		"brightness_table": rows,
		"emitter_overrides": overrides,
	}


## E317 (Choco Ball) CB92 — ONE row of the bell curve, not a walk: the entry index is fixed at
## 4 (emitter 4's `vel_spread_start[2]`), and only the first EIGHT of its nine int32s are used.
static func _e317_cb92(buf: PackedByteArray) -> Dictionary:
	const ENTRY_INDEX: int = 4
	const ENTRY_BYTES: int = 36
	var entry_offset: int = 0x3788 + ENTRY_INDEX * ENTRY_BYTES
	return {
		"callback_id": 92,
		"brightness_table": _int32s(buf, entry_offset, 9).slice(0, 8),
		"radius_profile": _int32s(buf, 0x3860, 5),
	}


# --- primitives --------------------------------------------------------------

static func _leaf(cb_id: int) -> String:
	return "callbacks/CB%02d/callback_data.json" % cb_id


## Rows of `ints` int32s at `offset`, stopping at the first row that does not look like
## brightness. `offset < 0` means "this callback has no table" and answers `[]`.
static func _rows(buf: PackedByteArray, offset: int, ints: int,
		require_full_row: bool = true) -> Array:
	var rows: Array = []
	if offset < 0 or ints <= 0:
		return rows
	var stride: int = ints * 4
	for row in MAX_ROWS:
		var values: Array = _int32s(buf, offset + row * stride, ints)
		if require_full_row and values.size() < ints:
			break
		var in_range := true
		for v: int in values:
			if v < VALUE_MIN or v > VALUE_MAX:
				in_range = false
				break
		if not in_range:
			break
		rows.append(values)
	return rows


## `count` little-endian int32s, truncated at EOF rather than padded.
static func _int32s(buf: PackedByteArray, offset: int, count: int) -> Array:
	var out: Array = []
	for i in count:
		var pos: int = offset + i * 4
		if pos < 0 or pos + 4 > buf.size():
			break
		out.append(buf.decode_s32(pos))
	return out


static func _s16(buf: PackedByteArray, offset: int) -> int:
	if offset < 0 or offset + 2 > buf.size():
		return 0
	return buf.decode_s16(offset)


## The eight curve-index nibbles packed into the four bytes at `offset`, low nibble first.
static func _nibbles(buf: PackedByteArray, offset: int) -> Array:
	var out: Array = []
	for i in 4:
		var pos: int = offset + i
		var b: int = buf[pos] if pos >= 0 and pos < buf.size() else 0
		out.append(b & 0xF)
		out.append((b >> 4) & 0xF)
	return out
