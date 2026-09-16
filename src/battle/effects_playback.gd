class_name EffectsPlayback
extends Node3D
## Owns `addons/exmateria_effects`' playback for one battle: the compositor
## producer, the per-battle `CastHost`, and the `EffectManager` over it.
##
## 🔴 THIS IS NOW THE ONLY ABILITY-VFX PATH. It used to be the second one, off by
## default, coexisting with TacticsG's own renderers; those renderers have been
## deleted and every ability cast in the game arrives here. `enabled` is still false
## by default, but that now means "an owner must opt in", not "the old path is still
## there" — a scene that forgets to enable this draws NO ability VFX at all, and says
## so through `unavailable_reason`.
##
## What deliberately survives in `src/file_formats/vfx/`: `VfxConstants` (units and
## shadows read `DepthMode.UNIT` from it, which was never an effects concern),
## `ProjectileEffectInstance` (weapon arrows/stones/shuriken — the addon has no
## equivalent), and the `VisualEffectData` / `TrapEffectData` DATA model, which is
## still the only in-repo path from a ROM to effect content.
##
## 🔴 setup_native IS CHECKED, and that is not a style preference. On stock Godot
## the fold bracket does not exist, so `setup()` must never be called and
## `setup_native()` can legitimately REFUSE. An unchecked call is the documented
## way this integration renders nothing while looking installed, so a refusal
## disables playback loudly instead of leaving a producer that draws nothing.

## Opt-in. While false this node builds nothing and holds no producer, so the
## addon cannot affect a frame.
@export var enabled: bool = false

## The battle this plays for. Must be IN THE SCENE — the addon's contract says
## the stage is a scene node, never the persistent root viewport, because casts
## share the stage's World3D.
@export var battle_manager: Node

## Where the ROM-derived content lives, applied to `EffectsContent.ROOT_SETTING`
## by `begin()`. Empty leaves whatever the project already declares — which is
## nothing, on purpose, so a checkout with no content fails legibly instead of
## resolving paths that cannot exist.
@export var content_root: String = ""

## The rig a cast's CAMERA track drives, or null to leave the camera alone.
##
## 🔴 THE THIRD DISCARDED TRACK. `EffectInstance` runs a `CameraSubsystem` for 388 of
## the 401 installed effects — NOT gated on `is_cinematic`, so ordinary spell casts have
## one — and until this was wired, every frame of it was computed and thrown away, the
## same silent way the background gradient and the map tint were. Left unset (the
## regression scenes, the editor previews) nothing takes the camera and nothing changes.
@export var camera_rig: CameraController

## An effect's own clock rate — `EffectTimeline.PHYSICS_TIMESTEP`, the FFT game loop.
const EFFECT_FRAME_HZ: float = 30.0

## The longest palette RESTORE ramp in the installed corpus.
## `ColorRecipe.ramp_frames_for_time` turns a keyframe's Time byte into a DDA length
## (0 -> 0, 1..3 -> 8, else 32 * (t >> 2)), and every phase2 restore across the 402
## installed effects carries Time 0, 1, 2 or 4 — so 32 frames covers all of them.
## Counted from the content, not guessed: re-run the count if the corpus is re-exported.
const PALETTE_RESTORE_RAMP_FRAMES: int = 32

## The addon's own "has this cast finished drawing" test, mirrored rather than reached:
## `EffectManager.EFFECT_MIN_FRAME_FOR_CLEANUP`. Used for the two things that must keep
## ending exactly when they used to — the camera hand-back and the gameplay wait.
const VISUAL_DONE_MIN_FRAME: int = 50

## Wall-clock ceiling on one cast — a hang guard, not a policy. Derived PER CAST from
## the frame it has to reach, because `phase1_duration + phase2_delay` spans 0..618
## frames across the corpus (median 82): one flat number would either strand the long
## effects or hold the short ones. The slack covers `time_scale` pacing, measured as
## low as ~0.5x real time on E073.
const CAST_PACING_SLACK: float = 3.0
const CAST_CAP_MIN_SECONDS: float = 12.0
const CAST_CAP_MAX_SECONDS: float = 30.0

var _producer: ExMateriaEffects.EngineFoldCompositor
var _host: EffectsCastHost
var _manager: ExMateriaEffects.EffectManager
## Pumps `camera_rig` from whichever cast currently owns it. Built lazily so a playback
## with no rig never adds a node that would only ever no-op.
var _camera_track: EffectCameraTrack

