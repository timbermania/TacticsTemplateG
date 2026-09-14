extends "res://addons/exmateria_effects/subsystem/ColorSubsystem.gd"
## Runtime processor for palette-subsystem keyframes (map and unit tinting) — the
## combat-effect driver of the ADR-0067 unified colour stack (issue #164). A
## three-**channel** [ColorSubsystem]:
##   - affected_units: map tint      → TintedSurfaces (the reserved SURFACE_MAP token)
##   - caster:         caster unit   → TintedSurfaces
##   - target:         target unit   → TintedSurfaces
##
## Each channel's keyframes are reduced to a per-channel [ColorStack] by
## [method build_stack], then delivered by [method _deliver_output] so combat
## effects fold through `color_apply` over the real ALBEDO/CLUT entry — the
## faithful PALETTE applier (`color_tint_blend_apply @0x8008f710`, 5-bit CLUT,
## `quantize=true`, absolute base). This REPLACED the old imperative delta-domain
## stepper: the model, the 11 PSX blend modes, the DDA ramp, and the restore are all
## owned by ColorRecipe/ColorStack (proven byte-exact), so this subtype only maps
## parsed keyframes onto the stack. The declarative stack is re-derived every frame,
## so any `now` is directly evaluable (park / rewind come for free).
## Vault: [[Combat Color Appliers]]
## Vault: [[Map Tint]]

# ADR-0211 dec. 4 — the addon's façade is its whole symbol surface. One alias
# line per file keeps every use site's spelling, and makes a grep for
# `ExMateriaBattlefield` a complete census of host->addon symbol coupling.


const ColorStackClass = ExMateriaSchema.ColorStack

## The tint registry reached through its PORT rather than through the bare
## `TintedSurfaces` autoload identifier — a member may name no autoload at all
## (ADR-0308 dec. 1). `SURFACE_MAP` comes off the port too, and it has to: a GDScript
## `const` is not a property, so `node.SURFACE_MAP` on a resolved autoload fails at
## RUNTIME rather than at parse, which is the one respelling of this reach that would
## have gone green in the rig and red in the game.
const TintedSurfacesPort = preload("res://addons/exmateria_effects/install/TintedSurfacesPort.gd")
# 🟢 THE ILLUMINATION MACHINERY IS GONE (#1192, 2026-09-12). `build_illumination`,
# `_push_illum_phase_ops` and the `MapIlluminationDDA` alias are deleted. They were the
# producer half of Holy/E015's 8-bit additive map flood, unwired at rev 5 because the
# additive only ever tinted the PSX's untextured flat-colour terrain class and Godot
# renders textured terrain — so it computed to neutral 0 on every map.
#
# ADR-0208 dec. 5 declined this once, rightly: *"a counter is a weak reason."* What
# closed it was not a counter. #1192 asked for the run its own caveat said was missing,
# and got it — a probe in `build_illumination` fired 2x in its own unit test (the positive
# control, without which a zero means nothing) and 0x across eight battle and
# effect-playback scenes. On that evidence the owner ruled the future untextured-terrain
# scope dead, and ADR-0287 dec. 5's rule applies: an extraction must not carry dead code
# into an addon *"where a later reader will find it inside a published package and assume
# it is part of the interface."*
#
# THE DELIVERY HALF WENT WITH IT — `TintedSurfaces.update_illumination` and its
# `map_illum_add` sink. They were one feature in two files and #1224 had carried the
# second over on the same retention note; deleting one and keeping the other would have
# left a sink nothing feeds.
#
# ⚠️ WHAT STAYS, and it is deliberately not this addon's call:
# `addons/exmateria_battlefield/texturing/MapIlluminationDDA.gd` and the `map_illum_add`
# uniform in `indexed_color.gdshader` are `Battlefield`'s, still covered by
# `MapIlluminationDDATest`, and #1192 scopes them out. They are now independently
# unreached — a fact for that package to price, not for this one to act on.

# NAMED, NOT PRELOADED (ADR-0208 dec. 2 + dec. 5) — HISTORY NOW, kept because the warning
# below still binds. The alias this described (`MapIlluminationDDA`) was deleted at #1192;
# before that it had already been walked back from a `preload` of the addon script by full
# path, which was the last criterion-4 path reach from `src/`, the shipped game.
#
# ⚠️ DO NOT SPELL THE OLD PATH HERE, not even in prose. `check_lattice_scene.py` does not
# strip comments (its sibling `check_lattice_publish.py` does, via `_code_lines`), so a
# comment quoting the `res://addons/...` literal re-creates the very row this line paid —
# observed while writing this block, and recorded as ADR-0208 dec. 7.

