## Opcode definitions and track decoder for BOTH sound containers.
##
## The opcode language is one; SMD (music) and FEDS (effect sound) are two
## containers carrying it, and both decode through here — `smd_parser.gd` and
## `feds_bank.gd` alike. `SMD` in a name below still means the on-disc music
## container and is correct; the CLASS wearing that name was not (ADR-0136
## dec. 4, corrected at #407).
##
## Vault: [[GOLD Probe Validation]]
## Vault: [[SMD Header Layout]]
## Vault: [[SMD Opcodes]]

# Tick durations indexed by (data_byte % 19). Index 0 = read next byte.
const DELTA_TIME_TABLE: PackedInt32Array = [0, 192, 144, 96, 72, 64, 48, 36, 32, 24, 18, 16, 12, 9, 8, 6, 4, 3, 2]

const PPQ := 48  # Pulses per quarter note

## FFT's initial tempo. It is a CONSTANT in the ROM, not an SMD header field.
##
## The channel init at SCUS 0x8001386C-0x80013888 writes the whole tempo triple
## as literals -- chan+0x7C = 0x00660000, chan+0x8A = 0x100, chan+0x78 = 0x6600
## -- which is exactly opcode 0xA0's own formula (`byte << 16` into +0x7C,
## `byte * lh[+0x8A]` into +0x78) with byte = 102 (0x66). Every retail song then
## issues 0xA0 before its first note, so this seed is always overwritten before
## anything sounds.
##
## No SMD header byte reaches +0x7C / +0x7E / +0x86 / +0x8A -- verified by a
## complete scan of every sb/sh/sw to those offsets in 0x80013000-0x80019000.
## See #619. 102 is 119.8 BPM through fft_tempo_to_bpm(), which is why that
## function's zero-fallback is 120.0.
const FFT_INITIAL_TEMPO := 102

## FFT's initial master volume, in the same sense as FFT_INITIAL_TEMPO above:
## a driver constant, not a header field.
##
## The live master volume is entity+0x96 (the walker reads it at PC 0x80017204
## as `lh v1,0x96(s2)` and multiplies the per-channel amplitude by it). Two
## sites write it, and neither reads the SMD header:
##
##   FUN_800137D8 @ 0x80013878  `sw 0x7F000000, 0x94(s0)`  -> +0x96 = 0x7F00
##   FUN_80012F08 (SetMasterVolume(entity, level, fade)) @ 0x80012F48
##       `sw level<<24, 0x94(s0)`                          -> +0x96 = level<<8
##
## and the ordinary music-start path passes `level` as a literal: SeqPlay's
## caller at 0x80043E68 is `ori a1,zero,0x7f`. So +0x96 lands on 0x7F00 twice
## over.
##
## Header halfword 0x18 IS parsed -- `lhu` at 0x80013728 into entity+0x1A, whose
## initializer default is also 0x7F (FUN_80013788 @ 0x800137C4) -- but nothing in
## SCUS reads entity+0x1A. Verified live on MUSIC_34: seeding entity+0x1A to
## 0x0030 for 6 s while the driver ticked (54 hits at 0x80014D58 in 0.5 s) left
## entity+0x96 at 0x7F00; a control write of 0x1234 to +0x96 persisted, so the
## instrument was not inert. See #619.
const FFT_INITIAL_MASTER_VOLUME := 0x7F

