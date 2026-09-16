class_name EffectCameraTrack
extends Node
## Drives TacticsG's `CameraController` from an `addons/exmateria_effects` cast's
## `CameraSubsystem`, and gives the camera back when the cast ends.
##
## 🔴 THE TRACK WAS ALREADY RUNNING. `EffectInstance` builds a `CameraSubsystem`
## whenever `effect_data.camera.has_active_keyframes()` and the timeline advances it
## with every other subsystem — measured, 388 of the 401 `E###` effects pass that gate,
## and it is NOT gated on `is_cinematic`, so ordinary spell casts carry camera tracks
## too. Nothing read its output. This is the third instance of that exact pattern in
## this integration (the background gradient was the first, the map tint the second),
## and all three failed the same silent way: computed every frame, discarded, no error.
##
## The subsystem is a PURE STATE MACHINE — it never touches a `Camera3D`. It publishes
## `current_position` / `current_angles` / `current_zoom` in PSX units and expects a
## host to convert and consume them. Three conversions, all of them already installed
## on the `ExMateriaPlatform` façade, and all of them the SAME ones `EffectInstance`
## uses in reverse to feed the subsystem — which is what closes the chirality loop:
##
##   position  `PsxChirality.psx_position_to_godot`      (28 units/tile, Y negate)
##   angles    `PsxChirality.psx_angles_to_godot_rotation` (4096 = 360, pitch negated)
##   zoom      `CameraCalibration.zoom_to_ortho_size`    (12.6 ortho size at 4096)
##
## 🔴 THE SEED IS THE HOST'S LIVE POSE, and that is what makes the track land in
## TacticsG's world rather than the ROM's. Measured over the corpus, the dominant
## angle/position sources are RELATIVE — `MAP` (891 keyframes), `TARGET` (584),
## `SLOT_COPY` (395), `CASTER` (162), `OFFSET` (182) all resolve against
## `current_*` / `saved_*` / a live anchor, never against an absolute ROM coordinate.
## Seeding `saved_*` and `current_*` from the rig through the exact inverse of the
## conversions above therefore makes those keyframes chirality-neutral by construction:
## they move the camera relative to where the player already had it.
##
## ⚠️ ROLL IS DROPPED. `psx_angles_to_godot_rotation` returns `z = 0` and this rig has
## no roll concept. The corpus says that costs one effect: of 388 with active
## keyframes, exactly two carry a non-zero roll component, and E242's single one is
## `4096` — a full turn, i.e. the identity. Only E452 genuinely rolls. It is dropped
## LOUDLY (`_warn_roll_once`) rather than silently, because a silent drop here is
## indistinguishable from the bug this whole file exists to fix.


## The PSX↔Godot seams, aliased back to bare spellings (ADR-0211 dec. 4).
const PsxChirality = ExMateriaPlatform.PsxChirality
const PsxMagnitude = ExMateriaPlatform.PsxMagnitude
const CameraCalibration = ExMateriaPlatform.CameraCalibration

## A roll this far from a whole number of turns is a real roll, not float noise on an
## authored 4096. In PSX angle units; 4096 is a full turn, so this is ~0.09 degrees.
const ROLL_EPSILON: float = 1.0

## 🔴 RUNS AFTER THE CASTS. `EffectInstance._process` is what advances the subsystem,
## and both it and this node are children of the same stage — so at the default
## priority, whichever was added first wins and this node would publish LAST FRAME's
## pose. A frame of camera lag is invisible in a log and looks exactly like a working
## integration; the priority is what makes `ARM E` able to assert the rig equals the
## subsystem this frame rather than approximately tracking it.
const PUMP_PRIORITY: int = 100

## The rig being driven. Nothing happens without one.
var rig: CameraController = null

## The `EffectInstance` currently holding the camera, or null.
var _cast: Node = null
## Its `CameraSubsystem`, cached so the release path can still name it after the
## instance's `_exit_tree` has nulled its own reference.
var _subsystem = null
var _warned_roll: bool = false

## Observability — read by `tools/effects/ability_vfx_regression.gd` ARM E, and by
## anything else that has to tell "the camera moved" from "the addon moved it".
## Counts rather than booleans: a volley that hands the camera to its first cast and
## refuses the rest should be able to say so.
var takeovers: int = 0
var refusals: int = 0
var frames_applied: int = 0
## The last pose pushed, both sides of the conversion, so a caller can print the
## subsystem values beside the host values instead of inferring one from the other.
var last_psx_position: Vector3 = Vector3.ZERO
var last_psx_angles: Vector3 = Vector3.ZERO
var last_psx_zoom: float = 0.0
var last_focus: Vector3 = Vector3.ZERO
var last_orbit_degrees: Vector3 = Vector3.ZERO
var last_ortho_size: float = 0.0


