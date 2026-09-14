extends RefCounted
## Runtime structure the [Sequencer] plays: a conductor track + N normal tracks.
## See CONTEXT.md "Audio" → Trackset.
##
## Built from either an [SMDFile] (`.SMD` music) via [method SMDParser.SMDFile.to_trackset],
## or a FEDS pair (effect-cast sound) via [method FedsBank.pair_to_trackset]. A
## Trackset is **not** an SMDFile — it's a runtime structure with no on-disk
## form. The shape (conductor at index 0, normal tracks 1+) matches what the
## sequencer expects regardless of source.
##
## Track 0 is the **conductor track**: tempo, time-signature, global events. For
## SMD songs this carries authored tempo data; for FEDS-pair-derived tracksets
## it's a structural placeholder (empty event list).

const _SoundOpcodes = preload("res://addons/exmateria_sound/runtime/sound_opcodes.gd")


# Per-track event arrays. tracks[0] is the conductor; tracks[1..N] are
# normal tracks. Each entry is Array of SoundOpcodes.NoteEvent|OpcodeEvent.
var tracks: Array = []

# FFT tempo units (header value). 0 → sequencer uses its default fallback.
var initial_tempo: int = 0

# Initial volume (0..0x7F).
var initial_volume: int = 0x7F

# WAVESET bank id this trackset references for sample data.
var assoc_wds_id: int = 0

# Human-readable label (song title for SMD, "feds_pair_N" for FEDS).
var name: String = ""


var initial_bpm: float:
	get:
		return _SoundOpcodes.fft_tempo_to_bpm(initial_tempo)


var track_count: int:
	get:
		return tracks.size()
