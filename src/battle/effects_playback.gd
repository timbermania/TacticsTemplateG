class_name EffectsPlayback
extends Node3D
## Owns `addons/exmateria_effects`' playback for one battle: the compositor
## producer, the per-battle `CastHost`, and the `EffectManager` over it.
##
## 🔴 COEXISTS WITH TacticsG's OWN VFX — it does not replace it. `enabled` is
## false by default, so installing this node changes nothing until a caller opts
## in. TacticsG's `trap_instance` / `projectile_instance` path stays the live one
## and is untouched; this is the second path, off, ready to be compared against
## the first. Nothing here deletes or bypasses `src/file_formats/vfx/`.
##
## 🔴 setup_native IS CHECKED, and that is not a style preference. On stock Godot
## the fold bracket does not exist, so `setup()` must never be called and
## `setup_native()` can legitimately REFUSE. An unchecked call is the documented
## way this integration renders nothing while looking installed, so a refusal
## disables playback loudly instead of leaving a producer that draws nothing.

## Opt-in. While false this node builds nothing and holds no producer, so the
## addon cannot affect a frame.
@export var enabled: bool = false

## The battle this plays for. Must be IN THE SCENE — the addon's contract says
## the stage is a scene node, never the persistent root viewport, because casts
## share the stage's World3D.
@export var battle_manager: Node

var _producer: ExMateriaEffects.EngineFoldCompositor
var _host: EffectsCastHost
var _manager: ExMateriaEffects.EffectManager

## Why playback is unavailable, or "" when it is. Read this instead of guessing:
## every refusal below is a quiet-by-design failure mode.
var unavailable_reason: String = ""


func is_available() -> bool:
	return _manager != null


func manager() -> ExMateriaEffects.EffectManager:
	return _manager


## Build the producer/host/manager for `camera`. Returns false — with
## `unavailable_reason` set — rather than half-building.
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
	# Content is ROM-derived and cannot ship in the addon. An unset root makes
	# every cast resolve to "" and fail like a missing file, so refuse up front
	# rather than spawn effects that can never load.
	if not ExMateriaEffects.EffectsContent.has_root():
		unavailable_reason = (
			"no content root: set `%s` to a directory holding effects/, effects/trap/ "
			+ "and sprites/textures/TRAP1*.tga"
		) % ExMateriaEffects.EffectsContent.ROOT_SETTING
		return false

	var producer := ExMateriaEffects.EngineFoldCompositor.new()
	add_child(producer)
	# CHECKED. Never the default fold `setup()` — TacticsG runs stock GL, where
	# the fold bracket does not exist.
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
