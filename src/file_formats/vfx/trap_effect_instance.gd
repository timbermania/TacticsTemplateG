class_name TrapEffectInstance
extends Node3D
## Self-contained TRAP particle effect — mesh pool, physics, spawning, rendering.
## Add as a child node, call play() with handler/element/direction.
## Designed to drop into battle_manager the same way VfxEffectInstance works for E###.BIN.

signal completed

## If true, automatically replays when all particles expire.
var loop: bool = false

# --- Particle simulation state ---
const TICK_DURATION: float = 1.0 / 30.0
const TRAP_INERTIA: float = 4096.0
const RADIUS_TO_VELOCITY: float = 1.0 / 14336.0

var _particles: Array[VfxParticleData] = []
var _physics: VfxPhysics
var _tick_counter: int = 0
var _tick_timer: float = 0.0
var _is_playing: bool = false
var _active_emitter_indices: Array[int] = []
var _max_spawn_end: int = 0
var _impact_direction: Vector3 = Vector3.ZERO

# Per-emitter palette override (handler-assigned at spawn, not baked in frame data)
# Flash emitters (1, 9) and knight break (11) always use palette 10 (overbright white);
# dust (0) uses element palette
const FLASH_EMITTER_INDICES: PackedInt32Array = [1, 9, 11]
const FLASH_PALETTE_ID: int = 10
var _emitter_palette: Dictionary[int, int] = {} # emitter_index -> palette_id

# Unit sprite white flash
var _palette_controller: TrapPaletteController

# --- Mesh pool renderer (VfxRenderer pattern) ---
const POOL_INITIAL_SIZE: int = 512
const POOL_GROWTH: int = 128
const OFFSCREEN_POS := Vector3(0, -10000, 0)

var _shared_quad: QuadMesh
var _meshes: Array[MeshInstance3D] = []
var _materials: Array[ShaderMaterial] = []
var _pool_size: int = 0
var _free_mesh_indices: Array[int] = []
var _particle_mesh_map: Dictionary[int, PackedInt32Array] = {} # uid -> PackedInt32Array
var _opaque_shader: Shader
var _blend_shaders: Array[Shader] = []
var _texture_size: Vector2 = Vector2(256, 144)
var _palette_textures: Dictionary[int, Texture2D] = {} # palette_id -> Texture2D
var _z_bias: float = 0.001
var _initialized: bool = false
var _orbital_handler: TrapOrbitalHandler = null
var _spell_charge_handler: TrapSpellChargeHandler = null
var _line_mesh: ImmediateMesh = null
var _line_mesh_instance: MeshInstance3D = null
var _line_material: ShaderMaterial = null
var _scatter_anchor: Vector3 = Vector3.ZERO  # PSX anchor for SCATTER convergence
var _charge_line_shader: Shader
const LINE_HALF_WIDTH: float = 0.03


func initialize() -> void:
	var trap_data: TrapEffectData = RomReader.trap_effect_data

	# Physics
	_physics = VfxPhysics.new()
	_physics.gravity = trap_data.gravity
	_physics.inertia_threshold = float(trap_data.inertia_threshold)

	# Renderer
	if trap_data.texture == null:
		return

	_shared_quad = QuadMesh.new()
	_shared_quad.size = Vector2(1.0, 1.0)

	_opaque_shader = load("res://src/file_formats/vfx/shaders/effect_particle_opaque.gdshader")
	_blend_shaders = [
		load("res://src/file_formats/vfx/shaders/effect_particle_mode0.gdshader"),
		load("res://src/file_formats/vfx/shaders/effect_particle_mode1.gdshader"),
		load("res://src/file_formats/vfx/shaders/effect_particle_mode2.gdshader"),
		load("res://src/file_formats/vfx/shaders/effect_particle_mode3.gdshader"),
	]
	_charge_line_shader = load("res://src/file_formats/vfx/shaders/trap_charge_line.gdshader")

	_texture_size = Vector2(trap_data.trap_spr.width, trap_data.trap_spr.height)
	_palette_textures[0] = trap_data.texture

	_grow_pool(POOL_INITIAL_SIZE)
	_free_mesh_indices.clear()
	for i in range(_pool_size):
		_free_mesh_indices.append(i)

	_initialized = true


