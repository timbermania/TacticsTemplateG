extends "res://addons/exmateria_effects/subsystem/ColorSubsystem.gd"
## Runtime processor for an effect's SCREEN channel — the background gradient (the
## sky/void behind the map). A single-channel [ColorSubsystem], now DECLARATIVE: it
## mirrors the PSX combat background-gradient applier `FUN_80090258 @0x80090258`, which
## is the SAME 11-mode colour engine as the CLUT applier, only in 8-bit framebuffer
## space (ADR-0067 slice 5b — one colour model). So the screen shares the palette's
## [ColorStack]/[ColorRecipe] machinery: build one continuous op stream across phases
## (build_stream) and fold the map's TOP and BOTTOM baselines through it.
##
## The screen lane carries TWO tween archetypes, selected by the keyframe ctrl bit 7:
##   - Blend  (ctrl bit 7 SET): recolor the backdrop through one of the 11 color-math
##     modes (FUN_80090258), the keyframe's SHARED RGB param over each vertex's own
##     baseline — top and bottom stay a gradient, both tinted by the same op. mode 5 =
##     baseline/2 + param (byte-exact, verified live: TOP baseline (32,64,124), dim
##     floor (16,32,62)).
##   - Gradient (ctrl bit 7 CLEAR): an ABSOLUTE set of the backdrop endpoints to the
##     keyframe's explicit RGB bytes (screen_gradient_color_setter @0x80090048) — a REAL
##     write, not a timing-only no-op (the refuted "FADE" belief, now dynamically
##     confirmed: SCREEN_KEYFRAME_BLEND_GRADIENT_E173_NIGHTSWORD.md).
## Both ramp linearly over the keyframe duration (Time*8), snap if Time==0.
##
## Because it folds ONE stream spanning all started phases at their absolute offsets,
## it is continuous across phase seams with no pop (the palette build_stream property).
## Vault: [[Color Screen Opcode]]
## Vault: [[Display Space Blend Fold]]
## Vault: [[Screen Effect Gradient System]]

const ScreenData = preload("res://addons/exmateria_effects/file_model/ScreenData.gd")

## The backdrop overlay reached through its PORT rather than through the bare
## `ScreenEffectOverlay` autoload identifier. A member may name no autoload at all
## (ADR-0308 dec. 1), and this file's single `:171` reach was one of the three
## `known_failures.tsv` rows the rig could not compile — the one it described as
## *"a pure CASCADE plus a reach of its own"*.
const ScreenOverlayPort = preload("res://addons/exmateria_effects/install/ScreenOverlayPort.gd")

const ColorStackClass = ExMateriaSchema.ColorStack

## And the same for `addons/exmateria_schema`, whose six generic-English globals
## collapsed onto one façade in the same pass (ADR-0212 dec. 1).
const ColorRecipe = ExMateriaSchema.ColorRecipe

## Screen has a single implicit channel (the whole screen). It is the degenerate
## one-channel case of the base's N-channel model.
const CHANNEL := "screen"

## Which backdrop endpoint a fold targets. A Gradient keyframe sets the two stops
## INDEPENDENTLY — the TOP stop folds `start_r/g/b`, the BOTTOM stop folds `end_r/g/b`
## — so the stream is built once per endpoint. Blend ops are endpoint-agnostic (the
## shared param tints both baselines the same), so `endpoint` only steers the Gradient
## target selection in `_push_gradient_op`.
const ENDPOINT_TOP := 0
const ENDPOINT_BOTTOM := 1

## Folded gradient endpoints (0-1): the map's default TOP/BOTTOM baseline run through
## the screen op stream at the current frame. Delivered to ScreenEffectOverlay as a
## top/bottom-delta gradient layer.
var top_color: Color = Color.BLACK
var bottom_color: Color = Color.BLACK
var _default_top: Color = Color.BLACK
var _default_bottom: Color = Color.BLACK

# Parsed screen-keyframe data (untyped to avoid load-order issues).
var screen_data = null


func initialize(data, default_top: Color = Color.BLACK, default_bottom = null) -> void:
	"""Initialize with parsed screen-keyframe data + the map's default gradient TOP and
	BOTTOM baselines (ScreenEffectOverlay's default corners). If default_bottom is
	omitted it defaults to default_top (a flat background)."""
	screen_data = data
	_default_top = default_top
	_default_bottom = default_top if default_bottom == null else default_bottom
	top_color = _default_top
	bottom_color = _default_bottom
	_setup_channels([CHANNEL])


