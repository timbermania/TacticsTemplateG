extends Node3D
# test-kind: pixel; needs a real framebuffer. NEVER --headless.
#
## SCORED evidence that the map is (a) lit by its own ROM light data and (b) a live
## sink for the effects addon's map tint.
##
## 🔴 BOTH FEATURES FAIL SILENTLY AND NEITHER PRINTS AN ERROR WHEN IT DOES.
## A light direction with the wrong sign renders a fully-drawn, fully-plausible map
## that is lit from underneath. An unregistered tint surface makes `_recomposite`
## iterate an empty material list and discard every tint the addon computed, with no
## log line anywhere. So every arm below is a MEASUREMENT against a control, and the
## controls are the pre-change behaviour: brightness spread 0, colour shift 0.
##
## ARM A — LIGHTING. Renders the map through a flat grey palette so the framebuffer
##   IS the lighting term, and scores the spread of it. Control: the same render with
##   `lighting_enabled = false`, which is exactly the map that shipped before and
##   reads a spread of 0 by construction.
## ARM B — DIRECTIONALITY AND GOURAUD. Reduces the rig to one light with no ambient
##   and renders it pointed at the map and then away, in both shading modes. Most of
##   the map must flip its lit/unlit state (a constant flips none), and the per-vertex
##   path must light MORE of the map both ways than the per-pixel path does — the
##   interpolated-across-a-clamped-vertex band, which is the dark valley's whereabouts.
## ARM C — TINT. Pushes a known tint at `TintedSurfaces.SURFACE_MAP` and measures the
##   colour shift on MAP PIXELS. Two negative controls: the same tint on a foreign
##   surface token must move nothing, and removing the layer must return to baseline.
## ARM D — TINT ORDER. The tint folds onto the palette entry BEFORE lighting. With a
##   full-white additive tint the map must still show its lighting variation; folded
##   AFTER lighting the same tint saturates every pixel and the frame goes flat.
##
## USAGE
##   Godot --path . res://tools/effects/map_lighting_regression.tscn
## The scene quits itself. Prints `MAPLIGHT: PASS` only if every check passed, and
## saves before/after screenshots into user://. Score it with
## `run_map_lighting_checks.py`, which also checks the CHECK COUNT — a GDScript error
## kills the enclosing method, not the process, so a verdict alone can be short.

## The port re-exports the reserved SURFACE_MAP token off the shipped script, because
## a GDScript const cannot be read through the autoload node.
const TintedSurfacesPort := preload("res://addons/exmateria_effects/install/TintedSurfacesPort.gd")

## An exterior with a strong warm key light and a wide mix of face orientations —
## walls, ramps, ground and water — so arm A has real orientation variety to read and
## arm B's one light finds both a lit and an unlit half.
const PROBE_MAP_PREFIX: String = "map_001"
## A second map with a strong warm overbright key light (604, 528, 476 before the /255)
## — the value the parse-time clamp trap would silently destroy.
const OVERBRIGHT_MAP_PREFIX: String = "map_062"

## The map mesh is exported with X and Y mirrored; this matches `RomReader.export_map`
## so the harness renders the same orientation the game does.
const MAP_MIRROR := Vector3(-1.0, -1.0, 1.0)

