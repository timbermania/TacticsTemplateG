extends SceneTree
## Run only through run_host_checks.py: writes synthetic config in isolated user data.

func _initialize() -> void:
	call_deferred("run_tests")

func run_tests() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or not OS.get_user_data_dir().begins_with(args[0] + "/"):
		push_error("HOST_REGRESSION: refusing non-isolated user data")
		quit(1)
		return
	var game_data = root.get_node("GameData")
	var defaults: Dictionary[String, String] = {"IMPORT_PATH": "", "ROM_PATH": "", "EXPORT_PATH": ""}
	assert(game_data._get_saved_data_paths() == defaults)
	var config_path: String = game_data.DATA_PATH_CONFIG
	for text: String in ["{}", "[]", "null", "broken", '{"IMPORT_PATH": 5}', '{"ROM_PATH": "synthetic", "extra": true}']:
		var file := FileAccess.open(config_path, FileAccess.WRITE)
		file.store_string(text)
		file.close()
		var actual: Dictionary = game_data._get_saved_data_paths()
		assert(actual.size() == 3)
		assert(actual["IMPORT_PATH"] == "")
		assert(actual["EXPORT_PATH"] == "")
		assert(actual["ROM_PATH"] == ("synthetic" if text.contains("synthetic") else ""))
		assert(FileAccess.get_file_as_string(config_path) == text)
	DirAccess.remove_absolute(config_path)
	var animation = load("res://src/file_formats/fft_animation.gd").new()
	var lifetime: WeakRef = weakref(animation)
	assert(animation.primary_anim == animation)
	assert(animation.parent_anim == animation)
	animation.primary_anim = animation
	var child_animation = load("res://src/file_formats/fft_animation.gd").new()
	child_animation.primary_anim = animation
	assert(child_animation.primary_anim == animation)
	child_animation = null
	animation = null
	assert(lifetime.get_ref() == null, "Animation must not retain itself")
	var vector_scene = load("res://src/utilities/ui/vector3i_edit.tscn")
	var vector_script = load("res://src/utilities/ui/vector3i_edit.gd")
	var bare = vector_script.new()
	assert(bare.vector == Vector3i.ZERO)
	bare.vector = Vector3i(2, -3, 4)
	assert(bare.vector == Vector3i(2, -3, 4))
	bare.free()
	var control = vector_scene.instantiate()
	control.vector = Vector3i(2, -3, 4)
	root.add_child(control)
	assert(control.vector == Vector3i(2, -3, 4))
	control.get_node("ySpinBox").value = 8
	assert(control.vector == Vector3i(2, 8, 4))
	control.free()
	print("HOST_REGRESSION: PASS")
	root.get_node("ApplicationShutdown").request_quit()
