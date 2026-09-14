extends Node
## Live effect carrier producer: engine-fold (4.8-dev Forward+) or native in-scene.
##
## Where the retired raw-GLSL fold (CombatDisplaySpaceComposite, deleted in #228 Phase 3) re-implemented
## each prim's shading in GLSL, this drives the effect prims through the ENGINE's Pass B fold: each
## OTDepthPrimOrder run is materialized as a per-run MultiMeshInstance3D wearing the REAL particle
## gdshader flagged `compositor_layer`, made a member via render_layer + stamped render_layer_order =
## its fold-order key. The engine draws them (in render_layer_order order, not depth) into the
## engine-owned held-out target for that layer, which:
##   Pass A (FoldSurface, POST_OPAQUE)      seeds  = opaque scene color → display
##   Pass B (ENGINE)                        folds  = the flagged prims, hardware add/sub/mix
##   Pass C (FoldSurface, PRE_TRANSPARENT)  resolves = display → linear + RGB555, EVERY pixel
##
## Passes A/C (the scratch lifecycle) are owned by FoldSurface — a separate module, since the scratch
## plumbing and the per-frame carrier rebuild change for different reasons (ADR-0074). This file owns
## ONLY the carrier rebuild: read the pool, materialize per-run MultiMeshInstance3D carriers, stamp
## their fold order. setup(camera) installs a FoldSurface and starts the carrier loop.
##
## Attach with `setup(camera)`; it reads EffectMultiMeshPool each frame (the per-frame carrier
## rebuild the retired CombatCompositeDriver used to do — #228 Phase 3). See memory
## engine-shaded-fold-passB-demi2-stage1 / engine-fold-scoped-demi-harness-plan.
##
## OCCLUSION (resolved 2026-07-27): the fold materials are `depth_draw_never` + depth-test ENABLED.
## The engine's fold pass builds its framebuffer from the compositor scratch + the SHARED opaque scene
## depth (render_forward_clustered.cpp: `rb->get_depth_texture()`, LOADed not cleared) and tests DEPTH
## with GREATER_OR_EQUAL. The fold shaders write `DEPTH = ot_computed_depth` — the same reversed-Z
## NDC the opaque scene writes — so folded effects (particles AND callbacks) are occluded per-fragment
## by units/map at their true depth. `depth_draw_never` keeps the fold from writing depth, so effects
## still fold against EACH OTHER in `render_layer_order` (OTDepthPrimOrder), not camera depth.
##
## FOLD mode requires 4.8-dev + `--rendering-method forward_plus` (the `compositor_layer`
## render_mode and the held-out pass are Forward+-only). For native/GL use setup_native().
##
## Vault: [[Display Space Blend Fold]]

## The fold bracket, aliased back to its bare spelling through the addon's one
## global name (ADR-0212 dec. 1, ADR-0211 dec. 4). `addons/exmateria_render`
## used to declare `class_name FoldSurface`; it now declares only
## `ExMateriaRender`, so this line is what keeps every use site below spelled
## the way it was.
const FoldSurface = ExMateriaRender.FoldSurface

## And the same for `addons/exmateria_schema`, whose six generic-English globals
## collapsed onto one façade in the same pass (ADR-0212 dec. 1).
const DepthMode = ExMateriaSchema.DepthMode
const Fold = ExMateriaSchema.Fold

## Preloaded `Shader` objects, not `String` paths — ADR-0191 dec. 11. A `load()` on a
## mistyped path returns null, a null shader does not raise, and the fold "just stops, with no
## error". That hazard is a property of naming a fold shader from GDScript, not of picking
## between two, so it reaches this block even though dec. 2's rule does not.
const FOLD_ADD := preload("res://addons/exmateria_effects/render/effect_fold_add.gdshader")
const FOLD_SUB := preload("res://addons/exmateria_effects/render/effect_fold_sub.gdshader")
const FOLD_MIX := preload("res://addons/exmateria_effects/render/effect_fold_mix.gdshader")