## Start the effect. handler_id selects which emitter group to fire.
## element_id selects the dust palette (0-8). direction is attacker→target vector.
## target_unit enables white flash on the unit sprite if provided.
func play(handler_id: int, element_id: int, direction: Vector3 = Vector3.ZERO, target_unit: Unit = null) -> void:
	if not _initialized:
		push_error("TrapEffectInstance.play() called before initialize()")
		return

	stop()

	_impact_direction = direction

	# Handler 4: spell charge lines
	if handler_id == TrapEffectData.HANDLER_SPELL_CHARGE:
		# PSX looks up sprite height from DAT_8009474b[sprite_type * 4]
		var sprite_height: float = TrapSpellChargeHandler.DEFAULT_HEIGHT
		if target_unit != null and target_unit.animation_manager != null \
				and target_unit.animation_manager.global_spr != null:
			sprite_height = float(target_unit.animation_manager.global_spr.graphic_height)
		_spell_charge_handler = TrapSpellChargeHandler.new()
		_spell_charge_handler.start(element_id, sprite_height)
		_setup_line_mesh()
		_emitter_palette.clear()
		_emitter_palette[TrapSpellChargeHandler.SPARKLE_EMITTER_INDEX] = TrapSpellChargeHandler.SPARKLE_PALETTE_ID
		# PSX patches SCATTER anchor to (height + 8) above feet
		_scatter_anchor = Vector3(0.0, _spell_charge_handler.convergence_y, 0.0)
		_tick_counter = 0
		_tick_timer = 0.0
		_is_playing = true
		return

	# Handler 22: orbital summon charge orbs
	if handler_id == TrapEffectData.HANDLER_ORBITAL:
		_orbital_handler = TrapOrbitalHandler.new()
		_orbital_handler.start(Vector3.ZERO)  # Local space — instance node is already at unit position
		_particles = _orbital_handler.particles
		_emitter_palette.clear()
		_emitter_palette[TrapOrbitalHandler.EMITTER_INDEX] = TrapEffectData.ORBITAL_PALETTE_ID
		_tick_counter = 0
		_tick_timer = 0.0
		_is_playing = true
		return

	# Determine which emitters to activate
	if handler_id == 0:
		_active_emitter_indices.assign(range(TrapEffectData.NUM_EMITTERS))
	else:
		_active_emitter_indices.assign(TrapEffectData.HANDLER_CONFIGS.get(handler_id, []))

	# Cache max spawn end + set per-emitter palettes
	var trap_data: TrapEffectData = RomReader.trap_effect_data
	_max_spawn_end = 0
	_emitter_palette.clear()
	for idx: int in _active_emitter_indices:
		if idx < trap_data.emitters.size():
			_max_spawn_end = maxi(_max_spawn_end, trap_data.emitters[idx].spawn_check_hi)
		if idx in FLASH_EMITTER_INDICES:
			_emitter_palette[idx] = FLASH_PALETTE_ID
		else:
			_emitter_palette[idx] = element_id

	_tick_counter = 0
	_tick_timer = 0.0
	_is_playing = true

	if target_unit != null:
		_palette_controller = TrapPaletteController.new()
		_palette_controller.start(target_unit)
	else:
		_palette_controller = null


func stop() -> void:
	_is_playing = false
	_orbital_handler = null
	_spell_charge_handler = null
	_scatter_anchor = Vector3.ZERO
	if _line_mesh_instance != null:
		_line_mesh_instance.queue_free()
		_line_mesh_instance = null
		_line_mesh = null
		_line_material = null
	_particles.clear()
	_release_all_meshes()
	if _palette_controller != null:
		_palette_controller.reset()
		_palette_controller = null


