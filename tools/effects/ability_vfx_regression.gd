extends Node3D
## Scores a real battle ABILITY drawing through `addons/exmateria_effects`: the `E###`
## mapping, the cast's pixels, the TRAP handlers and the SCREEN track.
##
##   Godot --path . res://tools/effects/ability_vfx_regression.tscn -- auto [--actions=DIR]
##   Godot --path . res://tools/effects/ability_vfx_regression.tscn -- auto noplay [...]
##
## Arm A needs `--actions=<dir>`. Never `--headless`: arms B/C/D read a framebuffer.

## Must be the path `RomReader.generate_effects_content()` writes and `BattleManager` reads.
const EffectExtractPaths := preload("res://src/file_formats/vfx/effect_extract.gd")
const CONTENT_ROOT := EffectExtractPaths.CONTENT_ROOT

## Fire: bright, centred and long-lived, so arm B cannot fail for dimness.
const PROBE_ACTION := {"unique_name": "fire", "vfx_name": "e_016", "vfx_id": 16}

## SECONDS, not frames — the effect advances on delta time. A spell peaks ~1.7s-4s.
const SAMPLE_SECONDS: float = 6.0
## Time for the producer to reach a steady state before the baseline is taken.
const SETTLE_SECONDS: float = 1.0
const MIN_DREW_PX: int = 500
## The control's honest reading is 0; this covers renderer dither.
const CONTROL_TOLERANCE_PX: int = 50
const PIXEL_EPSILON: float = 0.02
## Above this fraction a sample is desktop interference, and is re-baselined not scored.
const DISTURBANCE_FRACTION: float = 0.5
## Hit clouds: the handler almost every physical attack resolves to.
const TRAP_PROBE_HANDLER: int = 2
const TRAP_PROBE_ELEMENT: int = 1
## Trap handlers are immediate — no spell wind-up to wait through.
const TRAP_SAMPLE_SECONDS: float = 2.5
## Far enough to separate caster and origin on screen; near enough that both stay in frame.
const CASTER_ORIGIN_OFFSET := Vector3(2.2, 0.0, 0.0)
## The cast must land nearer the caster than the origin by at least this ratio.
const POSITION_MARGIN: float = 1.5

## Far apart in every channel, so a top/bottom swap fails the orientation check.
const BG_TOP := Color(0.10, 0.06, 0.30)
const BG_BOTTOM := Color(0.75, 0.45, 0.20)
## The sampled sky patch: top eighth of the frame, clear of the centre where casts play.
const BG_PATCH_FRACTION: float = 0.125
const BG_MIN_DELTA: float = 0.02
## Covers readback rounding only; the control's honest reading is 0.0.
const BG_CONTROL_TOLERANCE: float = 0.004

var _playback: EffectsPlayback
var _caster: Node3D
var _background: ScreenBackgroundQuad
var _failures: Array[String] = []
var _checks: int = 0

## `EffectsCastHost` reads these off the battle, so the names must match `BattleManager`'s.
var units: Array = []
var total_map_tiles: Dictionary = {}


func _ready() -> void:
	ProjectSettings.set_setting(
		ExMateriaEffects.EffectsContent.ROOT_SETTING, CONTENT_ROOT)

	var camera := Camera3D.new()
	camera.position = Vector3(0, 2.2, 5.0)
	camera.look_at_from_position(Vector3(0, 2.2, 5.0), Vector3(0, 1.0, 0), Vector3.UP)
	add_child(camera)

	# Attached with the camera, as `BattleManager._ready` does — the overlay latches its
	# material on the first screen frame. Hidden until arm D, or B and C re-baseline.
	_background = ScreenBackgroundQuad.attach(camera)
	_background.set_gradient(BG_TOP, BG_BOTTOM)
	_background.visible = false

	_caster = Node3D.new()
	_caster.name = "Caster"
	add_child(_caster)
	# Off the origin, or "at the caster" and "at the origin" are the same pixels.
	_caster.position = CASTER_ORIGIN_OFFSET
	units.append(_caster)

	_playback = EffectsPlayback.new()
	_playback.enabled = true
	_playback.battle_manager = self
	_playback.content_root = CONTENT_ROOT
	add_child(_playback)

	if not "auto" in OS.get_cmdline_user_args():
		print("[AbilityVfx] interactive mode; pass `-- auto` to score.")
		return

	_run_mapping_arm()

	if not _playback.begin(camera):
		_fail("playback unavailable: " + _playback.unavailable_reason)
		_finish(false)
		return
	await _run_pixel_arm()