# The IN-SCENE set: the same shading minus `compositor_layer`, so the carriers render in-scene with
# native Forward+ blend instead of the display-space fold. Selected when native_blend = true, which is
# now TWO things (#1352) — the PRODUCTION ROUTE on a build that has no `compositor_layer` primitive to
# fold with, and the #7916 comparison side on a build that does. CompositorAutopilot decides; this file
# only obeys. Off-fork it is not "the wrong side", it is the only side, and standing down instead is
# what made transparent effect particles silently vanish there.
# Their bodies differ from the fold twins' by one expression: the in-scene half linearizes
# (effect_particle_native.gdshaderinc), because Godot's HDR target is linear and the pipeline's tonemap
# is the return leg. A fold has no return leg, which is why that pow cannot be shared — see
# tools/check_no_pow_in_fold.py.
# Preloaded with their fold twins above: not fold shaders themselves (no `compositor_layer`), but
# `_make_mat` takes one type and a block that is half String, half Shader is the drift dec. 6 fixed
# one layer down in the shaders.
const NATIVE_ADD := preload("res://addons/exmateria_effects/render/effect_native_add.gdshader")
const NATIVE_SUB := preload("res://addons/exmateria_effects/render/effect_native_sub.gdshader")
const NATIVE_MIX := preload("res://addons/exmateria_effects/render/effect_native_mix.gdshader")

## When true, materialise carriers with the NATIVE in-scene set (no layer membership, no FoldSurface).
## Set via CompositorAutopilot, which derives it from the BUILD predicate and the #7916 demo override —
## so off-fork this is the route, and on the fork it is the comparison. This file never asks why.
var native_blend := false

# Pool-envelope → display-gouraud gain (the retired `psx_brightness` global, ADR-0074 endgame).
# The effect POOL decodes its colour curve to `/255` (EffectData: byte/255), so `color_modulate`
# does NOT span the full PSX gouraud range — it is the pool's `/127`-ish ENVELOPE. This scalar is
# the `÷255→÷128` scale-conversion that lifts it to display-space gouraud. It USED to live in the
# fold fragment as `* psx_brightness` (a GLOBAL uniform that also bit the opaque/in-scene paths and
# was a tuning footgun); the endgame bakes it into the fold COLOR here — the single choke point
# where every add/sub/mix run's COLOR is finalized for ALL pooled producers (particles + trap) —
# so `psx_brightness` can be deleted and every fold is uniformly `texel × gouraud/128`. Value is the
# exact retired 2.2 (DEMI2 fold-color audit verdict: FAITHFUL — do NOT "fix" to a literal /128, that
# would change appearance; this is a net-neutral relocation). See check_no_psx_brightness_in_fold.py.
const POOL_GOURAUD_GAIN := 2.2

var _pool: Node
var _fold_root: Node3D
var _quad: QuadMesh
var _mat_add: ShaderMaterial
var _mat_sub: ShaderMaterial
var _mat_mix: ShaderMaterial
var _fold_surface: FoldSurface
var _logged := false


## Standalone native entry point ONLY when the renderer cannot fold (e.g. GL).
## Call ONCE after adding this Node to the scene. Returns false without setup on
## a fold-capable renderer: callbacks still select Fold.owns() and would be
## stranded without its bracket. Fork Forward+ callers must use setup(camera).
## The native_blend comparison override on setup() remains pooled-carrier-only.
## Keep one producer for the active playback scene; freeing it frees its carriers.
func setup_native(cam: Camera3D) -> bool:
	if Fold.owns():
		push_warning("[engine-fold] setup_native requires a non-fold-capable renderer; use setup(camera) for folded callbacks")
		return false
	native_blend = true
	setup(cam)
	return _fold_root != null