## The casts this node spawned and must free itself — see `play_action_vfx`. The
## cinematic spawn deliberately does NOT enter the addon's `_owned_effects`, so its
## stage-exit sweep does not reach them.
var _owned_casts: Array[Node3D] = []

## The cast currently driving `camera_rig`, or null. Tracked here rather than read off
## `EffectCameraTrack._cast` so the camera hand-back below never reaches into another
## file's private state.
var _camera_cast: Node3D = null

## Why playback is unavailable, or "" when it is. Read this instead of guessing:
## every refusal below is a quiet-by-design failure mode.
var unavailable_reason: String = ""


func is_available() -> bool:
	return _manager != null


func manager() -> ExMateriaEffects.EffectManager:
	return _manager


## Build the producer/host/manager for `camera`. Returns false — with
## `unavailable_reason` set — rather than half-building.
func begin(camera: Camera3D) -> bool:
	_end()
	if not enabled:
		unavailable_reason = "disabled: EffectsPlayback.enabled is false"
		return false
	if not is_instance_valid(battle_manager) or not battle_manager.is_inside_tree():
		unavailable_reason = "no battle: battle_manager is unset or not in the scene"
		return false
	if not is_instance_valid(camera) or not camera.is_inside_tree():
		unavailable_reason = "no camera: setup_native needs an IN-TREE Camera3D"
		return false
	# Content is ROM-derived and cannot ship in the addon. An unset root makes
	# every cast resolve to "" and fail like a missing file, so refuse up front
	# rather than spawn effects that can never load.
	if not content_root.is_empty():
		ProjectSettings.set_setting(
			ExMateriaEffects.EffectsContent.ROOT_SETTING, content_root)
	if not ExMateriaEffects.EffectsContent.has_root():
		unavailable_reason = (
			"no content root: set `%s` to a directory holding effects/, effects/trap/ "
			+ "and sprites/textures/TRAP1*.tga"
		) % ExMateriaEffects.EffectsContent.ROOT_SETTING
		return false

	var producer := ExMateriaEffects.EngineFoldCompositor.new()
	add_child(producer)
	# CHECKED. Never the default fold `setup()` — TacticsG runs stock GL, where
	# the fold bracket does not exist.
	if not producer.setup_native(camera):
		producer.queue_free()
		unavailable_reason = "setup_native refused for this camera/renderer"
		return false

	_producer = producer
	_host = EffectsCastHost.new(battle_manager)
	_manager = ExMateriaEffects.EffectManager.new(_host)
	unavailable_reason = ""
	return true


func end() -> void:
	_end()


func _end() -> void:
	# Before the manager goes: a torn-down battle must not leave the rig frozen
	# mid-track with nothing left to advance it.
	if is_instance_valid(_camera_track):
		_camera_track.release()
	_camera_cast = null
	# 🔴 OURS TO FREE. `spawn_cinematic_effect` does not enter the addon's
	# `_owned_effects`, so `EffectManager._on_stage_exiting`'s sweep does not reach
	# these — a torn-down battle would otherwise leave every in-flight cast alive,
	# still holding a unit tint and a map tint.
	for cast: Node3D in _owned_casts:
		if is_instance_valid(cast):
			cast.queue_free()
	_owned_casts.clear()
	_manager = null
	_host = null
	if is_instance_valid(_producer):
		_producer.queue_free()
	_producer = null


func _exit_tree() -> void:
	_end()


