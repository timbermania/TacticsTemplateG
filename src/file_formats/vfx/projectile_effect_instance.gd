class_name ProjectileEffectInstance
extends Node3D
## Self-contained projectile trajectory effect — linear or parabolic arc from origin to target
## with oriented 3D Gouraud-shaded polygon model parsed from PSX ROM data.
## Linear: crossbow bolts, thrown stones, ninja weapons (handler 20).
## Parabolic: bow arrows with lofting arc (handler 1).
## No dependency on TrapEffectData or TrapEffectInstance.

signal completed

enum Variant { ARROW, STONE, SPECIAL }
enum Trajectory { LINEAR, PARABOLIC }

enum _State { IDLE, FLYING, DONE }

const TICK_DURATION: float = 1.0 / 30.0

# PSX rotation rates converted from PSX angle units (4096 = full circle)
# Stone: rotation_y = countdown * 256, rotation_x = countdown * 128
const STONE_TUMBLE_Y_RATE: float = 256.0 / 4096.0 * TAU
const STONE_TUMBLE_X_RATE: float = 128.0 / 4096.0 * TAU
# Special (shuriken): reverse spin on X
const SPECIAL_SPIN_RATE: float = 256.0 / 4096.0 * TAU

# PSX coordinate scale factor — divide PSX coords by this for Godot units
const PSX_SCALE: float = 100.0

# Model scales (matching godot-learning reference)
const ARROW_SCALE: float = 0.064
const STONE_SCALE: float = 0.1
const SPECIAL_SCALE: float = 0.1

# Ticks per tile of distance. PSX g_effect_duration is ~8-15 frames total;
# 5 ticks/tile gives ~25 ticks (0.83s) for a 5-tile throw — readable pace.
const TICKS_PER_TILE: float = 5.0

# ============================================================
#  PSX model data — vertices and faces from BATTLE.BIN
#  Parsed by tools/parse_projectile_models.py in godot-learning
# ============================================================

# Arrow: 19 vertices, 17 faces (quads + tris). File offset 0x14F9DC.
# PSX arrow tip is at -Y. Needs base rotation to point along flight direction.
const ARROW_VERTICES: Array[Vector3] = [
	Vector3(50, 50, 0), Vector3(-25, 50, -43), Vector3(-42, 0, -72),
	Vector3(83, 0, 0), Vector3(-25, 50, 43), Vector3(-42, 0, 72),
	Vector3(0, -283, 0), Vector3(50, 850, 0), Vector3(-25, 850, 43),
	Vector3(-25, 850, -43), Vector3(50, 650, 0), Vector3(148, 968, 0),
	Vector3(131, 769, 0), Vector3(-25, 650, 43), Vector3(-74, 968, 128),
	Vector3(-65, 769, 113), Vector3(-25, 650, -43), Vector3(-74, 968, -128),
	Vector3(-65, 769, -113),
]
# [indices, colors_rgb, type] — "q"=quad, "t"=tri
const ARROW_FACES: Array = [
	[[0,1,3,2], [[86,86,86],[189,189,193],[62,62,62],[161,161,166]], "q"],
	[[1,4,2,5], [[189,189,193],[108,108,108],[161,161,166],[76,76,76]], "q"],
	[[4,0,5,3], [[108,108,108],[86,86,86],[76,76,76],[62,62,62]], "q"],
	[[3,2,6], [[73,80,65],[191,208,175],[70,76,65]], "t"],
	[[2,5,6], [[191,208,175],[90,98,80],[70,76,65]], "t"],
	[[5,3,6], [[90,98,80],[73,80,65],[70,76,65]], "t"],
	[[7,8,9], [[148,106,60],[161,115,66],[206,147,85]], "t"],
	[[7,9,0,1], [[148,106,60],[206,147,85],[67,48,27],[149,106,62]], "q"],
	[[9,8,1,4], [[206,147,85],[161,115,66],[149,106,62],[85,60,34]], "q"],
	[[8,7,4,0], [[161,115,66],[148,106,60],[85,60,34],[67,48,27]], "q"],
	[[10,12,7,11], [[139,139,72],[139,139,72],[250,250,125],[139,139,72]], "q"],
	[[13,8,15,14], [[70,70,35],[255,255,136],[70,70,35],[70,70,35]], "q"],
	[[16,9,18,17], [[70,70,35],[255,255,176],[70,70,35],[70,70,35]], "q"],
]