# Parsed palette-keyframe data (PaletteData)
var palette_data = null

# Channel names.
const AFFECTED_UNITS = "affected_units"
const CASTER = "caster"
const TARGET = "target"
const ALL_CHANNELS = [AFFECTED_UNITS, CASTER, TARGET]

# Caster / target unit references for unit tinting — self-delivered to
# TintedSurfaces in advance() (ADR-0014). Set by EffectInstance via set_units().
var _caster_unit: WeakRef = null
var _target_unit: WeakRef = null


## Build the per-channel [ColorStack] for a phase from the parsed keyframes — the
## ADR-0067 combat-colour route. Each keyframe becomes one Color op pushed at its
## cumulative start frame, so the stack's DDA drives the ramp and the shader folds
## it over the real ALBEDO base. Consumer profile: this is the PALETTE applier
## (`color_tint_blend_apply @0x8008f710`) — 5-bit CLUT, so `quantize=true`, params
## ×1, base = the surface's committed colour (the fold's `base`, not delta-on-0).
func build_stack(channel: String, phase: String = EffectPhaseClass.PHASE_FOR_EACH) -> ColorStackClass:
	var stack: ColorStackClass = ColorStackClass.new()
	stack.set_quantize(true)  # palette applier is 5-bit CLUT (Consumer profile)
	_push_phase_ops(stack, channel, phase, 0)
	return stack


## Build ONE continuous stack for `channel` spanning EVERY phase whose start frame
## is known (the concatenated keyframe stream, the PSX-faithful model). The PSX color
## engine has NO phase concept — it is one stateful CLUT DDA; "phases" are just three
## authored blocks (phase1 / for_each / phase2). Concatenating them at their ABSOLUTE
## frame offsets (`phase_starts[phase]`) and folding at the absolute effect frame keeps
## phase1's settled tint present when for_each's ops fade in on top — no per-phase
## rebuild, so no pop at the boundary (the map color-parity fix, Raise/E005). A phase
## absent from `phase_starts` (not yet started) contributes nothing — and a future
## phase's ops are inert anyway (ColorStack guards `now < start_frame`). Phases are
## pushed in EffectPhase.ALL order so a later mode-8/10 restore sees the earlier layers.
func build_stream(channel: String, phase_starts: Dictionary) -> ColorStackClass:
	var stack: ColorStackClass = ColorStackClass.new()
	stack.set_quantize(true)  # palette applier is 5-bit CLUT (Consumer profile)
	# Studio Solo/Mute: a muted palette lane (palette:<phase>:<channel>) excludes its ops
	# from the fold — recompiled per frame, so this + a rescrub drops just that lane. The
	# runtime never mutes, so short-circuit the per-phase key build in the common path.
	var has_mutes: bool = not _muted_ops.is_empty()
	for phase in EffectPhaseClass.ALL:
		if not phase_starts.has(phase):
			continue
		if has_mutes and _muted_ops.has("%s/%s" % [phase, channel]):
			continue
		_push_phase_ops(stack, channel, phase, phase_starts[phase])
	return stack


## Walk one phase's channel keyframes in timeline order, invoking `emit(kf, at)` for
## each ENABLED keyframe at its absolute frame (`base_offset` + cumulative start). The
## single definition of the keyframe-timeline rule, shared by every sink (5-bit CLUT
## stack AND the 8-bit illumination DDA): the max_keyframe-1 processing window, the
## disabled-advances-timing-only skip, and the duration accumulation. A sink just says
## what to push — the timing is here so a fix lands once.
func _each_keyframe(channel: String, phase: String, base_offset: int, emit: Callable) -> void:
	var ch = palette_data.get_channel(phase, channel)
	if not ch or ch.keyframes.is_empty():
		return
	var start_frame := 0
	# The PSX stepper breaks at kf_idx >= max_keyframe - 1, so it applies only
	# indices 0..max_keyframe-2; the rest are terminators/padding.
	var last_idx: int = mini(ch.keyframes.size(), maxi(0, ch.max_keyframe - 1))
	for i in range(last_idx):
		var kf = ch.keyframes[i]
		# Disabled keyframes (ctrl bit 7 clear) advance timing only — the PSX makes
		# no apply call, so they contribute nothing.
		if kf.enabled:
			emit.call(kf, base_offset + start_frame)
		start_frame += maxi(1, kf.duration_frames)


