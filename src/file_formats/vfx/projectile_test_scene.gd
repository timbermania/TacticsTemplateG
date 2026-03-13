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
var target_unit: Unit
var attacker_unit: Unit
var _direction: Vector3 = Vector3(1, 0, 0)
var _distance: float = 3.0

var _projectile_instance: ProjectileEffectInstance


func _ready() -> void:
	variant_option.item_selected.connect(_on_variant_changed)
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

	# Find tile for placement
	for tile: TerrainTile in map_data.terrain_tiles:
		if tile.location == Vector2i(2, 1):
			target_world_pos = tile.get_world_position()

	# Adjust Y for Y-mirror
	target_world_pos.y = mesh_aabb.end.y - target_world_pos.y

	target_marker.position = target_world_pos + Vector3(0, 0.15, 0)
	camera_controller.position = target_world_pos


func _spawn_target_unit() -> void:
	target_unit = _spawn_unit(target_world_pos, 0x4a, 0) # Squire, palette 0


func _spawn_attacker_unit() -> void:
	var attacker_pos: Vector3 = target_world_pos - _direction * _distance
	attacker_unit = _spawn_unit(attacker_pos, 0x4a, 3) # Squire, palette 3 (different color)


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


func _update_positions() -> void:
	var origin_pos: Vector3 = target_world_pos - _direction * _distance
	origin_marker.position = origin_pos + Vector3(0, 0.15, 0)
	target_marker.position = target_world_pos + Vector3(0, 0.15, 0)
	if attacker_unit != null:
		attacker_unit.char_body.global_position = origin_pos + Vector3(0, 0.25, 0)
		# Face attacker toward target
		var face_dir: Vector3 = _direction
		attacker_unit.update_unit_facing(face_dir)
		attacker_unit.update_animation_facing(camera_controller.camera_facing_vector)


func _update_info_display() -> void:
	var variant_names: PackedStringArray = ["Arrow", "Stone", "Special"]
	var variant_idx: int = variant_option.get_selected_id()

	var attacker_pos: Vector3 = attacker_unit.char_body.global_position if attacker_unit != null else Vector3.ZERO
	var target_pos: Vector3 = target_unit.char_body.global_position if target_unit != null else Vector3.ZERO

	var text: String = ""
	text += "[b]Projectile Debug[/b]\n"
	text += "variant: %s\n" % variant_names[variant_idx]
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


func _on_play_pressed() -> void:
	if _projectile_instance == null or attacker_unit == null or target_unit == null:
		return

	var variant: ProjectileEffectInstance.Variant = variant_option.get_selected_id() as ProjectileEffectInstance.Variant
	var origin_pos: Vector3 = attacker_unit.char_body.global_position
	var target_pos: Vector3 = target_unit.char_body.global_position
	_projectile_instance.loop = loop_checkbox.button_pressed
	_projectile_instance.play(origin_pos, target_pos, variant)
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