# Stone: 8 vertices, 12 triangle faces. File offset 0x14FD00.
const STONE_VERTICES: Array[Vector3] = [
	Vector3(-7, -31, 80), Vector3(-30, 73, -22), Vector3(-83, -4, 16),
	Vector3(38, 54, 41), Vector3(60, 10, -73), Vector3(-39, -29, -69),
	Vector3(79, -22, 18), Vector3(-25, -77, 9),
]
const STONE_FACES: Array = [
	[[0,2,1], [[123,89,38],[141,103,43],[93,68,32]], "t"],
	[[3,0,1], [[74,53,25],[123,89,38],[93,68,32]], "t"],
	[[4,3,1], [[83,60,29],[74,53,25],[93,68,32]], "t"],
	[[5,4,1], [[47,34,24],[83,60,29],[70,51,24]], "t"],
	[[2,5,1], [[141,103,43],[47,34,24],[93,68,32]], "t"],
	[[6,0,3], [[42,30,24],[123,89,38],[74,53,25]], "t"],
	[[4,6,3], [[83,60,29],[42,30,24],[65,47,26]], "t"],
	[[4,7,6], [[50,36,52],[75,54,55],[50,36,52]], "t"],
	[[7,2,0], [[161,117,48],[141,103,43],[123,89,38]], "t"],
	[[7,5,2], [[75,54,55],[47,34,24],[123,89,42]], "t"],
	[[6,7,0], [[42,30,24],[75,54,55],[86,62,50]], "t"],
	[[5,7,4], [[47,34,24],[75,54,55],[50,36,52]], "t"],
]

# Special (shuriken/"unknown"): 10 vertices, 16 triangle faces. File offset 0x1503B8.
const SPECIAL_VERTICES: Array[Vector3] = [
	Vector3(0, 0, 30), Vector3(50, -50, 0), Vector3(0, -200, 0),
	Vector3(-50, -50, 0), Vector3(50, 50, 0), Vector3(200, 0, 0),
	Vector3(-50, 50, 0), Vector3(0, 200, 0), Vector3(-200, 0, 0),
	Vector3(0, 0, -30),
]
const SPECIAL_FACES: Array = [
	[[0,1,2], [[36,43,56],[62,78,91],[66,86,104]], "t"],
	[[0,2,3], [[44,51,45],[62,69,58],[53,57,53]], "t"],
	[[0,4,5], [[36,43,56],[99,137,136],[115,158,144]], "t"],
	[[0,5,1], [[29,34,41],[35,37,49],[36,41,58]], "t"],
	[[0,6,7], [[55,64,61],[129,168,129],[126,160,115]], "t"],
	[[0,7,4], [[29,34,41],[48,59,80],[57,72,86]], "t"],
	[[0,3,8], [[36,43,56],[92,110,83],[75,88,75]], "t"],
	[[0,8,6], [[44,51,45],[75,91,89],[75,88,81]], "t"],
	[[9,3,2], [[55,67,68],[137,183,142],[135,176,131]], "t"],
	[[9,2,1], [[28,33,43],[96,118,144],[62,77,90]], "t"],
	[[9,6,8], [[55,67,68],[102,128,100],[85,104,89]], "t"],
	[[9,8,3], [[45,53,50],[147,178,167],[79,96,90]], "t"],
	[[9,4,7], [[35,42,58],[72,92,100],[72,96,110]], "t"],
	[[9,7,6], [[45,53,50],[127,143,121],[59,67,63]], "t"],
	[[9,1,5], [[55,67,68],[106,147,142],[121,168,151]], "t"],
	[[9,5,4], [[28,33,43],[76,83,98],[41,48,63]], "t"],
]

var loop: bool = false

