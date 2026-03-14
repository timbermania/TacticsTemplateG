class_name ProjectileTestScene
extends Node3D
## Standalone projectile trajectory debug scene — loads a map, spawns a Squire unit,
## and previews projectile trajectory effects via ProjectileEffectInstance.

@export var camera_controller: CameraController
@export var maps_container: Node3D
@export var target_marker: MeshInstance3D
@export var origin_marker: MeshInstance3D
@export var units_container: Node3D
@export var effect_container: Node3D

# UI
@export var variant_option: OptionButton
@export var trajectory_option: OptionButton
@export var arc_height_slider: HSlider
@export var arc_height_label: Label
@export var play_button: Button
@export var loop_checkbox: CheckBox
@export var speed_slider: HSlider
@export var speed_label: Label
@export var direction_slider: HSlider
@export var direction_label: Label
@export var distance_slider: HSlider
@export var distance_label: Label
@export var info_label: RichTextLabel

var target_world_pos: Vector3 = Vector3(2.5, 0, 1.5)
var attacker_world_pos: Vector3 = Vector3(2.5, 0, 1.5)
var target_unit: Unit
var attacker_unit: Unit
var _direction: Vector3 = Vector3(1, 0, 0)
var _distance: float = 5.0

var _projectile_instance: ProjectileEffectInstance

# Map data for tile lookups
var _terrain_tiles: Array[TerrainTile] = []
var _mesh_aabb: AABB


func _ready() -> void:
	variant_option.item_selected.connect(_on_variant_changed)
	trajectory_option.item_selected.connect(_on_trajectory_changed)
	arc_height_slider.value_changed.connect(_on_arc_height_changed)
	play_button.pressed.connect(_on_play_pressed)
	speed_slider.value_changed.connect(_on_speed_changed)
	direction_slider.value_changed.connect(_on_direction_changed)
	distance_slider.value_changed.connect(_on_distance_changed)
	loop_checkbox.toggled.connect(_on_loop_toggled)

	if RomReader.is_ready:
		_on_rom_loaded()
	else:
		RomReader.rom_loaded.connect(_on_rom_loaded, CONNECT_ONE_SHOT)


func _on_rom_loaded() -> void:
	_load_map()
	_spawn_target_unit()
	_spawn_attacker_unit()
	_setup_projectile_instance()
	_populate_ui()
	_update_positions()
	_update_info_display()