func _init(camera_rig: CameraController = null) -> void:
	rig = camera_rig
	name = "EffectCameraTrack"
	process_priority = PUMP_PRIORITY


## Is an effect driving the camera right now?
func is_driving() -> bool:
	return _subsystem != null


## Offer a freshly spawned cast the camera.
##
## 🔴 THIS IS THE `camera_started` SIGNAL WITHOUT THE SIGNAL, and it has to be, because
## `camera_started` is emitted INSIDE `EffectInstance.initialize()` — before
## `spawn_spell_effect` has returned — and `spawn_spell_effect` takes no camera
## callbacks (only `spawn_cinematic_effect` does). Connecting after the spawn misses it
## entirely. But `EffectInstance.camera_controller` is non-null for exactly the effects
## that emitted it, and `EffectsPlayback.play_action_vfx` already identifies the spawned
## instance by diffing the stage's children — so the same information is available one
## line later, with no new routing and no second spawn path. (Route charge-time
## abilities through `spawn_cinematic_effect` later if their lifecycle needs it; that is
## a different question from getting the track visible.)
##
## `camera_finished` IS connected, because that one fires from `_exit_tree`, long after
## the spawn returns.
func adopt(cast: Node) -> bool:
	if not is_instance_valid(rig) or not is_instance_valid(cast):
		return false
	if not ("camera_controller" in cast) or cast.camera_controller == null:
		return false
	if is_driving():
		refusals += 1
		return false
	if not rig.begin_effect_takeover():
		refusals += 1
		return false
	_cast = cast
	_subsystem = cast.camera_controller
	takeovers += 1
	frames_applied = 0
	_seed_from_rig()
	if cast.has_signal(&"camera_finished") \
			and not cast.camera_finished.is_connected(_on_camera_finished):
		cast.camera_finished.connect(_on_camera_finished, CONNECT_ONE_SHOT)
	# 🔴 PUSH THE SEED BEFORE RETURNING. Without this the rig spends one frame DRIVEN
	# but never written: `CameraController._process` has already stood down, and the
	# first `apply_pose` does not land until the next `_process`. The pose does not
	# visibly change (the seed IS the rig's own pose), which is exactly why it went
	# unnoticed at a coarse sample rate — but it leaves `last_*` empty while
	# `is_driving()` reports true, so anything reading the pair sees them disagree.
	# The invariant is worth having whole: while the track is driving, the rig always
	# carries a pose the track converted.
	pump()
	return true


## Push one frame. Safe to call unconditionally; does nothing unless a cast is driving.
func pump() -> void:
	if not is_driving():
		return
	# The instance frees itself when the spell ends, and a freed stage takes the rig
	# with it. Either way the camera has to come back rather than freeze mid-track.
	if not is_instance_valid(_cast) or not is_instance_valid(rig) \
			or not _subsystem.is_active():
		release()
		return
	apply_pose(_subsystem.current_position, _subsystem.current_angles,
		_subsystem.current_zoom)
	frames_applied += 1


## Convert one PSX pose and write it to the rig. The single conversion seam: the live
## pump calls it, and so does the chirality check in the regression, which is the only
## way that check can be about the CONVERSION rather than about an effect.
func apply_pose(psx_position: Vector3, psx_angles: Vector3, psx_zoom: float) -> void:
	if not is_instance_valid(rig) or not rig.is_effect_driven():
		return
	_warn_roll_once(psx_angles.z)
	var focus: Vector3 = PsxChirality.psx_position_to_godot(psx_position)
	var rot: Vector3 = PsxChirality.psx_angles_to_godot_rotation(
		psx_angles.x, psx_angles.y, psx_angles.z)
	var orbit := Vector3(rad_to_deg(rot.x), rad_to_deg(rot.y), rad_to_deg(rot.z))
	# Clamped to the rig's own published limits. An ADDITIVE zoom channel accumulates
	# without a bound of its own, and the corpus carries raw zoom keyframes from -2976
	# to 8192 — a non-positive zoom already guards to 1.0x inside `zoom_to_ortho_size`,
	# but nothing upstream stops a run-away from arriving at a degenerate ortho size.
	var size: float = clampf(CameraCalibration.zoom_to_ortho_size(psx_zoom),
		rig.zoom_in_max, rig.zoom_out_max)
	last_psx_position = psx_position
	last_psx_angles = psx_angles
	last_psx_zoom = psx_zoom
	last_focus = focus
	last_orbit_degrees = orbit
	last_ortho_size = size
	rig.apply_effect_pose(focus, orbit, size)


