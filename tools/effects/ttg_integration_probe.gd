extends Node3D
# test-kind: logic; synthetic contract fixture for the TacticsG-side Effects seams.
#
# A SCENE, not `--script`. Measured: under `--script` the engine registers NO
# autoloads, so `effects_cast_host.gd` — which legitimately names the host's
# `RomReader` — reports `Identifier not found` and `can_instantiate()` FALSE. A
# `--script` probe therefore reports a broken host whether or not it is broken.
#
# `load()` IS NOT A PARSE CHECK either: a script with a parse error still returns
# a non-null GDScript. Measured here — `effects_playback.gd` printed "loaded ok"
# in the same run the engine printed "Failed to load script ... Parse error". So
# every check asserts a SYMBOL or a BEHAVIOUR, never a non-null handle.

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

	# Loaded into a `Script`-typed local at RUNTIME, not a `const preload`: calling
	# `get_script_constant_map()` on the façade const is a PARSE error ("Cannot call
	# non-static function ... directly"), and a parse error here would take the
	# whole probe down rather than fail one check.
	var facade: Script = load("res://addons/exmateria_effects/exmateria_effects.gd")
	var exports: Dictionary = facade.get_script_constant_map()
	for n in ["CastHost", "AbilityVisual", "EffectManager", "EngineFoldCompositor", "EffectsContent"]:
		check(exports.has(n), "facade exports " + n)
	check(exports.size() == 24, "facade export count is 24 (got %d)" % exports.size())

	# Every host verb is reachable during teardown, when the battle is already
	# gone. Each must degrade rather than throw.
	var host = host_script.new(null)
	check(host.actors().is_empty(), "actors() on a dead stage is empty, not a crash")
	check(host.arena_bounds() == Rect2i(), "arena_bounds() on a dead stage is the empty rect")
	check(host.actor_element_id(null) == 0, "actor_element_id defaults to 0")
	check(host.diagnostic_label() == "", "diagnostic_label is empty with no battle")
	host.note_cast(1, 2, "E005")
	check(host.casts == [[1, 2, "E005"]], "note_cast records, and does not print by default")

	# Upstream ADR-0364 dec. 3 on a SECOND host: the addon asks for an element ID,
	# and TacticsG already computes exactly that id from its own bitfield. No name
	# exists on this side, so an array-of-names interface could not have been met.
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
	# The default is still OFF — but that no longer means "coexists with TacticsG's VFX",
	# because there is no longer a second path to coexist with. It now means a bare
	# EffectsPlayback draws nothing until an owner (BattleManager) opts it in, so a scene
	# that forgets to enable it fails loudly through `unavailable_reason` below.
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

	# THE SEAM THE DOCS SAY ONLY THE SYNTHETIC TEST REACHES. With a content root
	# declared, an in-tree camera and a battle, `begin()` must get all the way to
	# a CHECKED `setup_native()` and stand up a real manager. This is the arm that
	# would catch "installed but renders nothing", because every refusal above is
	# quiet by design.
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

	# 🔴 This assertion was INVERTED, deliberately. It used to require TacticsG's own
	# `TrapEffectInstance` to still exist, as proof that installing the addon had changed
	# nothing. That was true of the installation pass; it is false now — the addon owns
	# ability VFX and the old renderers are gone, so the old assertion would fail for the
	# right reason and hide the real one. What must hold now is that the renderers are
	# RETIRED while the data/exporter layer they were built on survives, because
	# `VisualEffectData` is still the only in-repo path from a ROM to effect content.
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

	_check_unit_tint_surface()

	print("PROBE: " + ("PASS" if not failed else "FAIL"))
	get_tree().quit(1 if failed else 0)


## 🔴 THE TOKEN IS `char_body`'s INSTANCE ID, NOT THE `Unit`'s — measured on a REAL
## `Unit`, not on a stand-in.
##
## `PaletteSubsystem._deliver_output` pushes its CASTER / TARGET colour stacks at
## `get_instance_id()` of whatever the cast was handed as caster/target, and
## `EffectsPlayback.play_action_vfx` is handed `unit.char_body` — it refuses a `Unit`
## outright, because a `Unit` is a `Node3D` that is never positioned. Register the
## `Unit`'s own id and `TintedSurfaces.update_stack` returns early on an unknown token:
## it compiles, it runs, and it tints nothing, silently. `tools/effects/
## ability_vfx_regression.gd` arm F scores the fold itself on the real sprite
## materials; this is the half that can only be asked of `unit.tscn` + `unit.gd`.
##
## The unit is built here rather than in a battle because `Unit._enter_tree` — where
## the bind lives, so that reparenting `battle_view` into the scenario editor's
## SubViewport and back does not permanently unregister every unit — needs nothing
## but the scene's own exported `char_body` and `animation_manager`.
func _check_unit_tint_surface() -> void:
	var registry: Node = get_tree().root.get_node_or_null(^"/root/TintedSurfaces")
	check(registry != null, "the TintedSurfaces autoload is present to register into")
	if registry == null:
		return
	# 🔴 A FIXTURE, NOT A SHORTCUT. `Unit._ready` reaches `GameData` for the status-icon
	# sheet and its palette, and `GameData` is empty in a probe with no ROM indexed — so
	# without these two entries the run prints two `no indexed texture named "misc"`
	# errors and one hard `Invalid access to property 'misc'`, which is exactly the
	# noise a probe exists to make legible. The bind under test happens in `_enter_tree`,
	# before any of that, and does not depend on either value.
	var had_texture: bool = GameData.textures.has("misc")
	var had_palette: bool = GameData.palettes.has("misc")
	if not had_texture:
		GameData.textures["misc"] = ImageTexture.create_from_image(
			Image.create_empty(8, 8, false, Image.FORMAT_RGBA8))
	if not had_palette:
		var stub := PackedColorArray()
		stub.resize(256)
		GameData.palettes["misc"] = stub

	var unit: Unit = Unit.instantiate()
	add_child(unit)

	var body_id: int = unit.char_body.get_instance_id()
	check(unit.tint_surface_token() == body_id,
		"a Unit registers its CHAR_BODY's instance id (%d), which is what the addon "
			% body_id + "keys caster/target tints on — not its own (%d)"
			% unit.get_instance_id())
	check(registry.is_surface_registered(body_id),
		"and TintedSurfaces knows that token, so update_stack does not early-return")
	check(not registry.is_surface_registered(unit.get_instance_id()),
		"and the Unit's own id is NOT a surface — registering it would tint nothing")
	var materials: Array = registry._surface_materials.get(body_id, [])
	check(materials.size() >= 2,
		"with the unit's sprite materials on it (%d)" % materials.size())

	# The other half of the lifecycle. `BattleManager` reparents `battle_view` in and
	# out of the scenario editor's SubViewport, which takes every unit out of the tree
	# and back, so the pair has to survive a round trip and not just a teardown.
	remove_child(unit)
	check(not registry.is_surface_registered(body_id),
		"leaving the tree unregisters the surface rather than leaking it")
	add_child(unit)
	check(registry.is_surface_registered(body_id)
			and registry._surface_materials.get(body_id, []).size() >= 2,
		"and coming back re-registers it — a reparent must not kill a unit's tint")
	unit.queue_free()

	if not had_texture:
		GameData.textures.erase("misc")
	if not had_palette:
		GameData.palettes.erase("misc")
