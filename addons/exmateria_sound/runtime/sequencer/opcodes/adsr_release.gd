## FFT analog: smd_op_c5_adsr_release @ 0x800161FC
##                (opcode 0xC5)
##
## Address corrected in #330: this line read `0x800161E0`, which is the jumptable
## entry for the PRECEDING opcode 0xC4 (smd_op_c4_adsr2_sustain) — an
## off-by-one, and the same one fft-ghidra already corrected on its
## side. Verified against FFT's own
## smd_opcode_jumptable @ 0x80028B0C (SCUS_942.21).
##
## Pass D2 — mirrors effect_sound/opcodes/adsr_release.gd. Release rate goes
## into adsr2 bits 0-4 (slot+0x6A on FFT). Default mode bits = 0.
## Walker's _fan_adsr2_low ORs slot.adsr2_mode_byte == 7 → 0x20.

const _SS = preload("res://addons/exmateria_sound/runtime/shared/slot_state.gd")


static func apply(_sequencer, ts, params) -> void:
	if ts.ctx == null:
		return
	var byte: int = (params[0] if params.size() > 0 else 0) & 0xFF
	var release_low: int = byte & 0x3F
	ts.ctx.channel.adsr2 = (ts.ctx.channel.adsr2 & 0xFFC0) | release_low
	ts.ctx.slot.adsr2 = ts.ctx.channel.adsr2
	# Iter-32: FFT 0xC5 also stores the raw operand to slot+0x6A
	# (`sh v1, 0x6a(a2)` at PC 0x80016218). Walker's LOW writer reads
	# slot+0x6A as the rate input independent of slot.adsr2's low bits.
	# See docs/MUSIC_ITER32_ADSR2_LOW_RELEASE_BYTE_FIELD_SOURCE.md.
	ts.ctx.channel.release_rate_byte = byte
	ts.ctx.slot.release_rate_byte = byte
	ts.ctx.slot.walker_flag_word |= _SS.WALKER_FLAG_ADSR2_LOW
