class_name ScreenBackgroundQuad
extends MeshInstance3D
## TacticsG's background gradient, in a form the effects addon can drive.
##
## `addons/exmateria_effects` carries a SCREEN track alongside the particle track:
## `ScreenSubsystem` folds each effect's keyframes over the map's gradient and hands
## the result to the `ScreenEffectOverlay` autoload. That autoload has exactly one
## way to reach a renderer — a node named `ScreenBackground` directly under the
## current `Camera3D`, whose `material_override` is a `ShaderMaterial` exposing
## `color_tl/tr/bl/br` plus the ColorStack uniforms. Without it the addon push_errors
## once per delivered frame ("ScreenBackground node not found in camera") and the
## screen half of every effect is simply dropped. This node IS that renderer.
##
## 🔴 IT DOES NOT REPLACE `BattleManager.background_gradient`. That `TextureRect`
## lives on a CanvasLayer at layer -3 and is drawn by the WorldEnvironment's
## `background_mode = 3` (BG_CANVAS), which is what puts a 2D image BEHIND the 3D
## scene at all. It still covers the parts of the window the 3D view does not — the
## scenario editor renders the battle into a SubViewport that occupies only part of
## the screen, and the quad can only ever paint inside that. The two are kept at the
## same colours by `set_gradient()`'s single caller, so at rest there is no seam; an
## effect moves the quad only, which is correct — the effect is in the battle view.
##
## The colours are TacticsG's own: `FftMapData` parses a two-colour gradient out of
## the ROM per map, `Scenario` carries it, and the editor's two colour pickers edit
## it. The addon wants four corners, so top goes to both top corners and bottom to
## both bottom ones.

## The addon looks this name up literally. Renaming the node silently disables the
## whole screen track — `_find_background_material()` answers with a push_error, and
## an effect that draws no background looks identical to one that has none.
const NODE_NAME: StringName = &"ScreenBackground"

## The autoload the addon delivers through (declared in project.godot). Reached by
## path rather than by the global identifier so this script still compiles in a tree
## that never registered it, exactly as the addon's own `ScreenOverlayPort` does.
const OVERLAY_NODE: NodePath = ^"/root/ScreenEffectOverlay"

const SHADER: Shader = preload("res://src/shaders/screen_background.gdshader")

## Matches the reference camera rig: a quad parked in front of the camera. The MVP is
## bypassed in the vertex shader, so neither the size nor the offset decides what is
## drawn — they only have to keep the mesh's AABB somewhere sane. `extra_cull_margin`
## is what actually guarantees it is never frustum-culled, under any zoom, projection
## or pose the camera controller reaches.
const QUAD_SIZE: Vector2 = Vector2(40, 20)
const QUAD_OFFSET_Z: float = -100.0

var _material: ShaderMaterial
var _top: Color = Color.BLACK
var _bottom: Color = Color.BLACK


## Build (or return) the background under `camera`. Idempotent: calling it again for
## a camera that already has one hands back the existing node rather than stacking a
## second opaque fullscreen quad on top of the first.
static func attach(camera: Camera3D) -> ScreenBackgroundQuad:
	if camera == null:
		return null
	var existing: Node = camera.get_node_or_null(NodePath(NODE_NAME))
	if existing is ScreenBackgroundQuad:
		var found: ScreenBackgroundQuad = existing
		found._prime_overlay()
		return found
	if existing != null:
		# Something else already owns the one name the addon will look up. Say so:
		# the addon would silently find it, fail the ShaderMaterial cast, and drop
		# the screen track for the rest of the run.
		push_error("ScreenBackgroundQuad: %s already exists under %s and is not one of these"
			% [NODE_NAME, camera.name])
		return null
	var quad := ScreenBackgroundQuad.new()
	quad.name = NODE_NAME
	camera.add_child(quad)
	return quad


func _init() -> void:
	var quad := QuadMesh.new()
	quad.size = QUAD_SIZE
	mesh = quad
	position.z = QUAD_OFFSET_Z
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The mesh never moves with the camera's framing because the shader throws the
	# MVP away, but the ENGINE still culls against the untransformed AABB. A margin
	# this wide means "never cull me" without needing a custom AABB.
	extra_cull_margin = 16384.0
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	# Cosmetic here (the depth write in the shader is what orders it), kept to match
	# the reference material the addon was authored against.
	_material.render_priority = -100
	# `material_override`, NOT `material`: the addon reads `material_override` and
	# nothing else.
	material_override = _material
	_write_corners(_top, _top, _bottom, _bottom)