func start_fade() -> void:
	if _orbital_handler != null:
		_orbital_handler.start_fade()
	if _spell_charge_handler != null:
		_spell_charge_handler.start_fade()


func is_playing() -> bool:
	return _is_playing


func set_z_bias(value: float) -> void:
	_z_bias = value
	for mat: ShaderMaterial in _materials:
		mat.set_shader_parameter("z_bias", value)


# ============================================================
#  _process — fixed-timestep tick loop
# ============================================================

func _process(delta: float) -> void:
	if not _is_playing:
		return

	_tick_timer += delta
	while _tick_timer >= TICK_DURATION:
		_tick_timer -= TICK_DURATION
		_process_tick()

	_render_particles()


func _process_tick() -> void:
	var trap_data: TrapEffectData = RomReader.trap_effect_data
	if trap_data.emitters.is_empty():
		return

	# Handler 22: orbital tick
	if _orbital_handler != null:
		_orbital_handler.tick()
		for p: VfxParticleData in _particles:
			p.age += 1  # Orbital particles bypass physics, must increment age manually
			_tick_trap_animation(p, trap_data)
		_tick_counter += 1
		if _orbital_handler.is_done():
			if loop:
				_orbital_handler.start(Vector3.ZERO)
				_tick_counter = 0
				_tick_timer = 0.0
			else:
				_is_playing = false
				completed.emit()
		return

	# Handler 4: spell charge lines
	if _spell_charge_handler != null:
		_spell_charge_handler.tick()
		_spawn_handler_sparkles(trap_data)
		var removed: int = _update_and_cull_particles(trap_data)
		_spell_charge_handler.active_sparkle_count -= removed
		_tick_counter += 1
		if _spell_charge_handler.is_done():
			if loop:
				_spell_charge_handler.restart()
				_particles.clear()
				_tick_counter = 0
				_tick_timer = 0.0
			else:
				_is_playing = false
				completed.emit()
		return

	_spawn_particles_for_tick(trap_data)
	_update_and_cull_particles(trap_data)

	if _palette_controller != null and not _palette_controller.is_done():
		_palette_controller.update()

	_tick_counter += 1

	var flash_done: bool = _palette_controller == null or _palette_controller.is_done()
	if _tick_counter > _max_spawn_end and _particles.is_empty() and flash_done:
		if loop:
			_particles.clear()
			_tick_counter = 0
			_tick_timer = 0.0
		else:
			_is_playing = false
			completed.emit()


func _update_and_cull_particles(trap_data: TrapEffectData) -> int:
	for p: VfxParticleData in _particles:
		_physics.update_particle(p)
		_tick_trap_animation(p, trap_data)
	var prev_count: int = _particles.size()
	_particles = _particles.filter(
		func(p: VfxParticleData) -> bool: return p.active and not p.is_dead())
	return prev_count - _particles.size()


# ============================================================
#  Particle spawning — tick-window based
# ============================================================

func _spawn_particles_for_tick(trap_data: TrapEffectData) -> void:
	for emitter_idx: int in _active_emitter_indices:
		if emitter_idx >= trap_data.emitters.size():
			continue
		var emitter: TrapEffectData.TrapEmitter = trap_data.emitters[emitter_idx]

		if _tick_counter < emitter.spawn_check_lo or _tick_counter > emitter.spawn_check_hi:
			continue

		var current_count: int = 0
		for p: VfxParticleData in _particles:
			if p.emitter_index == emitter_idx:
				current_count += 1

		for _i: int in range(emitter.spawn_rate):
			if current_count >= emitter.max_particles:
				break
			var p: VfxParticleData = _create_particle(emitter_idx, emitter, trap_data)
			_particles.append(p)
			current_count += 1


