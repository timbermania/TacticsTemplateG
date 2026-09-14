@tool
extends RefCounted

## The screen-backdrop overlay's PORT SIGNATURE — the four verbs a member may name
## instead of the `ScreenEffectOverlay` autoload identifier.
##
## Written for `install/TintedSurfacesPort.gd`'s reason and under the same ruling
## (ADR-0308 dec. 1): a member may reach no autoload identifier at all, the host
## registers this one as
## `ScreenEffectOverlay="*res://addons/exmateria_effects/overlay/ScreenEffectOverlay.gd"`
## — a script THIS addon ships — so the node-path bind is free on arm 2b's own stated
## grounds rather than on "it compiles". Read that file's header for the argument; it
## is not repeated here.
##
## | verb | with the overlay | without it |
## |---|---|---|
## | `update_layer_gradient` | folds the owner's top/bottom delta in | **no-op** |
## | `remove_layer` | drops the owner's layer | **no-op** |
## | `get_default_top` | the live map's TOP baseline | the shipped script's own fallback |
## | `get_default_bottom` | the live map's BOTTOM baseline | the same, bottom corners |
##
## 🔴 **THE TWO READS ARE THE ONLY VERBS IN EITHER PORT WHOSE ABSENT ANSWER IS NOT
## THE IDENTITY, AND THEY ARE THE ONLY PART OF THIS WORTH ARGUING ABOUT.** Both feed
## `ScreenSubsystem.initialize()` as the baselines the screen `ColorStack` folds the
## gradient endpoints OVER, so the value is not inert: `subsystem/ScreenSubsystem.gd`'s
## `fold_top()` is a pure read the WYSIWYG target-colour solver drives per candidate
## param (#255), and a `Color.BLACK` here would make that solver return numbers that
## are wrong rather than absent. So the absent answer is the shipped script's OWN
## declared fallback — `overlay/ScreenEffectOverlay.gd`'s `default_tl`/`default_tr`
## and `default_bl`/`default_br`, whose own comment reads *"These should be set by the
## map/scene - the hardcoded values are fallbacks"*. A consumer with no overlay
## registered folds over the same baseline a consumer who registered one but loaded no
## map would.
##
## 🔴 AND IT IS **DERIVED FROM THAT SCRIPT, NOT RESTATED FROM IT.** The first draft
## of this file declared `const DEFAULT_TOP := Color(0.1, 0.15, 0.3, 1.0)` — the corner
## literals copied across — plus a docstring promising a test that asserted the copy
## still matched. Two spellings of one value held together by a guard is strictly worse
## than one spelling: `get_default_top()` AVERAGES the two top corners, so the copy
## duplicated the averaging rule as well as the numbers, and **the promised test did not
## exist when the docstring claimed it** — the phantom-citation shape ADR-0154 is about,
## committed here by the session that had just read that ADR. Asking the shipped script
## itself cannot drift and needs no guard.
##
## 🔴 **THE DERIVED PAIR IS CACHED AND THE NODE IS NOT.** `ScreenEffectOverlay`
## extends `Node`, not `RefCounted`, so an instance parked in a `static var` for the life
## of the process is never freed and Godot reports it at exit as a leaked ObjectDB
## instance — which would red whichever test in this suite counts those, from a file with
## nothing to do with it. So `_absent_pair()` builds one, reads BOTH corner answers, frees
## it, and caches the two `Color`s. At most one allocation per process, and only if a
## caller reaches a read verb with no overlay registered, which in the host is never.
##
## Nothing else here is instantiated; the class is otherwise a namespace of statics.
## `tests/TunePortTest.gd` drives both the bound and the absent path.

## The shipped script — named for `_absent_pair()` to instance, and so this file records
## which script the autoload identifier it replaces pointed at.
const ScreenEffectOverlayScript = preload("res://addons/exmateria_effects/overlay/ScreenEffectOverlay.gd")

## `[top, bottom]`, read off a detached overlay on first need. The node is built AND
## freed inside `_absent_pair()`; only these two `Color`s outlive it.
static var _absent_baselines: Array = []

## Resolved singleton, or `null`. Never caches a negative — `TintedSurfacesPort._port`.
static var _port: Node = null


## The two baselines the shipped script declares for its own corners.
##
## The instance is never added to the tree, so `_ready()` does not run and
## `_find_background_material()` cannot fire; the only methods called on it are the two
## pure corner averages.
static func _absent_pair() -> Array:
	if _absent_baselines.is_empty():
		var o: Node = ScreenEffectOverlayScript.new()
		_absent_baselines = [o.get_default_top(), o.get_default_bottom()]
		o.free()
	return _absent_baselines


## The live overlay node, or `null` where the consumer registered no autoload.
##
## 🔴 `has_method` IS LOAD-BEARING AND NOT BELT-AND-BRACES HERE, unlike in the tinted
## port. `overlay/ScreenEffectOverlay.gd` is NOT a `@tool` script, so in the editor
## the engine instantiates the autoload as a PLACEHOLDER that answers to the name and
## carries none of the script's methods (`TunePort._resolve`'s second rejection). A
## bare null-check would sail straight past it and call into nothing.
static func _resolve() -> Node:
	if _port != null and is_instance_valid(_port):
		return _port
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	var root: Window = (loop as SceneTree).root
	if root == null:
		return null
	var n := root.get_node_or_null(^"ScreenEffectOverlay")
	if n == null or not n.has_method(&"update_layer_gradient"):
		return null
	_port = n
	return n


## Test seam — `TintedSurfacesPort._forget_port`.
static func _forget_port() -> void:
	_port = null


## Fold `owner_id`'s top/bottom deltas into the backdrop. Returns `true` when delivered.
static func update_layer_gradient(owner_id: int, top_delta: Color, bottom_delta: Color,
		tint: Color = Color.BLACK) -> bool:
	var p := _resolve()
	if p == null:
		return false
	p.update_layer_gradient(owner_id, top_delta, bottom_delta, tint)
	return true


## Drop `owner_id`'s layer from the backdrop. Returns `true` when delivered.
static func remove_layer(owner_id: int) -> bool:
	var p := _resolve()
	if p == null:
		return false
	p.remove_layer(owner_id)
	return true


## The map's default gradient TOP baseline; with no overlay registered, the fallback
## `overlay/ScreenEffectOverlay.gd` declares for its own top corners.
static func get_default_top() -> Color:
	var p := _resolve()
	if p == null:
		return _absent_pair()[0]
	return p.get_default_top()


## The map's default gradient BOTTOM baseline; with no overlay registered, the
## fallback that script declares for its own bottom corners.
static func get_default_bottom() -> Color:
	var p := _resolve()
	if p == null:
		return _absent_pair()[1]
	return p.get_default_bottom()