# --- ARM A: the mapping --------------------------------------------------------

## Does `effect_id_for` name the effect `Action.vfx_data` did? `vfx_name` was that key,
## and every resolved id must also exist on disk.
func _run_mapping_arm() -> void:
	var dir_path := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--actions="):
			dir_path = arg.substr("--actions=".length())
	if dir_path.is_empty():
		print("[AbilityVfx] ARM A MAPPING: SKIPPED — pass --actions=<dir of *.action.json>")
		return

	var dir := DirAccess.open(dir_path)
	if dir == null:
		_fail("ARM A: cannot open actions dir " + dir_path)
		return

	var drew := 0
	var routed := 0
	var missing_dir: Array[String] = []
	var disagreed: Array[String] = []
	var names := dir.get_files()
	for file_name: String in names:
		if not file_name.ends_with(".action.json"):
			continue
		var text := FileAccess.get_file_as_string(dir_path.path_join(file_name))
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		var data: Dictionary = parsed
		var action := Action.new()
		action.unique_name = str(data.get("unique_name", file_name))
		action.vfx_name = str(data.get("vfx_name", ""))
		action.vfx_id = int(data.get("vfx_id", 0))

		# The `vfx_data` gate verbatim: set only when `vfx_name` was non-empty.
		var old_drew: bool = not action.vfx_name.is_empty()
		var effect_id: int = EffectsPlayback.effect_id_for(action)
		if old_drew:
			drew += 1
		if effect_id < 0:
			if old_drew:
				disagreed.append("%s: old drew %s, new route declines"
					% [action.unique_name, action.vfx_name])
			continue
		routed += 1
		# The `vfx_name` key's digits must name the effect that was picked.
		if old_drew:
			var expected: int = _digits_of(action.vfx_name)
			if expected != effect_id:
				disagreed.append("%s: old key %s, new id E%03d"
					% [action.unique_name, action.vfx_name, effect_id])
		if not DirAccess.dir_exists_absolute(
				ExMateriaEffects.EffectsContent.effect_dir("E%03d" % effect_id)):
			missing_dir.append("%s -> E%03d" % [action.unique_name, effect_id])

	print("[AbilityVfx] ARM A MAPPING: %d actions drew under the old path, %d route now"
		% [drew, routed])
	_check(not disagreed.is_empty() == false,
		"every routed ability keeps the effect the old path drew (%d disagreements)"
			% disagreed.size())
	for d: String in disagreed.slice(0, 10):
		print("    DISAGREEMENT: " + d)
	_check(missing_dir.is_empty(),
		"every routed ability has content on disk (%d missing)" % missing_dir.size())
	for m: String in missing_dir.slice(0, 10):
		print("    MISSING CONTENT: " + m)
	_check(routed > 100, "a real ability set routed, not a handful (%d)" % routed)


func _digits_of(text: String) -> int:
	var digits := ""
	for c: String in text:
		if c >= "0" and c <= "9":
			digits += c
	return digits.to_int() if not digits.is_empty() else -1


# --- ARM B: the pixels ---------------------------------------------------------

