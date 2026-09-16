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
## ARM E — CAMERA. The addon's CAMERA track, driving TacticsG's own `CameraController`
##   through `EffectCameraTrack`. Measured like D and for the same reason — see
##   `_run_camera_arm`.
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

## ARM E. The rig is built from the scene the game actually ships, not a bare Camera3D:
## the projection, the child stand-off and the starting zoom are the things under test.
const CAMERA_RIG_SCENE := preload("res://src/camera_controller.tscn")
## The addon's own view model, loaded BY PATH rather than off the facade — the probe
## pins the facade's export count at 24, so leaning on it here would couple this arm to
## that number. Used as an INDEPENDENT ORACLE for chirality: it is the addon's own
## statement of which way a PSX pose looks in Godot space.
const FACING_RESOLVER_PATH := "res://addons/exmateria_effects/camera/CinematicFacingResolver.gd"
## The addon's own active-keyframe gate, for the coverage count. The corpus question is
## "how many effects pass `has_active_keyframes()`", so the count uses that method and
## not a re-derived rule that could drift from it.
const CAMERA_DATA_PATH := "res://addons/exmateria_effects/file_model/CameraData.gd"
## Same window as arm B: E016's camera track runs ~71 effect frames (phase1 20 +
## for_each 55 + phase2 16 at 30 Hz) and the cast lives past it.
const CAM_SAMPLE_SECONDS: float = 6.0
## How long to wait for the cast to free itself and hand the camera back on its own.
## `EffectManager`'s cleanup poll caps a spell at roughly 10.5s; past that the camera
## never coming back is a REAL defect, not a slow test.
const CAM_RELEASE_TIMEOUT: float = 14.0
## Host-vs-subsystem agreement. This is not a tolerance for a conversion — the host
## writes exactly what the adapter converted — so it is float noise only. A failure
## here means `_process` fought the takeover, or the pump ran a frame behind.
const CAM_TRACK_EPSILON: float = 0.0005
## Godot units the rig's focus must actually travel. E016 pans from the rig's seeded
## pose to the target, which this scene places CASTER_ORIGIN_OFFSET away.
const CAM_MIN_FOCUS_MOVE: float = 0.5
## The restore must land on the pre-cast numbers, not near them.
const CAM_RESTORE_EPSILON: float = 0.001
## The rig never moves without a cast, and `camera.size` never drifts.
const CAM_CONTROL_TOLERANCE: float = 0.004
## PSX yaw 1024 = 90 degrees — the chirality probe's pose.
const CAM_PROBE_YAW: float = 1024.0
## E4 drives the rig two tiles sideways with no cast in the scene, so the only thing
## that can repaint the frame is the camera. Against the landmarks below that moves a
## large fraction of the sampled pixels; the return-to-baseline reading is the control.
const CAM_PIXEL_OFFSET_PSX := Vector3(56.0, 0.0, 0.0)   # 2 tiles, 28 units each
const CAM_MIN_MOVED_PX: int = 2000
const CAM_RETURN_TOLERANCE_PX: int = 50
## The previous arm's cast has to finish decaying before a before/after pixel reading
## means anything. `EffectManager` caps a spell at roughly 10.5s.
const CAM_QUIET_TIMEOUT: float = 14.0
## 🔴 THE SCENE IS OTHERWISE EMPTY, and an empty frame does not move when the camera
## does. The first cut of E4 sampled a band of flat clear colour and read 0.0000 for a
## camera that the CPU side proved had travelled 2.4 units — a false negative produced
## by measuring a part of the frame with nothing in it. These are what the camera move
## is measured AGAINST: unshaded, so no light rig is needed, and spread so a pan, an
## orbit and a zoom each repaint a different part of the frame.
const CAM_LANDMARKS: Array[Vector3] = [
	Vector3(0, 0, 0), Vector3(3, 0, 0), Vector3(-3, 0, 0),
	Vector3(0, 0, 3), Vector3(0, 0, -3),
]
const CAM_LANDMARK_SIZE := Vector3(1.6, 1.6, 1.6)