# Opcode -> [name, param_count]
const OPCODE_INFO := {
	# 0x80-0x9F: control flow + structure
	0x80: ["Rest", 1], 0x81: ["Fermata", 1], 0x82: ["NOP", 0],
	0x90: ["EndBar", 0], 0x91: ["Loop", 0],
	0x94: ["Octave", 1], 0x95: ["RaiseOctave", 0], 0x96: ["LowerOctave", 0],
	0x97: ["TimeSignature", 2],
	0x98: ["Repeat", 1], 0x99: ["Coda", 0], 0x9A: ["RepeatBreak", 0],
	0x9B: ["NOP_Sled", 0],                  # FFT LAB_8001586c (jr ra; move v0,a0) — true no-op

	# 0xA0-0xAF: tempo + instrument
	0xA0: ["Tempo", 1], 0xA2: ["TempoSlide", 2],
	0xA9: ["FormulaSelector", 1],           # slot+0x7A → switch case L800156D0
	0xAC: ["Instrument", 1],
	0xAD: ["Byte76_Adjust", 1],             # slot+0x76 sign-extended add (was Unknown_AD)
	0xAE: ["PercussionOn", 0], 0xAF: ["PercussionOff", 0],
	# 0xB0-0xBF: slur, FMod, noise, reverb
	0xB0: ["SlurOn", 0], 0xB1: ["SlurOff", 0],
	0xB2: ["FMod_Enable", 0],               # entity+0x68 |= voice_mask
	0xB3: ["FMod_Disable", 0],              # entity+0x68 &= ~voice_mask
	0xB4: ["Noise_EnableAndClock", 1],      # entity+0x6C |= voice; SPUCNT[8-13] = op&0x3F
	0xB5: ["Noise_ClockAdd", 1],            # slot+0x1E += op (mod 64); re-asserts noise
	0xB6: ["Noise_EnableNoArm", 0],         # entity+0x6C |= voice; chan+0x4 |= 0x10 (no clock write)
	0xB7: ["Noise_Disable", 0],             # entity+0x6C &= ~voice_mask
	0xBA: ["ReverbOn", 0], 0xBB: ["ReverbOff", 0],
	# 0xC0-0xCF: ADSR
	0xC0: ["ADSR_Reset", 0], 0xC2: ["ADSR_Attack", 1],
	0xC3: ["ADSR_DecayRate", 1],            # FFT LAB_800161c4 — chan+0x66 = byte, arm ADSR1_MID
	0xC4: ["ADSR_SustainRate", 1], 0xC5: ["ADSR_Release", 1],
	0xC6: ["ADSR1_LowNibble_SlideTarget", 1],
	0xC7: ["ADSR_DecayAndSustainLevel", 2],
	0xC8: ["ADSR_AttackMode", 1],           # FFT LAB_80016260 — chan+0x58 = byte, arm ADSR1_HIGH (lin/exp)
	0xC9: ["ADSR_Decay", 1], 0xCA: ["ADSR_SustainLevel", 1],
	# 0xD0-0xDF: pitch bend, portamento, LFO sub-slot 0
	0xD0: ["SetPitchBend", 1],
	0xD1: ["AddPitchBend", 1],              # chan+0x86 += sb*32 (accumulating)
	0xD2: ["PitchBendRel", 1],              # §I.2 fix: was ConditionalSeqFlag (misnamed label)
	0xD3: ["PitchBend_Add_16bit", 2],       # chan+0x86 += signed 16-bit (high<<8 | low)
	0xD4: ["Portamento_Init", 2],           # param[0]=target, param[1]=rate
	0xD5: ["Chan6_Bit2_Toggle", 0],         # xori chan+0x6, 0x2
	0xD6: ["Detune", 1],
	0xD7: ["PitchLFO_Depth", 1], 0xD8: ["PitchLFO_Init", 3],
	0xD9: ["PitchLFO_Init_Signed", 3],      # sibling of 0xD8 with sign-preserving rate
	0xDA: ["FlagSet_0xFE", 0], 0xDB: ["FlagClear_0xFE", 0],
	0xDC: ["Portamento_Stop", 0],           # clear chan+0x6 bit 0x1
	# 0xE0-0xEF: dynamics, expression, LFO sub-slot 1
	0xE0: ["Dynamics", 1],
	0xE1: ["Dynamics_Add", 1],              # chan+0x98 += (sb<<24); chan_word_1 |= 0x100
	0xE2: ["Expression_VolBurst", 2],       # arms per-tick vol burst (chan+0xA8)
	0xE3: ["VolumeLFO_Depth", 1],
	0xE4: ["VolumeLFO_Init", 3],
	0xE5: ["VolLFO_Init_SubSlot1", 3],      # arms sub-slot 1 mode 1 (vol-L)
	0xE6: ["LFO_SubSlot1_Activate", 0],     # set chan+0x11E bit 0x1 (was FlagSet_0x11E)
	0xE7: ["LFO_SubSlot1_Disable", 0],      # clear chan+0x11E bit 0x1
	0xE8: ["Pan", 1],
	0xEB: ["PanLFO_Depth", 1],              # chan+0x138/0x13A = 256/(param+1) (sub-slot 2 depth)
	0xEC: ["PanLFO_Arm_SubSlot2", 3],       # sub-slot 2 mode 2, hardcoded callback idx 3
	0xED: ["PanLFO_Init_SubSlot2", 3],      # sub-slot 2 mode 2, callback selected from params
	0xEF: ["LFO_SubSlot2_Disable", 0],      # clear chan+0x13E bit 0x1
	# 0xF0-0xFF: dynamic LFO sub-slot machinery
	0xF0: ["LFO_SubSlot_Select_Init", 3],   # selects sub-slot + arms waveform/mode
	0xF1: ["LFO_SubSlot_Update", 3],        # updates depth + 16b signed rate of selected
	0xF2: ["LFO_SubSlot_DynamicDepth", 2],  # sub[+0x1A]=256/(p1+1); sub[+0x16]=p0
	0xF6: ["LFO_SubSlot_Activate", 1],      # activates sub-slot specified by param[0]
	0xF7: ["LFO_SubSlot_DynamicDisable", 1],# chan[+idx*32]+0xFE &= ~0x1 (dynamic E7/EF)
	0xFE: ["BankSelect", 1],
}

