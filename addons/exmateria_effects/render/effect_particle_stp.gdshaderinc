// Shared code for STP (Semi-Transparent Polygon) effect particle shaders.
// Included by effect_particle_opaque (production) and, since #227, only the
// reference-probe copies at tools/probe_shaders/effect_particle_mode0..3 —
// the transparent fold moved to the display-space compositor, so the mode
// shaders are no longer in the production render path.
// Contains: uniforms, varyings, vertex function, STP sampling helper.
//
// Depth is the unified PSX Ordering-Table model (ADR-0009): the per-object
// path (world origin MODEL_MATRIX[3] + VIEW), biased by the per-instance
// depth_mode packed into MODEL_MATRIX[2][2].
//
// ADR-0039: per-instance state is packed into MultiMesh per-instance buffers.
// Today's per-mesh uniforms (corner_*, uv_rect_data, depth_mode, color_modulate,
// semi_trans_on) are gone — see EffectParticleRenderer.gd `_write_instance()`
// for the GDScript-side packing.
//
// Per-instance packing layout:
//   MODEL_MATRIX basis (9 floats): corners + depth_mode
//     basis[0] = (tl.x, tl.y, tr.x)
//     basis[1] = (tr.y, bl.x, bl.y)
//     basis[2] = (br.x, br.y, depth_mode_as_float)
//   MODEL_MATRIX[3].xyz: particle world position (used for ot_depth +
//                       billboard center)
//   INSTANCE_CUSTOM (vec4): uv_rect (x, y, w, h) normalized
//   COLOR (vec4): color_modulate.rgb + semi_trans_on flag in alpha
// Vault: [[Effect MultiMesh Pool]]
#include "res://addons/exmateria_schema/compositing_key/ot_depth.gdshaderinc"

// === Shared uniforms ===
// NO source_color to match GL Compatibility behavior
uniform sampler2D effect_texture : filter_nearest, repeat_disable;
uniform vec2 texture_size = vec2(128.0, 256.0);

// Paletted-sampling path (ADR-0022 indexed-texture pattern, extended to TRAP1
// particles). When use_palette=true, effect_texture is an indexed-grayscale
// TGA (R=G=B=index*17, A=255) and the real color comes from palette_texture
// at row palette_row. Default off → effect_texture is RGBA-baked as before.
uniform bool use_palette = false;
uniform sampler2D palette_texture : filter_nearest, hint_default_transparent;
// Palette texture HEIGHT (rows). The CLUT row V must divide by the ACTUAL row count, not a
// hardcoded 16 — trap's TRAP1 CLUT is 16 rows but the tile cursor's RANGETILE CLUT is only 9, so
// a fixed /16.0 sampled the wrong row for the cursor. Mirrors the fp2.y=pal_rows field the retired
// combat_displayspace_composite.glsl fold used (#228 Phase 3). Default 16.0 keeps trap/the RGBA path byte-identical.
uniform float palette_rows = 16.0;
// palette_row is PER-INSTANCE (ADR-0045): packed into COLOR.a by the MultiMesh
// writer and recovered into v_palette_row below. Only read when use_palette=true
// (trap), so the RGBA-baked E### path is unaffected.

uniform bool srgb_to_linear = true;
// PSX color calibration global (tunable via ShaderCalibrationPanel). psx_brightness was REMOVED
// from this shared include (ADR-0074 endgame): the production folds that include this file
// (effect_fold_add/sub/mix) no longer multiply it — the pool→gouraud gain is baked into COLOR by
// EngineFoldCompositor — and the opaque path never used it. Only the throwaway tools/probe_shaders
// reference copies still multiply psx_brightness, and they now declare it locally. Keeping the
// declaration here would leave psx_brightness "reachable" from the fold closure and fail
// check_no_psx_brightness_in_fold.py.
//
// 🔴 texel_blend_gamma LEFT THE SAME WAY, and the delay is the interesting part (#1198,
// ADR-0290 dec. 3, #1217 (c)). This comment used to end "psx_gamma stays (still read by
// the probes' pow branch)", which was true and was the whole defect: ADR-0190 dec. 3 lets
// only a NON-SYSTEM addon declare a `global uniform`, so that line was `membership_arms`
// arm 4b — an arm that does not report debt, it FAILS — and no selection pass in six
// extractions had ever run it (ADR-0287). The reader census is seven code sites tree-wide
// and ZERO in the membership: three in `src/ui3/shaders/`, which declare it themselves
// (`formation_box.gdshaderinc:27`, `formation_orb.gdshaderinc:20`), and four in
// `tools/probe_shaders/effect_particle_mode{0..3}.gdshader`, which now carry a local
// `const float texel_blend_gamma = 1.4;` matching `project.godot:882` — verbatim what those same
// four files already do for `psx_brightness`, per the paragraph above. So this is the
// cheaper half of ADR-0287 dec. 3's pair: not a move, and not a new owner for the name,
// just the four throwaway probes paying for what only they read.