## E6. E016 (Fire) never turns the camera — its angle keyframes are `TARGET` with a zero
## yaw offset, so `_get_facing_yaw` snaps the seeded yaw onto the spoke it is already on
## and the measured `peak_yaw` is 0. That is E016 behaving correctly, and it means the
## ABSOLUTE-yaw path is untested by it. E063's phase-1 keyframe 3 is
## `DIRECT ang=[302, 3584, 0]` over 12 effect frames — a real ROM keyframe naming an
## absolute PSX yaw, which is the one source mode where the host cannot hide a chirality
## error behind a seed-relative offset.
const CAM_YAW_PROBE := {"unique_name": "e063-yaw-probe", "vfx_name": "e_063", "vfx_id": 63}
## PSX 3584 = 315 degrees. `psx_angles_to_godot_rotation` consumes yaw RAW (a camera yaw
## is an Orientation, ADR-0057), so the host rig must land on exactly this.
const CAM_YAW_TARGET_PSX: float = 3584.0
## The seed is a whole turn (the `+ 360` that keeps the 45-degree snap on the positive
## wheel), so `_wrap_yaw_shortest` takes the SHORT way: -512 PSX = -45 degrees. A yaw
## that turned the other way would read +315.
const CAM_YAW_EXPECTED_DELTA: float = -45.0
const CAM_YAW_EPSILON: float = 1.0
const CAM_YAW_SAMPLE_SECONDS: float = 5.0
## A synthetic arena, so `EffectsCastHost.arena_bounds()` answers with something other
## than the empty rect and the map-centre hand-off has a known expected value. Not
## square, so a transposed x/y would fail rather than pass.
const FAKE_MAP_TILES := Vector2i(12, 7)

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

	# `EffectsCastHost` reads this off the battle for `arena_bounds()`, which is what the
	# camera track turns into `CameraSubsystem.map_center` — see ARM E's map-centre check.
	for x in FAKE_MAP_TILES.x:
		for y in FAKE_MAP_TILES.y:
			total_map_tiles[Vector2i(x, y)] = true

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
	await _run_camera_arm(control)
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


# --- ARM E: the camera track ----------------------------------------------------