func _load_map() -> void:
	if 116 >= RomReader.maps_array.size():
		push_warning("[ProjectileTestScene] Map 116 out of range")
		return

	var map_data: MapData = RomReader.maps_array[116]
	if not map_data.is_initialized:
		map_data.init_map()

	var new_map_instance: MapChunkNodes = MapChunkNodes.instantiate()
	new_map_instance.map_data = map_data
	new_map_instance.name = map_data.unique_name

	# Y-mirror (same as VFX test scene / battle default)
	var mirror_scale := Vector3(1, -1, 1)
	var mesh_aabb: AABB = map_data.mesh.get_aabb()
	var surface_arrays: Array = map_data.mesh.surface_get_arrays(0)
	var original_mesh_center: Vector3 = mesh_aabb.get_center()
	for vertex_idx: int in surface_arrays[Mesh.ARRAY_VERTEX].size():
		var vertex: Vector3 = surface_arrays[Mesh.ARRAY_VERTEX][vertex_idx]
		vertex = vertex - original_mesh_center
		vertex = vertex * mirror_scale
		vertex = vertex + (mesh_aabb.size / 2.0)
		surface_arrays[Mesh.ARRAY_VERTEX][vertex_idx] = vertex

	for idx: int in surface_arrays[Mesh.ARRAY_VERTEX].size() / 3:
		var tri_idx: int = idx * 3
		var temp_vertex: Vector3 = surface_arrays[Mesh.ARRAY_VERTEX][tri_idx]
		surface_arrays[Mesh.ARRAY_VERTEX][tri_idx] = surface_arrays[Mesh.ARRAY_VERTEX][tri_idx + 2]
		surface_arrays[Mesh.ARRAY_VERTEX][tri_idx + 2] = temp_vertex
		var temp_uv: Vector2 = surface_arrays[Mesh.ARRAY_TEX_UV][tri_idx]
		surface_arrays[Mesh.ARRAY_TEX_UV][tri_idx] = surface_arrays[Mesh.ARRAY_TEX_UV][tri_idx + 2]
		surface_arrays[Mesh.ARRAY_TEX_UV][tri_idx + 2] = temp_uv

	var modified_mesh: ArrayMesh = ArrayMesh.new()
	modified_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)
	new_map_instance.mesh_instance.mesh = modified_mesh
	new_map_instance.set_mesh_shader(map_data.albedo_texture_indexed, map_data.texture_palettes)
	new_map_instance.collision_shape.shape = new_map_instance.mesh_instance.mesh.create_trimesh_shape()
	new_map_instance.play_animations(map_data)
	maps_container.add_child(new_map_instance)

	# Store terrain data for tile lookups
	_terrain_tiles.assign(map_data.terrain_tiles)
	_mesh_aabb = mesh_aabb

	# Find a central tile for target placement
	# Pick the tile closest to the map center so there's room for the attacker
	var min_loc := Vector2i(999, 999)
	var max_loc := Vector2i(-999, -999)
	for tile: TerrainTile in _terrain_tiles:
		if tile.no_cursor == 1:
			continue
		min_loc = Vector2i(mini(min_loc.x, tile.location.x), mini(min_loc.y, tile.location.y))
		max_loc = Vector2i(maxi(max_loc.x, tile.location.x), maxi(max_loc.y, tile.location.y))
	var center_loc := Vector2i((min_loc.x + max_loc.x) / 2, (min_loc.y + max_loc.y) / 2)
	var best_target_tile: TerrainTile = null
	var best_dist: float = INF
	for tile: TerrainTile in _terrain_tiles:
		if tile.no_cursor == 1:
			continue
		var diff: Vector2i = tile.location - center_loc
		var d: float = float(diff.x * diff.x + diff.y * diff.y)
		if d < best_dist:
			best_dist = d
			best_target_tile = tile
	if best_target_tile != null:
		target_world_pos = _tile_to_world(best_target_tile)

	# Find attacker tile
	attacker_world_pos = _find_attacker_pos()

	target_marker.position = target_world_pos + Vector3(0, 0.15, 0)
	camera_controller.position = target_world_pos


func _spawn_target_unit() -> void:
	target_unit = _spawn_unit(target_world_pos, 0x4a, 0) # Squire, palette 0


func _spawn_attacker_unit() -> void:
	attacker_unit = _spawn_unit(attacker_world_pos, 0x4a, 3) # Squire, palette 3 (different color)


func _spawn_unit(pos: Vector3, job_id: int, palette: int) -> Unit:
	var unit: Unit = Unit.instantiate()
	units_container.add_child(unit)
	unit.initialize_unit()
	unit.char_body.global_position = pos + Vector3(0, 0.25, 0)
	unit.stat_basis = Unit.StatBasis.MALE
	unit.set_job_id(job_id)
	unit.set_sprite_palette(palette)
	unit.update_unit_facing(Vector3.FORWARD)
	camera_controller.rotated.connect(unit.char_body.set_rotation_degrees)
	unit.char_body.set_rotation_degrees(Vector3(0, camera_controller.rotation_degrees.y, 0))
	unit.update_animation_facing(camera_controller.camera_facing_vector)
	unit.hide_debug_menu()
	unit.stat_bars_container.visible = false
	return unit


func _setup_projectile_instance() -> void:
	_projectile_instance = ProjectileEffectInstance.new()
	_projectile_instance.name = "ProjectileEffectInstance"
	effect_container.add_child(_projectile_instance)
	_projectile_instance.initialize()


func _populate_ui() -> void:
	variant_option.clear()
	variant_option.add_item("Arrow", ProjectileEffectInstance.Variant.ARROW)
	variant_option.add_item("Stone", ProjectileEffectInstance.Variant.STONE)
	variant_option.add_item("Special", ProjectileEffectInstance.Variant.SPECIAL)
	variant_option.select(1) # Default to Stone

	trajectory_option.clear()
	trajectory_option.add_item("Linear", ProjectileEffectInstance.Trajectory.LINEAR)
	trajectory_option.add_item("Parabolic", ProjectileEffectInstance.Trajectory.PARABOLIC)
	trajectory_option.select(0)

	arc_height_label.text = "%.2f" % arc_height_slider.value


