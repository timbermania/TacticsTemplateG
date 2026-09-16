class_name UnitSpritesManager
extends Node3D
## Owns the three paletted sprite materials a unit paints with, and — since the
## effects addon's colour track landed — the registration that makes them a TINTED
## SURFACE.
##
## 🔴 THE COLOUR STACK IS PUSHED BY TOKEN, AND THE TOKEN IS `char_body`'s INSTANCE ID.
## `PaletteSubsystem._deliver_output` keys its CASTER / TARGET channels on
## `get_instance_id()` of whatever `EffectInstance.set_unit_targets` was handed, and
## since `379a36f` that is the unit's `char_body` — a TacticsG `Unit` is a `Node3D`
## that is never positioned, so handing the addon a `Unit` put every cast at the world
## origin and `EffectsPlayback.play_action_vfx` now refuses one outright. Registering
## the `Unit`'s id here instead compiles, runs, and tints NOTHING:
## `TintedSurfaces.update_stack` returns early on a token it does not know, silently.
## `Unit._enter_tree` is the one caller and it passes `char_body.get_instance_id()`.
##
## The seam is deliberately token-in / materials-out rather than effects-specific: any
## host consumer that wants to recolour a unit reaches `TintedSurfaces` with the same
## token. `StatusEffect.shading_color` (parsed from the ROM at
## `scus_942_21_data.gd:198`, applied by nothing) is the obvious second one.

const LAYERING_OFFSET: float = 0.001
const UNIT_SPRITE_SHADER: Shader = preload("uid://cdcosdsn4y30b")

## The three colour SUB-SURFACES of one unit, in the order
## `addons/exmateria_schema/colour_model/color_stack.gdshaderinc:25-26` names them.
## A colour layer carries a 3-bit mask over exactly these: `ColorStack.MASK_WHOLE`
## (0x7) is "body | weapon | effect", which is what every shipped FFT effect and the
## `TintedSurfaces.update_layer` additive bridge use, while `MASK_SURFACE0` (0x1) is
## the body alone. Passing the same id from all three materials would make those two
## masks indistinguishable, so each material passes its own.
const SURFACE_BODY: int = 0
const SURFACE_WEAPON: int = 1
const SURFACE_EFFECT: int = 2

## The `TintedSurfaces` autoload reached through the addon's PORT for its constants
## only — the port publishes no `register_surface` verb, because registration is the
## HOST's side of the contract, so the calls themselves go to the autoload.
## `src/content_scripts/map/map_chunk_nodes.gd` does the same for the map surface.
const TintedSurfacesPort := preload("res://addons/exmateria_effects/install/TintedSurfacesPort.gd")

@export var sprite_primary: Sprite3D
@export var sprite_weapon: Sprite3D
@export var sprite_effect: Sprite3D
@export var sprite_text: Sprite3D

@export var sprite_item: Sprite3D
var item_initial_pos: Vector3 = Vector3(0, -0.714, 0)
@export var sprite_background: Sprite3D

var _primary_material: ShaderMaterial
var _weapon_material: ShaderMaterial

## The effect sprite's material, once `set_effect_material` has been handed the
## per-unit duplicate. 🔴 NOT the one the scene ships: `unit_sprites_manager.tscn`
## holds that as a SubResource, which every instantiated unit SHARES until
## `Unit.initialize_unit` duplicates it — registering the shared one would fold one
## unit's caster flash onto every unit's effect sprite at once.
var _effect_material: ShaderMaterial

## The surface token this unit's materials are registered under, or 0 (which
## `TintedSurfaces` reserves for `SURFACE_MAP`, and `get_instance_id()` never returns)
## when they are not registered at all.
var _tint_token: int = 0


func _ready() -> void:
	_primary_material = ShaderMaterial.new()
	_primary_material.shader = UNIT_SPRITE_SHADER
	_primary_material.set_shader_parameter("depth_mode", VfxConstants.DepthMode.UNIT)
	_primary_material.set_shader_parameter("color_surface_id", SURFACE_BODY)
	sprite_primary.material_override = _primary_material

	_weapon_material = ShaderMaterial.new()
	_weapon_material.shader = UNIT_SPRITE_SHADER
	_weapon_material.set_shader_parameter("depth_mode", VfxConstants.DepthMode.UNIT)
	_weapon_material.set_shader_parameter("color_surface_id", SURFACE_WEAPON)
	sprite_weapon.material_override = _weapon_material

	# 🔴 THE OWNER BINDS BEFORE THIS RUNS, ON THE FIRST ENTRY. `Unit._enter_tree` fires
	# top-down before any child's `_ready`, so the first `bind_tint_surface` arrives
	# while both materials above are still null and registers nothing. It records the
	# token; this completes it. On a RE-entry (`BattleManager` reparents `battle_view`
	# in and out of the scenario editor's SubViewport, which takes every unit out of
	# the tree) `_ready` does not run again and `_enter_tree` does the whole job.
	_register_tint_materials()


func set_primary_texture(tex: Texture2D) -> void:
	sprite_primary.texture = tex
	_primary_material.set_shader_parameter("sprite_texture", tex)


func set_weapon_texture(tex: Texture2D) -> void:
	sprite_weapon.texture = tex
	_weapon_material.set_shader_parameter("sprite_texture", tex)