func _create_particle(emitter_idx: int, emitter: TrapEffectData.TrapEmitter, trap_data: TrapEffectData) -> VfxParticleData:
	var p := VfxParticleData.new()
	var has_direction: bool = _impact_direction.length_squared() > 0.001

	var ellipsoid_offset: Vector3 = _calc_ellipsoid_offset(emitter)
	var spawn_pos: Vector3 = ellipsoid_offset + emitter.pos_scatter

	if has_direction and emitter.velocity_mode == TrapEffectData.VelocityMode.DIRECTIONAL:
		spawn_pos = _rotate_by_direction(spawn_pos, _impact_direction)

	var vel: Vector3 = Vector3.ZERO
	match emitter.velocity_mode:
		TrapEffectData.VelocityMode.SPHERICAL_RANDOM:
			vel = _calc_scatter_velocity(emitter, ellipsoid_offset)
		TrapEffectData.VelocityMode.SCATTER:
			# PSX SCATTER: particles spawn randomly within ±velocity range around
			# the anchor point, then fly inward toward the anchor.
			# The anchor (caster body center on PSX) is set per-handler via _scatter_anchor.
			var scatter_range: Vector3 = emitter.velocity
			spawn_pos = _scatter_anchor + Vector3(
				randf_range(-absf(scatter_range.x), absf(scatter_range.x)),
				randf_range(-absf(scatter_range.y), absf(scatter_range.y)),
				randf_range(-absf(scatter_range.z), absf(scatter_range.z)))
			vel = _calc_scatter_velocity(emitter, _scatter_anchor - spawn_pos)
		TrapEffectData.VelocityMode.DIRECTIONAL, TrapEffectData.VelocityMode.FACING_DIRECTIONAL:
			var vel_local: Vector3 = _calc_directional_velocity(emitter)
			if has_direction:
				var dir_basis: Basis = _build_direction_basis(_impact_direction)
				vel = dir_basis * vel_local
			else:
				vel = vel_local

	var lifetime: int = randi_range(emitter.lifetime_min, emitter.lifetime_max)
	p.initialize(spawn_pos, vel, lifetime, emitter_idx)

	p.inertia = TRAP_INERTIA
	p.weight = float(randi_range(emitter.weight_min, emitter.weight_max))

	init_trap_animation(p, emitter, trap_data)
	return p


func _calc_ellipsoid_offset(emitter: TrapEffectData.TrapEmitter) -> Vector3:
	var vel: Vector3 = emitter.velocity
	var magnitude: float = vel.length()
	if magnitude < 0.001:
		return Vector3.ZERO

	var dir: Vector3 = _random_unit_sphere()
	return Vector3(
		dir.x * vel.x / magnitude,
		dir.y * vel.y / magnitude,
		dir.z * vel.z / magnitude
	) / VfxEmitter.POSITION_DIVISOR


func _calc_scatter_velocity(emitter: TrapEffectData.TrapEmitter, ellipsoid_offset: Vector3) -> Vector3:
	var speed: float = randf_range(float(emitter.radius_min), float(emitter.radius_max)) * RADIUS_TO_VELOCITY
	var vel: Vector3 = Vector3.ZERO
	if ellipsoid_offset.length() > 0.001 and absf(speed) > 0.001:
		vel = ellipsoid_offset.normalized() * speed
	return vel


func _calc_directional_velocity(emitter: TrapEffectData.TrapEmitter) -> Vector3:
	var angle_x: float = emitter.vel_range.x + randf_range(
		-emitter.scatter_half_range.x * 0.5, emitter.scatter_half_range.x * 0.5)
	var angle_y: float = emitter.vel_range.y + randf_range(
		-emitter.scatter_half_range.y * 0.5, emitter.scatter_half_range.y * 0.5)
	var angle_z: float = emitter.vel_range.z + randf_range(
		-emitter.scatter_half_range.z * 0.5, emitter.scatter_half_range.z * 0.5)

	var cone_basis: Basis = Basis.from_euler(Vector3(angle_x, angle_y, angle_z), EULER_ORDER_ZYX)
	var speed: float = randf_range(float(emitter.radius_min), float(emitter.radius_max)) * RADIUS_TO_VELOCITY
	return cone_basis * Vector3(0, speed, 0)


