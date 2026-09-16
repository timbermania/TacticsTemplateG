shader_type spatial;
render_mode unshaded, cull_disabled;

// TacticsG's HOST half of the effects addon's screen/background contract.
//
// `addons/exmateria_effects/overlay/ScreenEffectOverlay.gd` looks for a node named
// exactly `ScreenBackground` under the current Camera3D and writes four corner
// colours plus the ColorStack uniforms into its `material_override`. That is the
// whole contract; this file is what satisfies it. It is a HOST shader on purpose —
// `addons/` is a byte-pinned 241-file inventory enforced by
// `tools/effects/verify_installation.py`, so nothing new may live there.
//
// Derived from (not copied byte-for-byte):
//   fft-monorepo-main/godot-learning/addons/exmateria_battlefield/camera/screen_background.gdshader
// Two DELIBERATE divergences from that reference, both load bearing:
//
// 1. NO PSX DITHER. The reference `#include`s
//    `res://addons/exmateria_platform/dither/psx_dither.gdshaderinc`, which was NOT
//    part of this project's pinned selection and may not be added to it. The dither
//    is a cosmetic quantization pass, so it is dropped rather than reimplemented.
//
// 2. IT WRITES `DEPTH`, the reference does not. The reference leaves the quad at
//    NDC z = 0 and relies on Forward+'s reversed clip range, where 0 IS the far
//    plane. This project runs `gl_compatibility` (project.godot `[rendering]`),
//    whose NDC z spans [-1, 1] with near POSITIVE — measured, see
//    `src/shaders/psx_window_depth.gdshaderinc`. NDC 0 there is the MID-plane, so
//    the reference's quad would occlude every tile behind the midpoint of the
//    battlefield. Writing a window depth directly is renderer-agnostic: window
//    depth is [0, 1] with near high under BOTH renderers, so BACKGROUND_DEPTH ~ 0
//    is "as far away as anything can be" either way.
//
// The ColorStack header below is the one addon include this project deliberately
// retained for exactly this seam (docs/effects-installation.md, "Explicit
// configuration"). It supplies the uniforms `ScreenEffectOverlay._push_color_stack`
// writes for the additive TINT.
// Vault: [[Background Opcode]]

// 4-corner Gouraud shading (PSX-style), written by ScreenEffectOverlay.set_corners.
// These are set from code as raw Vector3s, so the `source_color` hint is the
// contract's spelling rather than a conversion that ever runs.
uniform vec3 color_tl : source_color = vec3(0.0, 0.0, 0.0);
uniform vec3 color_tr : source_color = vec3(0.0, 0.0, 0.0);
uniform vec3 color_bl : source_color = vec3(0.0, 0.0, 0.0);
uniform vec3 color_br : source_color = vec3(0.0, 0.0, 0.0);

#include "res://addons/exmateria_schema/colour_model/color_stack.gdshaderinc"

// Not 0.0: a depth buffer cleared to the far value plus a strict GREATER test would
// reject the quad entirely and the background would never draw at all. One part in
// a hundred thousand is closer than any real geometry in a battle and passes either
// comparison. (This is a WINDOW depth in [0, 1], not NDC — do not route it through
// psx_window_depth.)
const float BACKGROUND_DEPTH = 0.00001;

void vertex() {
	// Map quad corners directly to NDC screen corners, bypassing MVP.
	// Makes the mesh fill the screen regardless of camera zoom, projection or pose.
	// pixel-aspect-exempt: fullscreen NDC quad, not battle-space geometry.
	// The z here only has to survive clipping; `fragment()` decides the real depth.
	POSITION = vec4(sign(VERTEX.xy), 0.0, 1.0);
}

void fragment() {
	// Bilinear interpolation of the 4 corner colours.
	// SCREEN_UV: (0,0) = top-left, (1,1) = bottom-right.
	vec3 top = mix(color_tl, color_tr, SCREEN_UV.x);
	vec3 bottom = mix(color_bl, color_br, SCREEN_UV.x);
	vec3 base = mix(top, bottom, SCREEN_UV.y);

	// TINT mode (additive) folds through the unified stack: the summed per-owner
	// delta is a scale=1 affine layer over the gradient base, identity when no
	// effect tints the background. ADR-0067.
	ALBEDO = color_apply(base, 0);
	DEPTH = BACKGROUND_DEPTH;
}
