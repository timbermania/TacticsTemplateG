extends "res://addons/exmateria_sound/runtime/feds_bank.gd"
## Global banks can have absent channels. The installed play_pair(single_track)
## decodes BOTH tracks before muting one: stop zero offsets at the byte boundary,
## not just the playback boundary. Raw bank bytes and gain lookup stay unchanged.

func get_track_bytes(track_idx: int) -> PackedByteArray:
	if track_idx < 0 or track_idx >= num_tracks or track_offsets[track_idx] == 0:
		return PackedByteArray()
	return super.get_track_bytes(track_idx)

func get_track_bytes_from(track_idx: int) -> PackedByteArray:
	if track_idx < 0 or track_idx >= num_tracks or track_offsets[track_idx] == 0:
		return PackedByteArray()
	return super.get_track_bytes_from(track_idx)
