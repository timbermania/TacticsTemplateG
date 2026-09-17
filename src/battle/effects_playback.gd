class_name EffectsPlayback
extends Node3D
## Builds and owns the three addon objects one battle needs to draw effects, and is the
## only route by which an ability's VFX reach the screen.

## Opt-in. While false this node builds nothing, so the addon cannot affect a frame.
@export var enabled: bool = false

## Must be a node in the scene tree. Spawned effects are parented under it and have to
## share its 3D world, so the always-present root viewport will not do.
@export var battle_manager: Node

## Where the ROM-derived content lives. Empty means none is configured, and `begin()` then
## refuses with a reason rather than letting every cast fail as a missing file.
@export var content_root: String = ""

## The rig a cast's CAMERA track drives, or null to leave the camera alone. 388 of 401
## effects carry a camera track, not gated on `is_cinematic`, so ordinary casts have one.
@export var camera_rig: CameraController

var _producer: ExMateriaEffects.EngineFoldCompositor
var _host: EffectsCastHost
var _manager: ExMateriaEffects.EffectManager
## Moves `camera_rig` for whichever cast currently has it. Created on first use.
var _camera_track: EffectCameraTrack

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
	if not content_root.is_empty():
		ProjectSettings.set_setting(
			ExMateriaEffects.EffectsContent.ROOT_SETTING, content_root)
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
	# Before the manager goes, or the rig freezes mid-track with nothing to advance it.
	if is_instance_valid(_camera_track):
		_camera_track.release()
	_manager = null
	_host = null
	if is_instance_valid(_producer):
		_producer.queue_free()
	_producer = null


func _exit_tree() -> void:
	_end()


## The `E###` number `action` should draw, or -1 for nothing. `vfx_id` and `vfx_name` both
## carry it and are cross-checked, since export vintages spell the NAME differently
## (`e_192` vs `E192`) while agreeing on the NUMBER; a disagreement is reported, not fatal.
## `vfx_id == 0` is a real effect, never a "none" sentinel — fifteen abilities use E000.
static func effect_id_for(action: Action) -> int:
	if action == null:
		return -1
	var named: int = -1
	if not action.vfx_name.is_empty():
		var digits: String = ""
		for c: String in action.vfx_name:
			if c >= "0" and c <= "9":
				digits += c
		if not digits.is_empty():
			named = digits.to_int()
	if named >= 0:
		if named != action.vfx_id:
			push_warning(
				("EffectsPlayback: action \"%s\" disagrees with itself about its effect "
				+ "— vfx_name \"%s\" says E%03d, vfx_id says E%03d. Drawing the name's, "
				+ "which is what the old vfx_data path resolved. Re-export the action "
				+ "data; a stale export here draws the WRONG effect, not nothing.")
				% [action.unique_name, action.vfx_name, named, action.vfx_id])
		return named
	# Only here does 0 mean "none": with no `vfx_name` to corroborate it, a zero is
	# indistinguishable from an unset field.
	return action.vfx_id if action.vfx_id > 0 else -1


## Ids already reported missing, so a per-action cast loop cannot bury the reason.
var _missing_content: Dictionary = {}


## Play `action`'s ability VFX from `caster` at `target`. Returns the spawned node, or
## null when nothing was cast, so a caller can await its lifetime for timing.
func play_action_vfx(caster: Node3D, target: Node3D, action: Action) -> Node3D:
	if not is_available() or not is_instance_valid(caster) or not is_instance_valid(target):
		return null
	# A `Unit` never moves — only its `char_body` child does — so the spawn would place
	# the cast at the world ORIGIN.
	if caster is Unit or target is Unit:
		push_error("EffectsPlayback: pass `unit.char_body`, not the Unit — a Unit's own "
			+ "transform is never set, so the cast would spawn at the world origin.")
		return null
	var effect_id: int = effect_id_for(action)
	if effect_id < 0:
		return null
	# `initialize()` reports a missing directory only by freeing the instance, which looks
	# exactly like an effect that drew nothing.
	var dir: String = ExMateriaEffects.EffectsContent.effect_dir("E%03d" % effect_id)
	if dir.is_empty() or not DirAccess.dir_exists_absolute(dir):
		if not _missing_content.has(effect_id):
			_missing_content[effect_id] = true
			push_warning(
				("EffectsPlayback: no content at \"%s\" for E%03d, so \"%s\" draws "
				+ "nothing. Copy the per-effect `E###` directories into the content root.")
				% [dir, effect_id, action.unique_name])
		return null
	# -1 because `Action` has no numeric ability id; nothing reads the value on this path.
	# The spawn returns void, so the new node is found by diffing the stage's children
	# across the call. The handle is needed for TIMING — a caller waits on it before
	# returning units to idle.
	var stage: Node = battle_manager
	var before: Dictionary = {}
	for child: Node in stage.get_children():
		before[child.get_instance_id()] = true
	_manager.spawn_spell_effect(caster, target, -1, effect_id)
	for child: Node in stage.get_children():
		if before.has(child.get_instance_id()) or child.is_queued_for_deletion():
			continue
		if child.has_method("get_active_particle_count"):
			_offer_camera(child)
			return child as Node3D
	# Initialization failed; the manager already freed its instance.
	return null


