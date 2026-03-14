class_name TrapSummonChargeHandler
extends RefCounted
## PSX Handler 18 — Summon charge lines.
## Gouraud-shaded line trails converge from a 3D-oriented spawn ring toward the target's torso.
## Same render approach as handler 4 but with directional ring, per-frame rotation, no sparkles,
## and self-managed duration.

enum State { INIT, ACTIVE, ENDING, DONE }

class LineSlot:
	var alive: bool = false
	var history: Array[Vector3] = []  # 7 entries (ring buffer)
	var age: int = 0
	var spawn_position: Vector3 = Vector3.ZERO

const MAX_LINE_SLOTS: int = 16
const HISTORY_SIZE: int = 7  # 6 LINE_G2 segments per line
const MAX_CONCURRENT_LINES: int = 10
const LINE_MAX_LIFETIME: int = 32
const EXPIRATION_AGE: int = LINE_MAX_LIFETIME + HISTORY_SIZE
const SPAWN_CHANCE_DIVISOR: int = 2  # 50% spawn chance per tick
const GOLDEN_ANGLE_INCREMENT: int = 0x571  # 1393 PSX units = 122.4 degrees
const FULL_CIRCLE: int = 4096
const SPAWN_RADIUS: float = 6.0
const DEFAULT_HEIGHT: float = 24.0  # PSX units — fallback if no unit provided
const RING_ROTATION_RATE: int = 128  # PSX: frame_counter << 7

var state: State = State.INIT
var line_slots: Array[LineSlot] = []
var element_color: Color = Color.WHITE
var active_line_count: int = 0
var convergence_y: float = 0.0

var _spawn_angle_accumulator: int = 0
var _axis_basis: Basis = Basis.IDENTITY  # rotation from Y-up to caster→target axis
var _frame_counter: int = 0
var _duration: int = 30


func start(p_element_id: int, p_sprite_height: float = DEFAULT_HEIGHT,
		p_direction: Vector3 = Vector3.ZERO, p_initial_frame: int = 0) -> void:
	convergence_y = (p_sprite_height / 2.0) / VfxEmitter.POSITION_DIVISOR

	var trap_data: TrapEffectData = RomReader.trap_effect_data
	if p_element_id >= 0 and p_element_id < trap_data.element_colors.size():
		element_color = trap_data.element_colors[p_element_id]
	else:
		element_color = Color.WHITE

	# Compute axis basis from caster→target direction
	if p_direction.length_squared() > 0.001:
		var yaw: float = atan2(p_direction.x, p_direction.z)
		var horizontal_dist: float = sqrt(p_direction.x * p_direction.x + p_direction.z * p_direction.z)
		var pitch: float = atan2(p_direction.y, horizontal_dist)
		_axis_basis = Basis.from_euler(Vector3(pitch, yaw, 0))
	else:
		_axis_basis = Basis.IDENTITY

	_duration = maxi(p_initial_frame + 4, 30)

	restart()


func tick() -> void:
	match state:
		State.ACTIVE:
			_try_spawn_line()
			_update_lines()
			_frame_counter += 1
			if _frame_counter >= _duration:
				start_fade()
		State.ENDING:
			_update_lines()
			_frame_counter += 1
			if active_line_count == 0:
				state = State.DONE
		State.DONE, State.INIT:
			return


func start_fade() -> void:
	if state == State.ACTIVE:
		state = State.ENDING


func is_done() -> bool:
	return state == State.DONE


func restart() -> void:
	if line_slots.size() != MAX_LINE_SLOTS:
		line_slots.resize(MAX_LINE_SLOTS)
		for i in range(MAX_LINE_SLOTS):
			var slot := LineSlot.new()
			slot.history.resize(HISTORY_SIZE)
			line_slots[i] = slot
	for slot in line_slots:
		slot.alive = false
		slot.age = 0
		slot.spawn_position = Vector3.ZERO
		slot.history.fill(Vector3.ZERO)
	active_line_count = 0
	_spawn_angle_accumulator = 0
	_frame_counter = 0
	state = State.ACTIVE


func get_brightness_index(slot: LineSlot) -> int:
	if slot.age <= LINE_MAX_LIFETIME:
		return HISTORY_SIZE - 1  # 6 visible segments
	return maxi(0, LINE_MAX_LIFETIME - (slot.age - (HISTORY_SIZE - 1)))


func _try_spawn_line() -> void:
	if active_line_count >= MAX_CONCURRENT_LINES:
		return
	if randi() % SPAWN_CHANCE_DIVISOR != 0:
		return

	# Find first dead slot
	var slot_idx: int = -1
	for i in range(MAX_LINE_SLOTS):
		if not line_slots[i].alive:
			slot_idx = i
			break
	if slot_idx < 0:
		return

	# Compute spawn angle with golden angle distribution + per-frame rotation
	var theta_psx: int = (randi() & 0x1FF) + _spawn_angle_accumulator + _frame_counter * RING_ROTATION_RATE
	_spawn_angle_accumulator += GOLDEN_ANGLE_INCREMENT
	var theta: float = float(theta_psx) * TAU / float(FULL_CIRCLE)

	# Local spawn on XZ ring, then rotate by axis basis for 3D orientation
	var local_spawn := Vector3(cos(theta) * SPAWN_RADIUS, 0.0, sin(theta) * SPAWN_RADIUS)
	var rotated_spawn: Vector3 = _axis_basis * local_spawn
	var spawn_pos := Vector3(rotated_spawn.x, rotated_spawn.y + convergence_y, rotated_spawn.z)

	var slot: LineSlot = line_slots[slot_idx]
	slot.alive = true
	slot.age = 0
	slot.spawn_position = spawn_pos
	for i in range(HISTORY_SIZE):
		slot.history[i] = spawn_pos

	active_line_count += 1


func _update_lines() -> void:
	for slot in line_slots:
		if not slot.alive:
			continue

		slot.age += 1
		var write_index: int = slot.age % HISTORY_SIZE

		if slot.age <= LINE_MAX_LIFETIME:
			var t: float = float(slot.age) / float(LINE_MAX_LIFETIME)
			var factor: float = (1.0 - cos(t * PI)) / 2.0
			slot.history[write_index].x = slot.spawn_position.x * (1.0 - factor)
			slot.history[write_index].z = slot.spawn_position.z * (1.0 - factor)
			slot.history[write_index].y = slot.spawn_position.y * (1.0 - factor) + convergence_y * factor
		else:
			slot.history[write_index] = Vector3(0.0, convergence_y, 0.0)

		if slot.age > EXPIRATION_AGE:
			slot.alive = false
			active_line_count -= 1