func setup(cam: Camera3D) -> void:
	if cam == null:
		push_warning("[engine-fold] no camera — engine-fold compositor disabled")
		return
	_pool = Engine.get_main_loop().root.get_node_or_null("EffectMultiMeshPool")
	if _pool == null:
		push_warning("[engine-fold] no EffectMultiMeshPool — disabled")
		return
	_quad = QuadMesh.new()
	if native_blend:
		# In-scene: native blend, one twin per blend mode (add / sub / mix), each linearizing its own
		# texel because Godot's target is linear and the tonemap is the return leg.
		# 25%-add (ADD_25) rides NATIVE_ADD — its 0.25 level_scale is baked into COLOR below, same as the fold path.
		_mat_add = _make_mat(NATIVE_ADD)
		_mat_sub = _make_mat(NATIVE_SUB)
		_mat_mix = _make_mat(NATIVE_MIX)
	else:
		_mat_add = _make_mat(FOLD_ADD)
		_mat_sub = _make_mat(FOLD_SUB)
		_mat_mix = _make_mat(FOLD_MIX)
	_fold_root = Node3D.new()
	_fold_root.name = "EngineFoldPrims"
	add_child(_fold_root)
	if not native_blend:
		# The Pass A/C display-space scratch is FoldSurface's job (ADR-0074); this file owns only the
		# per-frame carrier rebuild below. FoldSurface installs the Compositor on the camera. In
		# native-blend mode there is no fold scratch — the carriers just blend into the scene buffer.
		_fold_surface = FoldSurface.new()
		_fold_surface.setup(cam)
	process_priority = 1000   # after the effect renderers fill their pool buckets
	print("[engine-fold] active on camera '%s' (%s)" % [cam.name,
		"NATIVE in-scene blend, linear — no fold layer" if native_blend else "Forward+ engine Pass B fold"])


func _make_mat(shader: Shader) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	# Prims emit RAW display texels (design §2): no sRGB→linear on the texel. The fold shaders
	# (effect_fold_add/sub/mix) now do this STRUCTURALLY — the pow(texel_blend_gamma) ternary was removed
	# (2026-07-31 particle fold-color audit), so there's no srgb_to_linear flag to force off anymore.
	# The in-scene twins' `srgb_gamma` keeps its shader default (2.2, the exponent
	# effect_particle_opaque has always used); it is a uniform so a look pass can move it, not a knob
	# this file sets. The fold twins have no such uniform to set — that is the point of the split.
	m.set_shader_parameter("use_palette", false)
	return m


