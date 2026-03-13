class_name ProjectileEffectInstance
extends Node3D
## Self-contained projectile trajectory effect — linear interpolation from origin to target
## with oriented 3D wireframe model. Used for crossbow bolts, thrown stones, ninja weapons.
## No dependency on TrapEffectData or TrapEffectInstance.

signal completed

enum Variant { ARROW, STONE, SPECIAL }

enum _State { IDLE, FLYING, DONE }

const TICK_DURATION: float = 1.0 / 30.0
const LINE_HALF_WIDTH: float = 0.03

# PSX rotation rates converted from PSX angle units (256 = ~5.625 degrees per frame)
# Stone: rotation_y = countdown * 256, rotation_x = countdown * 128
const STONE_TUMBLE_Y_RATE: float = 256.0 / 4096.0 * TAU  # ~22.5 deg/tick
const STONE_TUMBLE_X_RATE: float = 128.0 / 4096.0 * TAU  # ~11.25 deg/tick
# Special: reverse spin on X
const SPECIAL_SPIN_RATE: float = 256.0 / 4096.0 * TAU

# Wireframe model constants (local-space line pairs: [start, end, start, end, ...])

# Arrow: shaft + 3 fins
const ARROW_LINES: PackedVector3Array = [
	# shaft
	Vector3(0, 0, -0.15), Vector3(0, 0, 0.15),
	# fins (cross-section near tail)
	Vector3(-0.03, 0, -0.10), Vector3(0, 0, -0.04),
	Vector3(0.03, 0, -0.10), Vector3(0, 0, -0.04),
	Vector3(0, -0.03, -0.10), Vector3(0, 0, -0.04),
]

# Stone: irregular wireframe polyhedron (6 vertices, 12 edges)
const STONE_LINES: PackedVector3Array = [
	# Top cap
	Vector3(0, 0.04, 0), Vector3(0.03, 0.02, 0.03),
	Vector3(0, 0.04, 0), Vector3(-0.03, 0.02, 0.03),
	Vector3(0, 0.04, 0), Vector3(-0.03, 0.02, -0.03),
	Vector3(0, 0.04, 0), Vector3(0.03, 0.02, -0.03),
	# Equator ring
	Vector3(0.03, 0.02, 0.03), Vector3(-0.03, 0.02, 0.03),
	Vector3(-0.03, 0.02, 0.03), Vector3(-0.03, 0.02, -0.03),
	Vector3(-0.03, 0.02, -0.03), Vector3(0.03, 0.02, -0.03),
	Vector3(0.03, 0.02, -0.03), Vector3(0.03, 0.02, 0.03),
	# Bottom cap
	Vector3(0, -0.04, 0), Vector3(0.03, 0.02, 0.03),
	Vector3(0, -0.04, 0), Vector3(-0.03, 0.02, 0.03),
	Vector3(0, -0.04, 0), Vector3(-0.03, 0.02, -0.03),
	Vector3(0, -0.04, 0), Vector3(0.03, 0.02, -0.03),
]

# Special: star/shuriken shape (8 points, 16 edges)
const SPECIAL_LINES: PackedVector3Array = [
	# Outer star points to center ring
	Vector3(0.06, 0, 0), Vector3(0.02, 0, 0.02),
	Vector3(0.06, 0, 0), Vector3(0.02, 0, -0.02),
	Vector3(-0.06, 0, 0), Vector3(-0.02, 0, 0.02),
	Vector3(-0.06, 0, 0), Vector3(-0.02, 0, -0.02),
	Vector3(0, 0, 0.06), Vector3(0.02, 0, 0.02),
	Vector3(0, 0, 0.06), Vector3(-0.02, 0, 0.02),
	Vector3(0, 0, -0.06), Vector3(0.02, 0, -0.02),
	Vector3(0, 0, -0.06), Vector3(-0.02, 0, -0.02),
	# Inner ring
	Vector3(0.02, 0, 0.02), Vector3(-0.02, 0, 0.02),
	Vector3(-0.02, 0, 0.02), Vector3(-0.02, 0, -0.02),
	Vector3(-0.02, 0, -0.02), Vector3(0.02, 0, -0.02),
	Vector3(0.02, 0, -0.02), Vector3(0.02, 0, 0.02),
	# Vertical struts for depth
	Vector3(0.02, 0.015, 0.02), Vector3(0.02, -0.015, 0.02),
	Vector3(-0.02, 0.015, 0.02), Vector3(-0.02, -0.015, 0.02),
	Vector3(-0.02, 0.015, -0.02), Vector3(-0.02, -0.015, -0.02),
	Vector3(0.02, 0.015, -0.02), Vector3(0.02, -0.015, -0.02),
]