var _state: _State = _State.IDLE
var _variant: Variant = Variant.STONE
var _trajectory: Trajectory = Trajectory.LINEAR
var _origin: Vector3
var _target: Vector3
var _delta: Vector3
var _total_distance: float
var _progress: float
var _step: float
var _current_position: Vector3
var _orientation: Basis

# Parabolic arc state (handler 1)
var _arc_height: float = 2.0
var _xz_distance: float
var _xz_direction: Vector3

# Rotation accumulators
var _tumble_y: float = 0.0
var _tumble_x: float = 0.0
var _spin_x: float = 0.0

var _tick_timer: float = 0.0

# Rendering — baked ArrayMesh per variant, transformed via MeshInstance3D
var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _meshes: Dictionary = {} # Variant -> ArrayMesh (cached)


func initialize() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.vertex_color_use_as_albedo = true
	_material.cull_mode = BaseMaterial3D.CULL_FRONT

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _material
	_mesh_instance.visible = false
	add_child(_mesh_instance)

	# Pre-build all variant meshes
	_meshes[Variant.ARROW] = _build_mesh(ARROW_VERTICES, ARROW_FACES)
	_meshes[Variant.STONE] = _build_mesh(STONE_VERTICES, STONE_FACES)
	_meshes[Variant.SPECIAL] = _build_mesh(SPECIAL_VERTICES, SPECIAL_FACES)


func play(origin: Vector3, target: Vector3, variant: Variant, trajectory: Trajectory = Trajectory.LINEAR, arc_height: float = 2.0) -> void:
	stop()

	_origin = origin
	_target = target
	_trajectory = trajectory
	_arc_height = arc_height
	_delta = target - origin
	_total_distance = _delta.length()

	if trajectory == Trajectory.PARABOLIC:
		variant = Variant.ARROW # Handler 1 is arrow-only
		# XZ-only distance (handler 1 ignores Y in distance calc)
		var xz_delta: Vector3 = Vector3(_delta.x, 0.0, _delta.z)
		_xz_distance = xz_delta.length()
		_xz_direction = xz_delta.normalized() if _xz_distance > 0.001 else Vector3.FORWARD

	_variant = variant

	var effective_distance: float = _xz_distance if trajectory == Trajectory.PARABOLIC else _total_distance
	if effective_distance < 0.001:
		_state = _State.DONE
		completed.emit()
		return

	# Duration proportional to distance
	var duration_ticks: float = maxf(effective_distance * TICKS_PER_TILE, 2.0)
	_step = effective_distance / duration_ticks

	_progress = 0.0
	_current_position = origin
	_tumble_y = 0.0
	_tumble_x = 0.0
	_spin_x = 0.0

	_orientation = _compute_orientation(_delta)

	_mesh_instance.mesh = _meshes[variant]
	_mesh_instance.visible = true

	_tick_timer = 0.0
	_state = _State.FLYING


func stop() -> void:
	_state = _State.IDLE
	_tumble_y = 0.0
	_tumble_x = 0.0
	_spin_x = 0.0
	if _mesh_instance != null:
		_mesh_instance.visible = false


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
		_update_transform()


func _process_tick() -> void:
	_progress += _step
	var effective_distance: float = _xz_distance if _trajectory == Trajectory.PARABOLIC else _total_distance
	if _progress >= effective_distance:
		_progress = effective_distance
		_current_position = _target
		_mesh_instance.visible = false
		_state = _State.DONE
		if loop:
			play(_origin, _target, _variant, _trajectory, _arc_height)
		else:
			completed.emit()
		return

	var t: float = _progress / effective_distance

	if _trajectory == Trajectory.PARABOLIC:
		# XZ position: linear interpolation along horizontal plane
		var xz_pos: Vector3 = Vector3(_origin.x, 0.0, _origin.z).lerp(Vector3(_target.x, 0.0, _target.z), t)
		# Y position: lerp base heights + parabolic arc offset
		var base_y: float = lerpf(_origin.y, _target.y, t)
		var arc_y: float = _evaluate_parabolic_arc(t)
		_current_position = Vector3(xz_pos.x, base_y + arc_y, xz_pos.z)

		# Recompute orientation from arc tangent each tick for arrow tilt
		var arc_derivative: float = 4.0 * _arc_height * (1.0 - 2.0 * t) / _xz_distance
		var tangent: Vector3 = Vector3(_xz_direction.x, arc_derivative, _xz_direction.z).normalized()
		_orientation = _compute_orientation(tangent * _xz_distance)
	else:
		# Linear interpolation
		_current_position = _origin.lerp(_target, t)

	# Update rotation per variant
	match _variant:
		Variant.STONE:
			_tumble_y += STONE_TUMBLE_Y_RATE
			_tumble_x += STONE_TUMBLE_X_RATE
		Variant.SPECIAL:
			_spin_x -= SPECIAL_SPIN_RATE


