extends Node3D
## SCORED evidence that a real battle ABILITY draws through `addons/exmateria_effects`.
##
## `src/battle/effects_demo_scene.gd` proves the addon can put pixels on screen, but it
## plays TRAP handlers by hand — it never touches the ability route, and TRAP content is
## 660 KB while the ability route needs the 224 MB of `E###` directories. This is the
## other half: it drives `EffectsPlayback.play_action_vfx_at`, the exact call
## `Unit.use_ability` now makes, and scores the result.
##
## 🔴 A RUN WITH NO ERRORS IS NOT EVIDENCE. Both arms below exist because the two ways
## this integration fails are both silent: the cast can draw nothing (measured against a
## negative control, arm B) or draw the WRONG effect (measured against the ability data
## itself, arm A). Neither prints an error on its own.
##
## ARM A — MAPPING. Re-derives `E###` for every exported action and checks the result
##   against the data the old `vfx_data` path keyed on. Needs `--actions=<dir>` (a
##   directory of `*.action.json` from a TacticsG data export); skipped, loudly, without.
## ARM B — PIXELS. Plays one real ability and counts CHANGED pixels against a control run.
## ARM C — TRAP. Same, for the shared/TRAP handlers `show_shared_vfx` now routes here.
## ARM D — BACKGROUND. The addon's SCREEN track, driving TacticsG's own gradient
##   through `ScreenBackgroundQuad`. Measured differently from B and C on purpose —
##   see `_run_background_arm`.
##
## USAGE
##   Godot --path . res://tools/effects/ability_vfx_regression.tscn -- auto [--actions=DIR]
##   Godot --path . res://tools/effects/ability_vfx_regression.tscn -- auto noplay [...]
## Exits 0 only if every arm that ran passed. Never --headless: arms B/C/D read a
## framebuffer.

## The one value `RomReader.generate_effects_content()` writes to and `BattleManager` reads
## from. Scoring a different path than the exporter produces would be scoring nothing.
const EffectExtractPaths := preload("res://src/file_formats/vfx/effect_extract.gd")
const CONTENT_ROOT := EffectExtractPaths.CONTENT_ROOT

## One real ability, with the values its exported action actually carries. Fire is a
## bright, centred, long-lived cast — a poor choice would fail arm B for being dim
## rather than for being broken.
const PROBE_ACTION := {"unique_name": "fire", "vfx_name": "e_016", "vfx_id": 16}

## 🔴 SECONDS, not frames. The effect advances on DELTA TIME while a frame-count loop
## advances on frame rate, so the same 300-frame window covered 5s at vsync and under
## 1s unthrottled — and the arm scored a working effect as 193 changed pixels purely
## because the window closed before the cast peaked. A spell's first particle lands
## around 1.7s in and it has decayed by ~4s, so the window is wall-clock.
const SAMPLE_SECONDS: float = 6.0
## Time to let the producer reach a steady state before the baseline is taken.
const SETTLE_SECONDS: float = 1.0
## Comfortably under E016's observed ~17k peak and far above the control's noise.
const MIN_DREW_PX: int = 500
## The control is expected to be exactly 0; a few pixels of tolerance keeps the test
## from turning a renderer dither into a failure.
const CONTROL_TOLERANCE_PX: int = 50
const PIXEL_EPSILON: float = 0.02
## 🔴 A cast changes a few percent of the frame; a window resize, focus change or
## another window passing over it changes nearly ALL of it. Without this the desktop
## can fail a correct run (observed: a control run reporting 442,715 changed pixels,
## i.e. the entire sampled frame). A sample past this fraction is not evidence about
## the addon either way, so it re-baselines and says so rather than scoring it.
const DISTURBANCE_FRACTION: float = 0.5
## Hit clouds — the handler almost every physical attack in the game resolves to.
const TRAP_PROBE_HANDLER: int = 2
const TRAP_PROBE_ELEMENT: int = 1
## Trap handlers are short and immediate; they need nothing like a spell's wind-up.
const TRAP_SAMPLE_SECONDS: float = 2.5
## Far enough from (0,0,0) that a cast placed at either one is unmistakably separated
## on screen, and both stay in frame so neither can win by being the only thing visible.
const CASTER_ORIGIN_OFFSET := Vector3(2.2, 0.0, 0.0)
## The cast must land nearer the caster than the origin by at least this ratio.
const POSITION_MARGIN: float = 1.5

## ARM D. Two colours far apart in every channel, so a top/bottom swap (the corner
## ordering is the one thing about this gradient that is easy to get backwards and
## impossible to see in a log) fails the orientation check instead of passing it.
const BG_TOP := Color(0.10, 0.06, 0.30)
const BG_BOTTOM := Color(0.75, 0.45, 0.20)
## The sampled background patch: the top eighth of the frame, full width. Chosen to
## sit clear of the cast, which plays around the centre — this arm must score the
## BACKGROUND moving, not particles wandering into the patch.
const BG_PATCH_FRACTION: float = 0.125
## E016's screen track peaks well above this; the control sits at zero. Calibrated
## against a measured run, not guessed — see the printed `peak_d_rgb`.
const BG_MIN_DELTA: float = 0.02
## The control's honest reading is 0.0. The tolerance covers readback rounding only.
const BG_CONTROL_TOLERANCE: float = 0.004

