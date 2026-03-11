class_name TrapSpellChargeHandler
extends RefCounted
## PSX Handler 4 — Spell charge lines.
## Gouraud-shaded line trails contract from a ring toward the caster with cosine ease-in-out,
## plus sparkle particles. Lines rendered via ImmediateMesh in TrapEffectInstance.

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
const HEIGHT_OVERSHOOT: float = 8.0  # PSX adds 8 units above head
const SPARKLE_EMITTER_INDEX: int = 12
const SPARKLE_PALETTE_ID: int = 15
const MAX_SPARKLES: int = 14
const FADE_CURVE: PackedByteArray = [0, 25, 50, 75, 100, 125, 255]  # tail dim -> head bright

var state: State = State.INIT
var line_slots: Array[LineSlot] = []
var element_color: Color = Color.WHITE
var active_line_count: int = 0
var sparkles_to_spawn: int = 0
var active_sparkle_count: int = 0
var element_id: int = 0
var convergence_y: float = 0.0

var _spawn_angle_accumulator: int = 0


func start(p_element_id: int, p_sprite_height: float = DEFAULT_HEIGHT) -> void:
	element_id = p_element_id
	convergence_y = (p_sprite_height + HEIGHT_OVERSHOOT) / VfxEmitter.POSITION_DIVISOR

	var trap_data: TrapEffectData = RomReader.trap_effect_data
	if element_id >= 0 and element_id < trap_data.element_colors.size():
		element_color = trap_data.element_colors[element_id]
	else:
		element_color = Color.WHITE

	restart()


func tick() -> void:
	match state:
		State.ACTIVE:
			_try_spawn_line()
			_try_spawn_sparkle()
			_update_lines()
		State.ENDING:
			_update_lines()
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
	sparkles_to_spawn = 0
	active_sparkle_count = 0
	_spawn_angle_accumulator = 0
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

	# Compute spawn angle with golden angle distribution
	var theta_psx: int = (randi() & 0x1FF) + _spawn_angle_accumulator
	_spawn_angle_accumulator += GOLDEN_ANGLE_INCREMENT
	var theta: float = float(theta_psx) * TAU / float(FULL_CIRCLE)

	var spawn_pos := Vector3(cos(theta) * SPAWN_RADIUS, convergence_y, sin(theta) * SPAWN_RADIUS)

	var slot: LineSlot = line_slots[slot_idx]
	slot.alive = true
	slot.age = 0
	slot.spawn_position = spawn_pos
	for i in range(HISTORY_SIZE):
		slot.history[i] = spawn_pos

	active_line_count += 1


func _try_spawn_sparkle() -> void:
	sparkles_to_spawn = 0
	if active_sparkle_count < MAX_SPARKLES:
		sparkles_to_spawn = 1


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
			slot.history[write_index].y = convergence_y
		else:
			slot.history[write_index] = Vector3(0.0, convergence_y, 0.0)

		if slot.age > EXPIRATION_AGE:
			slot.alive = false
			active_line_count -= 1