## Plays one real ability and proves it REACHED THE FRAMEBUFFER. CHANGED pixels, not bright
## ones — the clear is already past any threshold. `-- auto noplay` is the control.
func _run_pixel_arm() -> void:
	var action := Action.new()
	action.unique_name = PROBE_ACTION["unique_name"]
	action.vfx_name = PROBE_ACTION["vfx_name"]
	action.vfx_id = PROBE_ACTION["vfx_id"]
	_check(EffectsPlayback.effect_id_for(action) == PROBE_ACTION["vfx_id"],
		"probe ability \"%s\" routes to E%03d" % [action.unique_name, PROBE_ACTION["vfx_id"]])

	# The producer's first frames after `begin()` are not steady enough to baseline on.
	await _settle(SETTLE_SECONDS)
	var baseline := await _grab()
	var control: bool = "noplay" in OS.get_cmdline_user_args()
	if not control:
		# The exact call `Unit.use_ability` makes, target relative to the caster.
		_check(_playback.play_action_vfx_at(
				_caster, _caster.global_position + Vector3(0, 1.0, 0), action) != null,
			"play_action_vfx_at spawned a cast")

	# Sampled across the whole cast: a spell winds up ~100 frames and has decayed by 250.
	var peak := 0
	var peak_image: Image = null
	var elapsed: float = 0.0
	while elapsed < SAMPLE_SECONDS:
		await get_tree().process_frame
		elapsed += get_tree().root.get_process_delta_time()
		var current := await _grab()
		var changed := _changed_pixels(baseline, current)
		if _is_disturbance(changed):
			baseline = current
			continue
		if changed > peak:
			peak = changed
			peak_image = current

	print("[AbilityVfx] ARM B PIXELS%s peak_changed_px=%d" % [
		" (CONTROL, no cast)" if control else "", peak])
	var suffix: String = "-control" if control else ""
	if peak_image != null:
		peak_image.save_png("user://ability-vfx-regression%s.png" % suffix)
	else:
		baseline.save_png("user://ability-vfx-regression%s.png" % suffix)
	print("[AbilityVfx] screenshot user://ability-vfx-regression%s.png" % suffix)

	# Where, not just whether — everything above passes for a cast in the wrong place.
	if not control and peak_image != null:
		var centroid := _changed_centroid(baseline, peak_image)
		if centroid.x >= 0.0:
			var cam := get_viewport().get_camera_3d()
			var at_caster: Vector2 = cam.unproject_position(_caster.global_position)
			var at_origin: Vector2 = cam.unproject_position(Vector3.ZERO)
			var d_caster: float = centroid.distance_to(at_caster)
			var d_origin: float = centroid.distance_to(at_origin)
			print("[AbilityVfx] ARM B WHERE centroid=%s caster=%s origin=%s d_caster=%.1f d_origin=%.1f"
				% [str(centroid), str(at_caster), str(at_origin), d_caster, d_origin])
			_check(d_origin > d_caster * POSITION_MARGIN,
				"the cast drew ON THE CASTER, not at the world origin (%.1f vs %.1f px)"
					% [d_caster, d_origin])

	if control:
		_check(peak <= CONTROL_TOLERANCE_PX,
			"CONTROL drew nothing (%d changed px must be <= %d)"
				% [peak, CONTROL_TOLERANCE_PX])
	else:
		_check(peak > MIN_DREW_PX,
			"ability pixels reached the framebuffer (%d changed px must be > %d)"
				% [peak, MIN_DREW_PX])
	await _run_trap_arm(control)
	await _run_background_arm(control)
	_finish(true)


# --- ARM C: the TRAP handlers ---------------------------------------------------

## `show_shared_vfx` has no renderer behind it but `play_shared_vfx`, so nothing else
## would report hit clouds missing.
func _run_trap_arm(control: bool) -> void:
	# Let the spell decay first, or its tail counts as the trap.
	await _settle(SAMPLE_SECONDS)
	var baseline := await _grab()
	if not control:
		_check(_playback.play_shared_vfx(
				TRAP_PROBE_HANDLER, TRAP_PROBE_ELEMENT,
				_caster.global_position + Vector3(0, 1.0, -2.0), _caster, true, true),
			"play_shared_vfx started handler %d" % TRAP_PROBE_HANDLER)
	var peak := 0
	var elapsed: float = 0.0
	while elapsed < TRAP_SAMPLE_SECONDS:
		await get_tree().process_frame
		elapsed += get_tree().root.get_process_delta_time()
		var current := await _grab()
		var changed := _changed_pixels(baseline, current)
		if _is_disturbance(changed):
			baseline = current
			continue
		peak = maxi(peak, changed)
	print("[AbilityVfx] ARM C TRAP%s peak_changed_px=%d" % [
		" (CONTROL, no cast)" if control else "", peak])
	if control:
		_check(peak <= CONTROL_TOLERANCE_PX,
			"CONTROL drew no trap (%d changed px must be <= %d)"
				% [peak, CONTROL_TOLERANCE_PX])
	else:
		_check(peak > MIN_DREW_PX,
			"trap pixels reached the framebuffer (%d changed px must be > %d)"
				% [peak, MIN_DREW_PX])