# Every opcode 0x80-0xFF that OPCODE_INFO does not name. Together the two
# dicts cover the whole opcode space, so `param_count_of` is TOTAL — there is
# no unknown byte, and therefore no fall-through for a parser to get wrong.
# That is the point: a missing entry used to consume zero params and desync
# the byte stream silently. See #616.
#
# These are unimplemented at the dispatcher level — they fall through to
# `_op_unhandled` (no-op) — but they consume the correct number of param
# bytes so the stream stays aligned.
#
# Arg counts are read from FFT's own size table, `smd_opcode_arg_size_table`
# at ROM 0x80028D0C (128 bytes, one per opcode; arity = max(0, value - 1)).
# Verified byte-for-byte against SCUS_942.21 on 2026-08-26; OPCODE_INFO agrees
# with the ROM on all 72 of its entries. Seven values here previously did NOT
# (0xA3 0xB9 0xF4 0xF8 0xF9 0xFB 0xFC, all claiming params the ROM gives none)
# despite this comment already citing that table -- corrected in #616.
#
# The size table answers the parser's question: how many bytes to consume.
# Whether a handler exists for a byte is the jumptable's business
# (0x80028B0C) and is tracked separately in #330.
const _EXTRA_OPCODES := {
	0x83: 0, 0x84: 0, 0x85: 0, 0x86: 0, 0x87: 0, 0x88: 0, 0x89: 0, 0x8A: 0,
	0x8B: 0, 0x8C: 0, 0x8D: 1, 0x8E: 3, 0x8F: 0, 0x92: 0, 0x93: 0, 0x9C: 3,
	0x9D: 3, 0x9E: 3, 0x9F: 0, 0xA1: 1, 0xA3: 0, 0xA4: 1, 0xA5: 1, 0xA6: 1,
	0xA7: 2, 0xA8: 0, 0xAA: 1, 0xAB: 0, 0xB8: 3, 0xB9: 0, 0xBC: 0, 0xBD: 0,
	0xBE: 0, 0xBF: 0, 0xC1: 3, 0xCB: 0, 0xCC: 0, 0xCD: 0, 0xCE: 0, 0xCF: 0,
	0xDD: 0, 0xDE: 0, 0xDF: 0, 0xE9: 1, 0xEA: 2, 0xEE: 0, 0xF3: 0, 0xF4: 0,
	0xF5: 1, 0xF8: 0, 0xF9: 0, 0xFA: 0, 0xFB: 0, 0xFC: 0, 0xFD: 1, 0xFF: 0,
}


