shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D sprite_texture : source_color, filter_nearest;
uniform vec4[16] palette_colors : source_color; // palette of 16 colors each
uniform vec3 unit_tint = vec3(0.0, 0.0, 0.0);
uniform bool billboard_enabled = false;

#include "res://src/shaders/psx_depth_common.gdshaderinc"

// The unified PSX colour stack (ADR-0067). `TintedSurfaces` pushes the effects
// addon's CASTER and TARGET palette tracks into `color_layer_*` + `quantize` through
// `ColorStack.apply_packed`, keyed by the unit's `char_body` instance id, and
// `color_apply` below folds them. Declaring this include IS the unit half of the
// receiving contract docs/effects-installation.md:17-19 held this header for;
// `src/content_scripts/map/map_shader.gdshader` declares the map half.
//
// The registration that makes it non-empty is `UnitSpritesManager.bind_tint_surface`;
// with nothing registered every layer array is empty, `color_apply` is the identity,
// and the fragment below is byte-for-byte what it was before this include existed.
#include "res://addons/exmateria_schema/colour_model/color_stack.gdshaderinc"

// Which of the unit's THREE colour sub-surfaces this material paints. `color_apply`
// tests each layer's mask against `1 << color_surface_id`, so the body, the weapon and
// the effect sprite must pass DISTINCT ids or a single-surface layer (`MASK_SURFACE0`)
// would light all three. `UnitSpritesManager.SURFACE_BODY/WEAPON/EFFECT` is the CPU
// side of this constant and sets it per material.
//
// 🔴 NOT A LITERAL, unlike every upstream consumer. Upstream's unit shader composites
// all three sprite layers in ONE quad and is therefore a single-surface consumer that
// hardcodes 0 (`exmateria_sprite_rig/render/unit_sprite_body.gdshaderinc:894`).
// TacticsG paints the three layers as three Sprite3Ds with three materials, so it is
// the case the 0/1/2 convention in `color_stack.gdshaderinc:25-26` was written for and
// the id has to be per-material. The default is 0 for the materials that are never
// registered at all (the status icon on `unit.tscn`), where no layer ever folds.
uniform int color_surface_id : hint_range(0, 2) = 0;

void vertex() {
	if (billboard_enabled) {
		mat4 modified_model_view = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0], // Camera X (Right vector)
			INV_VIEW_MATRIX[1], // Camera Y (Up vector)
			INV_VIEW_MATRIX[2], // Camera Z (Forward vector)
			MODEL_MATRIX[3]     // Keeps the object's original 3D position
		);
		MODELVIEW_MATRIX = modified_model_view;
		// Fix normals so lighting doesn't break
		MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	}
	
	computed_depth = psx_depth(
		MODEL_MATRIX[3].xyz, PROJECTION_MATRIX, VIEW_MATRIX,
		INV_VIEW_MATRIX[3].xyz, depth_mode, depth_bias_custom);
}

void fragment() {
	vec4 tex = texture(sprite_texture, UV);
	int palette_index = int(round(tex.x * 255.0));
	tex = palette_colors[palette_index];
	vec4 col = tex * COLOR;
	if (col.a < 0.5) {
		discard;
	}
	// 🔴 THE STACK FOLDS INTO THE CLUT ENTRY, THE HOST'S OWN TINT LANDS AFTER IT.
	// The effect palette track is a CLUT REWRITE: the PSX changes the palette entry
	// and everything downstream reads the modified entry, which is why
	// `TintedSurfaces` passes quantize=true (the 5-bit CLUT path, `color_apply`'s
	// 31-step round). `unit_tint` is TacticsG's own single additive highlight — a
	// SIBLING input, not a layer of this stack, and not expressible as one — so it
	// keeps landing exactly where it landed before, on the result. With no layers
	// registered `color_apply` is the identity and this is the old line unchanged.
	ALBEDO = clamp(color_apply(col.rgb, color_surface_id) + unit_tint, vec3(0.0), vec3(1.0));
	DEPTH = computed_depth;
}