## Proves the addon's CAMERA track reaches TacticsG's own camera rig.
##
## The third track this integration computed every frame and threw away, after the
## background gradient and the map tint. `EffectInstance` builds a `CameraSubsystem`
## for any effect whose `camera.has_active_keyframes()` — not gated on `is_cinematic`,
## so ordinary spell casts have one — advances it with every other subsystem, and until
## `EffectCameraTrack` existed nothing read `current_angles` / `current_position` /
## `current_zoom`. There is no error for that, which is why this arm exists.
##
## 🔴 IT DELIBERATELY DOES NOT USE `_changed_pixels` OR `_is_disturbance`, for exactly
## the reason arm D does not: a camera move repaints nearly the whole frame, which is
## the shape `DISTURBANCE_FRACTION` throws away as desktop interference. The guard is
## not widened; this arm measures in the pairs arm D established.
##
##   E0 COVERAGE  — how many installed effects pass the addon's own
##      `has_active_keyframes()` gate, and how many carry a non-zero ROLL. The claim
##      "the camera track is wired" is worth what the corpus count says it is worth,
##      and roll is the one channel this host drops.
##   E1 CHIRALITY — a hand-derived sign check on the CONVERSION alone, with no cast in
##      it, cross-checked against the addon's own `CinematicFacingResolver._view_forward`.
##      A yaw that turns the wrong way is the likeliest first bug here and it presents
##      as "the camera went somewhere wrong", never as an error.
##   E2 CPU       — the rig's `global_position` / `rotation_degrees` / `camera.size`
##      must equal what the adapter converted from the LIVE subsystem values this frame.
##      This is the half that catches the failure the whole task started from: a host
##      value that moves without a matching subsystem value is the host's own bug, and
##      a subsystem value that moves without a matching host value is the discard.
##   E3 MOVED     — and the rig must actually have gone somewhere, against a control.
##   E4 FRAMEBUFFER — and it must have repainted the frame.
##   E5 RESTORED  — and the camera must come back, on its own, to the pre-cast numbers.
func _run_camera_arm(control: bool) -> void:
	_background.visible = false
	_run_camera_coverage()

	# The rig the game ships, not a bare Camera3D: its projection and its child
	# stand-off are two of the things under test.
	var rig: CameraController = CAMERA_RIG_SCENE.instantiate()
	add_child(rig)
	rig.global_position = Vector3.ZERO
	rig.camera.current = true
	var landmarks := _add_camera_landmarks()
	await _settle(SETTLE_SECONDS)

	# 🔴 MEASURED, NOT ASSUMED. `CameraCalibration` speaks ORTHOGRAPHIC size
	# (GODOT_CAMERA_SIZE 12.6 at zoom 4096), so whether that lands on `camera.size`
	# or has to be turned into a perspective stand-off decides the whole zoom mapping.
	# `camera_controller.tscn` ships `projection = 1` and `BattleManager`'s Orthographic
	# checkbox ships `button_pressed = true`, so the calibration lands directly — no
	# projection is forced for the duration of a cast, and none is restored.
	_check(rig.camera.projection == Camera3D.PROJECTION_ORTHOGONAL,
		"E0 the shipped rig is ORTHOGRAPHIC, so CameraCalibration's ortho size is "
		+ "the zoom mapping directly (projection=%d)" % rig.camera.projection)

	await _run_camera_chirality(rig)
	await _run_camera_pixels(rig)

	# Re-point the producer at the rig's camera and hand the rig over. Arms B-D ran on
	# the scene's own camera and are finished.
	if not _playback.begin(rig.camera):
		_fail("E camera arm: playback unavailable on the rig camera: "
			+ _playback.unavailable_reason)
		return
	_playback.camera_rig = rig

	var pre_position: Vector3 = rig.global_position
	var pre_rotation: Vector3 = rig.rotation_degrees
	var pre_zoom: float = rig.zoom
	var pre_size: float = rig.camera.size
	var pre_projection: int = rig.camera.projection
	var baseline := await _grab()

	if not control:
		var cast_action := Action.new()
		cast_action.unique_name = PROBE_ACTION["unique_name"]
		cast_action.vfx_name = PROBE_ACTION["vfx_name"]
		cast_action.vfx_id = PROBE_ACTION["vfx_id"]
		_check(_playback.play_action_vfx_at(
				_caster, _caster.global_position + Vector3(0, 1.0, 0), cast_action) != null,
			"camera arm spawned a cast")

	var track: EffectCameraTrack = _playback.camera_track()
	if not control:
		_check(track != null and track.takeovers == 1,
			"E2 the cast claimed the rig (takeovers=%d)"
				% [track.takeovers if track != null else -1])
		# `EFFECT_CTR` (69 keyframes across the corpus) anchors on the map centre, which
		# `spawn_spell_effect` never sets — it defaults to the world origin, so those
		# keyframes would frame a corner of the map instead of its middle. The host is
		# the only side that knows the arena's size, and this is the one line that
		# carries it across; without an assertion it is exactly the kind of wiring that
		# is silently absent. `FAKE_MAP_TILES` puts an arena under
		# `EffectsCastHost.arena_bounds()` so the expected centre is a known number.
		var expected_centre := Vector3(
			float(FAKE_MAP_TILES.x) * 14.0, 0.0, float(FAKE_MAP_TILES.y) * 14.0)
		_check(track != null and track._subsystem != null
				and track._subsystem.map_center.is_equal_approx(expected_centre),
			"E2 the host handed the subsystem the map centre for EFFECT_CTR (%s, expected %s)"
				% [_v3(track._subsystem.map_center) if track != null and track._subsystem != null
					else "<none>", _v3(expected_centre)])

	var drift: float = 0.0          # worst host-vs-converted-subsystem disagreement
	var stale: int = 0              # frames where the adapter read a stale subsystem
	var peak_focus: float = 0.0
	var peak_yaw: float = 0.0
	var peak_size: float = 0.0
	var peak_image: Image = null
	var samples: int = 0
	var logged: int = 0
	var elapsed: float = 0.0
	# 🔴 NO PER-FRAME PIXEL SCAN IN HERE. `_changed_pixels` walks 429k samples in
	# GDScript and costs ~78 ms a call — with one in this loop the arm sampled 77 times
	# across a 6s window instead of ~350, i.e. it watched a 30 Hz track at 13 Hz and
	# could not have caught a single-frame divergence. The framebuffer claim is E4's,
	# and E4 makes it without a cast in the scene, where it actually means something.
	while elapsed < CAM_SAMPLE_SECONDS:
		await get_tree().process_frame
		elapsed += get_tree().root.get_process_delta_time()
		if track == null or not track.is_driving():
			continue
		samples += 1
		# E2a: the adapter converted THIS frame's subsystem values, not last frame's.
		# `EffectCameraTrack` runs at process_priority 100 so it pumps after the
		# EffectInstance that advances the subsystem; without that it would publish a
		# frame-old pose, which no log would show.
		var live: Vector3 = track._subsystem.current_position
		if not live.is_equal_approx(track.last_psx_position):
			stale += 1
		# E2b: and the rig carries exactly what the adapter converted.
		drift = maxf(drift, (rig.global_position - track.last_focus).length())
		drift = maxf(drift, (rig.rotation_degrees - track.last_orbit_degrees).length())
		drift = maxf(drift, absf(rig.camera.size - track.last_ortho_size))
		var focus_travel: float = (rig.global_position - pre_position).length()
		if focus_travel > peak_focus:
			peak_focus = focus_travel
			peak_image = await _grab()   # the frame at the far end of the pan
		peak_focus = maxf(peak_focus, focus_travel)
		# Wrapped to (-180, 180]: the seed adds a whole turn to keep the subsystem's
		# 45-degree yaw snap on the positive wheel, and an unwrapped reading would
		# report that no-op as a 360-degree spin.
		peak_yaw = maxf(peak_yaw,
			absf(fposmod(rig.rotation_degrees.y - pre_rotation.y + 180.0, 360.0) - 180.0))
		peak_size = maxf(peak_size, absf(rig.camera.size - pre_size))
		if logged < 6:
			logged += 1
			# 🔴 SUBSYSTEM VALUES BESIDE HOST VALUES. "No errors in the log" is never
			# evidence; two columns that track each other is.
			print(("[AbilityVfx]   E2 f%-3d SUBSYS pos=%s ang=%s zoom=%.0f"
				+ "  ->  HOST pos=%s rot=%s size=%.3f")
				% [samples, _v3(track.last_psx_position), _v3(track.last_psx_angles),
					track.last_psx_zoom, _v3(rig.global_position),
					_v3(rig.rotation_degrees), rig.camera.size])

	# `samples` is how many times this loop CAUGHT the track driving, not how many
	# effect frames ran — the loop samples at render rate and the track advances on a
	# fixed 30 Hz clock. It bounds the evidence, not the effect.
	print(("[AbilityVfx] ARM E CAMERA%s samples_driving=%d drift=%.6f stale=%d "
		+ "peak_focus=%.3f peak_yaw=%.2f peak_size=%.3f")
		% [" (CONTROL, no cast)" if control else "", samples, drift, stale,
			peak_focus, peak_yaw, peak_size])
	var suffix: String = "-control" if control else ""
	if peak_image != null:
		peak_image.save_png("user://ability-vfx-camera%s.png" % suffix)
		print("[AbilityVfx] screenshot user://ability-vfx-camera%s.png" % suffix)

	if control:
		_check(track == null or track.takeovers == 0,
			"CONTROL nothing claimed the camera (takeovers=%d)"
				% [track.takeovers if track != null else 0])
		_check(rig.global_position.is_equal_approx(pre_position)
				and rig.rotation_degrees.is_equal_approx(pre_rotation)
				and absf(rig.camera.size - pre_size) <= CAM_CONTROL_TOLERANCE,
			"CONTROL the rig never moved (pos %s rot %s size %.3f)"
				% [_v3(rig.global_position), _v3(rig.rotation_degrees), rig.camera.size])
		var drifted := _changed_pixels(baseline, await _grab())
		_check(drifted <= CONTROL_TOLERANCE_PX,
			"CONTROL the frame is unchanged (%d <= %d px)"
				% [drifted, CONTROL_TOLERANCE_PX])
		_free_all(landmarks)
		rig.queue_free()
		return

	_check(samples > 0, "E2 the track drove the rig at all (%d samples)" % samples)
	_check(stale == 0,
		"E2 every applied pose came from the LIVE subsystem, not a frame behind "
		+ "(%d stale of %d)" % [stale, samples])
	_check(drift <= CAM_TRACK_EPSILON,
		"E2 the rig carries exactly the converted subsystem pose (worst drift %.6f <= %.6f)"
			% [drift, CAM_TRACK_EPSILON])
	_check(peak_focus > CAM_MIN_FOCUS_MOVE,
		"E3 a real cast moved the camera (%.3f > %.3f units of focus travel)"
			% [peak_focus, CAM_MIN_FOCUS_MOVE])

	# E5. The cast frees itself when the spell ends and `camera_finished` fires from its
	# `_exit_tree`; the camera must come back WITHOUT this test asking for it.
	var waited: float = 0.0
	while waited < CAM_RELEASE_TIMEOUT and track != null and track.is_driving():
		await get_tree().process_frame
		waited += get_tree().root.get_process_delta_time()
	_check(track == null or not track.is_driving(),
		"E5 the cast handed the camera back on its own within %.0fs (waited %.1fs)"
			% [CAM_RELEASE_TIMEOUT, waited])
	if track != null and track.is_driving():
		track.release()   # so the restore assertions below still mean something
	_check(not rig.is_effect_driven(), "E5 the rig is no longer in a driven state")
	print("[AbilityVfx]   E5 pre=%s/%s/%.3f  post=%s/%s/%.3f"
		% [_v3(pre_position), _v3(pre_rotation), pre_size,
			_v3(rig.global_position), _v3(rig.rotation_degrees), rig.camera.size])
	_check((rig.global_position - pre_position).length() <= CAM_RESTORE_EPSILON
			and (rig.rotation_degrees - pre_rotation).length() <= CAM_RESTORE_EPSILON
			and absf(rig.zoom - pre_zoom) <= CAM_RESTORE_EPSILON
			and absf(rig.camera.size - pre_size) <= CAM_RESTORE_EPSILON
			and rig.camera.projection == pre_projection,
		"E5 the rig is back at its exact pre-cast state")

	await _run_camera_yaw_arm(rig)
	_free_all(landmarks)
	rig.queue_free()


