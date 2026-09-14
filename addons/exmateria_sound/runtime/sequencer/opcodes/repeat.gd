## FFT analog: smd_repeat @ 0x80015AB8
##                (opcode 0x98)
##
## Address corrected in #330: this line read `LAB_80015960`, which is the entry
## point of nothing — it is an interior address. Verified against FFT's own
## smd_opcode_jumptable @ 0x80028B0C (SCUS_942.21).
##
## Vault: [[SMD Opcodes]]


static func apply(sequencer, ts, params) -> void:
	var count: int = (params[0] - 1) if params.size() > 0 else 0
	var _octave: int = ts.ctx.channel.octave
	# FFT smd_repeat PC 0x80015AF4/AFC: `lbu a0, 0x7e(a2); sb a0, 0x2(v1)`
	# saves chan+0x7e (bmidi_baseline_byte) so smd_coda can restore it
	# per iteration. Without this, RaiseOctave/LowerOctave inside the
	# loop body permanently drift bmidi_baseline_byte → notes one octave off.
	var _bmidi: int = ts.ctx.channel.bmidi_baseline_byte
	ts.loop_stack.append([ts.event_idx, count, _octave, _bmidi])
