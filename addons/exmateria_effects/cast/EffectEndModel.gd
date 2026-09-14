extends RefCounted
## The **derived effect end** — the frame at which the real engine would REAP the
## cast, which is NOT the last authored keyframe. In FFT an effect terminates when
## its script's wind-down loop sees `active_particle_count == 0` and falls through
## to op_end (research/wiki_articles/effect_state.txt): only emitters + particles
## (+ callbacks) hold the cast open. Screen / palette / camera / sound keyframes
## do NOT — so a SCREEN tint authored out to f611 is an upper bound the game never
## reaches; the cast dies the instant particles are gone and that long tail is cut.
##
## EffectScoreModel.max_frame is that last-authored-keyframe upper bound; this is
## the faithful runtime end. Computed by SIMULATING the effect (RD-free, exactly
## the ADR-0070 replay harness: ParticleSubsystem pumped through EffectTimeline)
## until BOTH gates hold — every phase block has exhausted its keyframes AND the
## particle subsystem is done (no emitters, zero live particles). Deterministic:
## a FIXED seed so the drawn marker is stable across loads (a cast's true end can
## vary a few frames by seed; the marker shows one representative, faithful end).
##
## No class_name (ADR-0004 cache-safety); instantiate by path.

const ParticleSubsystemClass = preload("res://addons/exmateria_effects/subsystem/ParticleSubsystem.gd")
const EffectTimelineClass = preload("res://addons/exmateria_effects/cast/EffectTimeline.gd")

# Stable seed for the drawn marker (see class doc — one representative end).
const MARKER_SEED: int = 0
# Safety net: an effect whose particles never die (pathological / infinite loop)
# would otherwise spin forever. 3600 = 2 min at the 30 Hz effect clock.
const HARD_CAP: int = 3600


## The derived end frame for `effect_data`: the first frame at which all phase
## blocks are finished scheduling spawns AND no particles/emitters remain. Returns
## 0 for a null / empty effect; returns `frame_cap` if the effect never settles.
static func derived_end_frame(effect_data, seed_value: int = MARKER_SEED, frame_cap: int = HARD_CAP) -> int:
	if effect_data == null:
		return 0

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var mgr = ParticleSubsystemClass.new()
	mgr.rng = rng
	mgr.initialize(effect_data, 512)
	mgr.set_anchors(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)

	var tl = EffectTimelineClass.new()
	var p1d := 0
	var p2s := 0
	if effect_data.timeline:
		p1d = effect_data.timeline.phase1_duration
		p2s = p1d + effect_data.timeline.phase2_delay
	tl.setup(p1d, p2s, effect_data.time_scale)
	tl.set_rng(rng, seed_value)   # so the harness re-seeds identically to the live cast
	tl.set_subsystems([mgr])
	mgr.timeline = tl
	tl.start()

	# Step one fixed frame at a time (seek forward pumps exactly the delta) until the
	# cast has settled.
	var f := 0
	while f < frame_cap:
		f += 1
		tl.seek(f)
		if _settled(mgr, f):
			return f
	return frame_cap


## Termination gate — the faithful FFT reap: `active_particle_count == 0` after
## spawning has ceased (the engine's op_branch_count_eq winddown check; see
## research/wiki_articles/effect_state.txt). Two parts:
##   (a) we are PAST the last frame any phase spawns a particle — so no new spawn
##       is coming, and an early spawn GAP (particle count briefly 0 before
##       for_each opens) can't read as the end; AND
##   (b) zero particles remain alive.
## Deliberately NOT `is_done()` / "all phase blocks finished": ActiveEmitter
## objects linger in the pool after their last particle dies (a Godot-model
## artifact, not "effect still alive"), and a phase block only advances while its
## window is open — so both of those gates can stay stuck long after the cast is
## visually over. Particle count is the signal the real engine actually reaps on.
static func _settled(mgr, frame: int) -> bool:
	if frame <= mgr.get_last_active_effect_frame():
		return false
	return mgr.get_active_particle_count() == 0
