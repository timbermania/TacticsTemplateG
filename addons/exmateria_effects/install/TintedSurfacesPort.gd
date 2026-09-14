@tool
extends RefCounted

## The tinted-surface registry's PORT SIGNATURE — the six verbs a member may name
## instead of the `TintedSurfaces` autoload identifier.
##
## ADR-0308 dec. 1: **a member may reach NO autoload identifier at all.** All eight
## stranger rigs declare an EMPTY `[autoload]` block and an addon cannot ship
## `project.godot` entries (ADR-0262 dec. 6), so a bare `TintedSurfaces` resolves in
## the HOST and is simply undefined in a stranger project. It was three of this
## addon's five `known_failures.tsv` rows and eleven of its twenty-six arm-2
## standalone-parse lines.
##
## 🔴 **THIS ADDON SHIPS THE SCRIPT THE AUTOLOAD POINTS AT, AND THAT IS WHY THE
## NODE-PATH BIND BELOW IS LEGITIMATE RATHER THAN A DODGE.**
## `check_addon_portability.py`'s own arm-2 remedy note states the rule: the node
## path is free *"on two grounds and neither is 'it compiles': the autoload points at
## a script THIS addon ships, or the addon is the kernel or the platform port. A
## SYSTEM naming a script it does not ship has swapped a parse error for a silent
## null, which is a worse report of the same dependency."* The host registers
## `TintedSurfaces="*res://addons/exmateria_effects/overlay/TintedSurfaces.gd"` —
## ours. `CharacterCatalog` is the corpus precedent (ADR-0308 dec. 6): **the script
## travels with the addon and the registration does not.** So this port converts a
## host-project-**configuration** dependency into an addon-**presence** one, which is
## the same trade ADR-0175 dec. 2 made for `Tune`, and arm 2b does not score it.
##
## 🔴 **A PORT RATHER THAN FIFTEEN INLINE RESOLVES, WHICH IS THE ONLY PART OF THIS
## THAT WAS A CHOICE.** `render/EffectParticleRenderer.gd` and `trap/TrapEffect.gd`
## already reach `EffectMultiMeshPool` by a hand-rolled
## `Engine.get_main_loop().root.get_node_or_null(…)` + null-check, and copying that
## into four more files would have been the cheaper diff. It would also have spread
## the ABSENT decision — the thing that actually needs reviewing — across four files
## as four independently-guessed null-checks. The absent answer per verb is stated
## once, in the table below, in the file a reviewer reads.
##
## | verb | with the registry | without it |
## |---|---|---|
## | `update_stack` | folds the op stream onto the surface | **no-op** |
## | `update_layer` | writes the owner's tint layer | **no-op** |
## | `remove_layer` | drops one owner's layer | **no-op** |
## | `remove_all_layers_for_owner` | drops every layer an owner holds | **no-op** |
## | `is_surface_registered` | whether that surface has a material | **`false`** |
##
## Every write verb is a no-op and every read answers "nothing is registered", which
## is not a compromise: with no registry in the tree there IS no tinted surface to
## write to, so `false` is the true answer rather than a fallback. The four writers
## return `bool` so a caller that cares can tell delivered from dropped; no call site
## reads it today, which is correct for them and is why the return exists rather than
## a `void` (`EventPort`'s reasoning, and #590's lesson read forward).
##
## Nothing here is instantiated; the class is a namespace of statics.
## `tests/TunePortTest.gd` drives both the bound and the absent path.

## The shipped script, named for its CONSTANT and never for its methods.
##
## 🔴 `SURFACE_MAP` CANNOT GO THROUGH THE NODE. A GDScript `const` is not a property,
## so `node.SURFACE_MAP` on a resolved autoload fails at runtime — the reach has to
## land on the SCRIPT, and the script is a plain `preload` inside this addon the
## moment the file travels with it (ADR-0308 §2's reading of `UI3Registry`). Reading
## it here rather than re-declaring the literal is what makes drift impossible: there
## is one `0` and it is the one in `overlay/TintedSurfaces.gd`.
const TintedSurfacesScript = preload("res://addons/exmateria_effects/overlay/TintedSurfaces.gd")

## The reserved token for the MAP surface, re-exported off the shipped script above.
const SURFACE_MAP: int = TintedSurfacesScript.SURFACE_MAP

## Resolved singleton, or `null`. Same cache discipline as `ExMateriaPlatform`'s three
## ports: never caches a NEGATIVE result, because the autoload can appear after this
## class is first touched (`plugin.gd` registers it at enable time, and a test can add
## or replace it between cases).
static var _port: Node = null


## The live registry node, or `null` where the consumer registered no autoload.
##
## Two rejections, not one — `TunePort._resolve`'s reasoning, and it is not
## theoretical here: `overlay/TintedSurfaces.gd` IS `@tool`, but `has_method` is what
## separates a real registry from any other node that happens to answer to the name,
## and it is the check that keeps a consumer's unrelated `TintedSurfaces` node from
## being called into.
static func _resolve() -> Node:
	if _port != null and is_instance_valid(_port):
		return _port
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	var root: Window = (loop as SceneTree).root
	if root == null:
		return null
	var n := root.get_node_or_null(^"TintedSurfaces")
	if n == null or not n.has_method(&"update_stack"):
		return null
	_port = n
	return n


## Test seam — drop the cache so the next call re-resolves. `is_instance_valid` is
## not the same question as "does the lookup still succeed": a test that removes the
## autoload from the tree without freeing it leaves a valid instance behind.
static func _forget_port() -> void:
	_port = null


## Fold `stack` onto `surface_id` on behalf of `owner_id` at frame `now`.
## Returns `true` when the registry took it.
static func update_stack(surface_id: int, owner_id: int, stack, now: int) -> bool:
	var p := _resolve()
	if p == null:
		return false
	p.update_stack(surface_id, owner_id, stack, now)
	return true


## Write `owner_id`'s flat `tint` layer on `surface_id`. Returns `true` when delivered.
static func update_layer(surface_id: int, owner_id: int, tint: Color) -> bool:
	var p := _resolve()
	if p == null:
		return false
	p.update_layer(surface_id, owner_id, tint)
	return true


## Drop `owner_id`'s layer from `surface_id`. Returns `true` when delivered.
static func remove_layer(surface_id: int, owner_id: int) -> bool:
	var p := _resolve()
	if p == null:
		return false
	p.remove_layer(surface_id, owner_id)
	return true


## Drop every layer `owner_id` holds, on every surface. Returns `true` when delivered.
static func remove_all_layers_for_owner(owner_id: int) -> bool:
	var p := _resolve()
	if p == null:
		return false
	p.remove_all_layers_for_owner(owner_id)
	return true


## Whether `surface_id` has a registered material.
##
## `false` with no registry present is the TRUE answer and not a fallback: nothing can
## be registered where there is nothing to register with. Both call sites guard a
## write with it, so the absent path skips the write — which is the same outcome the
## write verbs above reach on their own.
static func is_surface_registered(surface_id: int) -> bool:
	var p := _resolve()
	if p == null:
		return false
	return p.is_surface_registered(surface_id)
