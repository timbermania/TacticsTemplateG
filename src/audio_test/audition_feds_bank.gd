extends RefCounted
## A validated FEDS bank's HEADER, as `audition_inputs.feds()` decodes it.
##
## 🔴 THIS USED TO SUBCLASS `addons/exmateria_sound/runtime/feds_bank.gd`, AND THAT
## MADE THE `GameData` AUTOLOAD PARSE-DEPEND ON THE SOUND ADDON. The chain ran
## `game_data.gd:14` -> `extracted_audio_catalog.gd` -> `disc_audio_catalog.gd:8` ->
## `audition_inputs.gd:4` -> here -> the addon, every hop a `const preload`, which
## Godot resolves at PARSE time. So removing the sound addon did not degrade the
## catalog, it took the whole game down at boot — the loudest possible version of the
## failure, but only visible by walking the chain.
##
## Nothing that survives the removal ever decoded a track. `audition_inputs.feds()`
## fills these fields straight from a blob it has already bounds-checked, and the two
## readers left — `sound_id_error()` and `disc_audio_catalog` — read only `raw` and
## `data_offset`. The opcode/trackset decoding the old base class carried (240 of its
## 246 lines, plus `sound_opcodes.gd` and `trackset.gd`) had exactly one caller in the
## whole checkout, `tools/audio/disc_audio_regression.gd`, which went with the addons.
## So this is the whole of what the host still needs, and it is written here rather
## than inherited from a package that is gone.
##
## The field names and the two derived counts are kept as they were: they are what the
## FEDS container itself declares, and `audition_inputs.feds()` assigns them by name.

var magic: String = ""
var data_size: int = 0            ## From the header; may exclude the magic+header itself.
var pair_count_plus1: int = 0     ## num_pairs = pair_count_plus1 - 1.
var resource_id: int = 0          ## The bank's SPU VRAM id in the original engine.
var data_offset: int = 0          ## Offset inside the blob where the opcode streams begin.
var track_offsets: PackedInt32Array = PackedInt32Array()  ## Per-track u16 offsets.
var raw: PackedByteArray = PackedByteArray()


var num_pairs: int:
	get:
		return maxi(0, pair_count_plus1 - 1)

var num_tracks: int:
	get:
		return num_pairs * 2