## E0. Count what the claim is actually worth, using the ADDON'S OWN GATE.
##
## All 401 `camera.json` files carry 59 fixed keyframe slots per table, so "every effect
## has a camera track" is true of the table and says nothing about the content. The real
## gate is `CameraData.has_active_keyframes()` (`max_keyframe > 0` on any table), and
## the equivalent number for the SCREEN track looked like "all 401" until inspected.
func _run_camera_coverage() -> void:
	var camera_data_script: Script = load(CAMERA_DATA_PATH)
	if camera_data_script == null:
		_fail("E0: cannot load " + CAMERA_DATA_PATH)
		return
	var dir := DirAccess.open(EffectExtractPaths.EFFECTS_DIR)
	if dir == null:
		print("[AbilityVfx] ARM E0 COVERAGE: SKIPPED — no content at "
			+ EffectExtractPaths.EFFECTS_DIR)
		return
	var total := 0
	var active := 0
	var rolled: Array[String] = []
	var inactive: Array[String] = []
	for effect_name: String in dir.get_directories():
		var path: String = EffectExtractPaths.EFFECTS_DIR.path_join(effect_name).path_join(
			"camera.json")
		if not FileAccess.file_exists(path):
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) != TYPE_DICTIONARY:
			continue
		total += 1
		var data: Variant = camera_data_script.from_json(parsed)
		if not data.has_active_keyframes():
			inactive.append(effect_name)
			continue
		active += 1
		# ROLL, the one channel this host drops: `psx_angles_to_godot_rotation` returns
		# z = 0 and `CameraController` has no roll axis. A whole turn is the identity, so
		# it is not a roll — E242's only non-zero roll component is exactly 4096.
		for table_name: String in ["phase1", "for_each", "phase2"]:
			var table: Variant = data.get_table(table_name)
			if table == null or table.max_keyframe <= 0:
				continue
			for i in range(table.max_keyframe + 1):
				var kf: Variant = table.get_keyframe(i)
				if kf == null or (kf.channel_mask & 1) == 0:
					continue
				if absf(fposmod(float(kf.angle.z) + 2048.0, 4096.0) - 2048.0) > 1.0:
					if not rolled.has(effect_name):
						rolled.append(effect_name)
	print("[AbilityVfx] ARM E0 COVERAGE %d/%d effects pass has_active_keyframes(); "
		% [active, total] + "%d carry a real ROLL %s; inactive: %s"
		% [rolled.size(), str(rolled), str(inactive)])
	_check(total > 0 and active > 0,
		"E0 the installed corpus has camera tracks to drive (%d of %d)" % [active, total])
	# 🔴 E000 IS ONE OF THE INACTIVE ONES, and it is not an academic entry: fifteen
	# physical abilities (Attack, the Breaks, the Aims, Throw Stone, Accumulate, Seal
	# Evil) resolve to E000. Basic attacks get no camera track, by the ROM's own data.
	_check(inactive.has("E000"),
		"E0 E000 — the effect every physical attack resolves to — has NO camera track, "
		+ "so a plain Attack must not move the camera")


