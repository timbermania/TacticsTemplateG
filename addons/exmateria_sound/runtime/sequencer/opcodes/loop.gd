## FFT analog: smd_loop @ 0x800159DC
##                (opcode 0x91)
##
## Address corrected in #330: this line read `LAB_800158c4`, which is the entry
## point of nothing — it is an interior address. Verified against FFT's own
## smd_opcode_jumptable @ 0x80028B0C (SCUS_942.21).


static func apply(sequencer, ts, _params) -> void:
	ts.loop_point = ts.event_idx
