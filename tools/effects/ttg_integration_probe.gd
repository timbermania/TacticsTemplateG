extends Node3D
# test-kind: logic; a synthetic fixture for the places where TacticsG meets the effects
# addon, with no ROM and no battle.
#
# A SCENE, not `--script`: under `--script` no autoloads register, so any script naming one
# reports a broken host whether or not it is broken. And `load()` is not a parse check — a
# script with a parse error still returns non-null, so every check asserts a SYMBOL or a
# BEHAVIOUR, never a handle.

var failed: bool = false


func check(ok: bool, message: String) -> void:
	print("PROBE: %s %s" % ["ok" if ok else "FAIL", message])
	failed = failed or not ok


func _ready() -> void:
	call_deferred("run")


func run() -> void:
	var host_script: GDScript = load("res://src/battle/effects_cast_host.gd")
	var play_script: GDScript = load("res://src/battle/effects_playback.gd")
	check(host_script != null and host_script.can_instantiate(), "cast host compiles and is instantiable")
	check(play_script != null and play_script.can_instantiate(), "playback compiles and is instantiable")

	# Runtime local, not a `const preload`: `get_script_constant_map()` on the façade const
	# is a PARSE error, which takes the whole probe down rather than failing one check.
	var facade: Script = load("res://addons/exmateria_effects/exmateria_effects.gd")
	var exports: Dictionary = facade.get_script_constant_map()
	for n in ["CastHost", "AbilityVisual", "EffectManager", "EngineFoldCompositor", "EffectsContent"]:
		check(exports.has(n), "facade exports " + n)
	check(exports.size() == 24, "facade export count is 24 (got %d)" % exports.size())

	# All of these get called during teardown, when the battle is already gone, so each
	# must answer something empty rather than throw.
	var host = host_script.new(null)
	check(host.actors().is_empty(), "actors() on a dead stage is empty, not a crash")
	check(host.arena_bounds() == Rect2i(), "arena_bounds() on a dead stage is the empty rect")
	check(host.actor_element_id(null) == 0, "actor_element_id defaults to 0")
	check(host.diagnostic_label() == "", "diagnostic_label is empty with no battle")
	host.note_cast(1, 2, "E005")
	check(host.casts == [[1, 2, "E005"]], "note_cast records, and does not print by default")

	# The addon asks for an element ID, which TacticsG computes from its own bitfield; no
	# name exists on this side, so an array-of-names interface could not be met.
	var expected := {
		Action.ElementTypes.FIRE: 1, Action.ElementTypes.LIGHTNING: 2,
		Action.ElementTypes.ICE: 3, Action.ElementTypes.WIND: 4,
		Action.ElementTypes.EARTH: 5, Action.ElementTypes.WATER: 6,
		Action.ElementTypes.HOLY: 7, Action.ElementTypes.DARK: 8,
	}
	var disagreed: Array = []
	for element: int in expected:
		if TrapEffectData.element_type_to_trap_id(element) != expected[element]:
			disagreed.append(element)
	check(disagreed.is_empty(), "all eight TacticsG elements equal the addon's 1-8")
	check(TrapEffectData.element_type_to_trap_id(Action.ElementTypes.NONE) == 0, "NONE is element 0")

	# The addon's own table must still agree, or the two drifted apart upstream.
	check(ExMateriaEffects.AbilityVisual.ELEMENT_NAME_TO_ID["Fire"] == 1
		and ExMateriaEffects.AbilityVisual.ELEMENT_NAME_TO_ID["Dark"] == 8,
		"the addon's own element table still ends at the same two anchors")

	# An id past the table is ABSENT, not a half-built visual.
	check(host.ability_visual(-1).is_empty(), "a negative ability id is absent")
	check(host.ability_visual(1 << 20).is_empty(), "an out-of-range ability id is absent")

	# Playback refuses loudly rather than rendering nothing.
	var play = play_script.new()
	add_child(play)
	# Defaults OFF: a bare EffectsPlayback draws nothing until an owner opts it in, so a
	# scene that forgets fails loudly through `unavailable_reason` below.
	check(not play.enabled, "playback is OPT-IN: it builds nothing until an owner enables it")
	check(not play.begin(null), "begin() refuses while disabled")
	check(play.unavailable_reason.begins_with("disabled"), "refusal states a reason: " + play.unavailable_reason)
	check(not play.is_available(), "no manager exists after a refusal")
	play.enabled = true
	check(not play.begin(null), "begin() still refuses with no battle_manager")
	check(play.unavailable_reason.begins_with("no battle"), "second refusal names the battle: " + play.unavailable_reason)
	play.battle_manager = self
	check(not play.begin(null), "begin() refuses a null camera rather than calling setup_native")
	check(play.unavailable_reason.begins_with("no camera"), "third refusal names the camera: " + play.unavailable_reason)

	# With a content root, an in-tree camera and a battle, `begin()` must reach a CHECKED
	# `setup_native()` — the arm that catches "installed but renders nothing".
	var previous_root: String = str(ProjectSettings.get_setting(
		ExMateriaEffects.EffectsContent.ROOT_SETTING, ""))
	ProjectSettings.set_setting(ExMateriaEffects.EffectsContent.ROOT_SETTING, "res://tools/effects/")
	var camera := Camera3D.new()
	add_child(camera)
	var began: bool = play.begin(camera)
	check(began, "begin() reaches CHECKED setup_native and succeeds: " + play.unavailable_reason)
	check(play.is_available() == began, "is_available() agrees with what begin() returned")
	if began:
		check(play.manager() != null, "an EffectManager exists over the TacticsG host")
		play.end()
		check(not play.is_available(), "end() tears the manager back down")
	ProjectSettings.set_setting(ExMateriaEffects.EffectsContent.ROOT_SETTING, previous_root)
	camera.queue_free()

	# The renderers must be absent while the data/exporter layer survives: `VisualEffectData`
	# is the only in-repo path from a ROM to effect content.
	check(not ResourceLoader.exists("res://src/file_formats/vfx/trap_effect_instance.gd"),
		"TacticsG's own TRAP renderer is retired — the addon draws these now")
	check(not ResourceLoader.exists("res://src/file_formats/vfx/vfx_effect_instance.gd"),
		"TacticsG's own spell VFX renderer is retired — the addon draws these now")
	check(ResourceLoader.exists("res://src/file_formats/vfx/visual_effect_data.gd"),
		"the VFX DATA model survives the renderer's retirement (ROM export still works)")
	check(ResourceLoader.exists("res://src/file_formats/vfx/vfx_constants.gd"),
		"VfxConstants survives — units and shadows read DepthMode.UNIT from it")
	check(ResourceLoader.exists("res://src/file_formats/vfx/projectile_effect_instance.gd"),
		"weapon projectiles survive — the addon has no equivalent")

	print("PROBE: " + ("PASS" if not failed else "FAIL"))
	get_tree().quit(1 if failed else 0)