## Hand the camera back. Idempotent.
func release() -> void:
	if _cast != null and is_instance_valid(_cast) \
			and _cast.has_signal(&"camera_finished") \
			and _cast.camera_finished.is_connected(_on_camera_finished):
		_cast.camera_finished.disconnect(_on_camera_finished)
	_cast = null
	_subsystem = null
	if is_instance_valid(rig):
		rig.end_effect_takeover()


func _process(_delta: float) -> void:
	pump()


func _exit_tree() -> void:
	# A scene reset or a torn-down battle must not leave the rig in a driven state with
	# nothing left to drive it — that is a camera frozen mid-cast with no error.
	release()


func _on_camera_finished() -> void:
	release()


## Seed the subsystem's base pose from the rig's live one, through the exact inverse of
## the conversions `apply_pose` uses.
##
## `SLOT_COPY` (395 keyframes) and `ORIGIN` resolve against `saved_*`, and the first
## `TARGET`/`CASTER` keyframe of a track yaws relative to `current_angles`; without this
## seed they all resolve against the subsystem's hardcoded `(302, 3584, 0)` / origin /
## 4096 defaults and the camera teleports to a pose that has nothing to do with the
## battle. Measured on E016 (Fire): its phase-2 keyframe is `SLOT_COPY` with a zero
## offset, i.e. "put the camera back where it was" — which resolves to the player's own
## pose only because of this.
func _seed_from_rig() -> void:
	if _subsystem == null or not is_instance_valid(rig):
		return
	_subsystem.saved_position = PsxChirality.godot_position_to_psx(rig.global_position)
	# The `+ 360` is not cosmetic: `CameraSubsystem._get_facing_yaw` snaps to a 45-degree
	# spoke with `floorf(yaw / 512.0) * 512.0`, and a negative yaw floors onto the spoke
	# below rather than the nearest one. Keeping the seed positive puts the snap on the
	# wheel the ROM assumes. A whole turn is a no-op everywhere else (`_wrap_yaw_shortest`
	# is modular, and `angle_to_deg(4096) = 360`).
	_subsystem.saved_angles = Vector3(
		PsxMagnitude.deg_to_angle(-rig.rotation_degrees.x),
		PsxMagnitude.deg_to_angle(rig.rotation_degrees.y + 360.0),
		0.0)
	_subsystem.saved_zoom = CameraCalibration.ortho_size_to_zoom(rig.camera.size)
	_subsystem.current_position = _subsystem.saved_position
	_subsystem.current_angles = _subsystem.saved_angles
	_subsystem.current_zoom = _subsystem.saved_zoom


## `EFFECT_CTR` (69 keyframes) anchors on the map centre, which the subsystem cannot
## know — `spawn_spell_effect` never sets it, so it defaults to the world origin and
## those keyframes frame a corner of the map. TacticsG knows the size; `bounds` is the
## same `Rect2i` `EffectsCastHost.arena_bounds()` publishes, in tiles.
func set_map_bounds(bounds: Rect2i) -> void:
	if _subsystem == null:
		return
	# PSX map centre is `map_tiles * 14` per axis (half of the 28 units a tile spans),
	# Y = 0 — the same expression `EffectInstance` uses for its CAMERA particle anchor.
	_subsystem.map_center = Vector3(
		float(bounds.size.x) * 14.0, 0.0, float(bounds.size.y) * 14.0)


func _warn_roll_once(psx_roll: float) -> void:
	if _warned_roll:
		return
	if absf(fposmod(psx_roll + 2048.0, 4096.0) - 2048.0) <= ROLL_EPSILON:
		return
	_warned_roll = true
	push_warning(("EffectCameraTrack: effect camera roll of %.0f PSX units (%.1f deg) "
		+ "DROPPED — CameraController has no roll axis and "
		+ "PsxChirality.psx_angles_to_godot_rotation returns z=0. Measured across the "
		+ "installed corpus this affects one effect (E452); if you are seeing it "
		+ "elsewhere the corpus changed.")
		% [psx_roll, PsxMagnitude.angle_to_deg(psx_roll)])