## E1. Which way does a PSX yaw turn in Godot space?
##
## Hand-derived, then cross-checked against the addon. For pitch 0 and PSX yaw 1024
## (= 90 degrees), `psx_angles_to_godot_rotation` gives a Godot euler of (0, 90, 0), so
## the rig's forward (`basis * -Z`) is (-1, 0, 0): the camera looks down world -X, which
## puts the EYE at +X of the focus and world +Z on the camera's LEFT. A yaw that turned
## the other way would put it on the right — and nothing in the engine would complain.
##
## 🔴 THIS RUNS WITH NO CAST IN IT. The conversion is the thing under test, so it is
## driven through `EffectCameraTrack.apply_pose` directly. An arm that could only reach
## the conversion through a real effect would be scoring the effect.
func _run_camera_chirality(rig: CameraController) -> void:
	var track := EffectCameraTrack.new(rig)
	add_child(track)
	_check(rig.begin_effect_takeover(), "E1 the rig accepts a takeover")
	track.apply_pose(Vector3.ZERO, Vector3(0.0, CAM_PROBE_YAW, 0.0), 4096.0)
	await get_tree().process_frame

	var forward: Vector3 = (rig.camera.global_transform.basis * Vector3(0, 0, -1)).normalized()
	_check(forward.is_equal_approx(Vector3(-1, 0, 0)),
		"E1 PSX yaw %.0f looks down world -X (forward %s)" % [CAM_PROBE_YAW, _v3(forward)])

	# The addon's own view model, as an independent oracle: if the host applied the pose
	# to the wrong node, in the wrong units, or with the wrong euler order, these differ.
	var resolver_script: Script = load(FACING_RESOLVER_PATH)
	if resolver_script != null:
		var resolver: Variant = resolver_script.new(rig, Callable())
		var addon_forward: Vector3 = resolver._view_forward(0.0, CAM_PROBE_YAW)
		_check(forward.is_equal_approx(addon_forward),
			"E1 the host rig points exactly where the ADDON's own CinematicFacingResolver "
			+ "says that pose looks (%s vs %s)" % [_v3(forward), _v3(addon_forward)])

	# And the same claim in screen space, which is what a wrong-way yaw actually looks
	# like: a landmark at world +Z must land LEFT of centre.
	var marker := Node3D.new()
	add_child(marker)
	marker.global_position = Vector3(0, 0, 1)
	await get_tree().process_frame
	var cam := get_viewport().get_camera_3d()
	_check(cam == rig.camera, "E1 the rig's camera is the one rendering")
	var at_marker: Vector2 = rig.camera.unproject_position(marker.global_position)
	var centre: Vector2 = Vector2(get_viewport().get_visible_rect().size) * 0.5
	_check(at_marker.x < centre.x,
		"E1 world +Z lands LEFT of centre at PSX yaw %.0f (x %.1f < %.1f) — the yaw "
			% [CAM_PROBE_YAW, at_marker.x, centre.x] + "turns the way the ROM means")

	# The seed round-trip: the inverse conversions `EffectCameraTrack` seeds a subsystem
	# with must return the pose the forward conversions just produced. A mismatched pair
	# would drift a little further from the player's camera on every cast.
	var psx_back := Vector3(
		ExMateriaPlatform.PsxMagnitude.deg_to_angle(-rig.rotation_degrees.x),
		ExMateriaPlatform.PsxMagnitude.deg_to_angle(rig.rotation_degrees.y),
		0.0)
	_check(is_equal_approx(fposmod(psx_back.y, 4096.0), fposmod(CAM_PROBE_YAW, 4096.0))
			and absf(psx_back.x) < 0.001,
		"E1 the inverse conversion round-trips the pose (%s -> %s)"
			% [_v3(Vector3(0.0, CAM_PROBE_YAW, 0.0)), _v3(psx_back)])
	_check(is_equal_approx(
			ExMateriaPlatform.CameraCalibration.ortho_size_to_zoom(rig.camera.size), 4096.0),
		"E1 zoom round-trips through CameraCalibration (size %.4f)" % rig.camera.size)

	rig.end_effect_takeover()
	marker.queue_free()
	track.queue_free()