# Colors — PSX RGB values
const ARROW_COLOR := Color(0.251, 0.251, 0.251)    # PSX (0x40, 0x40, 0x40)
const STONE_COLOR := Color(0.753, 0.753, 0.753)     # PSX (0xC0, 0xC0, 0xC0)
const SPECIAL_COLOR := Color(0.753, 0.753, 0.753)   # PSX (0xC0, 0xC0, 0xC0)

# Default ticks per tile of distance (~10 ticks for 3 tiles)
const TICKS_PER_TILE: float = 3.33

var loop: bool = false

var _state: _State = _State.IDLE
var _variant: Variant = Variant.STONE
var _origin: Vector3
var _target: Vector3
var _delta: Vector3
var _total_distance: float
var _progress: float
var _step: float
var _current_position: Vector3
var _orientation: Basis

# Rotation accumulators
var _tumble_y: float = 0.0
var _tumble_x: float = 0.0
var _spin_x: float = 0.0

var _tick_timer: float = 0.0

# Rendering
var _line_mesh: ImmediateMesh
var _line_mesh_instance: MeshInstance3D
var _material: StandardMaterial3D


func initialize() -> void:
	_setup_line_mesh()


func play(origin: Vector3, target: Vector3, variant: Variant) -> void:
	stop()

	_origin = origin
	_target = target
	_variant = variant
	_delta = target - origin
	_total_distance = _delta.length()

	if _total_distance < 0.001:
		_state = _State.DONE
		completed.emit()
		return

	# Duration proportional to distance
	var duration_ticks: float = maxf(_total_distance * TICKS_PER_TILE, 2.0)
	_step = _total_distance / duration_ticks

	_progress = 0.0
	_current_position = origin
	_tumble_y = 0.0
	_tumble_x = 0.0
	_spin_x = 0.0

	# Compute orientation basis: look-at from origin toward target
	_orientation = _compute_orientation(_delta)

	_tick_timer = 0.0
	_state = _State.FLYING


func stop() -> void:
	_state = _State.IDLE
	_tumble_y = 0.0
	_tumble_x = 0.0
	_spin_x = 0.0
	if _line_mesh != null:
		_line_mesh.clear_surfaces()


func is_playing() -> bool:
	return _state == _State.FLYING


func _process(delta: float) -> void:
	if _state != _State.FLYING:
		return

	_tick_timer += delta
	while _tick_timer >= TICK_DURATION:
		_tick_timer -= TICK_DURATION
		_process_tick()
		if _state != _State.FLYING:
			break

	if _state == _State.FLYING:
		_render_wireframe()


func _process_tick() -> void:
	_progress += _step
	if _progress >= _total_distance:
		_progress = _total_distance
		_current_position = _target
		_line_mesh.clear_surfaces()
		_state = _State.DONE
		if loop:
			play(_origin, _target, _variant)
		else:
			completed.emit()
		return

	# Interpolate position
	var t: float = _progress / _total_distance
	_current_position = _origin.lerp(_target, t)

	# Update rotation per variant
	match _variant:
		Variant.STONE:
			_tumble_y += STONE_TUMBLE_Y_RATE
			_tumble_x += STONE_TUMBLE_X_RATE
		Variant.SPECIAL:
			_spin_x -= SPECIAL_SPIN_RATE
		# ARROW: no rotation