var _playback: EffectsPlayback
var _caster: Node3D
var _background: ScreenBackgroundQuad
var _failures: Array[String] = []
var _checks: int = 0

## `EffectsCastHost` reads these two off whatever it is handed as the battle, so this
## scene answers them exactly as `BattleManager` does.
var units: Array = []
var total_map_tiles: Dictionary = {}


func _ready() -> void:
	ProjectSettings.set_setting(
		ExMateriaEffects.EffectsContent.ROOT_SETTING, CONTENT_ROOT)

	var camera := Camera3D.new()
	camera.position = Vector3(0, 2.2, 5.0)
	camera.look_at_from_position(Vector3(0, 2.2, 5.0), Vector3(0, 1.0, 0), Vector3.UP)
	add_child(camera)

	# Stood up here, with the camera, exactly as `BattleManager._ready` does it — the
	# overlay latches its material the first time anything delivers a screen frame, so
	# attaching it later would be attaching it after the arms that matter.
	#
	# 🔴 HIDDEN UNTIL ARM D, and that is not tidiness. A full-screen gradient change
	# is precisely the shape `DISTURBANCE_FRACTION` throws away (see `_is_disturbance`),
	# so leaving it visible would make arms B and C silently re-baseline through the
	# screen track of their own cast and score the particles against a moving zero.
	# Arms B and C therefore run against the flat clear they were calibrated on, and
	# arm D — which measures the thing that guard rejects — runs last, alone, with its
	# own measure.
	_background = ScreenBackgroundQuad.attach(camera)
	_background.set_gradient(BG_TOP, BG_BOTTOM)
	_background.visible = false

	_caster = Node3D.new()
	_caster.name = "Caster"
	add_child(_caster)
	# 🔴 DELIBERATELY OFF THE ORIGIN. With the caster AT (0,0,0) this suite passed while
	# every cast in the real game spawned at the world origin, because "at the caster"
	# and "at the origin" were the same pixels. A TacticsG `Unit` is a Node3D that is
	# never moved — only its `char_body` child is — so handing the addon a Unit put
	# every effect at (0,0,0), and nothing here could see it. The offset is what makes
	# the position assertion below able to fail.
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

## Does `EffectsPlayback.effect_id_for` name the same ROM effect the old path drew?
##
## The old path resolved `Action.vfx_data`, which `GameData` loaded by `vfx_name` — so
## `vfx_name` IS the old key, and a routing that reproduces it cannot have silently
## changed which effect an ability draws. Every resolved id is then required to exist on
## disk, because a wrong-but-present directory is the failure that prints nothing.
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

		# The OLD gate, verbatim: `GameData.load_action` set `vfx_data` only when
		# `vfx_name` was non-empty, and `Unit.use_ability` drew only when it was valid.
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
		# The witness: the old key's digits must name the effect the new key picked.
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

## Plays one real ability and proves it REACHED THE FRAMEBUFFER.
##
## 🔴 The measure is CHANGED pixels against a baseline frame, not bright ones. The
## demo scene counts pixels over a brightness threshold, and that metric silently
## saturates here: this scene clears to a flat mid grey whose channels already sum
## past the threshold, so every pixel counts as lit before anything is cast and a
## real, visible fireball moves the count by zero. Measured this way E016 peaks at
## roughly seventeen thousand changed pixels. Change-detection also catches the
## subtractive and dark-blend effects a brightness count would score as "nothing
## drew" — which is the exact false negative this arm exists to prevent.
##
## `-- auto noplay` is the negative control: identical timing, identical measurement,
## no cast. Anything it reports is the scene settling rather than the addon, and the
## positive reading would mean nothing without it.
func _run_pixel_arm() -> void:
	var action := Action.new()
	action.unique_name = PROBE_ACTION["unique_name"]
	action.vfx_name = PROBE_ACTION["vfx_name"]
	action.vfx_id = PROBE_ACTION["vfx_id"]
	_check(EffectsPlayback.effect_id_for(action) == PROBE_ACTION["vfx_id"],
		"probe ability \"%s\" routes to E%03d" % [action.unique_name, PROBE_ACTION["vfx_id"]])

	# Settle before the baseline. The producer's first frames after `begin()` are not
	# yet steady, and a baseline taken during them makes the NEGATIVE CONTROL report
	# hundreds of changed pixels — which would leave the positive reading unanchored.
	await _settle(SETTLE_SECONDS)
	var baseline := await _grab()
	var control: bool = "noplay" in OS.get_cmdline_user_args()
	if not control:
		# The EXACT call `Unit.use_ability` makes.
		# Target expressed relative to the caster, as a real ability's would be.
		_check(_playback.play_action_vfx_at(
				_caster, _caster.global_position + Vector3(0, 1.0, 0), action) != null,
			"play_action_vfx_at spawned a cast")

	# Sampled across the whole cast, not at one guessed instant: a spell winds up for
	# roughly 100 frames before its first particle and has decayed again by 250, so a
	# single late or early reading would score a working effect as nothing.
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

	# 🔴 WHERE, not just whether. Everything above passes for a cast drawn in the wrong
	# place; this is the assertion that does not.
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