func _ready() -> void:
	_prime_overlay()


## The map's gradient, as TacticsG parses it. `top`/`bottom` are the two colours
## `Scenario.background_gradient_top` / `_bottom` carry.
func set_gradient(top: Color, bottom: Color) -> void:
	_top = top
	_bottom = bottom
	var overlay: Node = _overlay()
	if overlay != null:
		# The addon folds each effect's screen keyframes OVER these and delivers the
		# difference, so a wrong default does not merely mistint the idle background
		# — every effect's colours come out wrong, and `_recomposite()` snaps to the
		# addon's hardcoded blue the moment the first cast ends.
		overlay.set_defaults(top, top, bottom, bottom)
		if overlay.is_active():
			# An effect owns the corners right now; it will recomposite over the new
			# defaults on its next delivered frame. Writing here would stamp on it.
			return
	_write_corners(top, top, bottom, bottom)


func gradient_top() -> Color:
	return _top


func gradient_bottom() -> Color:
	return _bottom


## The four corner colours currently on the material, as the shader will read them.
## The measurement seam: it is the only way to tell "the addon drove the background"
## apart from "the addon was called and wrote nothing".
func corners() -> PackedColorArray:
	var out := PackedColorArray()
	for key: String in ["color_tl", "color_tr", "color_bl", "color_br"]:
		var v: Variant = _material.get_shader_parameter(key)
		var c := Vector3.ZERO if v == null else (v as Vector3)
		out.append(Color(c.x, c.y, c.z, 1.0))
	return out


## `c_` prefixes because a bare `tr` shadows `Object.tr()`, which this project
## promotes to an error (project.godot `gdscript/warnings/shadowed_variable_base_class`).
## The addon spells its own corner arguments the same way.
func _write_corners(c_tl: Color, c_tr: Color, c_bl: Color, c_br: Color) -> void:
	_material.set_shader_parameter("color_tl", Vector3(c_tl.r, c_tl.g, c_tl.b))
	_material.set_shader_parameter("color_tr", Vector3(c_tr.r, c_tr.g, c_tr.b))
	_material.set_shader_parameter("color_bl", Vector3(c_bl.r, c_bl.g, c_bl.b))
	_material.set_shader_parameter("color_br", Vector3(c_br.r, c_br.g, c_br.b))


func _overlay() -> Node:
	if not is_inside_tree():
		return null
	var node: Node = get_tree().root.get_node_or_null(OVERLAY_NODE)
	if node == null or not node.has_method(&"set_defaults"):
		# `has_method` is load bearing: ScreenEffectOverlay.gd is not @tool, so in the
		# editor the autoload is a placeholder that answers to the name with none of
		# its methods. Same reasoning as the addon's own ScreenOverlayPort.
		return null
	return node


## Hand the overlay this material instead of making it go and find one.
##
## 🔴 THIS IS NOT BELT-AND-BRACES, IT IS THE FIX FOR A REAL FAILURE. The overlay
## resolves its material through `get_viewport().get_camera_3d()`, and it is an
## AUTOLOAD, so that viewport is the ROOT one. TacticsG parks `battle_view` — which
## owns the camera — inside the scenario editor's SubViewport whenever the editor is
## open, and `get_camera_3d()` is per-viewport: the root viewport reports NO camera
## for as long as that is true. The lookup then fails for reasons that have nothing
## to do with whether a background exists, and the only symptom is a push_error.
## Assigning the cached pair directly removes the camera search from the path
## entirely, so the seam works identically in both parentings.
##
## Reaching past an underscore is deliberate and safe HERE specifically because
## `addons/` is byte-pinned to an enforced 241-file inventory (see
## `tools/effects/verify_installation.py`) — those two names cannot drift under us
## without a re-vendor that has to be reviewed anyway. The `in` guards mean a
## re-vendor that DID rename them degrades to the addon's own lookup rather than
## throwing.
func _prime_overlay() -> void:
	var overlay: Node = _overlay()
	if overlay == null:
		return
	if "_material" in overlay and "_initialized" in overlay:
		overlay._material = _material
		overlay._initialized = true
	# Re-assert the defaults: priming may be the first moment the overlay can reach
	# a renderer at all, and `set_defaults` is what pushes them onto it.
	overlay.set_defaults(_top, _top, _bottom, _bottom)