func _compute_orientation(delta_vec: Vector3) -> Basis:
	var dir: Vector3 = delta_vec.normalized()
	var up: Vector3 = Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	# Arrow: PSX tip is at -Y → 90° X tumble aligns tip with local -Z.
	# looking_at(dir) makes -Z face toward target, so tip points at target.
	return Basis.looking_at(dir, up)


## Symmetric parabola: rises from 0 at t=0, peaks at arc_height at t=0.5, returns to 0 at t=1.
## Matches PSX evaluate_parabolic_arc (0x801af59c) shape.
func _evaluate_parabolic_arc(t: float) -> float:
	return 4.0 * _arc_height * t * (1.0 - t)


func _update_transform() -> void:
	var model_scale: float
	match _variant:
		Variant.ARROW:
			model_scale = ARROW_SCALE
		Variant.STONE:
			model_scale = STONE_SCALE
		Variant.SPECIAL:
			model_scale = SPECIAL_SCALE

	# Build rotation: orientation along trajectory + variant-specific tumble
	var tumble_basis: Basis = Basis.IDENTITY
	match _variant:
		Variant.ARROW:
			# PSX arrow tip is at -Y; rotate +90° around X to point tip along -Z
			# Then looking_at in _compute_orientation makes -Z face the velocity
			tumble_basis = Basis(Vector3.RIGHT, PI / 2.0)
		Variant.STONE:
			tumble_basis = Basis.from_euler(Vector3(_tumble_x, _tumble_y, 0.0))
		Variant.SPECIAL:
			tumble_basis = Basis.from_euler(Vector3(_spin_x, 0.0, 0.0))

	var model_basis: Basis = _orientation * tumble_basis
	model_basis.x *= model_scale
	model_basis.y *= model_scale
	model_basis.z *= model_scale

	_mesh_instance.global_transform = Transform3D(model_basis, _current_position)


# ============================================================
#  Mesh building — SurfaceTool, same approach as ProjectileMeshBuilder
# ============================================================

static func _build_mesh(vertices: Array[Vector3], faces: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Deduplicate faces (some PSX models have duplicates with different colors)
	var seen: Dictionary = {}

	for face: Array in faces:
		var indices: Array = face[0]
		var colors: Array = face[1]
		var face_type: String = face[2]

		var key: String = str(indices)
		if seen.has(key):
			continue
		seen[key] = true

		if face_type == "q":
			# Quad: split into 2 triangles [0,1,2] + [1,2,3]
			_add_triangle(st, vertices, indices, colors, [0, 1, 2])
			_add_triangle(st, vertices, indices, colors, [1, 2, 3])
		else:
			_add_triangle(st, vertices, indices, colors, [0, 1, 2])

	return st.commit()


static func _add_triangle(st: SurfaceTool, vertices: Array[Vector3],
		indices: Array, colors: Array, tri_order: Array) -> void:
	for i: int in tri_order:
		var idx: int = indices[i]
		var v: Vector3 = vertices[idx]
		var c: Array = colors[i]

		st.set_color(Color(c[0] / 255.0, c[1] / 255.0, c[2] / 255.0))
		st.add_vertex(Vector3(v.x / PSX_SCALE, v.y / PSX_SCALE, v.z / PSX_SCALE))