## E6. The ABSOLUTE-yaw path, through a real cast. See `CAM_YAW_PROBE`.
##
## 🔴 THIS IS THE "KNOWN ASYMMETRIC CAST" HALF OF THE CHIRALITY QUESTION. E1 proves the
## conversion points the rig where the addon's own view model says it should; this
## proves a ROM keyframe carrying an absolute PSX yaw arrives at the host as exactly its
## degree equivalent, turning the short way — the failure mode being a camera that turns
## the wrong way, which never produces an error, only a wrong shot.
func _run_camera_yaw_arm(rig: CameraController) -> void:
	var dir: String = ExMateriaEffects.EffectsContent.effect_dir(
		"E%03d" % CAM_YAW_PROBE["vfx_id"])
	if dir.is_empty() or not DirAccess.dir_exists_absolute(dir):
		print("[AbilityVfx] ARM E6 YAW: SKIPPED — no content at " + dir)
		return
	await _await_quiet_frame()
	var pre_rotation: Vector3 = rig.rotation_degrees
	var pre_position: Vector3 = rig.global_position
	var action := Action.new()
	action.unique_name = CAM_YAW_PROBE["unique_name"]
	action.vfx_name = CAM_YAW_PROBE["vfx_name"]
	action.vfx_id = CAM_YAW_PROBE["vfx_id"]
	_check(_playback.play_action_vfx_at(
			_caster, _caster.global_position + Vector3(0, 1.0, 0), action) != null,
		"E6 the yaw probe spawned a cast")
	var track: EffectCameraTrack = _playback.camera_track()

	var extreme: float = 0.0      # signed, largest-magnitude wrapped yaw delta seen
	var best_landing: float = 999.0
	var subsystem_yaw_at_landing: float = 0.0
	var elapsed: float = 0.0
	while elapsed < CAM_YAW_SAMPLE_SECONDS:
		await get_tree().process_frame
		elapsed += get_tree().root.get_process_delta_time()
		if track == null or not track.is_driving():
			continue
		var delta: float = fposmod(
			rig.rotation_degrees.y - pre_rotation.y + 180.0, 360.0) - 180.0
		if absf(delta) > absf(extreme):
			extreme = delta
		# Where the host yaw sits against the keyframe's absolute PSX yaw, in degrees.
		var landing: float = absf(fposmod(
			rig.rotation_degrees.y
			- ExMateriaPlatform.PsxMagnitude.angle_to_deg(CAM_YAW_TARGET_PSX)
			+ 180.0, 360.0) - 180.0)
		if landing < best_landing:
			best_landing = landing
			subsystem_yaw_at_landing = track.last_psx_angles.y

	print(("[AbilityVfx] ARM E6 YAW extreme_delta=%+.2f deg (expected %+.2f) "
		+ "closest_to_PSX_%.0f=%.3f deg  subsystem_yaw_there=%.1f")
		% [extreme, CAM_YAW_EXPECTED_DELTA, CAM_YAW_TARGET_PSX, best_landing,
			subsystem_yaw_at_landing])
	_check(absf(extreme - CAM_YAW_EXPECTED_DELTA) <= CAM_YAW_EPSILON,
		"E6 a real DIRECT yaw keyframe turned the host rig %+.2f deg, the short way, "
			% extreme + "as the ROM's %.0f asks (expected %+.2f +/- %.1f)"
			% [CAM_YAW_TARGET_PSX, CAM_YAW_EXPECTED_DELTA, CAM_YAW_EPSILON])
	_check(best_landing <= CAM_YAW_EPSILON,
		"E6 and it landed on the degree equivalent of PSX %.0f (%.3f deg off, <= %.1f) "
			% [CAM_YAW_TARGET_PSX, best_landing, CAM_YAW_EPSILON]
		+ "— the yaw is consumed RAW, not negated")
	_check(is_equal_approx(fposmod(subsystem_yaw_at_landing, 4096.0),
			fposmod(CAM_YAW_TARGET_PSX, 4096.0)),
		"E6 and the SUBSYSTEM said so too (%.1f PSX) — the host did not arrive there "
			% subsystem_yaw_at_landing + "on its own")

	var waited: float = 0.0
	while waited < CAM_RELEASE_TIMEOUT and track != null and track.is_driving():
		await get_tree().process_frame
		waited += get_tree().root.get_process_delta_time()
	if track != null and track.is_driving():
		track.release()
	_check((rig.rotation_degrees - pre_rotation).length() <= CAM_RESTORE_EPSILON
			and (rig.global_position - pre_position).length() <= CAM_RESTORE_EPSILON,
		"E6 and the turn was given back (rot %s -> %s)"
			% [_v3(pre_rotation), _v3(rig.rotation_degrees)])