## The other half of the retirement. `ActionInstance.show_shared_vfx` used to drive
## TacticsG's own `TrapEffectInstance`; it now calls `EffectsPlayback.play_shared_vfx`,
## and that renderer has been deleted — so if this draws nothing, hit clouds and knight
## break are simply gone from the game and nothing else would say so.
func _run_trap_arm(control: bool) -> void:
	# Let the spell cast decay before re-baselining, or its tail is counted as the trap.
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


## True when a sample reflects the desktop rather than the cast. Reported, never
## silently swallowed: a run that re-baselines constantly is telling you the window is
## being interfered with and its reading should not be trusted.
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


## Wall-clock wait. Frame counts are not interchangeable with time here — see
## `SAMPLE_SECONDS`.
func _settle(seconds: float) -> void:
	var elapsed: float = 0.0
	while elapsed < seconds:
		await get_tree().process_frame
		elapsed += get_tree().root.get_process_delta_time()


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## Pixels that differ between two frames, sampled every other row and column. The
## epsilon is above the renderer's own dithering noise and far below a drawn particle.
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

## Proves the addon's SCREEN track reaches TacticsG's background.
##
## An effect is not only particles. Every `E###` also carries a screen/background
## track, and until `ScreenBackgroundQuad` existed the addon delivered every frame of
## it into a push_error ("ScreenBackground node not found in camera" — 182 of them in
## a measured run of this scene) while TacticsG drew the particle half of every spell.
## This arm is what tells "the background is driven" apart from "the background is
## there".
##
## 🔴 IT DELIBERATELY DOES NOT USE `_changed_pixels` OR `_is_disturbance`.
## `DISTURBANCE_FRACTION` discards any sample that moves more than half the frame,
## because that is what a window passing over the run looks like. A background
## gradient change is ALSO that — it moves every pixel the cast does not cover — so
## running arm D through that guard would silently re-baseline the very signal it is
## here to measure and report a working feature as zero. The guard is not widened;
## this arm measures something the guard was never written about:
##
##   D1 (CPU) — the four corner colours on the material the addon writes into must
##      leave the map's defaults during the cast, and must not move at all without one.
##   D2 (FRAMEBUFFER) — the mean colour of a patch of sky must move with them.
##
## They are two halves of one claim and neither is sufficient. D1 alone is the
## failure this whole task started from: the addon happily computes and delivers a
## gradient that nothing renders. D2 alone cannot tell a driven background from a
## screensaver — which is exactly what `DISTURBANCE_FRACTION` was added to catch. A
## D2 reading without a matching D1 reading IS interference, and the two numbers are
## printed side by side so that is visible rather than inferred.
func _run_background_arm(control: bool) -> void:
	# Only now: everything above is scored against a flat clear (see `_ready`).
	_background.visible = true
	await _settle(SETTLE_SECONDS)

	var rest := _background.corners()
	_check(rest[0].is_equal_approx(BG_TOP) and rest[1].is_equal_approx(BG_TOP)
			and rest[2].is_equal_approx(BG_BOTTOM) and rest[3].is_equal_approx(BG_BOTTOM),
		"at rest the host's two map colours sit on the addon's four corners (%s)" % [rest])

	# The overlay's own `_find_background_material()` asks the ROOT viewport for a
	# camera, which answers NOTHING while TacticsG has the battle parked in the
	# scenario editor's SubViewport — so `ScreenBackgroundQuad` hands it the material
	# directly instead. This scene cannot reproduce that parenting (its camera is in
	# the root viewport, where the addon's own lookup would have worked anyway), so
	# what it CAN check is the bypass itself: that the overlay is holding the host's
	# material and never needs to go looking. If a re-vendor renames those two
	# members this fails — which is the correct answer, because the host would then be
	# back on the lookup that cannot succeed with the editor open.
	var overlay: Node = get_tree().root.get_node_or_null(^"/root/ScreenEffectOverlay")
	_check(overlay != null and "_material" in overlay
			and overlay._material == _background.material_override,
		"the overlay is primed with the host quad's material, not a camera search")

	# The ordering quirk, checked against pixels rather than trusted: TacticsG's
	# `Gradient.colors[0]` is the BOTTOM and `[1]` the TOP, and an inverted sky is a
	# thing every layer of this would render without complaint.
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


## Mean colour of a band of sky (top of the frame) or ground (bottom), sampled the
## same way `_changed_pixels` samples — every other row and column.
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


## Largest per-channel difference. Max, not sum: it is the number a threshold can be
## reasoned about in ("this channel moved by 5% of full scale").
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
