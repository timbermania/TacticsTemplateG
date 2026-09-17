class_name EffectsPlayback
extends Node3D
## Builds and owns the three addon objects one battle needs to draw effects.

## Opt-in. While false this node builds nothing, so the addon cannot affect a frame.
@export var enabled: bool = false

## Must be a node in the scene tree. Spawned effects are parented under it and have to
## share its 3D world, so the always-present root viewport will not do.
@export var battle_manager: Node

var _producer: ExMateriaEffects.EngineFoldCompositor
var _host: EffectsCastHost
var _manager: ExMateriaEffects.EffectManager

## Why playback is unavailable, or "" when it is. Every refusal below is quiet by design.
var unavailable_reason: String = ""


func is_available() -> bool:
	return _manager != null


func manager() -> ExMateriaEffects.EffectManager:
	return _manager


## Set everything up for `camera`. On failure returns false with `unavailable_reason`
## filled in, and leaves nothing half-built.
func begin(camera: Camera3D) -> bool:
	_end()
	if not enabled:
		unavailable_reason = "disabled: EffectsPlayback.enabled is false"
		return false
	if not is_instance_valid(battle_manager) or not battle_manager.is_inside_tree():
		unavailable_reason = "no battle: battle_manager is unset or not in the scene"
		return false
	if not is_instance_valid(camera) or not camera.is_inside_tree():
		unavailable_reason = "no camera: setup_native needs an IN-TREE Camera3D"
		return false
	# Without a root every cast resolves to "" and fails as a missing file.
	if not ExMateriaEffects.EffectsContent.has_root():
		unavailable_reason = (
			"no content root: set `%s` to a directory holding effects/, effects/trap/ "
			+ "and sprites/textures/TRAP1*.tga"
		) % ExMateriaEffects.EffectsContent.ROOT_SETTING
		return false

	var producer := ExMateriaEffects.EngineFoldCompositor.new()
	add_child(producer)
	# Not `setup()`: that path needs a rendering feature this project does not build with.
	if not producer.setup_native(camera):
		producer.queue_free()
		unavailable_reason = "setup_native refused for this camera/renderer"
		return false

	_producer = producer
	_host = EffectsCastHost.new(battle_manager)
	_manager = ExMateriaEffects.EffectManager.new(_host)
	unavailable_reason = ""
	return true


func end() -> void:
	_end()


func _end() -> void:
	_manager = null
	_host = null
	if is_instance_valid(_producer):
		_producer.queue_free()
	_producer = null


func _exit_tree() -> void:
	_end()