## The `E###` number `action` should draw, or -1 when it draws nothing.
##
## 🔴 THIS IS THE MAPPING, and it is the only place allowed to know it. The addon
## keys effects by ROM effect NUMBER (`effects/E###`, formatted `E%03d` at three
## call sites in `EffectManager`). TacticsG's actions carry that same number twice:
## `Action.vfx_id`, and `Action.vfx_name` — the exported `VisualEffectData.unique_name`,
## which is the effect file's own stem. `FftAbilityData._build_action` assigns BOTH
## from one `VisualEffectData`, so they describe the same ROM file by construction.
##
## They are still cross-checked, because the two export vintages on record spell the
## NAME differently — `e_192` in one, `E192` in the other, and one omits `vfx_name`
## altogether — while agreeing on the NUMBER. Keying on a name format would draw the
## wrong effect, or nothing, depending on which export a user happens to have. So the
## number is the key, the name is the witness, and a disagreement is REPORTED: this is
## the one failure mode here that is silent by nature, because every E### directory
## exists and a wrong id loads a real effect rather than erroring.
##
## 🔴 `vfx_id == 0` IS A REAL EFFECT, never a "none" sentinel. Fifteen physical
## abilities — Attack, the Breaks, the Aims, Throw Stone, Accumulate, Seal Evil —
## resolve to E000 because `FftAbilityData` substitutes `RomReader.vfx[0]` for an
## ability with no effect file of its own. The old path drew E000 for them, so this
## one does too; reading 0 as "no effect" would silently drop all fifteen.
static func effect_id_for(action: Action) -> int:
	if action == null:
		return -1
	var named: int = -1
	if not action.vfx_name.is_empty():
		var digits: String = ""
		for c: String in action.vfx_name:
			if c >= "0" and c <= "9":
				digits += c
		if not digits.is_empty():
			named = digits.to_int()
	if named >= 0:
		if named != action.vfx_id:
			push_warning(
				("EffectsPlayback: action \"%s\" disagrees with itself about its effect "
				+ "— vfx_name \"%s\" says E%03d, vfx_id says E%03d. Drawing the name's, "
				+ "which is what the old vfx_data path resolved. Re-export the action "
				+ "data; a stale export here draws the WRONG effect, not nothing.")
				% [action.unique_name, action.vfx_name, named, action.vfx_id])
		return named
	# An export vintage that omits `vfx_name` still carries the number, and the
	# number is the key. Only here does 0 mean "none" — with no name to corroborate
	# it, a zero is indistinguishable from an unset field.
	return action.vfx_id if action.vfx_id > 0 else -1


## Effect ids already reported missing, so a per-action cast loop cannot bury the
## one line that says why nothing is drawing.
var _missing_content: Dictionary = {}


## Play `action`'s ability VFX from `caster` at `target`. Returns the spawned effect
## node, or null when nothing was cast — so a caller never has to infer it from
## silence, and can AWAIT the node's lifetime for timing (see `await_cast`).
func play_action_vfx(caster: Node3D, target: Node3D, action: Action) -> Node3D:
	if not is_available() or not is_instance_valid(caster) or not is_instance_valid(target):
		return null
	# 🔴 A `Unit` IS NOT A POSITIONED NODE. It is a Node3D that never moves — only its
	# `char_body` child is ever assigned a transform — so `spawn_spell_effect`, which
	# places the cast at `caster.global_position`, would put it at the world ORIGIN.
	# That shipped once and was invisible to every test here, because the scored scene
	# casts from a bare Node3D it positions itself, so "at the caster" and "at the
	# origin" were the same pixels. Refuse loudly instead of drawing in the wrong place.
	if caster is Unit or target is Unit:
		push_error("EffectsPlayback: pass `unit.char_body`, not the Unit — a Unit's own "
			+ "transform is never set, so the cast would spawn at the world origin.")
		return null
	var effect_id: int = effect_id_for(action)
	if effect_id < 0:
		return null
	# Existence is checked HERE, not left to `initialize()`. The manager's spell path
	# reports a missing directory only by freeing the instance it just made, which
	# looks exactly like an effect that drew nothing — and "content was never copied"
	# is the single most likely reason this integration appears installed and dead.
	var dir: String = ExMateriaEffects.EffectsContent.effect_dir("E%03d" % effect_id)
	if dir.is_empty() or not DirAccess.dir_exists_absolute(dir):
		if not _missing_content.has(effect_id):
			_missing_content[effect_id] = true
			push_warning(
				("EffectsPlayback: no content at \"%s\" for E%03d, so \"%s\" draws "
				+ "nothing. Copy the per-effect `E###` directories into the content root.")
				% [dir, effect_id, action.unique_name])
		return null
	# 🔴 `ability_id` is SIGNAL PAYLOAD ONLY on this path — the spawn never asks the host
	# for an `AbilityVisual`, it only forwards this int through `ability_react_triggered`
	# / `hit_reaction_triggered`. TacticsG's `Action` carries no numeric ability id (only
	# `unique_name`), so -1 is passed deliberately rather than a fabricated number that a
	# future reaction listener would trust.
	#
	# 🔴 THE CINEMATIC SPAWN, AND THE HOST OWNS THE LIFETIME. See `_reap_cast`: the
	# spell spawn attaches `EffectManager._poll_effect_cleanup`, which ends a cast on a
	# WALL-CLOCK budget while the effect's own clock is in frames — so it routinely
	# destroys a cast mid-timeline, before the ROM's palette RESTORE has run, and leaves
	# the caster and target holding their flash. `spawn_cinematic_effect` is the same
	# spawn with that poll left off ("the cinematic lifecycle is owned by the caller"),
	# so the host ends the cast on the ROM's terms instead.
	#
	# It is also simply a better entry point for this call site: it RETURNS the instance,
	# which `spawn_spell_effect` (void) did not, so the cast no longer has to be
	# identified by diffing the stage's children across the call and duck-typing the new
	# node. And it seeds `map_center_godot` from `arena_bounds()` itself.
	#
	# The two documented costs of this route do not apply here. `is_cinematic` opts the
	# instance out of the `combat_visuals` group, which NOTHING in this repo or the addon
	# ever reads (verified by grep — every hit is an `add_to_group` or a comment). And the
	# missing `_owned_effects` bookkeeping, which is only the addon's stage-exit sweep, is
	# replaced by `_owned_casts` + `_end()`.
	var cast: Node3D = _manager.spawn_cinematic_effect(caster, target, -1, effect_id)
	if cast == null:
		# Initialization failed; the manager already freed its instance.
		return null
	_owned_casts.append(cast)
	_offer_camera(cast)
	_reap_cast(cast)
	return cast


