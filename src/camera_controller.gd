class_name CameraController
extends Node3D

@export var camera: Camera3D

signal zoom_changed(new_zoom: float)
signal rotated(new_rotation: Vector3)
signal camera_facing_changed

@export var pan_speed_max: float = 10
@export var pan_accel: float = 10
@export var rotate_speed_max: float = 5
@export var rotate_accel: float = 5
@export var rotate_increment: float = 90.0 # degrees
@export var time_to_rotate: float = 0.5 # seconds

# https://ffhacktics.com/wiki/Camera
@export var low_angle: float = 26.54
@export var high_angle: float = 39.37

var zoom: float = 12:
	get:
		return zoom
	set(value):
		zoom = value
		zoom_changed.emit(zoom)
@export var zoom_out_max: float = 100
@export var zoom_in_max: float = 0.01

@export var follow_node: Node3D = null:
	get:
		return follow_node
	set(value):
		if value != follow_node:
			follow_node = value
			start_transitioning()
@export var time_to_transition: float = 0.35 # seconds
var is_transitioning: bool = false
@export var transition_curve: Curve
var transition_start_pos: Vector3
var transition_time: float = 0.0

var pan_direction: Vector2 = Vector2.ZERO

enum Direction {
	NORTHWEST,
	NORTHEAST,
	SOUTHWEST,
	SOUTHEAST,
	}

const CameraFacingVectors: Dictionary[Direction, Vector3] = {
	Direction.NORTHWEST: Vector3.LEFT + Vector3.FORWARD,
	Direction.NORTHEAST: Vector3.RIGHT + Vector3.FORWARD,
	Direction.SOUTHWEST: Vector3.LEFT + Vector3.BACK,
	Direction.SOUTHEAST: Vector3.RIGHT + Vector3.BACK,
	}

var is_rotating: bool = false
var camera_facing: Direction = Direction.NORTHWEST
var camera_facing_vector: Vector3:
	get: return CameraFacingVectors[camera_facing]


func _ready() -> void:
	camera.size = zoom


func _process(delta: float) -> void:
	# 🔴 STAND DOWN WHILE AN EFFECT TRACK OWNS THE RIG. Every branch below writes
	# `global_position`, so a takeover that did not stop this loop would be overwritten
	# every frame by the follow/pan it is supposed to be replacing — the camera would
	# look unmoved while the track ran perfectly. See `begin_effect_takeover`.
	if is_effect_driven():
		return
	if is_transitioning and follow_node != null:
		transition_time += delta
		var transition_percent: float = transition_time / time_to_transition
		var position_percent: float = transition_curve.sample(transition_percent)
		global_position = transition_start_pos.lerp(follow_node.global_position, position_percent)
		if transition_percent >= 1.0:
			is_transitioning = false
	elif follow_node != null:
		global_position = follow_node.global_position
	elif follow_node == null:
		var transform_basis: Basis = transform.basis
		transform_basis.y = Vector3.DOWN # camera should not move in/out of the direction it is facing
		position += (transform_basis * Vector3(pan_direction.x, pan_direction.y, 0)) * zoom * (pan_speed_max / 5.0) * delta


func start_transitioning() -> void:
	#if is_transitioning == true: # never reached it's previous target
		#pass # TODO keep momentum
	is_transitioning = true
	transition_start_pos = global_position
	transition_time = 0


func _unhandled_input(event: InputEvent) -> void:
	# The player's orbit/zoom/pan verbs all write state the takeover snapshot is
	# holding, so accepting them mid-cast would corrupt the restore rather than the
	# shot. Input during a cast is dropped, not queued.
	if is_effect_driven():
		return
	if event.is_action_pressed(&"zoom_in", false, true):  # Wheel Up Event
		zoom_camera(1)
	elif event.is_action_pressed(&"zoom_out", false, true):  # Wheel Down Event
		zoom_camera(-1)
	if event.is_action_pressed(&"camera_rotate_left", true):
		start_rotating_camera(-1)
	elif event.is_action_pressed(&"camera_rotate_right", true):
		start_rotating_camera(1)
	elif follow_node == null:
		pan_direction = Input.get_vector(&"camera_left", &"camera_right", &"camera_up", &"camera_down")
		#var dir := Input.get_vector(&"camera_left", &"camera_right", &"camera_up", &"camera_down")
		#if dir != Vector2.ZERO:
			#pan_camera(dir)


