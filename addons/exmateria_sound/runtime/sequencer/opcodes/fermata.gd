## FFT analog: smd_fermata @ 0x8001589C
##                (opcode 0x81)
##
## Address corrected in #330: this line read `LAB_8001588c`, which is the entry
## point of nothing — it is an interior address. Verified against FFT's own
## smd_opcode_jumptable @ 0x80028B0C (SCUS_942.21).
##
## UNREACHABLE TODAY, AND IT WAS WRONG (#988). `advance_track.gd` handles 0x81
## inline in both of its phases — the post-note scan and the pre-note branch —
## so 0x81 never reaches `_process_opcode` and never reaches this file. It sat in
## `opcodes/_table.gd` looking live while doing `idle_timeout += byte`, which is
## chan+0x78, not the chan+0x74 wait counter FFT writes.
## `MUSIC_ITER17_INLINE_REST_BYPASS_FIX.md` recorded that as "out of scope" and it
## stayed out of scope. It is corrected here rather than deleted, so that the two
## implementations of Fermata in this package AGREE — a dead copy that disagrees
## is exactly the latent divergence `exmateria-daw-plugin` ADR-0015 names, and no
## behavioural differential test can see one. `SequencerWalkDifferentialTest`
## calls this handler directly for that reason.
##
## FFT smd_fermata body (PC 0x8001589C-0x800158B4):
##   lhu   v0, 0x0(a2)     ; chan_word_0
##   lbu   v1, 0x0(a0)     ; the operand byte
##   ori   v0, v0, 0x100   ; chan_word_0 |= CHAN0_PITCH_REQ — run the note ON
##   sh    v0, 0x0(a2)
##   addiu v0, a0, 0x1
##   jr    ra
##   _sh   v1, 0x74(a2)    ; chan+0x74 = the byte — the wait, in the delay slot
##
## The same counter `smd_rest` @ 0x80015874 writes with its own byte; the two
## differ only in Rest arming KOFF while Fermata lets the note ring. See
## `exmateria-etude` ADR-0004.

const _SS = preload("res://addons/exmateria_sound/runtime/shared/slot_state.gd")


static func apply(_sequencer, ts, params) -> void:
	ts.ctx.channel.channel_word_0 |= _SS.CHAN0_PITCH_REQ
	ts.ctx.channel.note_duration = params[0] if params.size() > 0 else 0
