// NDC depth -> the value `DEPTH` expects.
//
// This file exists to hold ONE fact, in ONE place, for every shader in the
// project that writes DEPTH. Before it, eleven sites each wrote raw NDC z
// straight to DEPTH, and all eleven were wrong in the same direction — which
// is why the game still sorted against itself and the bug stayed invisible
// until the Effects addon, which writes the depth the engine actually wants,
// was installed alongside it.
//
// Measured, not argued (probe rig: --pass=sign / --pass=agree, both with
// colour controls):
//   • The Compatibility renderer uses REVERSED depth — near/front is
//     positive NDC z, far/behind is negative.
//   • NDC z spans [-1, 1], but a fragment's DEPTH is a WINDOW depth in
//     [0, 1]. Writing raw NDC therefore loses half the range and clamps
//     everything past the mid-plane.
//   • With the conversion below, a quad genuinely nearer the camera draws in
//     front of an engine-depth-written wall. Without it, the same quad is
//     wrongly occluded.
//
// This is a RANGE conversion, not a reversed-Z inversion: near stays high.
// Apply it AFTER any depth bias so the bias magnitude scales with it. Absolute
// depth-buffer slots (if you ever write one directly) are already in [0, 1]
// and must NOT be passed through here.
//
// Forward+ hands the shader an NDC z that is already [0, 1], so the
// conversion applies to Compatibility only. CURRENT_RENDERER and
// RENDERER_COMPATIBILITY are real engine-provided preprocessor defines —
// verified on this project's engine by the probe's --pass=defines, which also
// asks for FORWARD_PLUS so that absent names (which would compare 0 == 0 and
// make this guard silently true) are distinguishable from real ones.

float psx_window_depth(float ndc_z) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return ndc_z * 0.5 + 0.5;
#else
	return ndc_z;
#endif
}