## Push one phase's channel keyframes onto the 5-bit CLUT `stack`, each at its absolute
## frame. Shared by build_stack (single phase, offset 0) and build_stream (all phases).
func _push_phase_ops(stack: ColorStackClass, channel: String, phase: String, base_offset: int) -> void:
	_each_keyframe(channel, phase, base_offset, func(kf, at: int) -> void:
		stack.push_op(kf.blend_mode, kf.rgb.x, kf.rgb.y, kf.rgb.z, kf.time_value, at))


func initialize(data) -> void:
	"""Initialize subsystem with parsed palette-keyframe data. Channels are declared
	for owner_id / phase scaffolding; the tint itself is derived on demand from the
	keyframes by build_stack (no per-frame cursor state to seed)."""
	palette_data = data
	_setup_channels(ALL_CHANNELS)


func _evaluate(_channel: String, _phase: String) -> void:
	"""No-op: the palette timeline is DECLARATIVE (build_stack + the ColorStack DDA),
	so there is no per-frame stepper. _deliver_output rebuilds and delivers the stack
	each frame. Overridden empty because the base marks _evaluate abstract."""
	pass


func _reset_outputs() -> void:
	"""No held per-frame output state — the stack is rebuilt from the keyframes on
	every _deliver_output, so there is nothing to clear here."""
	pass


func set_units(caster, target) -> void:
	"""Set caster/target unit refs for unit tinting. The palette subsystem
	self-delivers the caster/target tints (ADR-0014), so it holds the unit refs
	EffectInstance used to push from. WeakRef avoids keeping freed units alive."""
	_caster_unit = weakref(caster) if caster else null
	_target_unit = weakref(target) if target else null


func _deliver_output() -> void:
	"""Self-deliver palette output (ADR-0014, ADR-0067): each channel's ColorStack
	→ its overlay, folded through color_apply over the real base. Map tint →
	TintedSurfaces.SURFACE_MAP, caster/target tints → the units' own tokens. Evaluated at the
	phase-relative `now` so the stack DDA lines up with the keyframe start frames.

	NOTE: for the for_each phase (the common combat case) `now` counts from effect
	start = the keyframe origin. Phased effects (phase1/phase2) rely on the base's
	phase-start baseline; a live combat A/B is the reassurance step (the handoff's
	optional eyeball) since combat effects don't render headless."""
	# Every palette channel folds the WHOLE keyframe stream (all started phases at their
	# absolute offsets) at the absolute effect frame — the PSX-faithful one-stateful-CLUT
	# model, so no channel pops back to base at a phase boundary (color-parity fix,
	# Raise/E005). The PSX color engine has no phase concept; map/caster/target are just
	# different CLUT banks driven by the same continuous DDA.
	TintedSurfacesPort.update_stack(TintedSurfacesPort.SURFACE_MAP, owner_id, build_stream(AFFECTED_UNITS, _phase_first_frame), _frame)
	# The map ILLUMINATION (8-bit additive applier, FUN_80090dec) is INTENTIONALLY NOT
	# delivered (Holy/E015 rev 5): statically it only ever tints the PSX's UNTEXTURED
	# flat-colour terrain primitive class (d2b4/d568), which Godot doesn't render — all
	# Godot map tiles are textured, and the framebuffer A/B over Holy's map is pixel-
	# identical with the additive on vs off. Delivering the flood globally over the textured
	# map over-brightened terrain the PSX never additive-tints (the map "clicking"/wash).
	# 🟢 #1192 DELETED THE MACHINERY that used to be kept here "for a future
	# untextured-terrain class" — see the header. The REASON it is not delivered is
	# unchanged and is why it was deletable; if such a class is ever added, the additive is
	# rebuilt scoped to that primitive class, not restored globally over the map.
	# Unit tints are runtime-only — no live caster/target in the editor preview.
	if Engine.is_editor_hint():
		return
	if _caster_unit:
		var caster = _caster_unit.get_ref()
		if caster:
			TintedSurfacesPort.update_stack(caster.get_instance_id(), owner_id, build_stream(CASTER, _phase_first_frame), _frame)
	if _target_unit:
		var target = _target_unit.get_ref()
		if target:
			TintedSurfacesPort.update_stack(target.get_instance_id(), owner_id, build_stream(TARGET, _phase_first_frame), _frame)