// PAR (ADR-0036): Pattern 2, anchor-only. The particle's anchor (object origin)
// projects through MVP, its clip.x gets PAR'd, then the billboard corner offset
// is added un-stretched — so the particle tracks the stretched map but the
// sprite art renders at native PSX pixel aspect. pixel_aspect comes from the shared
// seam (ADR-0060) the map, skirt, overlays, and unit shaders also read.
#include "res://addons/exmateria_platform/pixel_aspect/pixel_aspect.gdshaderinc"
// Sprite stretch (ADR-0044): horizontal billboard-WIDTH multiplier for the EFFECTS
// taxonomy (particles/projectiles/shadows/callbacks), 1.0 = native — declared by the
// PORT that pushes it (`PSXDisplay._apply_fx_stretch`) rather than here. This file used to
// spell `global uniform float psx_fx_stretch;` itself, which is arm 4b's other half and is
// MECHANICAL to fix because the seam already sits beside `pixel_aspect`:
// `exmateria_battlefield`'s `cursor_fold.gdshaderinc:39` and `tile_cursor.gdshaderinc:34`
// do exactly this (ADR-0220 dec. 2, ADR-0287 dec. 3). The seam also carries
// `psx_cursor_stretch`, which nothing here reads and which costs nothing: both names are
// already in this project's `[shader_globals]` (`project.godot:890/894`), and a global
// uniform a consumer has not declared reads 0 with no error anywhere (ADR-0238) — which is
// the install requirement the seam's own note says it can centralise but never remove.
#include "res://addons/exmateria_platform/display_port/psx_sprite_stretch.gdshaderinc"

// === Varyings ===
varying vec4 uv_rect;
varying float v_palette_row;  // ADR-0045: per-instance palette row (trap), from COLOR.a

// === Vertex (billboard + corner interpolation) ===
void vertex() {
	// Unpack per-instance corners and depth_mode from MODEL_MATRIX basis
	// (ADR-0039 packing — basis would otherwise be unused because the
	// MODELVIEW rebuild below discards it for billboarding).
	vec2 corner_tl = vec2(MODEL_MATRIX[0][0], MODEL_MATRIX[0][1]);
	vec2 corner_tr = vec2(MODEL_MATRIX[0][2], MODEL_MATRIX[1][0]);
	vec2 corner_bl = vec2(MODEL_MATRIX[1][1], MODEL_MATRIX[1][2]);
	vec2 corner_br = vec2(MODEL_MATRIX[2][0], MODEL_MATRIX[2][1]);
	int depth_mode = int(MODEL_MATRIX[2][2] + 0.5);

	// uv_rect comes from INSTANCE_CUSTOM (vec4)
	uv_rect = INSTANCE_CUSTOM;
	// Per-instance palette row (use_palette path only): packed as palette_id/15 in COLOR.a
	v_palette_row = COLOR.a * 15.0;

	// Bilinear interpolation of corners based on mesh UV
	vec2 top = mix(corner_tl, corner_tr, UV.x);
	vec2 bottom = mix(corner_bl, corner_br, UV.x);
	vec2 corner = mix(top, bottom, UV.y);

	// Billboard: position particle at MODEL_MATRIX origin, facing camera.
	// MODEL_MATRIX[3] still carries the per-instance world position even
	// though the basis is repurposed.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);

	// Apply corner offset in billboard space
	const float PSX_SCALE = 1.0 / 28.0;
	VERTEX.x = corner.x * PSX_SCALE;
	VERTEX.y = -corner.y * PSX_SCALE;
	VERTEX.z = 0.0;

	// Unified OT depth: per-object path (world origin + VIEW), biased by depth_mode.
	ot_computed_depth = ot_depth(MODEL_MATRIX[3].xyz, PROJECTION_MATRIX, VIEW_MATRIX, depth_mode);

	// PAR (Pattern 2, anchor-only): project the particle's anchor (object
	// origin) through MVP, PAR its clip.x, add the billboard corner offset
	// un-stretched. POSITION.x = vertex.x + anchor.x * (pixel_aspect - 1); the
	// billboard's view-space footprint is preserved at native PSX aspect.
	// Anchor tracks the map (pixel_aspect); offset stretches by the EFFECTS width
	// multiplier (psx_fx_stretch, default 1.0 = native). ADR-0044.
	vec4 anchor_clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	vec4 vertex_clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POSITION = pixel_aspect_anchor(vertex_clip, anchor_clip, psx_fx_stretch);
}

// === STP semi-transparent sampling ===
// Returns the texel color after discarding non-STP pixels.
// Discards: transparent (a < 0.01), opaque (a > 0.9), or black pixels.
// When use_palette=true, recovers the palette index from the indexed-grayscale
// effect_texture, then samples palette_texture at (idx, palette_row); the
// post-lookup pixel is the one the STP discard rules run against.
vec4 stp_sample(vec2 frag_uv) {
	vec2 uv_origin = uv_rect.xy;
	vec2 uv_size = uv_rect.zw;
	vec2 uv = uv_origin + frag_uv * uv_size;

	vec4 col = texture(effect_texture, uv);

	if (use_palette) {
		int idx = int(col.r * 15.0 + 0.5);
		vec2 palette_uv = vec2(
			(float(idx) + 0.5) / 16.0,
			(v_palette_row + 0.5) / palette_rows
		);
		col = texture(palette_texture, palette_uv);
	}

	// Only render semi-transparent pixels (STP=1 -> alpha=128 -> ~0.5)
	// Discard: transparent (a < 0.01) OR opaque (a > 0.9) OR black
	if (col.a < 0.01 || col.a > 0.9 || (col.r < 0.01 && col.g < 0.01 && col.b < 0.01)) {
		discard;
	}

	return col;
}