func _update_positions() -> void:
	attacker_world_pos = _find_attacker_pos()
	origin_marker.position = attacker_world_pos + Vector3(0, 0.15, 0)
	target_marker.position = target_world_pos + Vector3(0, 0.15, 0)
	if attacker_unit != null:
		attacker_unit.char_body.global_position = attacker_world_pos + Vector3(0, 0.25, 0)
		# Face attacker toward target
		var face_dir: Vector3 = (target_world_pos - attacker_world_pos).normalized()
		if face_dir.length_squared() > 0.001:
			attacker_unit.update_unit_facing(face_dir)
			attacker_unit.update_animation_facing(camera_controller.camera_facing_vector)


func _update_info_display() -> void:
	var variant_names: PackedStringArray = ["Arrow", "Stone", "Special"]
	var trajectory_names: PackedStringArray = ["Linear", "Parabolic"]
	var variant_idx: int = variant_option.get_selected_id()
	var trajectory_idx: int = trajectory_option.get_selected_id()

	var attacker_pos: Vector3 = attacker_unit.char_body.global_position if attacker_unit != null else Vector3.ZERO
	var target_pos: Vector3 = target_unit.char_body.global_position if target_unit != null else Vector3.ZERO

	var text: String = ""
	text += "[b]Projectile Debug[/b]\n"
	text += "variant: %s\n" % variant_names[variant_idx]
	text += "trajectory: %s\n" % trajectory_names[trajectory_idx]
	if trajectory_idx == ProjectileEffectInstance.Trajectory.PARABOLIC:
		text += "arc height: %.2f\n" % arc_height_slider.value
	text += "distance: %.1f tiles\n" % _distance
	text += "direction: %s\n" % _vec3_str(_direction)
	text += "attacker: %s\n" % _vec3_str(attacker_pos)
	text += "target: %s\n" % _vec3_str(target_pos)
	text += "playing: %s\n" % str(_projectile_instance.is_playing() if _projectile_instance != null else false)
	info_label.text = text


# ============================================================
#  UI Callbacks
# ============================================================

func _on_variant_changed(_index: int) -> void:
	_update_info_display()


func _on_trajectory_changed(index: int) -> void:
	if index == ProjectileEffectInstance.Trajectory.PARABOLIC:
		# Handler 1 is arrow-only — force Arrow variant and disable dropdown
		variant_option.select(0) # Arrow
		variant_option.disabled = true
	else:
		variant_option.disabled = false
	_update_info_display()


func _on_arc_height_changed(value: float) -> void:
	arc_height_label.text = "%.2f" % value
	_update_info_display()


func _on_play_pressed() -> void:
	if _projectile_instance == null or attacker_unit == null or target_unit == null:
		return

	var variant: ProjectileEffectInstance.Variant = variant_option.get_selected_id() as ProjectileEffectInstance.Variant
	var trajectory: ProjectileEffectInstance.Trajectory = trajectory_option.get_selected_id() as ProjectileEffectInstance.Trajectory
	var origin_pos: Vector3 = attacker_unit.char_body.global_position
	var target_pos: Vector3 = target_unit.char_body.global_position
	_projectile_instance.loop = loop_checkbox.button_pressed
	_projectile_instance.play(origin_pos, target_pos, variant, trajectory, arc_height_slider.value)
	_update_info_display()


func _on_loop_toggled(pressed: bool) -> void:
	if _projectile_instance != null:
		_projectile_instance.loop = pressed


func _on_speed_changed(value: float) -> void:
	Engine.time_scale = value
	speed_label.text = "%.1fx" % value


func _on_direction_changed(value: float) -> void:
	direction_label.text = "%d deg" % int(value)
	var angle_rad: float = deg_to_rad(value)
	_direction = Vector3(cos(angle_rad), 0, sin(angle_rad))
	_update_positions()
	_update_info_display()


func _on_distance_changed(value: float) -> void:
	_distance = value
	distance_label.text = "%.1f tiles" % value
	_update_positions()
	_update_info_display()


func _vec3_str(v: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]


# ============================================================
#  Tile helpers
# ============================================================

## Convert a tile's raw world position to Y-mirrored world position.
func _tile_to_world(tile: TerrainTile) -> Vector3:
	var pos: Vector3 = tile.get_world_position()
	pos.y = _mesh_aabb.end.y - pos.y
	return pos


## Compute attacker position at the desired distance from target along _direction.
## No tile snapping — avoids clamping to small maps that would reduce actual distance.
func _find_attacker_pos() -> Vector3:
	var desired: Vector3 = target_world_pos - _direction * _distance
	desired.y = target_world_pos.y
	return desired
