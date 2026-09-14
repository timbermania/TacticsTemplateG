## FFT analog: smd_op_c4_adsr2_sustain @ 0x800161E0
##                (opcode 0xC4)
##
## Address corrected in #330: this line read `LAB_800161C4`, which is the jumptable
## entry for the PRECEDING opcode 0xC3 (smd_op_c3_adsr_decay_rate) — an
## off-by-one, and the same one fft-ghidra already corrected on its
## side. Verified against FFT's own
## smd_opcode_jumptable @ 0x80028B0C (SCUS_942.21).
##
## Pass D2 — mirrors effect_sound/opcodes/adsr2_sustain.gd. Mode bit 0x100
## (sustain_decrease=1, FFT default a3) OR'd into the byte before
## shifting into the high halfword (bits 6-15 of adsr2).

const _SS = preload("res://addons/exmateria_sound/runtime/shared/slot_state.gd")


static func apply(_sequencer, ts, params) -> void:
	if ts.ctx == null:
		return
	var byte: int = ((params[0] if params.size() > 0 else 0) & 0xFF) & 0x7F
	var mode_bits: int = 0x100  # default a3 = sustain_decrease
	var new_sustain_high: int = ((byte | mode_bits) << 6) & 0xFFC0
	ts.ctx.channel.adsr2 = (ts.ctx.channel.adsr2 & 0x3F) | new_sustain_high
	ts.ctx.slot.adsr2 = ts.ctx.channel.adsr2
	ts.ctx.slot.walker_flag_word |= _SS.WALKER_FLAG_ADSR2_HIGH
