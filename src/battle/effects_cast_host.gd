class_name EffectsCastHost
extends ExMateriaEffects.CastHost
## TacticsG's live battle, as `addons/exmateria_effects`' per-battle contract.
##
## The addon never sees a TacticsG type. Everything it needs arrives through the
## six verbs below; the translation from `Unit`, `TerrainTile` and
## `FftAbilityData` into the addon's vocabulary lives HERE, on the host side of
## the seam, which is the whole point of the contract.
##
## The inherited stage reference is WEAK, so holding one of these on the battle
## manager cannot keep a finished battle alive.

## Poses the addon routes specially. It asks for a charging POSE and derives the
## handler itself; TacticsG's ROM tables give the HANDLER directly
## (`charging_vfx_ids` -> `shared_vfx_handler_ids`), so this inverts that mapping
## rather than inventing a pose TacticsG does not store.
##   handler  4 -> spell charge lines   (addon pose 1)
##   handler 22 -> orbital summon orbs  (addon pose 2)
##   anything else -> standard charge particles (addon pose 0 -> handler 8)
## Charge+N is NOT listed: the addon routes those by ability id, before pose.
const HANDLER_TO_CHARGING_POSE: Dictionary = {
	4: 1,
	22: 2,
}


func _battle() -> Node:
	var s := stage()
	return s if is_instance_valid(s) else null


## Live roster in stable slot order. Vacant slots stay null and are never
## compacted — the addon indexes casts by slot, so compaction would re-point them.
func actors() -> Array[Node3D]:
	var result: Array[Node3D] = []
	var battle := _battle()
	if battle == null:
		return result
	for unit in battle.units:
		# 🔴 `char_body`, not the Unit. The addon treats an actor as a POSITIONED node:
		# `spawn_charge_vfx` reads `actor.global_position` and parents the charge effect
		# to it, and `actors().find(caster)` has to match what the cast sites pass. A
		# TacticsG `Unit` is a Node3D that never moves — `char_body` carries the whole
		# transform — so handing over Units would put every charge effect at the origin
		# and make every roster lookup miss.
		if not is_instance_valid(unit):
			result.append(null)
			continue
		# Duck-typed on purpose: a `Unit` answers with its body, and a stage that rosters
		# plain Node3Ds (the demo scene, the scored regression) answers with itself.
		var body: Node3D = unit.get("char_body") as Node3D
		result.append(body if body != null else unit as Node3D)
	return result


## Derived from the live tile set rather than stored, so a rebuilt map cannot
## leave a stale rect behind. Empty means unavailable, and the addon then keeps
## its legacy size-only centering.
func arena_bounds() -> Rect2i:
	var battle := _battle()
	if battle == null or battle.total_map_tiles.is_empty():
		return Rect2i()
	var min_x: int = 1 << 30
	var min_y: int = 1 << 30
	var max_x: int = -(1 << 30)
	var max_y: int = -(1 << 30)
	for location: Vector2i in battle.total_map_tiles.keys():
		min_x = mini(min_x, location.x)
		min_y = mini(min_y, location.y)
		max_x = maxi(max_x, location.x)
		max_y = maxi(max_y, location.y)
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


## What this battle's ability data says ability `ability_id` should LOOK like.
##
## 🔴 The element is already an ID on this side. `TrapEffectData.ELEMENT_TO_TRAP_ID`
## maps TacticsG's `Action.ElementTypes` BITFIELD to exactly the 1-8 the addon's
## handlers take (FIRE=1 … DARK=8), so nothing is converted twice and no element
## NAME is invented — TacticsG stores none. That is upstream ADR-0364 dec. 3
## landing on a real second host.
func ability_visual(ability_id: int) -> ExMateriaEffects.AbilityVisual:
	if ability_id < 0 or ability_id >= RomReader.fft_abilities.size():
		return ExMateriaEffects.AbilityVisual.absent()
	var data: FftAbilityData = RomReader.fft_abilities[ability_id]
	if data == null:
		return ExMateriaEffects.AbilityVisual.absent()
	var handler_id: int = 0
	if data.ability_action != null:
		handler_id = data.ability_action.user_shared_vfx_handler_id
	return ExMateriaEffects.AbilityVisual.of(
		data.display_name,
		data.formula_id,
		TrapEffectData.element_type_to_trap_id(data.element_type),
		int(HANDLER_TO_CHARGING_POSE.get(handler_id, 0)),
	)


## Charge-line colour, not the ability's element. TacticsG units carry elemental
## AFFINITIES (absorb/cancel/half/weak), which are a damage rule and not a
## colour, so there is deliberately nothing to translate: 0 leaves the addon on
## the ability's own element.
func actor_element_id(_actor: Node3D) -> int:
	return 0


## An observation, not a success notification — spell/cinematic/item calls can
## precede an initialization failure, and trap calls follow a successful one.
## Off by default: a cast happens per action, so an unconditional print would
## bury the log. `EffectsDebug` is deliberately not reached — it is in the addon
## but NOT on its façade, and the façade is the whole symbol surface a consumer
## may name (upstream ADR-0211 dec. 4).
static var log_casts: bool = false

var casts: Array = []


func note_cast(caster_idx: int, target_idx: int, effect_name: String) -> void:
	casts.append([caster_idx, target_idx, effect_name])
	if log_casts:
		print("[TTG_CAST] caster=%d target=%d %s" % [caster_idx, target_idx, effect_name])


func diagnostic_label() -> String:
	var battle := _battle()
	return "TacticsG" if battle != null else ""