## True when a sample reflects the desktop, not the cast. Reported, since constant
## re-baselining means the reading cannot be trusted.
func _is_disturbance(changed: int) -> bool:
	if _sampled_total <= 0 or changed < int(_sampled_total * DISTURBANCE_FRACTION):
		return false
	print("[AbilityVfx] NOTE viewport disturbance (%d/%d px) — re-baselining, not scoring"
		% [changed, _sampled_total])
	return true


## Screen-space centroid of the pixels that changed, or (-1,-1) when none did.
func _changed_centroid(before: Image, after: Image) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for y in range(0, before.get_height(), 2):
		for x in range(0, before.get_width(), 2):
			var a := before.get_pixel(x, y)
			var b := after.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > PIXEL_EPSILON:
				sum += Vector2(x, y)
				n += 1
	return sum / float(n) if n > 0 else Vector2(-1.0, -1.0)


## Wall-clock wait — frame counts are not interchangeable here, see `SAMPLE_SECONDS`.
func _settle(seconds: float) -> void:
	var elapsed: float = 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_tree().root.get_process_delta_time()


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## Pixels differing between two frames, every other row and column; the epsilon sits above
## renderer dither and below a drawn particle.
var _sampled_total: int = 0


func _changed_pixels(before: Image, after: Image) -> int:
	var count := 0
	_sampled_total = 0
	for y in range(0, before.get_height(), 2):
		for x in range(0, before.get_width(), 2):
			var a := before.get_pixel(x, y)
			var b := after.get_pixel(x, y)
			_sampled_total += 1
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > PIXEL_EPSILON:
				count += 1
	return count


# --- ARM D: the background ------------------------------------------------------

