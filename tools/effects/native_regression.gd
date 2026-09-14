extends Node3D
# test-kind: render lane-pinned; synthetic regression fixture, no private content.
const Effects = preload("res://addons/exmateria_effects/exmateria_effects.gd")
const CB = preload("res://addons/exmateria_effects/callbacks/EffectCallback.gd")
const Registry = preload("res://addons/exmateria_effects/callbacks/CallbackRegistry.gd")
var failed := false
func check(ok: bool, message: String) -> void:
	print("PROBE: %s %s" % ["ok" if ok else "FAIL", message])
	failed = failed or not ok
func _ready() -> void:
	call_deferred("run")
func run() -> void:
	check(Effects == ExMateriaEffects, "published facade load/global identity")
	var facade: Script = load("res://addons/exmateria_effects/exmateria_effects.gd")
	check(facade.get_script_constant_map().size() == 21, "all 21 public exports retained")
	check(RenderingServer.get_current_rendering_method() == "gl_compatibility", "real GL Compatibility")
	check(not ExMateriaSchema.Fold.owns(), "stock fold predicate false without override")
	check(not ExMateriaAudioEngine.ready_ok and not ExMateriaEffectSfx.ready_ok, "installed audio remains deferred/idle")
	check(ClassDB.class_exists("ExMateriaSpuStream"), "installed native SPU extension loaded")
	var cam := Camera3D.new()
	cam.name = "ProbeCamera"
	add_child(cam)
	cam.position = Vector3(0, 0, 5)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.0
	cam.current = true
	var producer := Effects.EngineFoldCompositor.new()
	add_child(producer)
	check(producer.setup_native(cam), "public native producer setup accepted")
	check(producer.native_blend and producer._fold_surface == null and cam.compositor == null, "no fold bracket allocated")
	for frame in 10:
		await get_tree().process_frame
	var pool = get_node("/root/EffectMultiMeshPool")
	check(pool.get_available_count() == 64, "pool prewarms all 64 slots")
	var slot: int = pool.borrow_slot()
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.9, 0.4, 0.15, 0.5))
	pool.set_effect_texture(slot, ImageTexture.create_from_image(image))
	var staging := Effects.UnifiedPrimStager.new()
	staging.begin(cam.global_transform.affine_inverse())
	var corners := Basis(Vector3(-10, -10, 10), Vector3(-10, -10, 10), Vector3(10, 10, 0))
	for mode in 4:
		staging.append(corners, Vector3(float(mode) - 1.5, 0, 0), Color(0.4, 0.4, 0.4, 1), Color(0, 0, 1, 1), mode, 0, float(mode))
	staging.publish(pool, slot)
	for frame in 4:
		await get_tree().process_frame
	check(producer._fold_root.get_child_count() == 4, "four synthetic blend runs materialized")
	var paths: Array[String] = []
	for carrier in producer._fold_root.get_children():
		paths.append(carrier.material_override.shader.resource_path)
		check(carrier.multimesh.instance_count == 1, "one CPU record per native carrier")
	for suffix in ["add", "mix", "sub"]:
		check(paths.has("res://addons/exmateria_effects/render/effect_native_%s.gdshader" % suffix), "native %s material selected" % suffix)
	var callback = Registry.create(10)
	add_child(callback)
	callback._create_cb_mesh(false)
	check(not callback._folded and callback._material.shader == CB.CB_SHADER_NORMAL, "callback real native additive route")
	var verts := PackedVector3Array([Vector3(-0.5,0.5,0), Vector3(0.5,0.5,0), Vector3(0,1.5,0)])
	var colors := PackedColorArray([Color.GREEN, Color.GREEN, Color.GREEN])
	var uv := PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.UP])
	var centers := PackedFloat32Array([0,0.8,0, 0,0.8,0, 0,0.8,0])
	CB._build_mesh(callback._array_mesh, callback._material, verts, colors, uv, centers)
	callback.stamp_fold_order()
	for id in [3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,26,27,30,32,36,39,56,57,91,92]:
		var c = Registry.create(id)
		check(c != null and c is CB, "registered callback %d retains base" % id)
		c.free()
	for frame in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var screenshot := get_viewport().get_texture().get_image()
	check(screenshot.save_png("user://native-probe.png") == OK, "screenshot saved")
	var background := screenshot.get_pixel(5, 5)
	for mode in 4:
		var at := cam.unproject_position(Vector3(float(mode) - 1.5, 0, 0))
		var pixel := screenshot.get_pixel(clampi(int(at.x), 0, screenshot.get_width()-1), clampi(int(at.y), 0, screenshot.get_height()-1))
		var difference := absf(pixel.r-background.r) + absf(pixel.g-background.g) + absf(pixel.b-background.b)
		check(difference > 0.12, "blend mode %d has visible framebuffer contribution %s" % [mode, pixel])
	var cb_at := cam.unproject_position(Vector3(0, 0.8, 0))
	var cb_pixel := screenshot.get_pixel(int(cb_at.x), int(cb_at.y))
	check(cb_pixel.g > 0.8 and cb_pixel.g > cb_pixel.r + 0.3, "callback triangle visible in framebuffer")
	print("PROBE: screenshot user://native-probe.png")
	pool.release_slot(slot)
	callback.queue_free()
	producer.queue_free()
	for frame in 3:
		await get_tree().process_frame
	check(pool.get_available_count() == 64, "slot released")
	print("PROBE: %s" % ["FAILED" if failed else "PASS"])
	ApplicationShutdown.request_quit(1 if failed else 0)