## Offer a freshly spawned cast the camera rig.
##
## 🔴 CALLED HERE, ONE LINE AFTER THE SPAWN, BECAUSE THE SIGNAL IS ALREADY GONE.
## `EffectInstance` emits `camera_started` INSIDE `initialize()` — before
## `spawn_spell_effect` returns — and `spawn_spell_effect` takes no camera callbacks;
## only `spawn_cinematic_effect` does, and it wires them before `initialize()` for
## exactly this reason. Connecting to `camera_started` after the spawn misses it
## entirely. `instance.camera_controller != null` carries the same information and is
## readable right here, off the instance this function already had to identify for
## TIMING. `camera_finished` is a different matter — it fires from `_exit_tree`, well
## after the spawn returns — so `EffectCameraTrack` connects that one normally.
##
## Routing charge-time abilities through `spawn_cinematic_effect` instead would get the
## callbacks properly, but it is a bigger change (cinematics opt out of the
## `combat_visuals` group, their lifetime is caller-owned, and TacticsG calls that path
## nowhere today) and it is not needed to make the track visible. Left as a follow-up.
func _offer_camera(cast: Node) -> void:
	if not is_instance_valid(camera_rig):
		return
	if not is_instance_valid(_camera_track):
		_camera_track = EffectCameraTrack.new(camera_rig)
		add_child(_camera_track)
	_camera_track.rig = camera_rig
	if not _camera_track.adopt(cast):
		return
	# Remembered so `_reap_cast` can hand the rig back at the beat the node used to die
	# on, without reaching into `EffectCameraTrack`'s own private `_cast`.
	_camera_cast = cast as Node3D
	if _host != null:
		# `EFFECT_CTR` keyframes anchor on the map centre, which the addon's spawn never
		# sets — the host is the only side that knows the arena's size.
		_camera_track.set_map_bounds(_host.arena_bounds())


## Own one cast's lifetime, and end it on the ROM's terms.
##
## 🔴 WHY THE HOST DOES THIS AT ALL. `EffectManager._poll_effect_cleanup` — the reaper
## the SPELL spawn attaches, and the one this replaces — frees a cast on a WALL-CLOCK
## budget: 0.5s plus 100 polls at 0.1s. An effect's own clock is in FRAMES and is paced
## by its `time_scale` curve, which routinely runs below 30 Hz, so that budget expires
## mid-timeline. Measured: E073 reaped at effect frame 171 of 278, E015 at 134 of 227.
##
## That is not just a truncated animation. Almost every effect puts its palette RESTORE
## — the mode 8/10 op that fades a caster/target flash back to the untinted CLUT entry —
## in PHASE 2, and `PaletteSubsystem.build_stream` only pushes ops for phases that have
## actually STARTED. Reaped before `phase1_duration + phase2_delay`, the restore never
## executes: the unit holds its flash until `EffectInstance._exit_tree` yanks the layers,
## which is a SNAP back to base rather than the authored fade. Measured on E073, the
## caster sat at pure white for 5.6 seconds and then jumped.
##
## 🔴 ONLY THE NODE LIVES LONGER. Everything the player can see or feel still ends when
## it used to: the camera goes back at `_cast_visual_done` (below), and `await_casts`
## returns on the same test, so ability pacing is unchanged. What the extra frames buy
## is the colour track running to its restore — the cast is silent and particle-free by
## then, and it costs a few subsystem ticks over nothing.
func _reap_cast(cast: Node3D) -> void:
	var restore_frame: int = _palette_restore_frame(cast)
	# A hang guard, not a policy: if the effect never gets there, the cast still goes.
	var budget: float = clampf(
		float(restore_frame) / EFFECT_FRAME_HZ * CAST_PACING_SLACK,
		CAST_CAP_MIN_SECONDS, CAST_CAP_MAX_SECONDS)
	var waited: float = 0.0
	var handed_back: bool = false
	while is_instance_valid(cast) and waited < budget:
		var tree := get_tree()
		if tree == null:
			return
		await tree.process_frame
		if not is_instance_valid(cast) or not is_inside_tree():
			break
		waited += tree.root.get_process_delta_time()
		var visual_done: bool = _cast_visual_done(cast)
		if visual_done and not handed_back:
			handed_back = true
			# The rig used to come back when the node died. It still comes back HERE,
			# which is that same moment — not at the end of the colour tail.
			if is_instance_valid(_camera_track) and _camera_cast == cast:
				_camera_track.release()
				_camera_cast = null
		if visual_done and cast.get_effect_frame() >= restore_frame:
			break
	_owned_casts.erase(cast)
	if _camera_cast == cast:
		if is_instance_valid(_camera_track):
			_camera_track.release()
		_camera_cast = null
	if is_instance_valid(cast):
		cast.queue_free()


