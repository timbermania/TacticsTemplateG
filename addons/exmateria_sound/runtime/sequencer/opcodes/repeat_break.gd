## FFT analog: smd_op_9a_repeat_break @ 0x80015B6C
##                (opcode 0x9A)
##
## Address corrected in #330: this line read `LAB_800159f8`, which is the entry
## point of nothing — it is an interior address. Verified against FFT's own
## smd_opcode_jumptable @ 0x80028B0C (SCUS_942.21).
##
## MECHANISM, and how it differs from FFT (#988). FFT does not scan. Its loop
## entry is 12 bytes at `chan + 0xB0 + depth*12`, and `smd_repeat` @ 0x80015AB8
## writes only the body pointer (`entry+0x4`) and the count (`entry+0x0`); the
## RepeatBreak target `entry+0x8` is written by `smd_coda` @ 0x80015B38, as the
## stream pointer just past the Coda, on each iteration that loops. So FFT
## REMEMBERS where the Coda was rather than looking for it: this handler reaches
## the same answer for well-formed bytecode and a different one where FFT would
## read an `entry+0x8` no Coda had written yet (a `Repeat(1)` whose body holds a
## RepeatBreak). Not worth modelling: 0x9A occurs zero times in the 100 retail
## songs, so neither path is reachable from shipped data.

const _SoundOpcodes = preload("res://addons/exmateria_sound/runtime/sound_opcodes.gd")


static func apply(sequencer, ts, _params) -> void:
	if ts.loop_stack.size() > 0:
		var entry: Array = ts.loop_stack[-1]
		if entry[1] == 0:  # Last iteration
			var depth := 1
			# #988: scan from ts.event_idx, NOT ts.event_idx + 1. advance_track
			# increments event_idx BEFORE dispatching an opcode, so on entry here
			# it already points at the event AFTER this RepeatBreak — starting one
			# further on skips that event, and if it is the matching Coda the scan
			# runs off the end and the track terminates early. `TrackExpansion`
			# scans from the same place; they disagreed until this line changed.
			# No retail song can reach it: 0x9A occurs ZERO times in all 100 songs,
			# which is exactly why a corpus differential could never have found it.
			var search: int = ts.event_idx
			while search < ts.events.size() and depth > 0:
				var e = ts.events[search]
				if e is _SoundOpcodes.OpcodeEvent:
					if e.opcode == 0x98:
						depth += 1
					elif e.opcode == 0x99:
						depth -= 1
				search += 1
			ts.event_idx = search
			ts.loop_stack.pop_back()
			return