static func _random_unit_sphere() -> Vector3:
	var theta: float = randf() * TAU
	var phi: float = acos(2.0 * randf() - 1.0)
	return Vector3(
		sin(phi) * cos(theta),
		cos(phi),
		sin(phi) * sin(theta)
	)


# ============================================================
#  Impact direction — rotate positions/velocities by attacker angle
# ============================================================

static func _rotate_by_direction(local_vec: Vector3, direction: Vector3) -> Vector3:
	var base_rotated := Vector3(local_vec.y, -local_vec.x, local_vec.z)

	var dir_xz := Vector3(direction.x, 0.0, direction.z)
	if dir_xz.length_squared() < 0.001:
		return base_rotated

	dir_xz = dir_xz.normalized()
	var angle: float = atan2(dir_xz.z, dir_xz.x)
	var cos_a: float = cos(angle)
	var sin_a: float = sin(angle)

	return Vector3(
		base_rotated.x * cos_a - base_rotated.z * sin_a,
		base_rotated.y,
		base_rotated.x * sin_a + base_rotated.z * cos_a)


static func _build_direction_basis(direction: Vector3) -> Basis:
	var dir: Vector3 = direction.normalized()
	var yaw: float = atan2(-dir.x, dir.z)
	var horizontal_dist: float = sqrt(dir.x * dir.x + dir.z * dir.z)
	var pitch: float = atan2(dir.y, horizontal_dist) + PI * 0.5
	return Basis.from_euler(Vector3(pitch, yaw, 0.0), EULER_ORDER_YXZ)


# ============================================================
#  TRAP animation — 1:1 tick (not /2 like E###.BIN)
# ============================================================

static func init_trap_animation(p: VfxParticleData, emitter: TrapEffectData.TrapEmitter, trap_data: TrapEffectData) -> void:
	p.anim_index = emitter.anim_index
	p.anim_frame = 0
	p.anim_time = 0

	if p.anim_index < 0 or p.anim_index >= trap_data.animations.size():
		return
	var animation: VisualEffectData.VfxAnimation = trap_data.animations[p.anim_index]
	if animation.animation_frames.is_empty():
		return

	var first: VisualEffectData.VfxAnimationFrame = animation.animation_frames[0]
	if first.frameset_id < 0x80:
		p.current_frameset = first.frameset_id
		p.anim_time = first.duration
		if first.duration == 0:
			mark_animation_terminal(p)


static func _tick_trap_animation(p: VfxParticleData, trap_data: TrapEffectData) -> void:
	if p.animation_complete or p.animation_held:
		return
	if p.anim_index < 0 or p.anim_index >= trap_data.animations.size():
		return

	var animation: VisualEffectData.VfxAnimation = trap_data.animations[p.anim_index]
	if animation.animation_frames.is_empty():
		return

	p.anim_time -= 1
	if p.anim_time > 0:
		return

	p.anim_frame += 1
	_resolve_trap_animation_frame(p, animation)


static func _resolve_trap_animation_frame(p: VfxParticleData, animation: VisualEffectData.VfxAnimation) -> void:
	while p.anim_frame < animation.animation_frames.size():
		var af: VisualEffectData.VfxAnimationFrame = animation.animation_frames[p.anim_frame]

		if af.frameset_id == VisualEffectData.ANIM_OPCODE_LOOP:
			mark_animation_terminal(p)
			return

		p.current_frameset = af.frameset_id
		p.anim_time = af.duration

		if af.duration == 0:
			mark_animation_terminal(p)
			return

		return

	p.animation_complete = true


static func mark_animation_terminal(p: VfxParticleData) -> void:
	if p.lifetime == -1:
		p.animation_complete = true
	else:
		p.animation_held = true


# ============================================================
#  Spell charge line helpers
# ============================================================