## The effect frame by which the ROM's palette restore has finished: phase 2's start
## plus the longest restore ramp. Read off the cast's OWN parsed timeline header, so
## re-exporting the corpus changes this without touching the host. 0 when an effect
## carries no timeline, which makes the wall-clock floor the whole budget.
func _palette_restore_frame(cast: Node3D) -> int:
	if not is_instance_valid(cast) or cast.effect_data == null \
			or cast.effect_data.timeline == null:
		return 0
	var timeline = cast.effect_data.timeline
	return int(timeline.phase1_duration) + int(timeline.phase2_delay) \
		+ PALETTE_RESTORE_RAMP_FRAMES


## Has this cast finished DRAWING? The addon's own condition, mirrored: no live
## particles, past its minimum frame. This is the beat the camera goes back on and the
## beat `await_casts` returns on, so both keep the timing they had when the addon's
## poll freed the node here.
func _cast_visual_done(cast: Node3D) -> bool:
	if not is_instance_valid(cast):
		return true
	return cast.get_active_particle_count() == 0 \
		and cast.get_effect_frame() > VISUAL_DONE_MIN_FRAME


## The live camera track, or null if nothing has ever claimed the rig. Exposed so a test
## can read the subsystem values beside the host values rather than infer one from the
## other — a host value that moves without a matching subsystem value is a host bug.
func camera_track() -> EffectCameraTrack:
	return _camera_track


## `play_action_vfx` for a call site that knows a target POSITION but not a target
## node — `Unit.use_ability` raycasts the map, so it has a point and no unit there.
##
## The addon parents a tracking anchor to whatever it is given as the target, so the
## marker must outlive the cast. `EffectManager`'s own cleanup poll caps a spell at
## roughly 10.5s (0.5s settle + 100 polls x 0.1s), so the marker is freed after 12s —
## and every anchor read in `EffectInstance` is `is_instance_valid`-guarded, so an
## effect that somehow outlives it degrades to a static anchor rather than a crash.
func play_action_vfx_at(caster: Node3D, world_position: Vector3, action: Action) -> Node3D:
	if not is_available() or not is_instance_valid(caster):
		return null
	var marker := Node3D.new()
	marker.name = "AbilityVfxTarget"
	add_child(marker)
	marker.global_position = world_position
	var cast: Node3D = play_action_vfx(caster, marker, action)
	if cast == null:
		marker.queue_free()
		return null
	# 🔴 TIED TO THE CAST, not to a flat 12s. The addon parents a tracking anchor to
	# whatever it is given as the target, so the marker has to outlive the cast — and
	# `_reap_cast` now runs a cast to its palette restore, which can be longer than the
	# twelve seconds this used to assume. Freeing on the cast's own exit keeps the two in
	# step whatever the effect's length; the timer stays as the guard for a cast that
	# somehow never leaves the tree, one beat past the reaper's own ceiling.
	cast.tree_exited.connect(
		func() -> void:
			if is_instance_valid(marker):
				marker.queue_free(),
		CONNECT_ONE_SHOT)
	get_tree().create_timer(CAST_CAP_MAX_SECONDS + 2.0).timeout.connect(
		func() -> void:
			if is_instance_valid(marker):
				marker.queue_free(),
		CONNECT_ONE_SHOT)
	return cast