## A background the map cannot produce, so the coverage mask cannot mistake a dark map
## pixel for sky.
const CLEAR_COLOR := Color(1.0, 0.0, 1.0)
## The flat albedo forced into every palette entry for arms A and B, so the frame IS
## the lighting term. 🔴 NOT WHITE. The light gains are gains — map_001's key light is
## 750/255 = 2.94 — so a white albedo saturates most of the map at 1.0 in BOTH the lit
## and the reversed render and flattens the very signal arm B reads. A quarter-grey
## albedo keeps `albedo x (ambient + diffuse)` inside range for the whole map.
const PROBE_ALBEDO := Color(0.25, 0.25, 0.25, 1.0)
## How close a pixel must be to `PROBE_ALBEDO` in the UNLIT probe frame to count as a
## textured map pixel.
const MASK_EPSILON: float = 0.05
## Luminance spread (max - min over the map mask) that counts as "lit". The unlit
## control reads 0.000; a real map reads an order of magnitude above this.
const MIN_LIT_SPREAD: float = 0.15
## The unlit control's honest reading is exactly 0. Tolerance covers 8-bit readback.
const CONTROL_SPREAD_TOLERANCE: float = 0.012
## Arm B renders one light with no ambient, so an unlit pixel is exactly 0.0.
const SINGLE_LIGHT_EPSILON: float = 0.01
## Fraction of the map that must change its lit/unlit state when the one light is
## reversed. A constant, or a brightness that does not read the normal, changes 0%.
const MIN_SYMMETRIC_DIFFERENCE: float = 0.60
## Each half must carry real area, or the symmetric difference would be satisfied by
## one blank frame.
const MIN_SINGLE_LIT_FRACTION: float = 0.10
## How much more of the map must be lit BOTH ways under Gouraud than under per-pixel.
## Set below the measured margin; see the note at the check itself for why the
## inequality has this sign.
const MIN_GOURAUD_OVERLAP_MARGIN: float = 0.02
## Mean per-channel colour shift over the map mask that counts as "the tint landed".
const MIN_TINT_SHIFT: float = 0.05
## A control arm's honest reading is 0; tolerance covers readback rounding only.
const TINT_CONTROL_TOLERANCE: float = 0.004
## The textured map must occupy at least this much of the frame or the arms are
## scoring sky.
const MIN_MASK_FRACTION: float = 0.05
## Owner tokens for the tint layers. Any int; they only have to be distinct.
const TINT_OWNER: int = 0x7717
## A surface token that is NOT the map. `TintedSurfaces` keys units by
## `get_instance_id()`, which is never this, so nothing else can be listening.
const FOREIGN_SURFACE: int = 0x5AFE

var _failures: Array[String] = []
var _checks: int = 0
var _camera: Camera3D
var _chunk: MapChunkNodes
var _material: ShaderMaterial
var _real_palette: PackedColorArray = []
var _mask: PackedByteArray = []
var _mask_count: int = 0
var _width: int = 0
var _height: int = 0