func _spawn_handler_sparkles(trap_data: TrapEffectData) -> void:
	var count: int = _spell_charge_handler.sparkles_to_spawn
	_spell_charge_handler.sparkles_to_spawn = 0
	var emitter_idx: int = TrapSpellChargeHandler.SPARKLE_EMITTER_INDEX
	if emitter_idx >= trap_data.emitters.size():
		return
	var emitter: TrapEffectData.TrapEmitter = trap_data.emitters[emitter_idx]
	for _i in range(count):
		var p: VfxParticleData = _create_particle(emitter_idx, emitter, trap_data)
		_particles.append(p)
		_spell_charge_handler.active_sparkle_count += 1


func _setup_line_mesh() -> void:
	_line_mesh = ImmediateMesh.new()
	_line_mesh_instance = MeshInstance3D.new()
	_line_mesh_instance.mesh = _line_mesh
	_line_material = ShaderMaterial.new()
	_line_material.shader = _charge_line_shader
	_line_mesh_instance.material_override = _line_material
	add_child(_line_mesh_instance)


func _render_charge_lines() -> void:
	_line_mesh.clear_surfaces()
	if _spell_charge_handler.active_line_count == 0:
		return

	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos: Vector3 = cam.global_position

	var elem_color: Color = _spell_charge_handler.element_color
	var fade_curve: PackedByteArray = TrapSpellChargeHandler.FADE_CURVE

	_line_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	for slot in _spell_charge_handler.line_slots:
		if not slot.alive:
			continue

		var brightness_segs: int = _spell_charge_handler.get_brightness_index(slot)
		if brightness_segs <= 0:
			continue

		var write_index: int = slot.age % TrapSpellChargeHandler.HISTORY_SIZE

		# Walk backwards through history: newest (write_index) to oldest
		for seg in range(brightness_segs):
			var idx_end: int = (write_index - seg + TrapSpellChargeHandler.HISTORY_SIZE) % TrapSpellChargeHandler.HISTORY_SIZE
			var idx_start: int = (idx_end - 1 + TrapSpellChargeHandler.HISTORY_SIZE) % TrapSpellChargeHandler.HISTORY_SIZE

			var p_start: Vector3 = slot.history[idx_start]
			var p_end: Vector3 = slot.history[idx_end]

			# Skip degenerate segments
			if p_start.is_equal_approx(p_end):
				continue

			# Color from fade curve (head = bright, tail = dim)
			var head_idx: int = TrapSpellChargeHandler.HISTORY_SIZE - 1 - seg
			var tail_idx: int = head_idx - 1
			if tail_idx < 0:
				tail_idx = 0
			if head_idx >= fade_curve.size():
				head_idx = fade_curve.size() - 1

			var alpha_end: float = float(fade_curve[head_idx]) / 255.0
			var alpha_start: float = float(fade_curve[tail_idx]) / 255.0
			var color_end := Color(elem_color.r * alpha_end, elem_color.g * alpha_end, elem_color.b * alpha_end, 1.0)
			var color_start := Color(elem_color.r * alpha_start, elem_color.g * alpha_start, elem_color.b * alpha_start, 1.0)

			# Camera-facing quad (billboard strip)
			var seg_dir: Vector3 = (p_end - p_start).normalized()
			var to_cam: Vector3 = (cam_pos - (p_start + p_end) * 0.5).normalized()
			var right: Vector3 = seg_dir.cross(to_cam).normalized() * LINE_HALF_WIDTH

			# Two triangles: start-left, start-right, end-right, start-left, end-right, end-left
			var s_l: Vector3 = p_start - right
			var s_r: Vector3 = p_start + right
			var e_l: Vector3 = p_end - right
			var e_r: Vector3 = p_end + right

			_line_mesh.surface_set_color(color_start)
			_line_mesh.surface_add_vertex(s_l)
			_line_mesh.surface_set_color(color_start)
			_line_mesh.surface_add_vertex(s_r)
			_line_mesh.surface_set_color(color_end)
			_line_mesh.surface_add_vertex(e_r)

			_line_mesh.surface_set_color(color_start)
			_line_mesh.surface_add_vertex(s_l)
			_line_mesh.surface_set_color(color_end)
			_line_mesh.surface_add_vertex(e_r)
			_line_mesh.surface_set_color(color_end)
			_line_mesh.surface_add_vertex(e_l)

	_line_mesh.surface_end()