func _compute_orientation(delta_vec: Vector3) -> Basis:
	var dir: Vector3 = delta_vec.normalized()
	# Yaw: rotation around Y to face direction in XZ plane
	var yaw: float = atan2(-dir.x, -dir.z)
	# Pitch: tilt based on Y component
	var horizontal_dist: float = sqrt(dir.x * dir.x + dir.z * dir.z)
	var pitch: float = atan2(dir.y, horizontal_dist)
	return Basis.from_euler(Vector3(pitch, yaw, 0.0), EULER_ORDER_YXZ)


func _render_wireframe() -> void:
	_line_mesh.clear_surfaces()

	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos: Vector3 = cam.global_position

	# Select lines and color for variant
	var lines: PackedVector3Array
	var color: Color
	match _variant:
		Variant.ARROW:
			lines = ARROW_LINES
			color = ARROW_COLOR
		Variant.STONE:
			lines = STONE_LINES
			color = STONE_COLOR
		Variant.SPECIAL:
			lines = SPECIAL_LINES
			color = SPECIAL_COLOR

	if lines.is_empty():
		return

	# Build variant-specific tumble rotation
	var tumble_basis: Basis = Basis.IDENTITY
	match _variant:
		Variant.STONE:
			tumble_basis = Basis.from_euler(Vector3(_tumble_x, _tumble_y, 0.0))
		Variant.SPECIAL:
			tumble_basis = Basis.from_euler(Vector3(_spin_x, 0.0, 0.0))

	# Combined transform: tumble in local space, then orient along trajectory
	var combined: Basis = _orientation * tumble_basis

	_line_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in range(0, lines.size(), 2):
		var local_start: Vector3 = lines[i]
		var local_end: Vector3 = lines[i + 1]

		# Transform to world space
		var world_start: Vector3 = combined * local_start + _current_position
		var world_end: Vector3 = combined * local_end + _current_position

		# Skip degenerate segments
		if world_start.is_equal_approx(world_end):
			continue

		# Camera-facing billboard quad (same technique as TrapEffectInstance._render_charge_lines)
		var seg_dir: Vector3 = (world_end - world_start).normalized()
		var to_cam: Vector3 = (cam_pos - (world_start + world_end) * 0.5).normalized()
		var right: Vector3 = seg_dir.cross(to_cam).normalized() * LINE_HALF_WIDTH

		var s_l: Vector3 = world_start - right
		var s_r: Vector3 = world_start + right
		var e_l: Vector3 = world_end - right
		var e_r: Vector3 = world_end + right

		# Triangle 1: s_l, s_r, e_r
		_line_mesh.surface_set_color(color)
		_line_mesh.surface_add_vertex(s_l)
		_line_mesh.surface_set_color(color)
		_line_mesh.surface_add_vertex(s_r)
		_line_mesh.surface_set_color(color)
		_line_mesh.surface_add_vertex(e_r)

		# Triangle 2: s_l, e_r, e_l
		_line_mesh.surface_set_color(color)
		_line_mesh.surface_add_vertex(s_l)
		_line_mesh.surface_set_color(color)
		_line_mesh.surface_add_vertex(e_r)
		_line_mesh.surface_set_color(color)
		_line_mesh.surface_add_vertex(e_l)

	_line_mesh.surface_end()


func _setup_line_mesh() -> void:
	_line_mesh = ImmediateMesh.new()
	_line_mesh_instance = MeshInstance3D.new()
	_line_mesh_instance.mesh = _line_mesh
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.cull_mode = BaseMaterial3D.CULL_FRONT
	_line_mesh_instance.material_override = _material
	add_child(_line_mesh_instance)
