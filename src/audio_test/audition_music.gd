extends "res://addons/exmateria_sound/runtime/smd_player.gd"
## Host adapter for the captured SMDPlayer's lifecycle. No native changes.

func attach_shared_engine(shared_spu: _Spu, shared_waveset: _WavesetParser) -> void:
	# The inherited constructor creates a sequencer before attachment replaces it.
	_release_sequencer_cycle()
	super.attach_shared_engine(shared_spu, shared_waveset)

func _exit_tree() -> void:
	# ApplicationShutdown may already have freed the child AudioStreamPlayer.
	if is_instance_valid(_audio_player):
		stop_music()
	_release_sequencer_cycle()

func _release_sequencer_cycle() -> void:
	# Captured addon has Sequencer -> MusicSlotPool -> Sequencer strong ownership.
	# Only sever after scheduling stops, or before replacing the unused instance.
	if seq == null:
		return
	if seq.music_entity != null:
		seq._SharedEntityList.get_singleton().unlink(seq.music_entity)
		seq.music_entity.owning_sequencer = null
		seq.music_entity = null
	if seq._music_slot_pool != null:
		seq._music_slot_pool._sequencer = null