# ============================================================
#  Mesh pool
# ============================================================

func _get_palette_texture(palette_id: int) -> Texture2D:
	if _palette_textures.has(palette_id):
		return _palette_textures[palette_id]
	var trap_data: TrapEffectData = RomReader.trap_effect_data
	var tex: Texture2D = trap_data.get_palette_texture(palette_id)
	_palette_textures[palette_id] = tex
	return tex


func _grow_pool(new_size: int) -> void:
	if new_size <= _pool_size:
		return
	for _i in range(new_size - _pool_size):
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.mesh = _shared_quad
		mesh_instance.visible = false
		mesh_instance.position = OFFSCREEN_POS

		var mat := ShaderMaterial.new()
		mat.shader = _opaque_shader
		mat.render_priority = 1
		mat.set_shader_parameter("z_bias", _z_bias)
		if not _palette_textures.is_empty():
			mat.set_shader_parameter("effect_texture", _palette_textures[0])
			mat.set_shader_parameter("texture_size", _texture_size)
		mesh_instance.material_override = mat
		_materials.append(mat)

		add_child(mesh_instance)
		_meshes.append(mesh_instance)
	_pool_size = new_size


func _borrow_mesh_index() -> int:
	if _free_mesh_indices.is_empty():
		var old_size: int = _pool_size
		_grow_pool(_pool_size + POOL_GROWTH)
		for i in range(old_size, _pool_size):
			_free_mesh_indices.append(i)
	return _free_mesh_indices.pop_back()


func _return_mesh(mi: int) -> void:
	_meshes[mi].visible = false
	_meshes[mi].position = OFFSCREEN_POS
	_free_mesh_indices.append(mi)


func _release_all_meshes() -> void:
	for uid: int in _particle_mesh_map:
		var mesh_indices: PackedInt32Array = _particle_mesh_map[uid]
		for mi in mesh_indices:
			_return_mesh(mi)
	_particle_mesh_map.clear()


# ============================================================
#  Rendering — dual-pass PSX shaders
# ============================================================

func _render_particles() -> void:
	if _spell_charge_handler != null:
		_render_charge_lines()

	if _particles.is_empty():
		_release_all_meshes()
		return

	var trap_data: TrapEffectData = RomReader.trap_effect_data
	if _opaque_shader == null:
		return

	var renderable: Dictionary = _collect_renderable(trap_data)
	_release_stale_meshes(renderable)
	_resize_particle_meshes(renderable, trap_data)
	_draw_particles(renderable, trap_data)


func _collect_renderable(trap_data: TrapEffectData) -> Dictionary:
	var result: Dictionary = {} # uid -> particle_index
	for pi in range(_particles.size()):
		var p: VfxParticleData = _particles[pi]
		if p.age == 0 or not p.active or p.is_dead():
			continue

		var frameset_idx: int = p.current_frameset
		if frameset_idx < 0 or frameset_idx >= trap_data.framesets.size():
			continue

		var frameset: VisualEffectData.VfxFrameSet = trap_data.framesets[frameset_idx]
		if frameset.frameset.is_empty():
			continue

		result[p.uid] = pi
	return result


func _release_stale_meshes(renderable: Dictionary) -> void:
	for uid: int in _particle_mesh_map.keys():
		if not renderable.has(uid):
			var mesh_indices: PackedInt32Array = _particle_mesh_map[uid]
			for mi in mesh_indices:
				_return_mesh(mi)
			_particle_mesh_map.erase(uid)


