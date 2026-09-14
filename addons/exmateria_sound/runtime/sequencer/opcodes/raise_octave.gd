## FFT analog: smd_raise_octave @ 0x80015A10
##                (opcode 0x95)
##
## Address corrected in #330: this line read `LAB_800158fc`, which is the entry
## point of nothing — it is an interior address. Verified against FFT's own
## smd_opcode_jumptable @ 0x80028B0C (SCUS_942.21).


static func apply(_sequencer, ts, _params) -> void:
	# Pass 7.D.d — FFT chan+0x7E += 0xC. Track channel.octave (int) AND
	# bmidi_baseline_byte (byte form consumed by SharedComputePitch).
	ts.ctx.channel.octave += 1
	ts.ctx.channel.bmidi_baseline_byte = (ts.ctx.channel.bmidi_baseline_byte + 12) & 0xFF
