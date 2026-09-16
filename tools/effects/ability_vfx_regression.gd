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
##
## USAGE
##   Godot --path . res://tools/effects/ability_vfx_regression.tscn -- auto [--actions=DIR]
##   Godot --path . res://tools/effects/ability_vfx_regression.tscn -- auto noplay [...]
## Exits 0 only if every arm that ran passed. Never --headless: arm B reads a framebuffer.

## The one value `RomReader.export_effects_content()` writes to and `BattleManager` reads
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

var _playback: EffectsPlayback
var _caster: Node3D
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

	_caster = Node3D.new()
	_caster.name = "Caster"
	add_child(_caster)
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
		_check(_playback.play_action_vfx_at(_caster, Vector3(0, 1.0, 0), action) != null,
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

	if control:
		_check(peak <= CONTROL_TOLERANCE_PX,
			"CONTROL drew nothing (%d changed px must be <= %d)"
				% [peak, CONTROL_TOLERANCE_PX])
	else:
		_check(peak > MIN_DREW_PX,
			"ability pixels reached the framebuffer (%d changed px must be > %d)"
				% [peak, MIN_DREW_PX])
	await _run_trap_arm(control)
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