## E4. The camera against the FRAMEBUFFER, with no cast in the scene.
##
## 🔴 IT DELIBERATELY DOES NOT USE `_is_disturbance`. A camera move repaints most of the
## frame, which is precisely the shape `DISTURBANCE_FRACTION` discards as a window
## passing over the run — putting this through that guard would re-baseline the signal
## and report a working camera as zero, the same trap arm D documents. What makes the
## reading trustworthy instead is that it is its own control: the rig is driven off its
## mark, measured, released, and measured again. A desktop disturbance does not politely
## undo itself when `end_effect_takeover()` is called.
##
## 🔴 AND IT DOES NOT USE A CAST. A live spell repaints the frame with particles whether
## or not the camera moved, so a pixel reading taken during one cannot tell "the camera
## moved" from "a fireball drew". The pose is pushed straight through
## `EffectCameraTrack.apply_pose` instead, which is the same seam the live pump uses.
func _run_camera_pixels(rig: CameraController) -> void:
	var track := EffectCameraTrack.new(rig)
	add_child(track)
	# 🔴 AGAINST A QUIESCENT FRAME, and this is not politeness. The first cut of this
	# arm took its baseline while arm D's cast was still decaying, so BOTH readings
	# carried the particles' own churn — 66k px for the camera move and 56k px for the
	# release that should have read zero. A before/after pixel claim is only about the
	# camera if nothing else in the frame is moving.
	var quiet_seconds := await _await_quiet_frame()
	var baseline := await _grab()
	_check(quiet_seconds >= 0.0,
		"E4 the frame went quiet before measuring (settled in %.1fs)" % quiet_seconds)
	_check(rig.begin_effect_takeover(), "E4 the rig accepts the pixel-arm takeover")
	# Same pose the rig already holds, shifted two tiles: only the camera can have
	# repainted anything.
	track.apply_pose(CAM_PIXEL_OFFSET_PSX,
		Vector3(ExMateriaPlatform.PsxMagnitude.deg_to_angle(-rig.rotation_degrees.x),
			0.0, 0.0),
		ExMateriaPlatform.CameraCalibration.ortho_size_to_zoom(rig.camera.size))
	await get_tree().process_frame
	var moved_image := await _grab()
	var moved := _changed_pixels(baseline, moved_image)
	moved_image.save_png("user://ability-vfx-camera-moved.png")
	track.release()
	await get_tree().process_frame
	var returned := _changed_pixels(baseline, await _grab())
	print("[AbilityVfx] ARM E4 PIXELS moved=%d/%d px returned=%d px"
		% [moved, _sampled_total, returned])
	print("[AbilityVfx] screenshot user://ability-vfx-camera-moved.png")
	_check(moved > CAM_MIN_MOVED_PX,
		"E4 driving the rig repainted the frame (%d changed px must be > %d)"
			% [moved, CAM_MIN_MOVED_PX])
	_check(returned <= CAM_RETURN_TOLERANCE_PX,
		"E4 releasing it put the frame back (%d changed px must be <= %d) — which a "
			% [returned, CAM_RETURN_TOLERANCE_PX]
		+ "desktop disturbance would not do")
	track.queue_free()