func check(ok: bool, message: String) -> void:
	_checks += 1
	print("MAPLIGHT: %s %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		_failures.append(message)


func _ready() -> void:
	RenderingServer.set_default_clear_color(CLEAR_COLOR)
	RomReader.rom_loaded.connect(_run, CONNECT_ONE_SHOT)
	RomReader.on_load_rom_dialog_file_selected(GameData.external_data_paths["ROM_PATH"])


func _run() -> void:
	var probe_name: String = _find_map(PROBE_MAP_PREFIX)
	check(not probe_name.is_empty(), "the ROM yielded a %s* map" % PROBE_MAP_PREFIX)
	if probe_name.is_empty():
		_finish()
		return

	var fft_map: FftMapData = RomReader.maps[probe_name]
	_chunk = fft_map.get_map_scene(MAP_MIRROR)
	add_child(_chunk)
	_material = _chunk.mesh_instance.material_override as ShaderMaterial
	check(_material != null, "the map chunk carries a ShaderMaterial")
	if _material == null:
		_finish()
		return

	# The parse is checked HERE, against the material the renderer will actually read,
	# rather than against the parser's own return value — a uniform that never reaches
	# the material is the failure mode that looks like correct code.
	_check_parse(fft_map)
	_check_overbright_survives_the_parse()
	_check_registration()

	_camera = Camera3D.new()
	add_child(_camera)
	_frame_camera(_chunk.mesh_instance.mesh.get_aabb())

	_real_palette = _material.get_shader_parameter("palettes_colors")
	await _settle(1.0)

	await _arm_a_and_b()
	await _arm_c_and_d()
	_finish()


# --- parse-side checks ---------------------------------------------------------

func _check_parse(fft_map: FftMapData) -> void:
	var lighting: MapLighting = fft_map.map_lighting
	check(lighting != null and lighting.has_directional_light(),
		"%s parsed at least one non-zero directional light" % fft_map.unique_name)
	var gains: PackedVector3Array = _material.get_shader_parameter("light_gains")
	var directions: PackedVector3Array = _material.get_shader_parameter("light_directions")
	check(gains.size() == 3 and directions.size() == 3,
		"the material carries 3 light gains and 3 light directions (%d/%d)" % [gains.size(), directions.size()])
	check(_material.get_shader_parameter("lighting_enabled") == true,
		"lighting is enabled on the material")
	check(_material.get_shader_parameter("lighting_per_vertex") == true,
		"the shading path is per-vertex Gouraud, not per-pixel")
	var unit_length: bool = true
	for direction: Vector3 in directions:
		unit_length = unit_length and absf(direction.length() - 1.0) < 0.001
	check(unit_length, "every light direction is normalised (%s)" % [directions])


## 🔴 THE CLAMP TRAP, MEASURED. A light gain is `int16 / 8` floored at 0 and NOT
## capped; MAP062's key light is (604, 528, 476), a warm ~2.4x overbright. Clamping it
## to 255 at parse time — what GaneshaDx's display path does — costs both the
## overbright and the warmth, and is invisible in every log. So the check is that a
## gain ABOVE 1.0 survives into the material, and that the channels stay unequal.
func _check_overbright_survives_the_parse() -> void:
	var name_062: String = _find_map(OVERBRIGHT_MAP_PREFIX)
	if name_062.is_empty():
		check(false, "the ROM yielded a %s* map" % OVERBRIGHT_MAP_PREFIX)
		return
	var map_062: FftMapData = RomReader.maps[name_062]
	if not map_062.is_initialized:
		map_062.init_map()
	var key: Vector3 = map_062.map_lighting.light_gains[0]
	check(is_equal_approx(key.x, 604.0 / 255.0) and is_equal_approx(key.y, 528.0 / 255.0)
			and is_equal_approx(key.z, 476.0 / 255.0),
		"%s's key light is the unclamped overbright (604, 528, 476)/255, got %s" % [name_062, key])
	check(key.x > 1.0 and key.x > key.z,
		"the gain exceeds 1.0 and stays warm — no 0-255 clamp was applied")


func _check_registration() -> void:
	var registry: Node = get_tree().root.get_node_or_null(^"/root/TintedSurfaces")
	check(registry != null, "the TintedSurfaces autoload is present")
	if registry == null:
		return
	# The registry's public surface cannot say WHICH materials it holds, and
	# `is_surface_registered(SURFACE_MAP)` is TRUE from boot whether or not anything
	# registered — that is the exact reading that made this bug invisible. So the
	# material list is read directly; a non-empty one is the only honest evidence.
	var materials: Array = registry._surface_materials.get(TintedSurfacesPort.SURFACE_MAP, [])
	check(_material in materials,
		"the chunk's material is in the SURFACE_MAP material list (%d registered)" % materials.size())


# --- ARM A + B: the lighting ---------------------------------------------------

## The framebuffer is made to BE the lighting term by forcing every palette entry to
## opaque white: `ALBEDO = 1.0 * (ambient + diffuse)`, clamped. That turns "faces of
## differing normals differ in brightness" into a number that can be read off a frame
## and compared against a control that is flat by construction.
func _arm_a_and_b() -> void:
	_set_probe_palette()

	_material.set_shader_parameter("lighting_enabled", false)
	await _settle(0.3)
	var unlit_image: Image = await _grab()
	_build_mask(unlit_image)
	check(float(_mask_count) / float(_width * _height / 4) > MIN_MASK_FRACTION,
		"the textured map covers %.1f%% of the sampled frame" % [100.0 * float(_mask_count) / float(_width * _height / 4)])
	var unlit: Dictionary = _luma_stats(unlit_image)
	print("MAPLIGHT: ARM A CONTROL (lighting off) spread=%.4f mean=%.4f" % [unlit["spread"], unlit["mean"]])
	check(unlit["spread"] <= CONTROL_SPREAD_TOLERANCE,
		"CONTROL: with lighting off every map pixel is the same brightness (spread %.4f)" % unlit["spread"])
	unlit_image.save_png("user://map-lighting-control.png")

	_material.set_shader_parameter("lighting_enabled", true)
	await _settle(0.3)
	var lit_image: Image = await _grab()
	var lit: Dictionary = _luma_stats(lit_image)
	print("MAPLIGHT: ARM A LIT spread=%.4f mean=%.4f min=%.4f max=%.4f"
		% [lit["spread"], lit["mean"], lit["min"], lit["max"]])
	check(lit["spread"] >= MIN_LIT_SPREAD,
		"faces of differing normals differ in brightness (spread %.4f >= %.3f)" % [lit["spread"], MIN_LIT_SPREAD])
	lit_image.save_png("user://map-lighting-lit.png")

	# ARM B — is the brightness actually a function of N.L, and is it sampled per
	# VERTEX? A stuck uniform, a constant, or a NORMAL that never reached the fragment
	# stage would all pass arm A: the texture is gone but geometry edges are not. So
	# this arm reduces the rig to ONE light with NO ambient — an unlit pixel is then
	# exactly 0.0 — and renders it pointed at the map and then away from it.
	var real_gains: PackedVector3Array = _material.get_shader_parameter("light_gains")
	var real_directions: PackedVector3Array = _material.get_shader_parameter("light_directions")
	var real_ambient: Vector3 = _material.get_shader_parameter("ambient_light")
	var key: Vector3 = real_directions[0]

	_material.set_shader_parameter("light_gains",
		PackedVector3Array([Vector3.ONE, Vector3.ZERO, Vector3.ZERO]))
	_material.set_shader_parameter("ambient_light", Vector3.ZERO)

	var gouraud: Dictionary = await _single_light_sets(key, true, "user://map-lighting-key")
	var per_pixel: Dictionary = await _single_light_sets(key, false, "")

	_material.set_shader_parameter("light_gains", real_gains)
	_material.set_shader_parameter("light_directions", real_directions)
	_material.set_shader_parameter("ambient_light", real_ambient)
	_material.set_shader_parameter("lighting_per_vertex", true)

	print("MAPLIGHT: ARM B single light (Gouraud): toward=%.1f%% away=%.1f%% both=%.1f%%"
		% [100.0 * gouraud["toward"], 100.0 * gouraud["away"], 100.0 * gouraud["both"]])
	var symmetric_difference: float = float(gouraud["toward"]) + float(gouraud["away"]) - 2.0 * float(gouraud["both"])
	check(symmetric_difference >= MIN_SYMMETRIC_DIFFERENCE,
		"reversing the one light flips the lit/unlit state of %.1f%% of the map (>= %.0f%%)"
			% [100.0 * symmetric_difference, 100.0 * MIN_SYMMETRIC_DIFFERENCE])
	check(float(gouraud["toward"]) >= MIN_SINGLE_LIT_FRACTION
			and float(gouraud["away"]) >= MIN_SINGLE_LIT_FRACTION,
		"both halves carry real area — brightness tracks the normal, it is not a constant")

	# 🔴 THE PER-VERTEX CLAIM, MEASURED RATHER THAN ASSERTED IN A COMMENT. Per PIXEL,
	# `max(0, N.L)` forbids a surface from being lit by a light AND by its reverse, so
	# the two lit sets are disjoint but for the N.L ~ 0 sliver. Per VERTEX the clamp
	# happens at the vertex and the hardware interpolates ACROSS it, so a face with one
	# endpoint facing the light and one facing away is partly lit in BOTH renders —
	# and that band is precisely the region where the per-pixel path would instead
	# collapse to ambient and draw the dark valley the PSX never shows. So a larger
	# overlap here is the signature of the faithful path, and it separates the two
	# modes on the same geometry and the same lights.
	print("MAPLIGHT: ARM B overlap Gouraud=%.2f%% vs per-pixel=%.2f%%"
		% [100.0 * gouraud["both"], 100.0 * per_pixel["both"]])
	check(float(gouraud["both"]) >= float(per_pixel["both"]) + MIN_GOURAUD_OVERLAP_MARGIN,
		"the default path interpolates the clamped vertex term (Gouraud overlap exceeds per-pixel by %.2f%% >= %.2f%%)"
			% [100.0 * (float(gouraud["both"]) - float(per_pixel["both"])), 100.0 * MIN_GOURAUD_OVERLAP_MARGIN])


## Render one light toward the map and then away from it, and return the fractions of
## the map mask lit in each and in both. `prefix` non-empty also saves the two frames.
func _single_light_sets(key: Vector3, per_vertex: bool, prefix: String) -> Dictionary:
	_material.set_shader_parameter("lighting_per_vertex", per_vertex)
	_material.set_shader_parameter("light_directions",
		PackedVector3Array([key, Vector3.ZERO, Vector3.ZERO]))
	await _settle(0.3)
	var toward_image: Image = await _grab()
	_material.set_shader_parameter("light_directions",
		PackedVector3Array([-key, Vector3.ZERO, Vector3.ZERO]))
	await _settle(0.3)
	var away_image: Image = await _grab()
	if not prefix.is_empty():
		toward_image.save_png(prefix + ".png")
		away_image.save_png(prefix + "-reversed.png")

	var toward_lit: int = 0
	var away_lit: int = 0
	var both_lit: int = 0
	for y: int in range(0, _height, 2):
		for x: int in range(0, _width, 2):
			if not _masked(x, y):
				continue
			var a: bool = _luma(toward_image.get_pixel(x, y)) > SINGLE_LIGHT_EPSILON
			var b: bool = _luma(away_image.get_pixel(x, y)) > SINGLE_LIGHT_EPSILON
			toward_lit += 1 if a else 0
			away_lit += 1 if b else 0
			both_lit += 1 if (a and b) else 0
	var total: float = maxf(1.0, float(_mask_count))
	return {
		"toward": float(toward_lit) / total,
		"away": float(away_lit) / total,
		"both": float(both_lit) / total,
	}


# --- ARM C + D: the tint -------------------------------------------------------

## 🔴 THIS ARM DELIBERATELY DOES NOT USE A "more than half the frame changed is
## desktop interference" GUARD. `ability_vfx_regression.gd` rejects such samples
## because a window passing over the run looks like that — but a map tint IS a change
## to every map pixel at once, so that guard would throw away the entire signal. What
## replaces it is a MASK plus two negative controls: the same tint on a surface token
## the map does not own, and the tint removed. Desktop interference would move all
## three readings; only a working registration moves exactly one.
func _arm_c_and_d() -> void:
	_material.set_shader_parameter("palettes_colors", _real_palette)

	# The before/after pair a human can actually look at: the same map, same camera,
	# with the lighting term off and on. `map-flat-before.png` is the map that shipped.
	_material.set_shader_parameter("lighting_enabled", false)
	await _settle(0.4)
	var flat_image: Image = await _grab()
	flat_image.save_png("user://map-flat-before.png")
	_material.set_shader_parameter("lighting_enabled", true)

	await _settle(0.4)
	var baseline: Image = await _grab()
	baseline.save_png("user://map-tint-baseline.png")
	var flat_shift: float = _mean_shift(flat_image, baseline)
	print("MAPLIGHT: flat-vs-lit mean colour shift over the map = %.4f" % flat_shift)
	check(flat_shift >= MIN_TINT_SHIFT,
		"the lighting term visibly changes the real, textured map (%.4f)" % flat_shift)

	# Control 1: the same tint, on a surface this map is not registered under.
	TintedSurfaces.update_layer(FOREIGN_SURFACE, TINT_OWNER, Color(1.0, 1.0, 1.0))
	await _settle(0.4)
	var foreign: Image = await _grab()
	TintedSurfaces.remove_layer(FOREIGN_SURFACE, TINT_OWNER)
	var foreign_shift: float = _mean_shift(baseline, foreign)
	print("MAPLIGHT: ARM C CONTROL (foreign surface) shift=%.4f" % foreign_shift)
	check(foreign_shift <= TINT_CONTROL_TOLERANCE,
		"CONTROL: a tint on a foreign surface token moves no map pixel (%.4f)" % foreign_shift)

	# The real thing.
	TintedSurfaces.update_layer(TintedSurfacesPort.SURFACE_MAP, TINT_OWNER, Color(1.0, 1.0, 1.0))
	await _settle(0.4)
	var tinted: Image = await _grab()
	tinted.save_png("user://map-tint-applied.png")
	var shift: float = _mean_shift(baseline, tinted)
	print("MAPLIGHT: ARM C tint shift=%.4f (control %.4f)" % [shift, foreign_shift])
	check(shift >= MIN_TINT_SHIFT,
		"a tint pushed at SURFACE_MAP shifts map pixels (%.4f >= %.3f)" % [shift, MIN_TINT_SHIFT])

	# ARM D — the ORDER. The tint above drives every palette entry to white. Folded
	# BEFORE lighting the frame is `white x (ambient + diffuse)`, which still carries
	# the whole lighting pattern; folded AFTER lighting it is `clamp(lit + 1)`, which
	# is flat white everywhere. So the spread separates the two orders outright.
	var tinted_stats: Dictionary = _luma_stats(tinted)
	print("MAPLIGHT: ARM D tinted spread=%.4f mean=%.4f" % [tinted_stats["spread"], tinted_stats["mean"]])
	check(tinted_stats["spread"] >= MIN_LIT_SPREAD,
		"the tint folds onto the palette entry BEFORE lighting: the lit variation survives a full-white tint (spread %.4f)" % tinted_stats["spread"])

	# Control 2: removing the layer must return the map to the baseline.
	TintedSurfaces.remove_layer(TintedSurfacesPort.SURFACE_MAP, TINT_OWNER)
	await _settle(0.4)
	var restored: Image = await _grab()
	var restored_shift: float = _mean_shift(baseline, restored)
	print("MAPLIGHT: ARM C CONTROL (layer removed) shift=%.4f" % restored_shift)
	check(restored_shift <= TINT_CONTROL_TOLERANCE,
		"CONTROL: removing the layer returns the map to baseline (%.4f)" % restored_shift)


# --- plumbing ------------------------------------------------------------------

func _find_map(prefix: String) -> String:
	var names: Array = RomReader.maps.keys()
	names.sort()
	for map_name: String in names:
		if map_name.begins_with(prefix):
			return map_name
	return ""


func _frame_camera(bounds: AABB) -> void:
	var center: Vector3 = bounds.get_center()
	var radius: float = bounds.size.length() * 0.6
	var eye: Vector3 = center + Vector3(0.6, 0.85, 0.9).normalized() * radius * 1.6
	_camera.look_at_from_position(eye, center, Vector3.UP)


func _set_probe_palette() -> void:
	var flat: PackedColorArray = PackedColorArray()
	flat.resize(256)
	flat.fill(PROBE_ALBEDO)
	_material.set_shader_parameter("palettes_colors", flat)


## Wall-clock, not frame counts — the same reason `ability_vfx_regression.gd` gives.
func _settle(seconds: float) -> void:
	var elapsed: float = 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_tree().root.get_process_delta_time()


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## Map coverage: the sampled pixels that are exactly `PROBE_ALBEDO` in the UNLIT probe
## frame, i.e. the TEXTURED polygons.
##
## 🔴 THE UNTEXTURED "BLACK POLYGON" CLASS IS EXCLUDED ON PURPOSE. Those faces take
## the shader's `COLOR.rgb` branch: they sample no CLUT, carry no normal of their own,
## and are emitted as Color.BLACK, so they are neither lit nor tinted and read 0.0 in
## every frame. Leaving them in the mask pins `min` at 0 forever, which makes the
## UNLIT control report a spread of 1.0 — a control that can never be flat is not a
## control. Measured: it read exactly that before this mask was narrowed.
##
## Building the mask from the UNLIT frame also matters: a mask built from a lit frame
## would silently drop the darkest faces, which are the ones these arms care about.
func _build_mask(image: Image) -> void:
	_width = image.get_width()
	_height = image.get_height()
	_mask.resize(_width * _height)
	_mask.fill(0)
	_mask_count = 0
	for y: int in range(0, _height, 2):
		for x: int in range(0, _width, 2):
			var pixel: Color = image.get_pixel(x, y)
			if absf(pixel.r - PROBE_ALBEDO.r) + absf(pixel.g - PROBE_ALBEDO.g) + absf(pixel.b - PROBE_ALBEDO.b) < MASK_EPSILON:
				_mask[y * _width + x] = 1
				_mask_count += 1


func _masked(x: int, y: int) -> bool:
	return _mask[y * _width + x] == 1


func _luma(color: Color) -> float:
	return (color.r + color.g + color.b) / 3.0


func _luma_stats(image: Image) -> Dictionary:
	var lowest: float = 1.0
	var highest: float = 0.0
	var total: float = 0.0
	for y: int in range(0, _height, 2):
		for x: int in range(0, _width, 2):
			if not _masked(x, y):
				continue
			var value: float = _luma(image.get_pixel(x, y))
			lowest = minf(lowest, value)
			highest = maxf(highest, value)
			total += value
	return {
		"min": lowest, "max": highest, "spread": highest - lowest,
		"mean": total / maxf(1.0, float(_mask_count)),
	}


## Mean per-channel absolute colour difference over MAP PIXELS ONLY.
func _mean_shift(before: Image, after: Image) -> float:
	var total: float = 0.0
	for y: int in range(0, _height, 2):
		for x: int in range(0, _width, 2):
			if not _masked(x, y):
				continue
			var a: Color = before.get_pixel(x, y)
			var b: Color = after.get_pixel(x, y)
			total += (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
	return total / maxf(1.0, float(_mask_count))


func _finish() -> void:
	if _failures.is_empty():
		print("MAPLIGHT: PASS (%d checks)" % _checks)
	else:
		print("MAPLIGHT: FAILED (%d of %d checks)" % [_failures.size(), _checks])
	get_tree().quit(0 if _failures.is_empty() else 1)
