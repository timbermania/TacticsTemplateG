shader_type spatial;
// Engine-fold variant of addons/exmateria_effects/callbacks/effect_callback_additive.gdshader: adds `compositor_layer`
// so the 4.8-dev engine Pass B routes callback ArrayMeshes (grids/rings/tubes/ribbons) into the
// compositor-owned display scratch instead of the transparent color layer. Without this, callbacks
// draw into the color layer and Pass C's coverage-discard clobbers them under any folded prim's
// footprint (the E065 Shiva "spikes pierce the flash" bug). See memory
// engine-shaded-fold-passB-demi2-stage1 and the handoff on un-folded callback meshes.
//
// IDENTICAL uniforms + vertex/fragment to effect_callback_additive so the callback's own
// _material (set_shader_parameter each frame) keeps working when EffectCallback swaps only .shader.
// Loaded ONLY when Fold.owns() (fork >= 4.8 + Forward+); the stock/Mobile
// path keeps effect_callback_additive.
// OCCLUSION (2026-07-27): depth-test ENABLED (dropped depth_test_disabled), depth_draw_never kept — the
// engine fold pass binds the shared opaque scene depth and tests DEPTH (= ot_computed_depth, per-face
// reversed-Z centroid) with GREATER_OR_EQUAL, so a callback tube half-behind a wall clips PER-FRAGMENT
// even though its fold ORDER is a single render_layer_order bucket. See effect_fold_add.gdshader.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, compositor_layer;
// psx-prim: textured — ALBEDO = texel * gouraud/128 (PSX (texel*color)>>7). ADR-0074 color-math clause.

// Unified PSX Ordering-Table depth (ADR-0009): per-face centroid in CUSTOM0
// (AVSZ4-baked), STANDARD mode.
#include "res://addons/exmateria_schema/compositing_key/ot_depth.gdshaderinc"

uniform sampler2D effect_texture : filter_nearest, repeat_disable;
uniform vec4 uv_rect = vec4(0.0, 0.0, 1.0, 1.0);  // x, y, w, h (normalized)
// use_texture / use_psx_brightness are set ONCE per callback subclass at material-build time (a
// textured decal vs a flat-Gouraud grid is a static per-producer trait), not varied per-prim per-
// frame — so this is material configuration, not the data-driven axis branching ADR-0074 forbids
// inside a compositor_layer material. If callbacks ever split into distinct textured/flat producers,
// prefer two monomorphic materials over the bool.
uniform bool use_texture = false;
uniform bool use_psx_brightness = true;  // false for callbacks with own brightness tables

// Display-space gouraud gain (the retired `psx_brightness` global, ADR-0074 endgame). Callbacks whose
// COLOR is a pool-envelope curve modulate (use_psx_brightness=true, the ÷255→÷128 class) take this
// scale; callbacks with their own brightness tables (use_psx_brightness=false) stay at 1.0. Baked as a
// shader-local const (exact retired 2.2 = net-neutral) so the fold is off the global and it can be
// deleted — mirrors crystal_fold's gain const + the particle path's POOL_GOURAUD_GAIN. Named
// PSX_OUTPUT_LEVEL to agree with the in-scene twin effect_callback_additive, which carries the same
// 2.2 under that name (ADR-0191 dec. 6 — the pair used to differ by this word alone).
const float PSX_OUTPUT_LEVEL = 2.2;

// PAR (ADR-0036): Pattern 1, full-stretch — see effect_callback_additive.gdshader for the rationale.
#include "res://addons/exmateria_platform/pixel_aspect/pixel_aspect.gdshaderinc"

void vertex() {
	// Per-face centroid in CUSTOM0 (local space) -> MODELVIEW; STANDARD mode (0).
	ot_computed_depth = ot_depth(CUSTOM0.xyz, PROJECTION_MATRIX, MODELVIEW_MATRIX, 0);

	// PAR (Pattern 1, full-stretch, via the shared seam).
	vec4 clip_pos = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION = pixel_aspect_full(clip_pos);
}

void fragment() {
	float brightness = use_psx_brightness ? PSX_OUTPUT_LEVEL : 1.0;
	if (use_texture) {
		vec2 uv = uv_rect.xy + UV * uv_rect.zw;
		vec4 tex = texture(effect_texture, uv);
		// STP filtering: only render semi-transparent pixels (alpha ~0.5)
		// Discard: transparent (a < 0.01), opaque (a > 0.9), or black
		if (tex.a < 0.01 || tex.a > 0.9 || (tex.r < 0.01 && tex.g < 0.01 && tex.b < 0.01)) {
			discard;
		}
		// PSX texture blend: texel * vertex_color >> 7 (not >> 8).
		ALBEDO = tex.rgb * COLOR.rgb * brightness;
		ALPHA = 1.0;
	} else {
		ALBEDO = COLOR.rgb * brightness;
		ALPHA = 1.0;
	}
	DEPTH = ot_computed_depth;
}