## TacticsG's "shared VFX": the TRAP handlers — hit clouds, knight break, the charge
## and orb poses. Returns true iff an effect was started.
##
## 🔴 This deliberately does NOT go through `EffectManager.spawn_trap_effect`, even
## though that exists. That entry point takes an ABILITY ID and derives the handler
## itself, asking the host for an `AbilityVisual` and choosing between hit clouds and
## knight break. TacticsG already KNOWS the handler — the ROM's
## `charging_vfx_ids -> shared_vfx_handler_ids` tables give it directly as
## `Action.user_shared_vfx_handler_id` / `target_shared_vfx_handler_id`, and that
## covers handlers the derivation cannot reach at all (6, the red Accumulate orbs).
## Deriving would THROW AWAY the better answer and, on a checkout with no ROM loaded,
## resolve every ability to the generic clouds. So the handler and element come from
## the action, and only the drawing is the addon's.
func play_shared_vfx(handler_id: int, element_id: int, from_position: Vector3,
		target_unit: Node3D, flash: bool, is_melee: bool = true) -> bool:
	if not is_available() or handler_id <= 0 or not is_instance_valid(target_unit):
		return false
	var trap := ExMateriaEffects.TrapEffect.new()
	# Parented to the struck actor, which is the addon's own contract for trap effects
	# and what makes the effect track a unit that is still moving.
	target_unit.add_child(trap)
	if not trap.initialize(TRAP_TYPE, element_id):
		trap.queue_free()
		return false
	var impact: Vector3 = target_unit.global_position + Vector3(0, TRAP_IMPACT_RISE, 0)
	var direction: Vector3 = (impact - from_position).normalized()
	var flash_target: Node3D = target_unit if flash else null
	if handler_id == HANDLER_HIT_CLOUDS:
		# Hit clouds split melee/ranged by emitter set, exactly as the addon's own
		# manager does — the handler id is the same for both.
		var emitters: Array[int] = []
		emitters.assign([0, 9] if is_melee else [0, 1])
		trap.play_at(impact, direction, flash_target, emitters, flash)
	else:
		trap.play_handler(handler_id, element_id, impact, direction, flash_target)
	return true


## The addon's TRAP sprite set. 7 is the one TacticsG's own trap path used and the one
## the demo scene plays; it is not a tunable.
const TRAP_TYPE: int = 7
## Hit clouds, the one handler that takes an emitter split rather than a plain play.
const HANDLER_HIT_CLOUDS: int = 2
## Lifts the impact off the tile floor so clouds read as hitting a body, not the ground.
const TRAP_IMPACT_RISE: float = 0.3


## Wait for the casts returned by `play_action_vfx*` to finish, or for
## `fallback_seconds` when there are none.
##
## 🔴 This is GAMEPLAY TIMING, not a visual detail. `ActionInstance` held the old
## `VfxEffectInstance`s and spun until they freed themselves before returning units to
## idle; an ability with no VFX took a flat 0.5s instead. Dropping the wait would not
## merely desync the animation — EVERY ability with an effect would resolve at the
## short timing, which is a pacing change across the whole game. The addon's
## `EffectManager` frees a finished spell itself, so "still valid" carries exactly the
## meaning the old instance did, and the `any()` shape is kept so several targets still
## resolve together rather than in sequence. The cap exists because a cast that never
## cleans up must not hang a turn forever.
func await_casts(casts: Array[Node3D], fallback_seconds: float = 0.5,
		max_seconds: float = 12.0) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var live := casts.filter(func(c: Node3D) -> bool: return is_instance_valid(c))
	if live.is_empty():
		await tree.create_timer(fallback_seconds).timeout
		return
	# 🔴 WAITS ON THE VISUAL, NOT ON THE NODE — and that is what KEEPS this timing the
	# same. It used to wait for the instance to free itself, which happened when the
	# addon's poll saw the particles finish. `_reap_cast` now keeps the node alive past
	# that point so the ROM's palette restore can run (see there), so waiting on node
	# validity would silently add the whole colour tail to every ability's resolution.
	# `_cast_visual_done` is the addon's own finished-drawing test, so an ability
	# resolves on exactly the beat it always did.
	var waited: float = 0.0
	while waited < max_seconds and live.any(
			func(c: Node3D) -> bool:
				return is_instance_valid(c) and not _cast_visual_done(c)):
		await tree.process_frame
		waited += tree.root.get_process_delta_time()