## Build ONE ColorStack spanning every started phase's screen keyframes at their
## absolute offsets (mirror of PaletteSubsystem.build_stream) — the 8-bit framebuffer
## consumer profile (quantize=false, param_max=255). Continuous across phase seams.
func build_stream(phase_starts: Dictionary, endpoint: int = ENDPOINT_TOP) -> ColorStackClass:
	var stack := ColorStackClass.new()
	stack.set_quantize(false)   # 8-bit framebuffer, full float
	stack.set_param_max(255)    # screen gradient applier is 8-bit (FUN_80090258)
	for phase in EffectPhaseClass.ALL:
		# Studio Solo/Mute: a muted screen lane (screen:<phase>) excludes its phase's ops
		# from the fold — the screen recompiles per frame, so this + a rescrub drops just
		# that lane. Muting all phases ⇒ empty stream ⇒ neutral backdrop.
		if phase_starts.has(phase) and not _muted_ops.has(phase):
			_push_phase_ops(stack, phase, phase_starts[phase], endpoint)
	return stack


## Push one phase's screen keyframes onto `stack` at `base_offset + cumulative start`.
## Blend keyframes (ctrl bit 7 set) push an 11-mode apply; Gradient keyframes (ctrl bit 7
## clear) push an absolute-set of the backdrop — BOTH consume the keyframe's duration and
## advance the cumulative offset. The screen ramp is linear over Time*8, passed as `dur`.
func _push_phase_ops(stack: ColorStackClass, phase: String, base_offset: int, endpoint: int = ENDPOINT_TOP) -> void:
	var ch = screen_data.get_channel(phase)
	if not ch or ch.keyframes.is_empty():
		return
	var start_frame := 0
	# Keyframe window = 0..max_keyframe-2, IDENTICAL to the palette stepper. Both
	# `advance_screen_color_track @0x801A45C8` and its for_each twin
	# `for_each_phase_timeline_tick @0x801A3408` break on the guard `index < max_keyframe-1`,
	# so the largest index that enters is max_keyframe-2 (dynamically confirmed live on E173:
	# no time=63/Time=600 call for idx11/idx12 anywhere in the setter-call trace —
	# SCREEN_KEYFRAME_BLEND_GRADIENT_E173_NIGHTSWORD.md §2.1/§5). The retired screen stepper
	# was believed to use a wider inclusive window; that is refuted — PSX drops the tail
	# Blends the wide bound applied. The visual those effects need is the Gradient path
	# (bit-7-clear, handled below), not the out-of-window Blends.
	var last_idx: int = mini(ch.keyframes.size(), maxi(0, ch.max_keyframe - 1))
	for i in range(last_idx):
		var kf = ch.get_keyframe(i)
		var dur := maxi(1, kf.duration_frames)
		if kf.mode == ScreenData.ScreenMode.BLEND:  # Blend (ctrl bit 7 set): a real 11-mode apply
			# The screen Blend stepper applies the signed param DOUBLED (`start << 1`) — the
			# 8-bit framebuffer applier's convention, PROVEN live on E173/savestate9 (§2 of the
			# living doc). double_param=true; the palette CLUT path does NOT double.
			stack.push_op(kf.blend_mode, kf.start_r_raw, kf.start_g_raw, kf.start_b_raw,
				kf.time_value, base_offset + start_frame, ColorStackClass.MASK_WHOLE, dur, true)
		else:  # Gradient (ctrl bit 7 clear): absolute-set this endpoint's stop
			_push_gradient_op(stack, kf, base_offset + start_frame, dur, endpoint)
		start_frame += dur


