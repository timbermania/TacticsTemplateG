extends SceneTree

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		quit(1)
		return
	var file := FileAccess.open(args[0], FileAccess.WRITE)
	if file == null:
		quit(1)
		return
	file.store_string("Godot " + Engine.get_version_info()["string"] + "\n\n")
	file.store_string(Engine.get_license_text() + "\n\n")
	file.store_string(JSON.stringify(Engine.get_copyright_info(), "  ") + "\n\n")
	file.store_string(JSON.stringify(Engine.get_license_info(), "  ") + "\n")
	file.close()
	quit()