## Proves the SCREEN track reaches the background. `_is_disturbance` would reject this arm's
## own signal, so it measures D1 the corner colours and D2 a patch of sky; D2 without D1 is
## interference, so both print.
func _run_background_arm(control: bool) -> void:
	# Only now: everything above is scored against a flat clear.
	_background.visible = true
	await _settle(SETTLE_SECONDS)

	var rest := _background.corners()
	_check(rest[0].is_equal_approx(BG_TOP) and rest[1].is_equal_approx(BG_TOP)
			and rest[2].is_equal_approx(BG_BOTTOM) and rest[3].is_equal_approx(BG_BOTTOM),
		"at rest the host's two map colours sit on the addon's four corners (%s)" % [rest])

	# The overlay's own lookup asks the ROOT viewport, which has no camera while the battle
	# is in the editor's SubViewport, so the material is handed over directly.
	var overlay: Node = get_tree().root.get_node_or_null(^"/root/ScreenEffectOverlay")
	_check(overlay != null and "_material" in overlay
			and overlay._material == _background.material_override,
		"the overlay is primed with the host quad's material, not a camera search")

	# `Gradient.colors[0]` is the BOTTOM, `[1]` the TOP; an inverted sky renders without
	# complaint, so it is checked against pixels.
	var sky := await _patch_mean(true)
	var ground := await _patch_mean(false)
	_check(_distance(sky, BG_TOP) < _distance(sky, BG_BOTTOM)
			and _distance(ground, BG_BOTTOM) < _distance(ground, BG_TOP),
		"the gradient is the right way up (sky %s vs top %s, ground %s vs bottom %s)"
			% [sky, BG_TOP, ground, BG_BOTTOM])

	var baseline := await _patch_mean(true)
	if not control:
		var cast_action := Action.new()
		cast_action.unique_name = PROBE_ACTION["unique_name"]
		cast_action.vfx_name = PROBE_ACTION["vfx_name"]
		cast_action.vfx_id = PROBE_ACTION["vfx_id"]
		_check(_playback.play_action_vfx_at(_caster, Vector3(0, 1.0, 0), cast_action) != null,
			"background arm spawned a cast")

	var peak_px: float = 0.0
	var peak_corner: float = 0.0
	var peak_image: Image = null
	var elapsed: float = 0.0
	while elapsed < SAMPLE_SECONDS:
		await get_tree().process_frame
		elapsed += get_tree().root.get_process_delta_time()
		var now := await _grab()
		var patch := _mean_of(now, true)
		var d_px := _distance(patch, baseline)
		if d_px > peak_px:
			peak_px = d_px
			peak_image = now
		var corners := _background.corners()
		for i in 4:
			var default_colour: Color = BG_TOP if i < 2 else BG_BOTTOM
			peak_corner = maxf(peak_corner, _distance(corners[i], default_colour))

	print("[AbilityVfx] ARM D BACKGROUND%s peak_d_rgb=%.4f peak_d_corner=%.4f"
		% [" (CONTROL, no cast)" if control else "", peak_px, peak_corner])
	var suffix: String = "-control" if control else ""
	if peak_image != null:
		peak_image.save_png("user://ability-vfx-background%s.png" % suffix)
		print("[AbilityVfx] screenshot user://ability-vfx-background%s.png" % suffix)

	if control:
		_check(peak_corner <= BG_CONTROL_TOLERANCE,
			"CONTROL never moved the gradient corners (%.4f <= %.4f)"
				% [peak_corner, BG_CONTROL_TOLERANCE])
		_check(peak_px <= BG_CONTROL_TOLERANCE,
			"CONTROL background patch is unchanged (%.4f <= %.4f)"
				% [peak_px, BG_CONTROL_TOLERANCE])
	else:
		_check(peak_corner > BG_MIN_DELTA,
			"D1 the cast drove the addon's gradient corners (%.4f > %.4f)"
				% [peak_corner, BG_MIN_DELTA])
		_check(peak_px > BG_MIN_DELTA,
			"D2 and it reached the framebuffer (%.4f > %.4f)" % [peak_px, BG_MIN_DELTA])


## Mean colour of a sky (top) or ground (bottom) band, every other row and column.
func _patch_mean(top: bool) -> Color:
	return _mean_of(await _grab(), top)


func _mean_of(image: Image, top: bool) -> Color:
	var height := image.get_height()
	var band := maxi(2, int(height * BG_PATCH_FRACTION))
	var first: int = 0 if top else height - band
	var total := Vector3.ZERO
	var count := 0
	for y in range(first, mini(first + band, height), 2):
		for x in range(0, image.get_width(), 2):
			var c := image.get_pixel(x, y)
			total += Vector3(c.r, c.g, c.b)
			count += 1
	if count == 0:
		return Color.BLACK
	total /= float(count)
	return Color(total.x, total.y, total.z, 1.0)


## Largest per-channel difference. Max, not sum, so a threshold reads as "this channel
## moved by N% of full scale".
func _distance(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))


# --- scoring -------------------------------------------------------------------

func _check(passed: bool, description: String) -> void:
	_checks += 1
	print("[AbilityVfx] %s %s" % ["PASS" if passed else "FAIL", description])
	if not passed:
		_failures.append(description)


func _fail(reason: String) -> void:
	_checks += 1
	print("[AbilityVfx] FAIL " + reason)
	_failures.append(reason)


func _finish(_ran: bool) -> void:
	print("[AbilityVfx] %d checks, %d failed" % [_checks, _failures.size()])
	if _failures.is_empty():
		print("[AbilityVfx] RESULT PASS")
	else:
		print("[AbilityVfx] RESULT FAIL")
		for f: String in _failures:
			push_error("AbilityVfx: " + f)
	get_tree().quit(0 if _failures.is_empty() else 1)