## Push one Gradient (ctrl bit-7-clear) keyframe: an ABSOLUTE set of the backdrop to the
## keyframe's explicit (start_r,g,b) bytes (unsigned 0-255), ramped linearly over `dur`
## (Time*8) frames. Mirrors PSX `screen_gradient_color_setter @0x80090048` re-targeting the
## shared gradient block (SCREEN_KEYFRAME_BLEND_GRADIENT_E173_NIGHTSWORD.md §1/§3). Modeled
## as an affine with scale 0 (bias = target): the fold `c.lerp(scale*src + bias, progress)`
## then ramps whatever the backdrop currently is toward the absolute target, and scale=0
## discards the per-vertex baseline so top and bottom both land on the SAME target.
##
## ENDPOINTS: the PSX engine sets the two backdrop stops INDEPENDENTLY — top from start
## (@0x42), bottom from end (@0xa5). `endpoint` selects which this stream folds: TOP folds
## `start_r/g/b`, BOTTOM folds `end_r/g/b`. All 32,510 shipped Gradient keyframes have
## start == end (a uniform set), so faithful playback of every shipped effect is unchanged;
## the split only becomes observable when the studio AUTHORS a top != bottom Gradient (#255
## scope B, the two-picker editor), and is proven by ScreenSubsystemTest's endpoint test.
##
## TODO(base-vs-current): whether a Blend AFTER a Gradient reads the map baseline or the
## just-set block is unconfirmed for the screen path (only affects luma modes 6/7, which no
## in-window screen keyframe uses — §"watch out"); revisit if a 6/7-after-Gradient effect appears.
func _push_gradient_op(stack: ColorStackClass, kf, now: int, dur: int, endpoint: int = ENDPOINT_TOP) -> void:
	var target: Vector3
	if endpoint == ENDPOINT_BOTTOM:
		target = Vector3(kf.end_r_raw, kf.end_g_raw, kf.end_b_raw) / 255.0
	else:
		target = Vector3(kf.start_r_raw, kf.start_g_raw, kf.start_b_raw) / 255.0
	stack.push_layer(ColorRecipe.affine(Vector3.ZERO, target), now, dur, ColorStackClass.MASK_WHOLE)


func _evaluate(_channel: String, _phase: String) -> void:
	"""No-op: the screen timeline is DECLARATIVE (build_stream + the ColorStack DDA),
	like the palette. _deliver_output rebuilds and folds the stream each frame.
	Overridden empty because the base marks _evaluate abstract."""
	pass


func _reset_outputs() -> void:
	"""Reset the folded gradient endpoints to the map defaults."""
	top_color = _default_top
	bottom_color = _default_bottom


func _deliver_output() -> void:
	"""Self-deliver the screen gradient to ScreenEffectOverlay (ADR-0014). Folds the
	map's TOP and BOTTOM baselines through the one screen op stream at the absolute
	effect frame (PSX-faithful, no seam pop), delivered as a top/bottom-delta layer."""
	# One stream PER endpoint: a Gradient sets top/bottom independently (start vs end), so the
	# top baseline folds through the top-target stream and the bottom through the bottom-target
	# one. Blend ops are identical in both streams (endpoint-agnostic), so shipped effects (all
	# start==end) fold identically to the single-stream path.
	top_color = _fold_color(build_stream(_phase_first_frame, ENDPOINT_TOP), _default_top)
	bottom_color = _fold_color(build_stream(_phase_first_frame, ENDPOINT_BOTTOM), _default_bottom)
	ScreenOverlayPort.update_layer_gradient(owner_id,
		_delta(top_color, _default_top), _delta(bottom_color, _default_bottom))


## Delta of a folded colour from its baseline (the overlay composites default + delta).
func _delta(folded: Color, base: Color) -> Color:
	return Color(folded.r - base.r, folded.g - base.g, folded.b - base.b, 1.0)


## Probe the current folded TOP backdrop colour at the parked frame WITHOUT delivering to the
## overlay — the WYSIWYG target-colour solver folds this per candidate signed param (#255). It
## reuses the EXACT forward path _deliver_output uses (build_stream + _fold_color at `_frame`),
## so a param the solver picks provably matches the live preview. Pure read: no overlay write,
## no clock touch.
func fold_top() -> Color:
	return _fold_color(build_stream(_phase_first_frame), _default_top)


## Fold one baseline colour through the stream at the absolute frame, clamped to [0,1]
## (the PSX applier clamps each channel to [0,255]).
func _fold_color(stream: ColorStackClass, base: Color) -> Color:
	var v: Vector3 = stream.fold(Vector3(base.r, base.g, base.b), 0, _frame)
	return Color(clampf(v.x, 0, 1), clampf(v.y, 0, 1), clampf(v.z, 0, 1), 1.0)