func _process(_dt: float) -> void:
	if _pool == null or _fold_root == null:
		return
	# Clear last frame's carriers and rebuild from the live pool (one MultiMeshInstance3D per run).
	for c in _fold_root.get_children():
		_fold_root.remove_child(c)
		c.free()
	var buckets: Array = _pool.call("get_active_effect_buckets")
	var fold_idx := 0
	for e in buckets:
		var bytes: PackedByteArray = e.get("unified_bytes", PackedByteArray())
		if bytes.is_empty():
			continue
		var all: PackedFloat32Array = bytes.to_float32_array()
		var tex: Texture2D = e.get("effect_tex_2d")
		# Paletted producers (tile cursor, trap) publish an INDEXED sheet + a CLUT; the fold shader
		# resolves the real color by sampling `palette_texture` at (idx, per-instance row) — same as the
		# shipped GLSL fold. Without this the engine-fold path folds the indexed grayscale as raw color,
		# so the cursor's subtractive outline (and trap) render wrong/black. `palette_rows` feeds the
		# CLUT-row V divisor (RANGETILE = 9 rows, TRAP1 = 16) — a hardcoded 16 sampled the wrong row.
		var use_palette: bool = e.get("use_palette", false)
		var palette_tex: Texture2D = e.get("palette_tex_2d")
		var palette_rows: int = int(e.get("palette_rows", 16))
		for run in e["runs"]:
			var mode: int = run["mode"]
			var base: int = run["base"]
			var cnt: int = run["count"]
			var stride: int = run.get("stride", 24)
			if cnt <= 0:
				continue
			var buf := PackedFloat32Array()
			buf.resize(cnt * 20)
			for i in range(cnt):
				var src := (base + i) * stride
				for fl in range(20):
					buf[i * 20 + fl] = all[src + fl]
				# #220 per-prim level_scale lives at record[20] on the stride-24 unified path
				# (mode3/ADD25 = 0.25, else 1.0), but the MultiMesh instance layout is only 20
				# floats (transform[0..11] + COLOR[12..15] + CUSTOM0[16..19]) — [20] falls off.
				# Bake it into the instance COLOR.rgb so the fold shader's
				# `ALBEDO = base * COLOR.rgb * brightness` matches the Mobile GLSL contrib
				# (col * COLOR * brightness * level, as the retired combat_displayspace_composite.glsl did).
				# Without it the engine-fold ADD path folds ADD_25 prims at 4x — the E065 Shiva
				# overbright, whose mid-life children (emitter 1) are almost all ADD_25.
				if stride > 20:
					var lvl := all[src + 20]
					buf[i * 20 + 12] *= lvl
					buf[i * 20 + 13] *= lvl
					buf[i * 20 + 14] *= lvl
				# ADR-0074 endgame: bake the pool-envelope->display-gouraud gain (the retired
				# psx_brightness) into COLOR.rgb here - the choke point for every pooled add/sub/mix
				# run (particles + trap) - so the fold fragment is a clean texel*gouraud/128 with no
				# global uniform. Applied unconditionally (after the level_scale bake). Net-neutral
				# relocation of the old `* psx_brightness`.
				buf[i * 20 + 12] *= POOL_GOURAUD_GAIN
				buf[i * 20 + 13] *= POOL_GOURAUD_GAIN
				buf[i * 20 + 14] *= POOL_GOURAUD_GAIN
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.use_custom_data = true
			mm.mesh = _quad
			mm.instance_count = cnt
			mm.buffer = buf
			var inst := MultiMeshInstance3D.new()
			inst.multimesh = mm
			var mat: ShaderMaterial = (_mat_sub if mode == 2 else (_mat_mix if mode == 0 else _mat_add)).duplicate()
			if tex != null:
				mat.set_shader_parameter("effect_texture", tex)
				mat.set_shader_parameter("texture_size", tex.get_size())
			if use_palette and palette_tex != null:
				mat.set_shader_parameter("use_palette", true)
				mat.set_shader_parameter("palette_texture", palette_tex)
				mat.set_shader_parameter("palette_rows", float(palette_rows))
			inst.material_override = mat
			# Per-instance layer membership (compositor_layer primitive): join the SHARED fold layer
			# (Fold.FOLD_LAYER — same resource Fold.add uses, so pool carriers and direct Fold.add
			# carriers share ONE partition) and stamp the int32 caller-order key every fold input shares
			# via DepthMode.render_layer_order_for (ADR-0074):
			#   primary   = the run's OT depth BUCKET (round(ot_order_z / 0.19), far→near) × RANK_STRIDE, and
			#   secondary = the submission-stream rank fold_idx (< RANK_STRIDE) that preserves
			#               OTDepthPrimOrder's exact within-stream order — including the DEMI add↔sub age
			#               tie-break — inside a bucket. run["depth"] is the EXACT ot_order_z the ordering
			#               used (right depth_mode), so a callback that self-stamps via Fold.add
			#               interleaves with these runs by TRUE depth.
			if not native_blend:
				inst.render_layer = Fold.FOLD_LAYER
				inst.render_layer_order = DepthMode.render_layer_order_for(float(run.get("depth", 0.0)), fold_idx)
			inst.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
			_fold_root.add_child(inst)
			fold_idx += 1
	if fold_idx > 0 and not _logged:
		print("[engine-fold] folding %d runs through the engine" % fold_idx)
		_logged = true
