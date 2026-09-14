extends Node
# Injected only into an isolated staged host; the actual main scene is unchanged.

func _ready() -> void:
	call_deferred("_check_startup")

func _check_startup() -> void:
	for frame in 120:
		await get_tree().process_frame
	var ok := get_tree().current_scene != null
	ok = ok and not ExMateriaAudioEngine.ready_ok and not ExMateriaEffectSfx.ready_ok
	ok = ok and ClassDB.class_exists("ExMateriaSpuStream")
	ok = ok and RenderingServer.get_current_rendering_method() == "gl_compatibility"
	ok = ok and get_node_or_null("/root/EffectMultiMeshPool") != null
	ok = ok and get_node_or_null("/root/ScreenEffectOverlay") != null
	ok = ok and get_node_or_null("/root/TintedSurfaces") != null
	print("EFFECTS_HOST_STARTUP: %s" % ["PASS" if ok else "FAIL"])
	ApplicationShutdown.request_quit(0 if ok else 1)
