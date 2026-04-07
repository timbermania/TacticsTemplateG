// Common uniforms, varyings, and vertex function for STP effect particle shaders.

uniform sampler2D effect_texture : filter_nearest, repeat_disable;
uniform vec2 texture_size = vec2(128.0, 256.0);

uniform vec2 corner_tl;
uniform vec2 corner_tr;
uniform vec2 corner_bl;
uniform vec2 corner_br;
uniform vec4 uv_rect_data;  // x, y, w, h (normalized)
uniform int depth_mode = 0;
uniform vec3 color_modulate = vec3(1.0);
uniform bool debug_depth = false;

varying vec4 uv_rect;
varying float tile_center_depth;
varying float tile_clip_w;

void vertex() {
	uv_rect = uv_rect_data;

	vec2 top = mix(corner_tl, corner_tr, UV.x);
	vec2 bottom = mix(corner_bl, corner_br, UV.x);
	vec2 corner = mix(top, bottom, UV.y);

	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]
	);

	vec4 clip_pos = PROJECTION_MATRIX * VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0);
	tile_center_depth = clip_pos.z / clip_pos.w;
	tile_clip_w = clip_pos.w;

	const float PSX_SCALE = 1.0 / 28.0;
	VERTEX.x = corner.x * PSX_SCALE;
	VERTEX.y = -corner.y * PSX_SCALE;
	VERTEX.z = 0.0;
}

vec3 depth_to_heatmap(float depth) {
	float d_inv = 1.0 - depth;
	if (d_inv < 0.5)
		return mix(vec3(0.0, 0.0, 1.0), vec3(0.0, 1.0, 0.0), d_inv * 2.0);
	else
		return mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), (d_inv - 0.5) * 2.0);
}

float compute_particle_depth(float base_depth, float clip_w, int mode) {
	// Fixed modes (reversed-Z: near=1.0, far=0.0)
	if (mode == 2) return 0.999;  // FIXED_FRONT
	if (mode == 3) return 0.001;  // FIXED_BACK
	if (mode == 4) return 0.99;   // FIXED_16

	// Relative modes: pull depth toward camera by world_bias world units
	// In reversed-Z perspective, depth ≈ near/distance, so the per-world-unit
	// depth change is approximately base_depth/clip_w (= near/distance^2)
	float world_bias = 0.0;
	if (mode == 1) world_bias = 1.0;   // PULL_FORWARD_8
	if (mode == 5) world_bias = 2.5;   // PULL_FORWARD_16
	return base_depth * (1.0 + world_bias / clip_w);
}