## Block until two consecutive frames are the same to within the return tolerance, so a
## before/after pixel reading is about the thing under test and not about whatever the
## previous arm left decaying. Returns the seconds waited, or -1.0 if it never settled —
## which is a real answer ("this reading is not trustworthy"), not a silent pass.
func _await_quiet_frame() -> float:
	var waited: float = 0.0
	var previous := await _grab()
	while waited < CAM_QUIET_TIMEOUT:
		await get_tree().process_frame
		waited += get_tree().root.get_process_delta_time()
		var current := await _grab()
		if _changed_pixels(previous, current) <= CAM_RETURN_TOLERANCE_PX:
			return waited
		previous = current
	return -1.0


## Something for a camera move to move. See `CAM_LANDMARKS`.
func _add_camera_landmarks() -> Array[Node3D]:
	var mesh := BoxMesh.new()
	mesh.size = CAM_LANDMARK_SIZE
	var made: Array[Node3D] = []
	for i in CAM_LANDMARKS.size():
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# Distinct per landmark, so a MIRRORED view is not pixel-identical to a correct
		# one — a chirality error that swapped left for right would otherwise be
		# invisible to a change count over a symmetric arrangement.
		material.albedo_color = Color.from_hsv(float(i) / float(CAM_LANDMARKS.size()), 0.85, 0.95)
		var box := MeshInstance3D.new()
		box.mesh = mesh
		box.material_override = material
		add_child(box)
		box.global_position = CAM_LANDMARKS[i]
		made.append(box)
	return made


func _free_all(nodes: Array[Node3D]) -> void:
	for node: Node3D in nodes:
		if is_instance_valid(node):
			node.queue_free()


func _v3(v: Vector3) -> String:
	return "(%.2f,%.2f,%.2f)" % [v.x, v.y, v.z]


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