## Offer a freshly spawned cast the camera rig. Polled, not signalled — see
## `EffectCameraTrack.adopt`.
##
## TODO: route charge-time abilities through `spawn_cinematic_effect` if they need the
## real callbacks.
func _offer_camera(cast: Node) -> void:
	if not is_instance_valid(camera_rig):
		return
	if not is_instance_valid(_camera_track):
		_camera_track = EffectCameraTrack.new(camera_rig)
		add_child(_camera_track)
	_camera_track.rig = camera_rig
	if _camera_track.adopt(cast) and _host != null:
		# Some keyframes are placed relative to the middle of the map, which the addon
		# cannot work out on its own — only this side knows the arena's size.
		_camera_track.set_map_bounds(_host.arena_bounds())


## The live camera track, or null. Public so a test can read what the addon asked for and
## what the camera actually did, side by side.
func camera_track() -> EffectCameraTrack:
	return _camera_track


## For a call site with a target POSITION but no target node. The addon parents a tracking
## anchor to the target, so the marker below must outlive the cast.
func play_action_vfx_at(caster: Node3D, world_position: Vector3, action: Action) -> Node3D:
	if not is_available() or not is_instance_valid(caster):
		return null
	var marker := Node3D.new()
	marker.name = "AbilityVfxTarget"
	add_child(marker)
	marker.global_position = world_position
	var cast: Node3D = play_action_vfx(caster, marker, action)
	if cast == null:
		marker.queue_free()
		return null
	get_tree().create_timer(12.0).timeout.connect(
		func() -> void:
			if is_instance_valid(marker):
				marker.queue_free(),
		CONNECT_ONE_SHOT)
	return cast


## The TRAP handlers — hit clouds, knight break, the charge and orb poses. The handler is
## passed in rather than derived from an ability id: the ROM's tables name it exactly, and
## deriving it reaches neither handler 6 (the red Accumulate orbs) nor anything at all on
## a checkout with no ROM loaded.
func play_shared_vfx(handler_id: int, element_id: int, from_position: Vector3,
		target_unit: Node3D, flash: bool, is_melee: bool = true) -> bool:
	if not is_available() or handler_id <= 0 or not is_instance_valid(target_unit):
		return false
	var trap := ExMateriaEffects.TrapEffect.new()
	# Parented to the struck actor so the effect follows a unit that is still moving.
	target_unit.add_child(trap)
	if not trap.initialize(TRAP_TYPE, element_id):
		trap.queue_free()
		return false
	var impact: Vector3 = target_unit.global_position + Vector3(0, TRAP_IMPACT_RISE, 0)
	var direction: Vector3 = (impact - from_position).normalized()
	var flash_target: Node3D = target_unit if flash else null
	if handler_id == HANDLER_HIT_CLOUDS:
		# Hit clouds split melee/ranged by emitter set; the handler id is the same.
		var emitters: Array[int] = []
		emitters.assign([0, 9] if is_melee else [0, 1])
		trap.play_at(impact, direction, flash_target, emitters, flash)
	else:
		trap.play_handler(handler_id, element_id, impact, direction, flash_target)
	return true


## Which of the addon's TRAP sprite sets to use. Fixed, not a tuning knob.
const TRAP_TYPE: int = 7
## Hit clouds, the one handler that takes an emitter split rather than a plain play.
const HANDLER_HIT_CLOUDS: int = 2
## Lifts the impact off the tile floor so clouds read as hitting a body, not the ground.
const TRAP_IMPACT_RISE: float = 0.3


## Wait for the casts `play_action_vfx*` returned, or `fallback_seconds` when none. This is
## GAMEPLAY TIMING: without it every ability with an effect resolves at the no-VFX timing.
## `any()` is what makes several targets resolve together, not in sequence.
func await_casts(casts: Array[Node3D], fallback_seconds: float = 0.5,
		max_seconds: float = 12.0) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var live := casts.filter(func(c: Node3D) -> bool: return is_instance_valid(c))
	if live.is_empty():
		await tree.create_timer(fallback_seconds).timeout
		return
	var waited: float = 0.0
	while waited < max_seconds and live.any(
			func(c: Node3D) -> bool: return is_instance_valid(c)):
		await tree.process_frame
		waited += tree.root.get_process_delta_time()