func zoom_camera(dir: int) -> void:
	if is_effect_driven():
		return
	var zoom_margin: float = zoom * (-dir) / 5
	var new_zoom: float = zoom + zoom_margin
	if new_zoom < zoom_out_max and new_zoom > zoom_in_max:
		var tween: Tween = create_tween().set_parallel() # TODO use curve for camera zoom smoothing, similar to node following
		tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN)
		tween.tween_property(camera, "size", new_zoom, 0.05)
		await tween.finished
		update_distance()
		zoom = new_zoom
		


#func pan_camera(dir: Vector2) -> void:
	#var new_position: Vector3 = Vector3.ZERO
	#var offset: Vector2 = dir * zoom * pan_speed_max
	#
	#var new_x = self.position.x + offset.x
	#var new_y = self.position.y - offset.y
	#var new_z = self.position.z
	#new_position = Vector3(new_x, new_y, new_z)
	#
	#var tween := create_tween().set_parallel()
	#tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN)
	#tween.tween_property(self, "position", new_position, 0.05)


func start_rotating_camera(dir: int) -> void:
	if is_rotating or is_effect_driven():
		return
	
	is_rotating = true
	var new_rotation: Vector3 = rotation_degrees
	var offset: float = dir * rotate_increment # * delta
	new_rotation.y = new_rotation.y + offset
	
	var tween: Tween = create_tween().set_parallel()
	tween.set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_IN)
	tween.tween_method(rotate_camera, rotation_degrees, new_rotation, time_to_rotate)
	await tween.finished
	
	#push_warning(str(camera_facing))
	is_rotating = false

func rotate_camera(new_rotation_degrees: Vector3) -> void:
	rotation_degrees = new_rotation_degrees
	rotated.emit(Vector3(0, new_rotation_degrees.y, 0))
	
	var camera_angle: float = rotation_degrees.y
	#var target_angle = fposmod(new_rotation_degress.y, 360)
	var camera_angle_pos: float = fposmod(camera_angle, 360)
		
	var new_camera_facing: Direction = Direction.NORTHEAST
	if camera_angle_pos < 90:
		new_camera_facing = Direction.NORTHWEST
	elif camera_angle_pos < 180:
		new_camera_facing = Direction.SOUTHWEST
	elif camera_angle_pos < 270:
		new_camera_facing = Direction.SOUTHEAST
	elif camera_angle_pos < 360:
		new_camera_facing = Direction.NORTHEAST
	
	if new_camera_facing != camera_facing:
		camera_facing = new_camera_facing
		camera_facing_changed.emit()
		get_tree().call_group("Units", "update_animation_facing", CameraFacingVectors[camera_facing])


func on_orthographic_toggled(toggled_on: bool) -> void:
	if toggled_on:
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = camera.position.z * 12.0 / 8.0
		camera.position.z = 200
	else:
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		camera.position.z = camera.size * 8.0 / 12.0


func update_distance() -> void:
	if camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
		camera.position.z = camera.size * 8.0 / 12.0


# --- Effect-track takeover ------------------------------------------------------
#
# `addons/exmateria_effects` runs a `CameraSubsystem` for (measured) 388 of the 401
# `E###` effects, and it is a PURE STATE MACHINE — it never touches a `Camera3D`. It
# produces a focus point, an orbit and a zoom per effect frame and expects a host rig
# to consume them. This is that consumer's half: the rig's own save / drive / restore,
# with no knowledge of the addon in it. The PSX→Godot conversion and the cast
# lifecycle live one layer out, in `EffectCameraTrack`.
#
# 🔴 THIS RIG IS ALREADY SHAPED LIKE THE ONE THE ADDON ASSUMES, which is why the
# takeover is three fields rather than a reimplementation. The addon's own
# `CinematicFacingResolver._view_forward` models a pose as
# `Basis.from_euler(psx_angles_to_godot_rotation(...)) * Vector3(0, 0, -1)` — a focus
# node carrying the orbit, with the camera looking down its local -Z. That is exactly
# `CameraController` + its `Camera3D` child parked at local +Z.

