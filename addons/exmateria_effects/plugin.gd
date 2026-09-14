@tool
extends EditorPlugin
## ExMateria Effects — Godot editor plugin entry.
##
## **It registers three autoloads, and that is this addon's whole install step.**
## Each is a singleton the effect runtime reaches by name or by `/root/` node
## path, and each script travels with the addon (ADR-0262 dec. 6: leaving the
## system's centre behind inverts the extraction), so the addon is what registers
## them:
##
##   EffectMultiMeshPool   render/EffectMultiMeshPool.gd    — the shared prim pool
##   ScreenEffectOverlay   overlay/ScreenEffectOverlay.gd   — the full-screen tint
##   TintedSurfaces        overlay/TintedSurfaces.gd        — the tinted-surface registry
##
## 🔴 THE `[autoload]` LINE STAYS THE CONSUMING PROJECT'S EITHER WAY (ADR-0262
## dec. 6). An addon cannot write another project's `project.godot`, so a name
## the host declares itself is the host's — `godot-learning` declares all four,
## to keep its own autoload ORDER explicit — and `has_setting` is what stops a
## consumer getting a duplicate. The shape is `addons/exmateria_catalogue/plugin.gd`'s
## verbatim, including that reason.
##
## 🔴 IT WAS FOUR AT THE MOVE AND IT IS THREE, NOT TWO — AND THE 4 → 2 WAS AN
## ARITHMETIC ERROR THIS FILE HELPED CARRY. ADR-0288 dec. 7 / #1224 merge the two tint
## overlays into one `TintedSurfaces`, which is 4 → **3**. The missing fourth was
## `EffectMultiMeshPool`, on the argument that it *"is already reached by node path and
## needs no bare-identifier entry"*. That conflates two different questions. The
## spelling of a reach (bare `Name.` vs `get_node_or_null("/root/Name")`) is arm 2 vs
## arm 2b; whether the NODE EXISTS is the `[autoload]` line, and only the consuming
## project can write one — `add_autoload_singleton` is an `EditorPlugin` API that edits
## `project.godot`, and this file's own note below records that `_enter_tree` has never
## been called in this repo. MEASURED at #1224 by deleting the line and booting
## `res://tests/GPUSpellCombatTest.tscn`: **8 × `ERROR: EffectParticleRenderer:
## EffectMultiMeshPool autoload not found`**, and `tests/lib/verdict.sh` scores the run
## `THREW`. A node-path reach needs the autoload exactly as much as a bare identifier
## does. Three is the floor while this addon ships three singletons.
##
## 🔴 THIS ADDON DECLARES NO `global uniform` AND THEREFORE PROVIDES NONE
## (ADR-0220 dec. 1 + ADR-0190, composed: only a non-system addon may declare
## one, and the declarer provides it). `psx_fx_stretch` moved to
## `exmateria_platform` at #1217 and `texel_blend_gamma` followed it there at #1270 (it was
## the host's in between, and extraction #8 moving `src/ui3/shaders/` under an addon
## root is what ended that) — so
## `check_addon_portability.py` arm 4b reads 0 here and there is no
## `PROVIDED_GLOBALS` array for arm 4c to grade. The `exmateria_platform` plugin
## is what a consumer needs enabled for the names this addon's shaders READ.
##
## 🔴 IN THIS REPO THIS CODE NEVER RUNS, and that is a stated fact rather than an
## oversight: `godot-learning/project.godot` has no `[editor_plugins]` section, so
## no `plugin.gd` in this package has ever had `_enter_tree` called (ADR-0203
## dec. 4). Booting the game verifies nothing about this file; the oracle is a
## stranger rig staging the addon into a project that did nothing for it
## (ADR-0194).
##
## Everything else in this addon is reached through `ExMateriaEffects`, the one
## `class_name` it declares (ADR-0212 dec. 1). See README.md.

const AUTOLOADS := [
	["EffectMultiMeshPool", "res://addons/exmateria_effects/render/EffectMultiMeshPool.gd"],
	["ScreenEffectOverlay", "res://addons/exmateria_effects/overlay/ScreenEffectOverlay.gd"],
	["TintedSurfaces", "res://addons/exmateria_effects/overlay/TintedSurfaces.gd"],
]

## Only the ones THIS plugin added. Removing on the way out what a consumer
## declared on its own would delete their line from their project file.
var _added: Array[String] = []


func _enter_tree() -> void:
	for entry in AUTOLOADS:
		# A consumer that already declares the name (the in-repo game does, to
		# keep its own autoload order explicit) must not get a duplicate.
		if not ProjectSettings.has_setting("autoload/" + entry[0]):
			add_autoload_singleton(entry[0], entry[1])
			_added.append(entry[0])


func _exit_tree() -> void:
	for autoload_name in _added:
		remove_autoload_singleton(autoload_name)
	_added.clear()