class NoteEvent:
	var velocity: int
	var relative_key: int  # 0-11 = C..B, 12 = tie, 13 = rest
	var delta_time: int
	var note_byte: int     # raw bytecode 2nd byte; FFT chan+0x92 source (PC 0x800153C4)
	var offset: int = -1   # start byte within the decoded slice (editor patch anchor)
	var size: int = 0      # bytes consumed: 2, or 3 in explicit-duration form

	func is_note() -> bool:
		return relative_key < 12

	func is_tie() -> bool:
		return relative_key == 12

	func is_rest() -> bool:
		return relative_key == 13


class OpcodeEvent:
	var opcode: int
	var params: PackedInt32Array
	var offset: int = -1   # start byte within the decoded slice (editor patch anchor)
	var size: int = 0      # 1 + param bytes actually consumed


## Whether this project has identified and named `opcode` — i.e. whether we know
## what it DOES, not merely how long it is. Authoring surfaces want this one: an
## opcode can have a perfectly good param count and still be a byte we do not
## understand well enough to offer someone.
##
## This used to be asked as `param_count_of(op) >= 0`, which conflated the two
## questions and silently offered every byte the size table happened to name. #616.
static func is_named_opcode(opcode: int) -> bool:
	return OPCODE_INFO.has(opcode)


## How many parameter bytes an opcode consumes. TOTAL over the opcode domain
## 0x80-0xFF: OPCODE_INFO and _EXTRA_OPCODES together cover all 128, so there is
## no unknown byte and no fall-through. The single source both the decoder above
## and the structural-authoring encoder read, so a byte stream written from this
## count always decodes back to the same event.
##
## Bytes below 0x80 are notes, not opcodes, and are a caller error here.
static func param_count_of(opcode: int) -> int:
	if opcode in OPCODE_INFO:
		return OPCODE_INFO[opcode][1]
	if opcode in _EXTRA_OPCODES:
		return _EXTRA_OPCODES[opcode]
	push_error("param_count_of: 0x%02X is not an opcode (opcodes are 0x80-0xFF)" % opcode)
	return 0


static func decode_track(data: PackedByteArray, length: int = -1) -> Array:
	## Returns Array of NoteEvent and OpcodeEvent.
	if length < 0:
		length = data.size()

	var events: Array = []
	var pos := 0

	while pos < length:
		var start := pos
		var byte := data[pos]
		pos += 1

		if byte < 0x80:
			# Note event
			if pos >= length:
				break
			var data_byte := data[pos]
			pos += 1

			var evt := NoteEvent.new()
			evt.velocity = byte
			evt.note_byte = data_byte
			evt.relative_key = data_byte / 19
			var delta_index := data_byte % 19
			evt.delta_time = DELTA_TIME_TABLE[delta_index]

			if evt.delta_time == 0 and pos < length:
				evt.delta_time = data[pos]
				pos += 1

			evt.offset = start
			evt.size = pos - start
			events.append(evt)
		else:
			# Control opcode
			var param_count := param_count_of(byte)

			var evt := OpcodeEvent.new()
			evt.opcode = byte
			evt.params = PackedInt32Array()
			for _i in range(param_count):
				if pos >= length:
					break
				evt.params.append(data[pos])
				pos += 1

			evt.offset = start
			evt.size = pos - start
			events.append(evt)

			if byte == 0x90:  # EndBar
				break

	return events


static func fft_tempo_to_bpm(tempo_val: int) -> float:
	if tempo_val == 0:
		return 120.0
	return (tempo_val * 256.0) / 218.0