## TacticsG's own single ADDITIVE unit highlight. A sibling of the effects colour
## stack, not a substitute and not a layer of it: the stack is an ordered list of
## affine/luma recipes with per-layer progress and 5-bit CLUT quantization, which a
## clamped `base + tint` cannot express. The shaders fold the stack into the palette
## entry and then add this, so the two compose without either one owning the other.
func set_tint(tint: Vector3) -> void:
	_primary_material.set_shader_parameter("unit_tint", tint)
	_weapon_material.set_shader_parameter("unit_tint", tint)


## Hand over the per-unit duplicate of the EFFECT sprite's material.
##
## Assignment goes through here rather than straight onto `sprite_effect` so the
## material picks up its sub-surface id and joins the tint registration. `Unit`
## duplicates the scene's shared SubResource in `initialize_unit()`, which runs well
## after `bind_tint_surface` — and can run a second time if `GameData` re-indexes — so
## the registration is rebuilt from scratch rather than appended to.
func set_effect_material(material: ShaderMaterial) -> void:
	sprite_effect.material_override = material
	_effect_material = material
	if material != null:
		material.set_shader_parameter("color_surface_id", SURFACE_EFFECT)
	if _tint_token != 0:
		bind_tint_surface(_tint_token)


## Register this unit's sprite materials as one TINTED SURFACE under `token`.
##
## 🔴 `token` MUST BE `char_body.get_instance_id()`. See the class header — the addon
## keys the caster/target colour channels on the node it was handed as the cast's
## caster/target, and that node is `char_body`.
##
## Idempotent: `TintedSurfaces.register_surface` de-duplicates by design, and re-binding
## the same token after the material set changes (see `set_effect_material`) rebuilds
## the surface rather than growing it.
func bind_tint_surface(token: int) -> void:
	if token == TintedSurfacesPort.SURFACE_MAP:
		push_error("UnitSpritesManager: refusing to bind the reserved SURFACE_MAP token "
			+ "%d. `get_instance_id()` never returns it, so this is a caller that has "
			% TintedSurfacesPort.SURFACE_MAP
			+ "no `char_body` and would otherwise fold the MAP's tint onto a unit.")
		return
	if _tint_token != 0 and _tint_token != token:
		unbind_tint_surface()
	if _tint_token == token and is_instance_valid(TintedSurfaces):
		# A rebuild, not a first bind: drop the old material list so a replaced
		# material cannot linger in it, and clear the stack off it on the way out.
		TintedSurfaces.unregister_surface(token)
	_tint_token = token
	_register_tint_materials()


## Drop the registration and clear any folded colour off the materials.
##
## `TintedSurfaces.unregister_surface` pushes an empty stack to every material of the
## surface before forgetting it, so a unit that leaves the tree mid-cast does not keep
## the last frame's tint baked into its uniforms.
func unbind_tint_surface() -> void:
	if _tint_token == 0:
		return
	if is_instance_valid(TintedSurfaces):
		TintedSurfaces.unregister_surface(_tint_token)
	_tint_token = 0


## The token this unit's materials are registered under, or 0 when unregistered. The
## address any host-side colour consumer needs to reach `TintedSurfaces` with.
func tint_surface_token() -> int:
	return _tint_token


## Push whichever of the three materials exist onto the bound surface. Null-tolerant on
## purpose: which materials exist depends on how far through `_ready` /
## `initialize_unit` the unit is, and `register_surface` ignores a null anyway.
func _register_tint_materials() -> void:
	if _tint_token == 0 or not is_instance_valid(TintedSurfaces):
		return
	for material: ShaderMaterial in [_primary_material, _weapon_material, _effect_material]:
		if material != null:
			TintedSurfaces.register_surface(_tint_token, material)


func reset_sprites() -> void:
	# reset position
	self.position = Vector3.ZERO
	sprite_item.position = item_initial_pos
	sprite_item.rotation = Vector3.ZERO
	sprite_item.frame = 32
	
	# reset layer priority
	sprite_primary.position.z = -2 * LAYERING_OFFSET
	sprite_weapon.position.z = -3 * LAYERING_OFFSET
	sprite_weapon.frame = (sprite_weapon.hframes * sprite_weapon.vframes) - 1 # TODO fix setting blank, set visible = false?
	#sprite_weapon.visible = false
	sprite_effect.position.z = -1 * LAYERING_OFFSET
	sprite_effect.frame = (sprite_effect.hframes * sprite_effect.vframes) - 1 # TODO fix setting blank, set visible = false?
	#sprite_effect.visible = false
	sprite_text.position.z = 0 * LAYERING_OFFSET
	
	sprite_primary.rotation_degrees.z = 0
	sprite_weapon.rotation_degrees.z = 0
	sprite_effect.rotation_degrees.z = 0
	sprite_text.rotation_degrees.z = 0
	
	# reset flip_h
	sprite_primary.flip_h = false
	sprite_weapon.flip_h = false
	sprite_effect.flip_h = false
	sprite_text.flip_h = false
	
	# reset flip_v
	sprite_primary.flip_v = false
	sprite_weapon.flip_v = false
	sprite_effect.flip_v = false
	sprite_text.flip_v = false


func flip_h() -> void:
	sprite_primary.flip_h = not sprite_primary.flip_h
	sprite_weapon.flip_h = not sprite_weapon.flip_h
	sprite_effect.flip_h = not sprite_effect.flip_h
	sprite_item.flip_h = not sprite_item.flip_h