## Everything a takeover overwrites, or empty while nobody is driving. The DICTIONARY
## IS THE FLAG: there is no second bool to fall out of step with it.
var _takeover_saved: Dictionary = {}


## True while an effect camera track owns this rig.
func is_effect_driven() -> bool:
	return not _takeover_saved.is_empty()


## Snapshot the player's camera state and hand the rig to an effect track. Returns
## false if somebody is already driving — the FIRST cast of a multi-target volley keeps
## the camera for its whole track rather than being cut into by the second.
func begin_effect_takeover() -> bool:
	if is_effect_driven():
		return false
	_takeover_saved = {
		"follow_node": follow_node,
		"global_position": global_position,
		"rotation_degrees": rotation_degrees,
		"zoom": zoom,
		"camera_size": camera.size,
		"camera_z": camera.position.z,
		"projection": camera.projection,
	}
	# 🔴 `follow_node` MUST GO. While it is set, `_process` writes `global_position`
	# from it every frame; the `is_effect_driven()` guard up top already stops that,
	# but leaving the reference would make a `follow_node` freed during the cast a
	# dangling restore. Nulling it here goes through the setter, which arms a
	# transition as a side effect — disarmed on the next line, because a takeover
	# snaps to the track's first pose and never eases into it.
	follow_node = null
	is_transitioning = false
	pan_direction = Vector2.ZERO
	return true


## Drive one frame of the rig from an effect track. `focus` is the world point the
## camera orbits, `orbit_degrees` the rig's own euler, `ortho_size` the orthographic
## size the addon's `CameraCalibration` calls for.
##
## 🔴 ROTATION GOES THROUGH `rotate_camera()`, NOT A BARE `rotation_degrees` WRITE, and
## that is the difference between a camera move and a camera move with the units still
## in it. TacticsG's unit sprites are billboards that re-face on `rotated` /
## `camera_facing_changed`; a raw write would orbit the camera while leaving every unit
## on screen facing the pre-cast direction.
func apply_effect_pose(focus: Vector3, orbit_degrees: Vector3, ortho_size: float) -> void:
	if not is_effect_driven():
		return
	global_position = focus
	rotate_camera(orbit_degrees)
	# `zoom` is this rig's name for the orthographic size (`_ready` copies it straight
	# into `camera.size`), so both are written and `update_distance()` derives the
	# perspective stand-off from it when a user has toggled the projection off ortho.
	zoom = ortho_size
	camera.size = ortho_size
	update_distance()


## Give the camera back. Restores the exact pre-cast values — the state a caller can
## assert against — rather than easing toward them.
##
## 🔴 THE RESTORE SNAPS. Re-assigning `follow_node` arms `start_transitioning()`, which
## would ease the rig back over `time_to_transition` from wherever the track left it;
## that reads as a second, unauthored camera move tacked onto the end of every spell.
## The transition is disarmed and the saved pose written directly instead. A rig that
## was following a unit re-acquires it on its very next `_process`, through the branch
## that already snaps to `follow_node.global_position`.
func end_effect_takeover() -> void:
	if not is_effect_driven():
		return
	var saved: Dictionary = _takeover_saved
	_takeover_saved = {}
	camera.projection = saved["projection"]
	camera.size = saved["camera_size"]
	camera.position.z = saved["camera_z"]
	zoom = saved["zoom"]
	# Through `rotate_camera` for the same reason `apply_effect_pose` is: the units
	# turned to follow the cast and have to turn back.
	rotate_camera(saved["rotation_degrees"])
	# Only if nobody claimed it meanwhile. `begin_effect_takeover` left it null, so a
	# non-null value here is a HOST decision taken during the cast — `BattleManager`
	# opening the scenario editor, or the turn moving to another unit — and restoring
	# over it would silently undo that. The last writer wins, and the takeover is not
	# the last writer just because it finished last.
	if follow_node == null:
		follow_node = saved["follow_node"]
	is_transitioning = false
	global_position = saved["global_position"]