func _resize_particle_meshes(renderable: Dictionary, trap_data: TrapEffectData) -> void:
	for uid: int in renderable:
		var pi: int = renderable[uid]
		var p: VfxParticleData = _particles[pi]
		var frameset: VisualEffectData.VfxFrameSet = trap_data.framesets[p.current_frameset]
		var needed: int = frameset.frameset.size() * 2
		var current: PackedInt32Array = _particle_mesh_map.get(uid, PackedInt32Array())
		var have: int = current.size()

		if have < needed:
			for _j in range(needed - have):
				current.append(_borrow_mesh_index())
			_particle_mesh_map[uid] = current
		elif have > needed:
			for i in range(needed, have):
				_return_mesh(current[i])
			current = current.slice(0, needed)
			_particle_mesh_map[uid] = current


func _draw_particles(renderable: Dictionary, trap_data: TrapEffectData) -> void:
	var draw_order: int = 0
	for uid: int in renderable:
		var pi: int = renderable[uid]
		var p: VfxParticleData = _particles[pi]
		var frameset_idx: int = p.current_frameset
		var frameset: VisualEffectData.VfxFrameSet = trap_data.framesets[frameset_idx]
		var mesh_indices: PackedInt32Array = _particle_mesh_map[uid]
		var local_slot: int = 0

		for fi in range(frameset.frameset.size()):
			var vfx_frame: VisualEffectData.VfxFrame = frameset.frameset[fi]
			if vfx_frame == null:
				local_slot += 2
				continue

			var mi_opaque: int = mesh_indices[local_slot]
			_render_frame(_meshes[mi_opaque], _materials[mi_opaque], p, vfx_frame, true, draw_order)
			draw_order += 1
			local_slot += 1

			var mi_semi: int = mesh_indices[local_slot]
			_render_frame(_meshes[mi_semi], _materials[mi_semi], p, vfx_frame, false, draw_order)
			draw_order += 1
			local_slot += 1


func _render_frame(mesh_inst: MeshInstance3D, mat: ShaderMaterial, p: VfxParticleData,
		vfx_frame: VisualEffectData.VfxFrame, is_opaque_pass: bool, draw_order: int) -> void:
	var t := Transform3D.IDENTITY
	t.origin = p.position
	mesh_inst.transform = t

	var uv_rect_data := Vector4(
		float(vfx_frame.top_left_uv.x) / _texture_size.x,
		float(vfx_frame.top_left_uv.y) / _texture_size.y,
		float(vfx_frame.uv_width) / _texture_size.x,
		float(vfx_frame.uv_height) / _texture_size.y
	)

	if is_opaque_pass:
		mat.shader = _opaque_shader
	else:
		var blend_mode: int = clampi(vfx_frame.semi_transparency_mode, 0, 3)
		mat.shader = _blend_shaders[blend_mode]

	var palette_id: int = _emitter_palette.get(p.emitter_index, vfx_frame.palette_id)
	var tex: Texture2D = _get_palette_texture(palette_id)
	mat.set_shader_parameter("effect_texture", tex)

	mat.set_shader_parameter("corner_tl", Vector2(float(vfx_frame.top_left_xy.x), float(vfx_frame.top_left_xy.y)))
	mat.set_shader_parameter("corner_tr", Vector2(float(vfx_frame.top_right_xy.x), float(vfx_frame.top_right_xy.y)))
	mat.set_shader_parameter("corner_bl", Vector2(float(vfx_frame.bottom_left_xy.x), float(vfx_frame.bottom_left_xy.y)))
	mat.set_shader_parameter("corner_br", Vector2(float(vfx_frame.bottom_right_xy.x), float(vfx_frame.bottom_right_xy.y)))
	mat.set_shader_parameter("uv_rect_data", uv_rect_data)

	mat.set_shader_parameter("color_modulate", p.color_modulate)
	mat.render_priority = draw_order + 1
	mesh_inst.visible = true
