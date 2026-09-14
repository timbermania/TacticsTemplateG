extends Node

## ExMateriaEffectSfx (Autoload Singleton) — the single, always-running FFT effect
## SFX driver. Accessed globally as: ExMateriaEffectSfx.
##
## Models the PSX SPU faithfully: a fixed-clock SPU that never stops. The pool +
## sequencer runtime are built once and tick every frame forever; keyed-off
## voices release and the reverb tank decays on that clock whether or not any
## effect is feeding new notes — so tails are never trimmed.
##
## Voice budget (two modes — FAITHFUL keeps PSX parity, the toggle preserves it):
##   FAITHFUL — exact FFT effect pool on one SPU: 8 slots, voices 16-23, slots
##              6-7 reserved -> 3 concurrent stereo pairs. For parity/A-B.
##   UNLOCKED — each SPU uses all 24 voices (base 0) -> 12 pairs, AND the engine
##              spins up additional stacked SPU "units" on demand (up to
##              MAX_UNITS) so many simultaneous effects don't starve. Idle units
##              aren't rendered, so cost scales with concurrent activity, not the
##              cap. This is the game default.
##
## A "unit" = one Spu + its own pool/flush/walker/runtime AND its own entity
## list (so each unit's Runtime drives only its own casts — see the per-unit
## entity-list injection in runtime.gd / play_sound.gd) AND its own reverb tank.
## Each effect cast binds to one unit at its first dispatch, ONE CAST PER UNIT:
## routed to an empty unit (or a freshly spawned one), doubling up only at the
## MAX_UNITS cap. This keeps concurrent casts on separate SPUs so they sum at the
## downstream bus limiter (smooth) instead of summing + brick-wall-clipping
## inside one unit's C++ core, and gives each cast an uncoupled reverb tail.
##
## Music coexists on the separate ExMateriaAudioEngine.music_spu; SFX units never touch
## it. Every SFX caller (game effects AND the FEDS/SFX-bank audition scenes)
## goes through this one engine, so all scenes behave identically.
##
## Must autoload AFTER ExMateriaAudioEngine (uses ExMateriaAudioEngine.sfx_spu + waveset).
##
## Vault: [[SPU Voice Engine]]
## Vault: [[Effect Sound Timing]]
## Vault: [[Effect Sound Slot Allocator]]
## Vault: [[WAVESET Instrument Bank]]
## Vault: [[Cure 4 Audio Parity]]

const _Pool := preload("res://addons/exmateria_sound/runtime/effect_sound/pool.gd")
const _Play := preload("res://addons/exmateria_sound/runtime/effect_sound/play_sound.gd")
const _Flush := preload("res://addons/exmateria_sound/runtime/shared/flush_tick.gd")
const _Walker := preload("res://addons/exmateria_sound/runtime/shared/spu_irq_walker.gd")
const _RuntimeC := preload("res://addons/exmateria_sound/runtime/runtime.gd")
const _EntityList := preload("res://addons/exmateria_sound/runtime/shared/entity_list.gd")
const _Spu = preload("res://addons/exmateria_spu/runtime/spu.gd")
const _FedsBank = preload("res://addons/exmateria_sound/runtime/feds_bank.gd")

const SYNTHETIC_SEED := {"entities": [{"channel_count": 8}]}
## The Godot bus this engine's stream lands on — `Master <- {Music, SFX, Ambient}`
## (D3 decision 6, #376 / #385 task 2). Effect SFX gets its own fader, separate from the
## score on `Music`; both used to hardcode `"Master"`, so a consumer had one knob for
## everything. Unknown-bus-safe and effect-free for the same reasons as
## `SMDPlayer.OUTPUT_BUS` — see the note there.
const OUTPUT_BUS := &"SFX"
## Ambient beds play on their OWN bus. That bus split is what now buys the
## headroom decoupling `_bg_limiter` used to buy by running a second hand-rolled
## limiter over the same summed buffer — a loud bed and combat SFX reach Master
## through independent limiters instead of sharing one gain (#385 task 3, §3a).
const BG_OUTPUT_BUS := &"Ambient"
## How far ahead of the audio clock the scheduler stamps register writes.
##
## For MUSIC a long lead is free — SMDPlayer runs 2 s, because a song has no
## responsiveness requirement. SFX is the opposite: a cue stamped at frame F
## SOUNDS at frame F, so the lead IS the input latency, and `D3` dec. 7 caps it
## at one mix block (11.6 ms) + output latency (measured 33-44 ms on this
## machine) — a budget of roughly 45-55 ms, not 11.6.
##
## The lead must EXCEED one mix block, and that is the binding constraint. At 3
## subs (~12.5 ms) against 11.6 ms blocks there is under 1 ms of margin, and the
## live stress rig measured ~180 overdue register writes per second: the audio
## thread reaches a frame before the scheduler has stamped it. Six subs (~25 ms)
## leaves ~13 ms of margin, holds `late` at 0, and still sits comfortably inside
## `D3` dec. 7's budget. The scheduler stamps whole subs, so the real lead rides
## between ~25 and ~29 ms.
##
## This is also why the scheduler keeps its own thread rather than folding into
## `_process` the way the music player did. GPUArena runs at 15 fps — a 66 ms
## frame, longer than the whole budget — so a main-thread scheduler would stamp
## most cues after the audio clock had already passed them.
const SCHED_LEAD_SUBS := 6
const SCHED_LEAD_FRAMES := SCHED_LEAD_SUBS * 184
const SCHED_IDLE_MS := 1        # scheduler sleep when the lead is full / capture mode
# Subs the scheduler may stamp in ONE _audio_mutex hold before it MUST release and
# yield. This is a latency bound, not a throughput knob — it is the longest a
# main-thread SFX call can be made to wait behind the scheduler. Keep it small: the
# lead is only SCHED_LEAD_SUBS deep, so steady state needs one sub per 1/240 s and
# the only reason to stamp several in a row is refilling the lead after a hitch.
const SCHED_CATCHUP_MAX_SUBS := 4
# The MANDATORY post-stamp yield. Short (not SCHED_IDLE_MS) so catch-up capacity
# stays ~16000 subs/s against a 240/s requirement, but non-zero so the thread
# actually descends into the kernel and a waiter gets scheduled. See _scheduler_main.
const SCHED_YIELD_USEC := 250
## Per-unit register-write ring, sized once when the unit's stream is armed.
## A write is 64 bytes and one unit takes at most a few dozen per tick, so three
## subs of lead is orders of magnitude inside this. `overflow` in
## get_deferred_stats() counts DROPPED writes and must stay 0.
const QUEUE_CAPACITY := 4096
# Extra (non-base) units stop rendering this many sub-ticks after their last
# activity (release + reverb fully decay first, ~3 s at 240 Hz), then sleep
# until a new cast lands on them — idle-skip keeps cost ~ concurrent activity.
const UNIT_IDLE_TAIL_SUBS := 720
# Defensive-reap grace (~240 subs/sec). A dispatched cast whose sequence is done,
# whose unit has no active voices, and that has been idle this long is treated as
# abandoned (caller missed its orphan/end) and reclaimed so it can't wedge a unit
# — see _reap_dead_sessions. 2 s is comfortably longer than the gap between a
# cast's pairs, so it won't cut a still-sequencing multi-pair effect.
const REAP_GRACE_SUBS := 480
# Defensive-reap grace for a ONE-SHOT cast (play_one_shot): one that has told the
# engine it will dispatch exactly one pair and will never be ended. The long grace
# above exists to protect a multi-pair effect mid-sequence, which a one-shot cannot
# be, so all this has to cover is the scheduler's own lead — the sequencer runs
# SCHED_LEAD_SUBS ahead of the audio clock, so "sequencing done" is true up to that
# far before the sound has actually been heard. 24 subs (100 ms) is 4x that lead and
# still 20x shorter than REAP_GRACE_SUBS. The reap's other two conditions (no active
# voices on the unit, sequence finished) are what actually decide; this only keeps a
# just-dispatched cast from being examined inside the lead window.
const ONE_SHOT_REAP_GRACE_SUBS := 24
# W11/R28 — the SILENCE fallback that lets a ONE-SHOT cast be reaped even while its
# unit still reports voices. The reap's "still audible" condition asks
# _unit_voice_count(u), which is a per-UNIT question: all one-shot casts pack onto
# MAX_EVENT_UNITS=2 reserved cores, so in sustained combat one audible blip vetoes
# reaping every other session on that core, forever. Measured at 80 units: 99.5 % of
# all reap skips, `killed` = 0 after the first window, and 240 drained sessions still
# linked into their core's entity list and sequenced every sub at ~32 us each — which
# put the scheduler over its 4.16 ms/sub budget and made a main-thread cue wait 25.7 ms
# on _audio_mutex (R28, F39-F42).
#
# Why a TIME fallback rather than a per-session voice test: the honest per-session
# question needs a per-voice audibility signal the SPU does not publish
# (get_audio_active_voices() is a unit-wide count; get_voice_debug_info() builds a
# 30-key Dictionary off core_ and carries the cross-thread read hazard the streamed
# count exists to avoid). And the per-unit veto is not merely conservative — it is what
# makes release_and_free() safe, because that keys off every slot in the play's
# _dispatchers array and a preempted slot's entry goes stale. So this does not remove
# the veto; it adds a second way past it that is strictly narrower:
#   - ONE-SHOT casts only (the reserved event lane). Combat casts, beds and the click
#     unit keep the veto unconditionally.
#   - `is_sequencing_done()` still gates it, so a cast whose slot was stolen by a live
#     cast reads NOT done (that slot's active_word bit-0 is set) and stays.
#   - 120 subs = 500 ms of silence AFTER the sequence ended. A one-shot blip's release
#     tail is far shorter, so its own voices are provably stopped; the residual is a
#     spurious key-off on a slot stolen by a cast that has ALSO already drained.
# Same family as ONE_SHOT_REAP_GRACE_SUBS above, and for the same reason: the
# lifecycle a fire-and-forget cast actually has is not the one the long grace assumes.
const ONE_SHOT_SILENCE_SUBS := 120
# UNLOCKED hard cap on stacked SPUs. With one-cast-per-unit routing this is also
# the max number of SIMULTANEOUS casts before they double up — 8 covers any
# realistic tactics-battle overlap. Each rendered unit adds one reverb tank's
# per-sample cost, and idle units sleep, so cost tracks concurrent activity and
# the cap only bounds the worst case.
const MAX_UNITS := 8
# Safety cap for an orphaned cast (visual ended) whose sound never reaches
# EndBar (e.g. a looping ambient) — force it to release after ~15 s so it can't
# drone/leak forever. Normal effects reap as soon as their FEDS sequence ends.
const ORPHAN_MAX_SUBS := 3600
# Reserved ambient ({6B} BG Sound) SPU units, held OUTSIDE the MAX_UNITS transient
# pool. A persistent looping bed (rain/windmill) would otherwise permanently hold a
# transient unit and, at the cap, get combat hits doubled onto its core (in-core
# clip). These reserved units are never returned by _pick_unit, never count against
# the 8-unit combat budget, and feed their OWN bus limiter so a loud bed can't eat
# combat's headroom. Small fixed set — scenario 4 layers 2 beds (rain + windmill);
# a couple more give headroom. Spawned lazily like transient units (idle ones sleep).
const MAX_BG_UNITS := 4
# Reserved GAME-EVENT ({21} sound effects, UI cues, unit-death blips — everything
# SfxRouter routes through play_one_shot) SPU units, held OUTSIDE the MAX_UNITS
# transient pool.
#
# These casts do NOT want _pick_unit's one-cast-per-unit policy. That policy buys a
# combat effect its own reverb tank so concurrent casts mix at the bus instead of
# summing in one core — worth a whole SPU for a big multi-pair effect. A game-event
# blip is a SINGLE pair (two voices) of a 12-pair pool, and the PSX gave the whole
# game one SPU; spending one of eight combat units on each blip is what let a
# repeated cue take the pool to the cap. Measured in GPUArena: at 8 live units the
# scheduler's per-sub stamping runs over its 4.16 ms real-time budget and the audio
# clock drops to ~130 subs/s against a required 240 — i.e. the SFX and the music
# both slow down. Capping this lane at two units bounds that by construction.
#
# Two units x EVENT_SESSIONS_PER_UNIT is far more concurrent game-event sound than
# anything reachable: the loudest real burst is a wipe (a handful of unit_died) or a
# key-repeat-driven UI cue, and one unit alone holds 12 pairs.
const MAX_EVENT_UNITS := 2
# One-shot casts PACKED per reserved event unit before the next one is spawned. 8 of
# the pool's 12 pair slots, leaving headroom so find_free_pair_slot is not preempting
# a still-sounding blip at the boundary.
const EVENT_SESSIONS_PER_UNIT := 8
# int16 full scale. Was BusLimiter.FULL_SCALE until that class was deleted
# (#385 task 3); the rail readout below still normalises against it, because the
# in-core clip it reports is an int16 clip and always was.
const FULL_SCALE := 32767.0

enum VoiceMode { FAITHFUL, UNLOCKED }

## The PSX voice budget is a POLICY THE BRACKET IS GIVEN, not a hardcoded compromise
## (goal #8, ADR-0152) — so it is a DECLARED tunable on the same terms as the de-click
## fade below: slug + `static var` default home + affordance hint here, `tunables()`
## publishes it, and the host adapter binds it and pushes the setter (ADR-0113's
## inversion, ADR-0153 dec. 3). Nothing here names a config registry.
##
## It was NOT declared until now, and `docs/GOALS.tsv` row `2 Audio 8` said it was —
## "declared by `tunables()` and bound by the host adapter" — while `tunables()`
## returned two rows and neither was this. The prose was the design; this is the build.
##
## The hint is an `enum` map, so ADR-0068 dec. 11's control resolver renders an
## OptionButton rather than guessing a spinbox off the int (TuneField._control_kind:
## an `enum` hint wins outright).
const VOICE_MODE_SLUG := "audio.voice_mode"
static var VOICE_MODE_DEFAULT := VoiceMode.UNLOCKED
const VOICE_MODE_HINT := {"enum": {"FAITHFUL": VoiceMode.FAITHFUL,
	"UNLOCKED": VoiceMode.UNLOCKED}}
var voice_mode: int = VOICE_MODE_DEFAULT

var ready_ok := false

## Park the live audio path and drive the units in LOCKSTEP through render_subs.
##
## A property, not a plain flag, and that is load-bearing since #385 task 3. The
## offline path calls render_interleaved_pcm16 on each unit's SPU — but while a
## stream is live the AUDIO THREAD owns that SPU, and every register write is
## queued rather than applied. Rendering offline against a live stream would both
## race the mixer and read silence, because the writes the render depends on are
## still sitting in the ring.
##
## So flipping this true hands every SPU back from the audio thread first, and
## flipping it false re-arms them. Tests that were written as
## `ExMateriaEffectSfx.capture_mode = true` keep working unchanged.
var capture_mode := false:
	set(value):
		if value == capture_mode:
			return
		capture_mode = value
		if _live and _audio_mutex != null:
			_audio_mutex.lock()
			_park_streams_locked(value)
			_audio_mutex.unlock()

var _units: Array = []              # Array of transient (combat-SFX) unit dicts (see _make_unit)
var _bg_units: Array = []           # reserved ambient units — out of the _units pool, never _pick_unit'd
var _click_units: Array = []        # reserved typewriter-click unit (0 or 1) — out of _units/_bg_units
var _event_units: Array = []        # reserved game-event (play_one_shot) units — out of the transient pool
# The note-chip AUDITION unit (ADR-0085 2026-08-13 hold-to-play): a single RESERVED unit,
# out of every other pool, that the studio pokes directly for hold-to-play note previews.
# Direct pokes MUST be mutex-guarded (they'd otherwise race the producer thread) and the
# unit is force-kept-active while sounding (else _unit_active idles it out and the producer
# stops ticking the SPU — the "works once then silent" bug). Two voices, rotated so a fast
# re-press lands on a fresh voice (a just-keyed voice won't re-attack until it releases).
var _audition_unit: Dictionary = {}
var _audition_voice_i: int = 0
const _AUDITION_VOICES := [22, 23]
const _AUDITION_VOL := 0x3FFF   # full SPU voice volume (a "sensible default", ADR build detail)
# The POLYPHONIC KEYBOARD (exmateria-etude) rides the same reserved unit. Where
# audition_* is a PREVIEW — one note, fixed level, the two rotating voices above —
# this is an INSTRUMENT: every key that is down sounds, at its own velocity, until
# it is released. The two voice sets are disjoint, so a preview and a held chord
# can sound at once without either noticing.
const NOTE_VOICE_COUNT := 22    ## voices 0..21 — everything _AUDITION_VOICES does not reserve
const MAX_VOICE_VOL := 0x3FFF   ## full-scale SPU voice volume (the same number _AUDITION_VOL uses)
var _note_voices: Dictionary = {}   # key (MIDI note) -> voice index, the keys currently down
var _note_order: Array[int] = []    # the same keys, oldest press first — the steal order
var _click_token: int = 0           # current retriggered click cast (0 = none)
# Retrigger de-click ramp for the typewriter blip (fast-type pop fix). Fade
# length in ms applied to the reserved click mixer ONLY: re-keying the click
# voice fades the previous blip's residual to zero instead of stepping, killing
# the amplitude-discontinuity click. 0 = off (historical instant reset). ~3 ms
# removes the pop while staying under the ~8 ms min glyph spacing, so every blip
# still plays at full density. Live-tunable via set_click_retrigger_fade_ms for
# by-ear A/B (3/5/10 ms).
#
# The de-click retrigger fade is the `audio.click_retrigger_fade_ms` tunable (ADR-0068),
# DECLARED by tunables() and bound by the host adapter — this package names no config
# registry (ADR-0113's inversion, ADR-0153 dec. 3). DEFAULT is a `static var` (not const)
# so it is the materializable home the bind's follower can rewrite (R1); HINT lives here
# too so the panel reads it back as a pure view.
const CLICK_RETRIGGER_FADE_MS_SLUG := "audio.click_retrigger_fade_ms"
static var CLICK_RETRIGGER_FADE_MS_DEFAULT := 3.0
const CLICK_RETRIGGER_FADE_MS_HINT := {"min": 0.0, "max": 20.0, "step": 0.5}
var click_retrigger_fade_ms: float = CLICK_RETRIGGER_FADE_MS_DEFAULT
var _bank_cache: Dictionary = {}    # feds_path -> FedsBank (click path only — no per-glyph disk reload)
var _sessions: Dictionary = {}      # token -> {play, entity, unit} (unit null until 1st dispatch)
var _cast_token := 0
var _abs_sub := 0
var _sample_acc := 0                # global 183/184 drift accumulator (shared by all units)

# True while this instance drives real audio. An offline-capture instance
# (init_as_capture) has no streams, no players and no scheduler thread: it renders
# in lockstep through render_subs, which is exactly what makes a capture
# deterministic and repeatable. Gates stream creation inside _make_unit.
var _live := false

# Scheduler-thread model. One Mutex serialises:
#   - the scheduler thread's per-sub tick (_abs_sub / _sample_acc / _units /
#     _sessions / the register writes it stamps)
#   - main-thread session lifecycle (begin/play/end/orphan/stop_all/panic/audition)
#
# The thread no longer RENDERS. Each unit's SPU is rendered by its own
# ExMateriaSpuStream inside Godot's `_mix`, on the audio thread (D3 dec. 2); all
# this thread does is tick the runtimes and stamp their register writes at the
# frame they belong at, SCHED_LEAD_FRAMES ahead of the audio clock. That deletes
# the GDScript sum + limiter that used to run here (D3 §3: 566 us per block, 2.3x
# the SPU render it protected) while keeping the small, jitter-immune lead that a
# main-thread scheduler cannot hold at 15 fps.
#
# Public session methods take the lock and dispatch to `_locked` helpers; internal
# callers (_reap_orphans, audition) use the helpers directly. The scheduler holds
# the lock only for one sub at a time, so main-thread session ops never wait long.
# Tests that use render_subs / capture_mode park the scheduler and drive
# _render_sub_pcm themselves under the same mutex.
var _audio_mutex: Mutex
var _sched_thread: Thread
var _sched_exit: bool = false

# Ambient sub-level trim (debug knob; 1.0 = no trim). This used to scale the bed
# PCM before a second hand-rolled limiter; it is now the ambient units' players'
# volume_db. Same knob, same range, same purpose — seat a persistent bed UNDER
# combat SFX — but expressed as a LEVEL rather than as limiting, which is what
# ADR-0050's own note ("so a persistent bed can be seated UNDER combat SFX")
# actually asked for. Setting it on the players rather than on the Ambient bus
# keeps it working in a host that declares no bus layout at all.
# The {6B} per-voice ramp applies on top of this.
var _bg_level := 1.0

# Diagnostic counters for the "popping under concurrent casts" hunt. Each maps
# to a distinct click/crackle mechanism so we can tell them apart in the data
# (surfaced via debug_snapshot). preempts: a voice pair was stolen mid-flight.
# cap_doublings: a cast had to share a unit at the MAX_UNITS cap (in-core clip).
# The old `underruns` counter is GONE: it counted the hand-fed generator ring
# running dry, and there is no ring any more — `_mix` renders the SPU directly.
# Its successor is the SCHEDULER block in debug_snapshot (late / dropped), which
# reports the failure this design can actually have: a register write reaching
# the audio thread after its own frame had already passed.
var _stat_preempts := 0
var _stat_cap_doublings := 0

# W11/R28 step 1 — the SPLIT inside a play_one_shot/audition call. R27 sized this
# path from the GAME side (SfxRouter.play_system: 0.47 ms idle -> 27.8 ms at ~130
# live sessions) and read TWO candidate mechanisms out of the source without timing
# either; sizing a fix off an undecomposed number is what refuted W9. These four
# buckets decide it, and each names a DIFFERENT fix:
#   load     -> _FedsBank.load_from_file             : cache the bank
#   lock     -> _audio_mutex.lock()                  : contention with _scheduler_main
#                                                      (see its docstring: a cast once
#                                                       waited 3591 ms here) — NOT a
#                                                       cache and NOT a reap
#   bind     -> first-dispatch unit binding in       : the unit pickers / _Play.new
#               _play_pair_locked (_pick_event_unit /
#               _pick_unit -> _reap_dead_sessions)
#   seq      -> find_free_pair_slot + play_feds_pair : the sequencer itself
# Cumulative microseconds and call counts; a reader diffs them across a window.
# Unconditional (like the game-side buckets) because they are 6 Time reads on a
# path that fires per ATTACK, not per frame. `miss` counts the early-return
# (bad path / bad pair) so `n` stays the honest divisor for lock/bind/seq.
var _stat_aud_n := 0
var _stat_aud_miss := 0
var _stat_aud_load_us := 0
var _stat_aud_lock_us := 0
var _stat_aud_disp_us := 0
var _stat_pp_n := 0
var _stat_pp_binds := 0
var _stat_pp_bind_us := 0
var _stat_pp_seq_us := 0

# W11 step 1b — what the SCHEDULER thread does while it holds _audio_mutex, since
# step 1 measured that the main thread's whole cost is WAITING for that mutex.
# Two candidates inside one hold, and they need different fixes:
#   reap  -> _reap_orphans + _reap_dead_sessions, O(live sessions), run every 30
#            subs from _advance_sub_locked  -> a DATA-STRUCTURE fix
#   stamp -> _stamp_unit_group, O(active units) per sub  -> the scheduler's own
#            design, i.e. the "get it off the tick thread" territory
# `walked` is COUNTED WORK (W8's ruling: wall clock on this box is contended),
# so a fix must move it, not just the milliseconds.
var _stat_sched_holds := 0
var _stat_sched_hold_us := 0
var _stat_sched_subs := 0
var _stat_sched_reaps := 0
var _stat_sched_reap_us := 0
var _stat_sched_walked := 0
var _stat_sched_killed := 0
# W11 step 1b — WHY the reap declines each session, and how much SEQUENCER work
# the survivors cost. `entities` is the summed per-unit entity-list length the
# scheduler ticks every sub: an un-reaped session is still linked into its unit's
# list, so it is still sequenced. That, not the reap walk, is the counted work.
var _stat_reap_skip_undispatched := 0
var _stat_reap_skip_grace := 0
var _stat_reap_skip_voices := 0
var _stat_reap_skip_seq := 0
var _stat_sched_entities := 0
var _stat_reap_silence_freed := 0

# Live console monitor (opt-in via the `audio.monitor_enabled` tunable). Taps the
# Master bus so it sees the TRUE final mix (SFX + music) and prints per-SECOND
# rates, so an audible pop can be correlated to a spiking mechanism in the real
# game. Lazily attaches the Master tap the first time it runs.
#
# The gate is a `static var` HERE, not a flag on the host's debug autoload: a system
# logs itself (ADR-0140 dec. 5). It is still a tunable — declared by tunables(), bound
# by the host adapter — so a scrub persists and the F3 dashboard renders it.
const AUDIO_MONITOR_SLUG := "audio.monitor_enabled"
static var audio_monitor_enabled := false
var _mon_cap: AudioEffectCapture
var _mon_t := 0.0
var _mon_last := 0.0
var _mon_master_clip := 0          # samples at the device rail this window
var _mon_master_peak := 0.0        # final-mix peak this window
var _mon_prev_underruns := 0
var _mon_prev_clamp := 0
var _mon_prev_preempts := 0


## This package's sibling SPU-owner singleton, found by NODE PATH and cached.
##
## `ExMateriaAudioEngine` as a bare identifier is not a symbol this package declares — it is a
## name the CONSUMER's `project.godot` autoload block creates, and this package declares
## no autoloads at all. Writing it here made the package's own always-on SFX driver fail
## to parse in any project but the host's:
##
##     godot --path exmateria-sound --check-only -s res://addons/exmateria_sound/runtime/effect_sfx_engine.gd
##     Parse Error: Identifier "ExMateriaAudioEngine" not declared in the current scope.  x13
##
## The pair is real and stays — this engine genuinely needs the shared waveset and the
## boot-loaded SFX SPU, and the autoload ORDER note above is still the contract. What
## changes is only how the name is resolved: a `/root/` lookup names no symbol, so the
## file parses everywhere and a consumer that did not autoload the pair gets a null and
## a push_error naming the reason, instead of a parse error naming an identifier.
##
## Deliberately UNTYPED — a `Node`-typed local cannot reach `ready_ok`/`waveset`/`sfx_spu`
## without the static type this exists to avoid needing.
var _audio_eng = null


func _audio_engine():
	if _audio_eng != null and is_instance_valid(_audio_eng):
		return _audio_eng
	# Not get_node(): init_as_capture() runs on a bare `.new()` instance that is
	# deliberately NOT in the scene tree, and such a node has no tree-relative path.
	var loop := Engine.get_main_loop() as SceneTree
	_audio_eng = loop.root.get_node_or_null(^"ExMateriaAudioEngine") if loop != null else null
	return _audio_eng


func _ready() -> void:
	var ae = _audio_engine()
	if ae == null:
		push_error("ExMateriaEffectSfx: no ExMateriaAudioEngine singleton at /root/ExMateriaAudioEngine — "
			+ "a consumer must autoload addons/exmateria_sound/runtime/audio_engine.gd "
			+ "BEFORE this script (see the autoload-order note at the top of this file).")
		return
	# Local modification, 2026-09-13: absent content is normal. Initialize only
	# after the host supplies a valid waveset, including after scene startup.
	if ae.ready_ok:
		_initialize_live()
	else:
		ae.initialized.connect(_initialize_live, CONNECT_ONE_SHOT)


func _initialize_live() -> void:
	if ready_ok:
		return
	# Both must precede the first _make_unit: a live unit arms a stream and a
	# player in _attach_stream, and a stream's SPU is handed to the audio thread
	# the moment it is armed.
	_audio_mutex = Mutex.new()
	_live = true
	_audio_engine().sfx_spu.reset()                 # unit 0 reuses the shared, boot-loaded SFX SPU
	_units.append(_make_unit(_audio_engine().sfx_spu))
	_Play._entity_state_seed = SYNTHETIC_SEED   # fresh per-cast plays seed from this static

	# Pre-create the note-chip audition unit (ADR-0085 2026-08-13) so the FIRST hold-to-play
	# press sounds immediately — a lazily-created unit takes a couple scheduler cycles to warm
	# into the render path (the first taps read silent). Built before the scheduler starts, so
	# no mutex needed here. session_count stays 0, so its stream is armed IDLE and costs
	# nothing until a press keys it.
	var _am := _Spu.new()
	if _am.load_instruments(_audio_engine().waveset.descriptors(), _audio_engine().waveset.adpcm_data):
		_am.reset()
		_audition_unit = _make_unit(_am, _Pool.new(24, 0, 24))

	ready_ok = true
	# No bind here. The tunables are DECLARED (see tunables()) and the host adapter binds
	# them + pushes each setter, so a committed override still applies at boot in every
	# scene (and re-arms the click mixer when it lazily spawns) without this package naming
	# the host's config registry — ADR-0113's inversion as applied by ADR-0153 dec. 3.
	_sched_thread = Thread.new()
	_sched_thread.start(Callable(self, "_scheduler_main"))
	print("[ExMateriaEffectSfx] ready — one AudioStream per SPU unit (mode=%s, units=%d, bus=%s/%s)"
		% [_mode_name(), _units.size(), OUTPUT_BUS, BG_OUTPUT_BUS])


## Initialize this instance as a DEDICATED OFFLINE-CAPTURE engine: its OWN SPU hardware and a
## single unit, with NO producer thread / generator / live-audio output. The studio's ghost +
## energy render queues drive it via render_subs, so an offline capture runs on a SEPARATE SPU
## from the live-audio autoload — it NEVER parks the live producer, so editing, auditioning, and
## building the energy band stay concurrent (the "everything as we go" fix). MUST be created on a
## bare `.new()` instance that is NOT added to the scene tree (so `_ready`'s live-audio path never
## runs). Shares ExMateriaAudioEngine.waveset (read-only instrument data — the ADPCM bank isn't mutated).
## Returns false if the waveset isn't ready. Free it with free() when the studio closes.
func init_as_capture() -> bool:
	var ae = _audio_engine()
	if ae == null or not ae.ready_ok:
		return false
	var spu := _Spu.new()
	if not spu.load_instruments(ae.waveset.descriptors(), ae.waveset.adpcm_data):
		return false
	spu.reset()
	_units = [_make_unit(spu)]
	_audio_mutex = Mutex.new()
	capture_mode = true   # capture-only: there is no producer to park; render_subs drives it
	ready_ok = true
	return true


func _exit_tree() -> void:
	if _sched_thread == null:
		return
	if _audio_mutex != null:
		_audio_mutex.lock()
		_sched_exit = true
		_audio_mutex.unlock()
	_sched_thread.wait_to_finish()
	_sched_thread = null
	_detach_units_locked(_all_units())
	# Local modification, 2026-09-13: break pool -> flush -> pool ownership
	# cycles only after the scheduler has stopped using them.
	for unit in _all_units():
		unit["pool"].set_flush_tick(null)


func _mode_name() -> String:
	return "FAITHFUL" if voice_mode == VoiceMode.FAITHFUL else "UNLOCKED"


func unit_count() -> int:
	return _units.size()


func debug_snapshot() -> Dictionary:
	## Live SPU/unit state for monitoring (stress scene / debug overlay).
	if not ready_ok:
		return {}
	_audio_mutex.lock()
	var units_info: Array = []
	var total_voices := 0
	for i in range(_units.size()):
		var u = _units[i]
		var vc: int = _unit_voice_count(u)
		total_voices += vc
		units_info.append({
			"voices": vc,
			"sessions": int(u["session_count"]),
			"active": _unit_active(u, i),
			# Which bus this unit is ROUTED to, and whether its stream is currently
			# live. Reported because the ambient / combat headroom split is now a
			# property of the routing (#385 task 3) — it used to be two hand-rolled
			# limiters over one summed buffer, visible only through their stats.
			# `bus` is the unit's routing and holds whether or not the stream is
			# parked (capture_mode parks them all); `streaming` is the runtime fact.
			"bus": str(u.get("bus", "")),
			"streaming": bool(u.get("streaming", false)),
		})
	# Reserved ambient ({6B}) units — parallel to units_info but out of the pool.
	var bg_info: Array = []
	for i in range(_bg_units.size()):
		var u = _bg_units[i]
		var vc: int = _unit_voice_count(u)
		total_voices += vc
		bg_info.append({
			"voices": vc,
			"sessions": int(u["session_count"]),
			"active": _unit_active(u, i),
			# Which bus this unit is ROUTED to, and whether its stream is currently
			# live. Reported because the ambient / combat headroom split is now a
			# property of the routing (#385 task 3) — it used to be two hand-rolled
			# limiters over one summed buffer, visible only through their stats.
			# `bus` is the unit's routing and holds whether or not the stream is
			# parked (capture_mode parks them all); `streaming` is the runtime fact.
			"bus": str(u.get("bus", "")),
			"streaming": bool(u.get("streaming", false)),
		})
	# Reserved typewriter-click unit (parallel to the others, out of every pool).
	var click_info: Array = []
	for i in range(_click_units.size()):
		var u = _click_units[i]
		var vc: int = _unit_voice_count(u)
		total_voices += vc
		click_info.append({
			"voices": vc,
			"sessions": int(u["session_count"]),
			"active": _unit_active(u, i),
			# Which bus this unit is ROUTED to, and whether its stream is currently
			# live. Reported because the ambient / combat headroom split is now a
			# property of the routing (#385 task 3) — it used to be two hand-rolled
			# limiters over one summed buffer, visible only through their stats.
			# `bus` is the unit's routing and holds whether or not the stream is
			# parked (capture_mode parks them all); `streaming` is the runtime fact.
			"bus": str(u.get("bus", "")),
			"streaming": bool(u.get("streaming", false)),
		})
	# Reserved game-event units (play_one_shot lane, out of every other pool).
	var event_info: Array = []
	for i in range(_event_units.size()):
		var u = _event_units[i]
		var vc: int = _unit_voice_count(u)
		total_voices += vc
		event_info.append({
			"voices": vc,
			"sessions": int(u["session_count"]),
			"active": _unit_active(u, i),
			"bus": str(u.get("bus", "")),
			"streaming": bool(u.get("streaming", false)),
		})
	var out := {
		"mode": _mode_name(),
		"units": units_info,
		"bg_units": bg_info,
		"click_units": click_info,
		"event_units": event_info,
		"total_voices": total_voices,
		"sessions": _sessions.size(),
		"max_units": MAX_UNITS,
		"max_bg_units": MAX_BG_UNITS,
		"max_event_units": MAX_EVENT_UNITS,
		"bg_level": _bg_level,
		# Pop/crackle diagnostics — each a distinct click mechanism.
		"preempts": _stat_preempts,
		"cap_doublings": _stat_cap_doublings,
		# Scheduler health, replacing the old producer `underruns`. There is no ring
		# to starve any more; the failure this design CAN have is a register write
		# reaching the audio thread after its own frame passed (late), or the ring
		# overflowing and dropping one outright (dropped). Both must stay 0.
		"scheduler": _scheduler_stats_locked(),
		# Native in-core SPU rail: the summed-voice saturation INSIDE each unit's
		# C++ core, before clip_pcm16 — the one clip stage the GDScript limiters
		# can't see (render_interleaved_pcm16 already returns clamped PCM). Grouped
		# so "where does it rail" is answerable (a typewriter burst = the click
		# group). pre_clamp_peak is the overshoot factor (1.0 = exactly at rail).
		"rail": _rail_stats_locked(),
	}
	_audio_mutex.unlock()
	return out


func _unit_voice_count(unit: Dictionary) -> int:
	## Active voices on this unit, read from whichever side owns the SPU.
	##
	## get_active_voice_count() walks core_ directly, which the AUDIO thread is
	## writing while a stream is live — `D3` §6 checked that nothing on the
	## gameplay path reads SPU state back, and this is the exception that proves
	## it: the defensive reap needs "is it still audible". The streamed answer is
	## the count the audio thread published at its last block, which is the same
	## question asked across the thread boundary instead of through it.
	if bool(unit.get("streaming", false)):
		return int(unit["mixer"].get_audio_active_voices())
	return int(unit["mixer"].get_active_voice_count())


func _rail_stats_locked() -> Dictionary:
	# Caller holds _audio_mutex. Aggregate the native rail counters per unit group.
	var sfx := _rail_agg(_units)
	var bg := _rail_agg(_bg_units)
	var click := _rail_agg(_click_units)
	var event := _rail_agg(_event_units)
	var peak_raw: int = maxi(maxi(int(sfx["peak_raw"]), int(bg["peak_raw"])),
			maxi(int(click["peak_raw"]), int(event["peak_raw"])))
	return {
		"pre_clamp_peak": float(peak_raw) / FULL_SCALE,
		"hits": int(sfx["hits"]) + int(bg["hits"]) + int(click["hits"]) + int(event["hits"]),
		"samples": int(sfx["samples"]) + int(bg["samples"]) + int(click["samples"]) + int(event["samples"]),
		"sfx": _rail_norm(sfx),
		"bg": _rail_norm(bg),
		"click": _rail_norm(click),
		"event": _rail_norm(event),
	}


func _rail_agg(units: Array) -> Dictionary:
	# Worst single-unit pre-clamp magnitude in the group (raw int16 scale) + SUMMED
	# rail hits/samples. peak is a max (the loudest unit is what pops), hits sum.
	var peak_raw := 0
	var hits := 0
	var samples := 0
	for u in units:
		var ds: Dictionary = u["mixer"].get_debug_stats()
		peak_raw = maxi(peak_raw, int(ds.get("rail_pre_clamp_peak", 0)))
		hits += int(ds.get("rail_hits", 0))
		samples += int(ds.get("rail_samples", 0))
	return {"peak_raw": peak_raw, "hits": hits, "samples": samples}


func _rail_norm(agg: Dictionary) -> Dictionary:
	# Group summary with the peak normalized to the rail (1.0 == exactly full-scale).
	return {"peak": float(int(agg["peak_raw"])) / FULL_SCALE, "hits": int(agg["hits"])}


func reset_audio_stats() -> void:
	## Zero the pop/crackle diagnostic counters.
	_audio_mutex.lock()
	_stat_preempts = 0
	_stat_cap_doublings = 0
	# The native rail counters are written per output sample ON THE AUDIO THREAD
	# now, so zeroing them needs the mixer thread's own mutex — the engine mutex no
	# longer serialises render against read.
	AudioServer.lock()
	for u in _all_units():
		u["mixer"].reset_rail_metrics()
		if bool(u.get("streaming", false)):
			u["mixer"].reset_deferred_stats()
	AudioServer.unlock()
	_audio_mutex.unlock()


func audition_split_stats() -> Dictionary:
	## W11 step 1 — CUMULATIVE microseconds inside the play_one_shot/audition path,
	## split four ways. Deliberately does NOT take _audio_mutex: `lock_us` measures
	## the wait for that very mutex, so a reader that blocks on it would perturb the
	## thing it is reporting (and debug_snapshot(), which does lock, can stall behind
	## _scheduler_main for as long as one catch-up batch). Plain int reads of counters
	## only the calling thread writes — a diagnostic, not a synchronised view.
	##
	## Read by diffing two samples across a window:
	##   load_us  / n  — _FedsBank.load_from_file            -> the fix is a bank cache
	##   lock_us  / n  — waiting on _audio_mutex             -> the fix is neither cache
	##                                                          nor reap; it is the
	##                                                          scheduler's hold
	##   bind_us  / pp_n — first-dispatch unit binding       -> the fix is the picker
	##   seq_us   / pp_n — slot alloc + play_feds_pair       -> the fix is the sequencer
	## `disp_us` is the whole under-lock span (bind + seq + begin/end bookkeeping),
	## so `disp_us - bind_us - seq_us` is what the session bookkeeping itself costs.
	return {
		"n": _stat_aud_n,
		"miss": _stat_aud_miss,
		"load_us": _stat_aud_load_us,
		"lock_us": _stat_aud_lock_us,
		"disp_us": _stat_aud_disp_us,
		"pp_n": _stat_pp_n,
		"binds": _stat_pp_binds,
		"bind_us": _stat_pp_bind_us,
		"seq_us": _stat_pp_seq_us,
		"sessions": _sessions.size(),
		# step 1b — the other side of the mutex.
		"sched_holds": _stat_sched_holds,
		"sched_hold_us": _stat_sched_hold_us,
		"sched_subs": _stat_sched_subs,
		"sched_reaps": _stat_sched_reaps,
		"sched_reap_us": _stat_sched_reap_us,
		"sched_walked": _stat_sched_walked,
		"sched_killed": _stat_sched_killed,
		"sched_entities": _stat_sched_entities,
		"skip_undisp": _stat_reap_skip_undispatched,
		"skip_grace": _stat_reap_skip_grace,
		"skip_voices": _stat_reap_skip_voices,
		"skip_seq": _stat_reap_skip_seq,
		"silence_freed": _stat_reap_silence_freed,
	}


func _scheduler_stats_locked() -> Dictionary:
	## Caller holds _audio_mutex. Worst case across every streaming unit, plus the
	## live lead on the reference clock — the SFX mirror of the F3 Music scheduler
	## line. `late` and `dropped` are the two failures this design can have.
	var late := 0
	var dropped := 0
	var min_free := -1
	var streams := 0
	for u in _all_units():
		if not bool(u.get("streaming", false)):
			continue
		streams += 1
		var ds: Dictionary = u["mixer"].get_deferred_stats()
		late += int(ds.get("overdue", 0))
		dropped += int(ds.get("overflow", 0))
		var free: int = int(ds.get("free_slots", 0))
		min_free = free if min_free < 0 else mini(min_free, free)
	var lead_ms := 0.0
	if not _units.is_empty() and bool(_units[0].get("streaming", false)):
		var u0 = _units[0]
		lead_ms = float(int(u0["sched_frame"]) - int(u0["mixer"].get_audio_frame())) \
				/ float(_Spu.SAMPLE_RATE) * 1000.0
	return {
		"streams": streams,
		"lead_ms": lead_ms,
		"target_lead_ms": float(SCHED_LEAD_FRAMES) / float(_Spu.SAMPLE_RATE) * 1000.0,
		"late": late,
		"dropped": dropped,
		"min_free_slots": min_free,
	}


func _make_pool():
	if voice_mode == VoiceMode.FAITHFUL:
		return _Pool.new(8, 16, 6)   # exact FFT pool: voices 16-23, slots 6-7 reserved (3 pairs)
	return _Pool.new(24, 0, 24)      # UNLOCKED: all 24 voices base 0 (12 pairs)


func _make_unit(mixer: _Spu, pool = null, bus: StringName = OUTPUT_BUS) -> Dictionary:
	mixer.set_irq_period_samples(512)
	if pool == null:
		pool = _make_pool()
	var flush = _Flush.new(pool, mixer)
	pool.set_flush_tick(flush)
	var walker = _Walker.new(pool, mixer)
	var list = _EntityList.new()       # PER-UNIT entity list (isolates this unit's casts)
	var rt = _RuntimeC.new(mixer, flush, walker)
	rt.sfx_only = true
	rt.entity_list = list
	var unit := {
		"mixer": mixer, "pool": pool, "flush": flush, "walker": walker,
		"rt": rt, "list": list, "session_count": 0, "last_active_sub": 0,
		# Stream half — populated by _attach_stream on a live engine, left null on an
		# offline-capture engine (which renders in lockstep through render_subs).
		"stream": null, "player": null, "bus": bus, "streaming": false,
		# The frame this unit's NEXT register write belongs at, in ITS OWN stream's
		# clock. Every unit's clock starts at 0 when its stream is armed, so a unit
		# spawned mid-battle is not on the same absolute timeline as unit 0 — which is
		# why the stamp is per-unit and only the PACING reads unit 0.
		"sched_frame": 0,
	}
	if _live and not capture_mode:
		_attach_stream(unit)
	return unit


func _attach_stream(unit: Dictionary) -> void:
	## Give this unit its own ExMateriaSpuStream on its own AudioStreamPlayer.
	##
	## ONE STREAM PER Spu is the parity boundary (`D3` dec. 5). The PSX has a single
	## 24-voice SPU; summing several of them was never PSX-accurate, so handing that
	## sum to Godot's bus mixer costs nothing in fidelity and deletes the GDScript
	## cross-unit sum + limiter that used to run on the producer thread. Concurrent
	## casts now mix in float on a real bus instead of saturating an int32 buffer.
	##
	## Armed IDLE. A unit holds a live cast only part of the time, and an
	## always-rendering stream would burn a full 24-voice render per silent unit per
	## block; set_stream_idle keeps the clock advancing (the scheduler paces off it)
	## while skipping the mix entirely. The scheduler re-asserts the flag every sub.
	var stream := ExMateriaSpuStream.new()
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.bus = unit["bus"]
	if unit["bus"] == BG_OUTPUT_BUS:
		player.volume_db = _bg_level_db()
	add_child(player)
	var mixer: _Spu = unit["mixer"]
	stream.set_mixer(mixer.get_native())
	mixer.set_deferred_mode(true, QUEUE_CAPACITY)   # clears the ring, rewinds both clocks
	mixer.set_stream_idle(true)
	unit["stream"] = stream
	unit["player"] = player
	unit["streaming"] = true
	# Arm WITH a lead. A fresh stream's audio clock is 0, so a write stamped at the
	# unit's frame 0 would land exactly at the cursor and be applied overdue on the
	# very first block.
	unit["sched_frame"] = SCHED_LEAD_FRAMES
	player.play()


func _all_units() -> Array:
	## Every unit this engine owns, in one list — the pools are separate for ROUTING
	## (combat / bed / click / audition each get their own SPU and their own bus), but
	## stream lifecycle and teardown apply to all of them identically.
	var all: Array = _units + _bg_units + _click_units + _event_units
	if not _audition_unit.is_empty():
		all.append(_audition_unit)
	return all


func _arm_writes(unit: Dictionary) -> void:
	## Stamp whatever register writes follow at this unit's current schedule frame.
	##
	## Anything that writes SPU registers OUTSIDE the scheduler's per-sub tick —
	## main-thread pokes (audition, bg gain), session teardown, the reapers — must
	## call this first. Without it the write carries whatever frame was stamped last,
	## which is a sub in the past, and the audio thread applies it overdue.
	## Safe to call on a capture unit: it is a no-op when nothing is streaming.
	if bool(unit.get("streaming", false)):
		unit["mixer"].set_schedule_frame(int(unit["sched_frame"]))


func _bg_level_db() -> float:
	## The ambient trim as a player gain. 0.0 is silence, not -0.0 dB, so it maps to
	## the engine's minimum rather than through linear_to_db(0) == -inf.
	return -80.0 if _bg_level <= 0.0 else linear_to_db(_bg_level)


func _spawn_unit():
	## Add a stacked SPU unit (UNLOCKED only). Returns the unit or null if at the
	## cap / upload failed. The instrument upload is the one-time per-unit cost,
	## paid lazily the first time concurrency overflows the existing units.
	if _units.size() >= MAX_UNITS:
		return null
	var m := _Spu.new()
	if not m.load_instruments(_audio_engine().waveset.descriptors(), _audio_engine().waveset.adpcm_data):
		push_warning("ExMateriaEffectSfx: extra SPU instrument load failed")
		return null
	m.reset()
	var u := _make_unit(m)
	_units.append(u)
	print("[ExMateriaEffectSfx] spawned SFX unit %d (now %d)" % [_units.size() - 1, _units.size()])
	return u


func _spawn_bg_unit():
	## Add a reserved ambient unit (out of the transient pool). Returns the unit or
	## null at MAX_BG_UNITS / on upload failure. Reserved units always use the full
	## 24-voice pool regardless of voice_mode — they're a game-side mix convenience,
	## not part of the FAITHFUL parity budget.
	if _bg_units.size() >= MAX_BG_UNITS:
		return null
	var m := _Spu.new()
	if not m.load_instruments(_audio_engine().waveset.descriptors(), _audio_engine().waveset.adpcm_data):
		push_warning("ExMateriaEffectSfx: reserved ambient SPU instrument load failed")
		return null
	m.reset()
	var u := _make_unit(m, _Pool.new(24, 0, 24), BG_OUTPUT_BUS)
	_bg_units.append(u)
	print("[ExMateriaEffectSfx] spawned ambient unit %d (now %d reserved)"
		% [_bg_units.size() - 1, _bg_units.size()])
	return u


func _spawn_event_unit():
	## Add a reserved game-event unit (out of the transient pool). Returns the unit
	## or null at MAX_EVENT_UNITS / on upload failure. Full 24-voice pool and the
	## normal SFX bus — a game-event blip mixes with combat exactly as it did; all
	## that changes is which SPU core it sequences on.
	if _event_units.size() >= MAX_EVENT_UNITS:
		return null
	var m := _Spu.new()
	if not m.load_instruments(_audio_engine().waveset.descriptors(), _audio_engine().waveset.adpcm_data):
		push_warning("ExMateriaEffectSfx: reserved game-event SPU instrument load failed")
		return null
	m.reset()
	var u := _make_unit(m, _Pool.new(24, 0, 24))
	_event_units.append(u)
	print("[ExMateriaEffectSfx] spawned game-event unit %d (now %d reserved)"
		% [_event_units.size() - 1, _event_units.size()])
	return u


func _pick_event_unit() -> Dictionary:
	## Route a one-shot game-event cast to a RESERVED event unit. PACKS rather than
	## spreads — the opposite of _pick_unit, deliberately. Spreading exists to give
	## each combat cast its own reverb tank; these are single-pair blips that shared
	## one SPU on the real hardware, and packing them is what keeps the number of
	## ACTIVE units (the thing the scheduler pays per sub for) flat no matter how
	## fast cues arrive. Returns {} only if the first spawn failed, and the caller
	## then falls back to the transient pool rather than dropping the sound.
	for u in _event_units:
		if int(u["session_count"]) < EVENT_SESSIONS_PER_UNIT:
			return u
	var spawned = _spawn_event_unit()
	if spawned != null:
		return spawned
	if _event_units.is_empty():
		return {}
	# Every reserved event unit is packed full. Share the least-loaded one; its pool
	# preempts the oldest pair slot, which for one-shot blips is the right answer.
	_stat_cap_doublings += 1
	var best = _event_units[0]
	for u in _event_units:
		if int(u["session_count"]) < int(best["session_count"]):
			best = u
	return best


func _pick_bg_unit() -> Dictionary:
	## Route a bg ({6B}) cast to a RESERVED ambient unit — never touches _units, so
	## combat never loses a slot to a bed and a bed never gets a combat hit doubled
	## onto its core. One bed per unit; spawn up to MAX_BG_UNITS, then double up on
	## the least-loaded reserved unit. Returns {} only if the first spawn failed
	## (no reserved units at all) — the caller then aborts the bg cast.
	for u in _bg_units:
		if int(u["session_count"]) == 0:
			return u
	var spawned = _spawn_bg_unit()
	if spawned != null:
		return spawned
	if _bg_units.is_empty():
		return {}
	# All reserved units busy (more concurrent beds than MAX_BG_UNITS): share a core.
	_stat_cap_doublings += 1
	var best = _bg_units[0]
	for u in _bg_units:
		if int(u["session_count"]) < int(best["session_count"]):
			best = u
	return best


func _ensure_click_unit() -> Dictionary:
	## Lazily spawn the single RESERVED typewriter-click unit, held OUTSIDE both
	## the transient _units combat pool and the _bg_units bed pool. The per-glyph
	## dialogue blip retriggers on this one unit (see play_click) so a fast
	## type-out never consumes a combat slot and never gets a combat hit doubled
	## onto its core. Full 24-voice pool (mode-independent, like reserved beds).
	## Returns the unit dict, or {} on instrument-upload failure.
	if not _click_units.is_empty():
		return _click_units[0]
	var m := _Spu.new()
	if not m.load_instruments(_audio_engine().waveset.descriptors(), _audio_engine().waveset.adpcm_data):
		push_warning("ExMateriaEffectSfx: reserved click SPU instrument load failed")
		return {}
	m.reset()
	# Arm the retrigger de-click on the click mixer only (music/SFX mixers keep
	# the default 0 = bit-identical). See click_retrigger_fade_ms.
	m.set_click_retrigger_fade_ms(click_retrigger_fade_ms)
	var u := _make_unit(m, _Pool.new(24, 0, 24))
	_click_units.append(u)
	print("[ExMateriaEffectSfx] spawned reserved click unit (retrigger de-click %.1f ms)" % click_retrigger_fade_ms)
	return u


## This package's DECLARED tunables — slug, row label, static-var default, affordance hint
## and the setter to push a new value into (ADR-0153 dec. 3). The HOST walks this and binds
## each to its own config registry; nothing here names that registry, which is what makes
## the package portable (ADR-0113, goal #5). Declaration is data, so it is safe to call
## before any audio hardware exists — a `reset()` test replays the binds from it.
func tunables() -> Array[Dictionary]:
	return [
		{"slug": CLICK_RETRIGGER_FADE_MS_SLUG, "label": "Fade (ms):",
			"default": CLICK_RETRIGGER_FADE_MS_DEFAULT, "hint": CLICK_RETRIGGER_FADE_MS_HINT,
			"setter": set_click_retrigger_fade_ms},
		{"slug": AUDIO_MONITOR_SLUG, "label": "Audio Monitor",
			"default": false, "hint": {},
			"setter": set_audio_monitor_enabled},
		{"slug": VOICE_MODE_SLUG, "label": "Voice budget:",
			"default": VOICE_MODE_DEFAULT, "hint": VOICE_MODE_HINT,
			"setter": set_voice_mode},
	]


## Write port, filled by the host adapter (ADR-0113): a panel edit reaches the host's
## config registry through here, so the package can write a declared tunable without
## naming what stores it. Unfilled (standalone / headless) it is a no-op, which is the
## correct standalone behaviour — the static-var homes above already hold the defaults.
static var tunable_writer := func(_slug: String, _value: Variant) -> void: pass


## Push a declared tunable's new value out through the host's write port. The panel's
## preset buttons go through this, so the host registry and every other view resync.
func write_tunable(slug: String, value: Variant) -> void:
	tunable_writer.call(slug, value)


## What the reserved click mixer is ACTUALLY armed with, in ms — or -1.0 while the
## click unit has not spawned (it spawns lazily on the first blip). A view reads this
## to confirm the coalesced knob reached the native core, which the registry's own
## value cannot tell it.
##
## It exists because the AUDIO panel used to walk `_click_units[0]["mixer"]` itself: a
## three-link chain through a private array, a private dict key, and the mixer. That
## made the shape of `_click_units` — an Array of Dictionary, index 0 reserved — part
## of the panel's contract, so `set_click_retrigger_fade_ms` below could not change it
## without silently breaking a caller in another file.
func armed_click_retrigger_fade_ms() -> float:
	if _click_units.is_empty():
		return -1.0
	var mixer: _Spu = _click_units[0]["mixer"]
	return mixer.get_click_retrigger_fade_ms()


## Setter for the `audio.monitor_enabled` gate (the on_update push target).
func set_audio_monitor_enabled(on: bool) -> void:
	audio_monitor_enabled = on


## Live-tune the typewriter-click retrigger de-click (ms) for by-ear A/B. Applies
## to the reserved click mixer immediately if spawned; 0 disables (restores the
## historical instant-reset pop). Persists as the value used when the click unit
## is first spawned.
func set_click_retrigger_fade_ms(ms: float) -> void:
	click_retrigger_fade_ms = maxf(ms, 0.0)
	if not _click_units.is_empty():
		var unit = _click_units[0]
		# NOT a queued register write — it sets a core_ field directly, so it must
		# not land while a _mix is in flight. The audio lock is the mixer thread's
		# own mutex; a by-ear A/B scrub is rare enough that holding it costs nothing.
		AudioServer.lock()
		unit["mixer"].set_click_retrigger_fade_ms(click_retrigger_fade_ms)
		AudioServer.unlock()


func _pick_unit() -> Dictionary:
	## Route a cast (at first dispatch), UNLOCKED: ONE CAST PER UNIT. Prefer a unit
	## with no live session so each cast gets its own SPU — own voices AND own
	## reverb tank — and concurrent casts mix at the bus limiter, not by summing +
	## clipping inside one unit's C++ core. session_count is the binding metric (it
	## spreads casts dispatched in the same frame, before their voices register);
	## the defensive reap (_reap_dead_sessions) keeps it from leaking, so a missed
	## end/orphan can't wedge a unit. Spawn if all busy; double up only at the cap.
	if voice_mode == VoiceMode.FAITHFUL:
		return _units[0]
	_reap_dead_sessions()
	for u in _units:
		if int(u["session_count"]) == 0:
			return u
	var spawned = _spawn_unit()
	if spawned != null:
		return spawned
	# At the unit cap: this cast has to share a unit, so its voices will sum +
	# clip in-core with the resident cast. Count it — a candidate pop source.
	_stat_cap_doublings += 1
	var best = _units[0]
	for u in _units:
		if int(u["session_count"]) < int(best["session_count"]):
			best = u
	return best


func set_voice_mode(mode: int) -> void:
	"""Switch FAITHFUL <-> UNLOCKED. Stops all SFX and rebuilds units (the voice
	base/slot count change). Safe live (e.g. from a debug toggle); brief silence
	as active casts drop. Extra UNLOCKED units are torn down on FAITHFUL.

	RECORDS THE VALUE EVEN WHEN THE ENGINE IS NOT UP, and the order matters: this is
	the setter the host adapter pushes at bind time, so a committed override arrives
	BEFORE `_ready()` in a scene that autoloads the adapter early, and before
	`init_as_capture()` on a bare instance. Dropping it on `not ready_ok` — which is
	what this did while nothing called it — would silently ignore the override and
	boot UNLOCKED. `_make_unit` reads `voice_mode`, so recording it here is exactly
	what makes the first build honour it. Same shape as set_click_retrigger_fade_ms,
	which stores unconditionally and re-arms the mixer only if one exists."""
	if mode == voice_mode:
		return
	voice_mode = mode
	if not ready_ok:
		return          # recorded; the unit build in _ready/init_as_capture reads it
	_audio_mutex.lock()
	_stop_all_locked()
	# The rebuilt unit reuses the SHARED sfx_spu, which the audio thread currently
	# owns through unit 0's stream. Take it back first — reset() is not a queued
	# register write, it mutates core_ directly.
	_detach_units_locked(_units)
	_audio_engine().sfx_spu.reset()
	_units = [_make_unit(_audio_engine().sfx_spu)]
	_abs_sub = 0
	_audio_mutex.unlock()
	print("[ExMateriaEffectSfx] voice_mode -> %s" % _mode_name())


func begin_effect() -> int:
	"""Open a cast. Unit binding is deferred to the first play_pair so concurrent
	begins spread across units. Returns a token for play_pair()/end_effect()."""
	if not ready_ok:
		return 0
	_audio_mutex.lock()
	var t := _begin_effect_locked()
	_audio_mutex.unlock()
	return t


func _begin_effect_locked() -> int:
	_cast_token += 1
	_sessions[_cast_token] = {"play": null, "entity": null, "unit": null, "orphan_sub": -1, "last_sub": _abs_sub, "last_slot_idx": -1, "is_bg": false, "one_shot": false}
	return _cast_token


func play_pair(token: int, feds_bank, pair_idx: int, sound_id: int,
		single_track: int = -1) -> bool:
	"""Dispatch one FEDS pair for the cast into a free pool slot on its unit
	(binding the unit on first call). pair_idx + sound_id come from
	EffectSoundController.pair_triggered (sound_id = resolver output —
	see CONTEXT.md "Audio" → SoundContainer + EffectSoundResolver).
	`single_track` (0/1) is the authoring-only per-track energy isolation
	(ADR-0085 §3): only that track's voice sounds. Default -1 = both."""
	if not ready_ok or feds_bank == null:
		return false
	_audio_mutex.lock()
	var ok := _play_pair_locked(token, feds_bank, pair_idx, sound_id, single_track)
	_audio_mutex.unlock()
	return ok


func _play_pair_locked(token: int, feds_bank, pair_idx: int, sound_id: int,
		single_track: int = -1) -> bool:
	var session = _sessions.get(token)
	if session == null:
		return false
	if pair_idx < 0 or pair_idx >= feds_bank.num_pairs:
		push_warning("ExMateriaEffectSfx: pair %d out of range (num_pairs=%d)"
				% [pair_idx, feds_bank.num_pairs])
		return false
	# Bind to a unit on the first dispatch (real occupancy known now). A bg cast
	# binds to a RESERVED ambient unit, outside the transient pool.
	# W11 step 1: _tp0.._tp1 is the BIND (the unit pickers — this is where
	# _pick_unit -> _reap_dead_sessions would be paid, if the cast routed there),
	# _tp1..end is the SEQUENCER (slot alloc + play_feds_pair). Every caller of
	# this function feeds the same counters; in a combat run play_one_shot
	# dominates them by orders of magnitude.
	var _tp0 := Time.get_ticks_usec()
	if session["unit"] == null:
		_stat_pp_binds += 1
		var unit: Dictionary
		if bool(session.get("is_click", false)):
			unit = _ensure_click_unit()
			if unit.is_empty():
				push_warning("ExMateriaEffectSfx: no reserved click unit available")
				return false
		elif bool(session.get("is_bg", false)):
			unit = _pick_bg_unit()
			if unit.is_empty():
				push_warning("ExMateriaEffectSfx: no reserved ambient unit available")
				return false
		elif bool(session.get("one_shot", false)):
			# Fire-and-forget game-event SFX: the reserved event lane, so a fast cue
			# never costs combat a slot. Fall back to the transient pool if the lane
			# could not be created at all — better a doubled-up combat unit than a
			# dropped sound.
			unit = _pick_event_unit()
			if unit.is_empty():
				unit = _pick_unit()
		else:
			unit = _pick_unit()
		var play = _Play.new(unit["pool"], _audio_engine().waveset)
		play.set_flush_tick(unit["flush"])
		play.set_entity_list(unit["list"])
		unit["session_count"] = int(unit["session_count"]) + 1
		session["unit"] = unit
		session["play"] = play
	var _tp1 := Time.get_ticks_usec()
	var u = session["unit"]
	var p = session["play"]
	var alloc: Dictionary = u["pool"].find_free_pair_slot(2)
	var slot_idx := int(alloc.get("slot_idx", -1))
	if slot_idx < 0:
		push_warning("ExMateriaEffectSfx: unit pool exhausted (pair=%d)" % pair_idx)
		return false
	# Record the pair's pool slot so a bg-sound ({6B}) volume ramp can later drive
	# the SPU voices it occupies (slot N → voice base+N, per pool.voice_for_slot).
	session["last_slot_idx"] = slot_idx
	if bool(alloc.get("preempted", false)):
		_stat_preempts += 1
		p.free_pair(slot_idx)
	if not p.play_feds_pair(feds_bank, pair_idx, slot_idx, sound_id, single_track):
		push_warning("ExMateriaEffectSfx: play_feds_pair failed (pair=%d slot=%d sid=%d)"
				% [pair_idx, slot_idx, sound_id])
		return false
	if session["entity"] == null:
		session["entity"] = p._entity_catchup
	u["last_active_sub"] = _abs_sub
	session["last_sub"] = _abs_sub
	_stat_pp_n += 1
	_stat_pp_bind_us += _tp1 - _tp0
	_stat_pp_seq_us += Time.get_ticks_usec() - _tp1
	return true


func end_effect(token: int) -> void:
	"""End a cast: key-off its held voices (release tail, not a cut) and unlink
	its entity from its unit's list. Voices ring out on the continuous clock."""
	if not ready_ok:
		return
	_audio_mutex.lock()
	_end_effect_locked(token)
	_audio_mutex.unlock()


func _end_effect_locked(token: int) -> void:
	var session = _sessions.get(token)
	if session == null:
		return
	var p = session["play"]
	var u = session["unit"]
	if p != null:
		# release_and_free() keys the cast's voices off — register writes, and they
		# are stamped with whatever frame was set last unless this re-arms first.
		if u != null:
			_arm_writes(u)
		p.release_and_free()
	if u != null:
		var entity = session["entity"]
		if entity != null:
			entity.is_done = true
			u["list"].unlink(entity)
		u["session_count"] = maxi(0, int(u["session_count"]) - 1)
		u["last_active_sub"] = _abs_sub
	_sessions.erase(token)


func orphan_effect(token: int) -> void:
	"""The cast's VISUAL ended (its EffectInstance was freed) but let its SOUND
	finish: stop expecting new pairs, keep the dispatched ones sequencing to
	their natural EndBar, and reap once done (or after ORPHAN_MAX_SUBS). This is
	what keeps whole effects audible after the particles stop — the alternative
	(end_effect) cuts the sound the instant the visual completes."""
	if not ready_ok:
		return
	_audio_mutex.lock()
	var s = _sessions.get(token)
	if s != null:
		if s["play"] == null:
			_end_effect_locked(token)  # never dispatched — nothing to ring out
		else:
			s["orphan_sub"] = _abs_sub
	_audio_mutex.unlock()


func _reap_orphans() -> void:
	# Caller must hold _audio_mutex.
	var done: Array = []
	for token in _sessions:
		var s = _sessions[token]
		if int(s["orphan_sub"]) < 0:
			continue  # still live (visual not ended)
		var p = s["play"]
		if p == null or p.is_sequencing_done() \
				or (_abs_sub - int(s["orphan_sub"])) > ORPHAN_MAX_SUBS:
			done.append(token)
	for token in done:
		_end_effect_locked(token)


func _reap_dead_sessions() -> void:
	# Caller must hold _audio_mutex. Reclaim sessions whose SOUND is provably over
	# even if the caller never orphaned/ended them (a missed EffectInstance
	# orphan/end must not wedge a unit forever): dispatched (play != null), idle
	# past REAP_GRACE_SUBS, no active voices on the unit, and sequencing finished.
	# Runs both at bind time (free a unit right before it's needed) AND on the
	# render clock (_render_sub_pcm, ~8x/sec) so casts that are never ended —
	# notably the fire-and-forget SfxRouter.audition game-event SFX — still drain
	# during lulls and after combat ends instead of sticking (#121).
	var dead: Array = []
	for token in _sessions:
		var s = _sessions[token]
		var p = s["play"]
		var u = s["unit"]
		if p == null or u == null:
			_stat_reap_skip_undispatched += 1
			continue  # never dispatched — its orphan/end path owns cleanup
		# A ONE-SHOT cast (play_one_shot) has declared it will never dispatch
		# another pair and will never be ended, so the whole reason for the long
		# grace — "it may still have more pairs coming" — does not apply to it.
		# Charging it the full 2 s is what made a repeated game-event blip hold a
		# whole SPU unit long after it went silent and saturate the 8-unit pool.
		var one_shot := bool(s.get("one_shot", false))
		var grace: int = ONE_SHOT_REAP_GRACE_SUBS if one_shot else REAP_GRACE_SUBS
		var idle: int = _abs_sub - int(s["last_sub"])
		if idle < grace:
			_stat_reap_skip_grace += 1
			continue  # recently active — may still dispatch more pairs
		if _unit_voice_count(u) > 0:
			# This is a per-UNIT question asked of a per-SESSION decision: any one
			# audible cast on the unit vetoes reaping every other session bound to
			# it. For a ONE-SHOT cast on the packed reserved event lane that is
			# permanently true, which is what let 240 drained sessions accumulate
			# (R28/F42). ONE_SHOT_SILENCE_SUBS is the narrow way past it — see that
			# constant for why it is safe and why it is one-shot-only. Every other
			# cast keeps the veto unconditionally.
			if not (one_shot and idle >= ONE_SHOT_SILENCE_SUBS):
				_stat_reap_skip_voices += 1
				continue  # still audible
			_stat_reap_silence_freed += 1
		if not p.is_sequencing_done():
			_stat_reap_skip_seq += 1
			continue  # still sequencing
		dead.append(token)
	for token in dead:
		_end_effect_locked(token)


func _load_bank_cached(feds_path: String) -> _FedsBank:
	## Cache parsed FedsBanks by path for the retriggered click path so a per-glyph
	## blip doesn't reopen+reparse the .feds file every call (FedsBank.load_from_file
	## has no cache of its own). Only play_click uses this; audition/begin_bg keep
	## their per-call load — they're parity/one-shot paths, not per-glyph rates.
	var fb = _bank_cache.get(feds_path)
	if fb == null:
		fb = _FedsBank.load_from_file(feds_path)
		if fb != null:
			_bank_cache[feds_path] = fb
	return fb


func play_click(feds_path: String, pair_idx: int, sound_id: int = -1) -> int:
	## Lightweight per-glyph dialogue "Text Typing" blip. Unlike audition() this
	## (a) caches the FedsBank (no per-glyph disk reload), (b) plays on the single
	## RESERVED click unit outside the transient/ambient pools, and (c) RETRIGGERS
	## — each blip keys-off + frees the previous one (release tail) before firing —
	## so a fast type-out is one cut-and-retrigger voice, not a burst of
	## fire-and-forget casts saturating the combat SFX pool. Mirrors the PSX
	## typewriter (one channel, retriggered per glyph). Returns the cast token
	## (0 on miss).
	if not ready_ok:
		return 0
	var fb = _load_bank_cached(feds_path)
	if fb == null or pair_idx < 0 or pair_idx >= fb.num_pairs:
		push_warning("ExMateriaEffectSfx: cannot play_click %s pair %d" % [feds_path, pair_idx])
		return 0
	_audio_mutex.lock()
	# Retrigger de-click seam-carry (Option 1). Capture the OUTGOING click pair's
	# SPU voices while they are still live, then — after the new blip re-binds the
	# same slot — arm each voice's de-click ramp from its own last output. The tear
	# down KOFFs those voices; when their ADSR reaches STOPPED the mixer's off-gate
	# would drop their contribution to zero in one sample (the ~2-sub-spacing pop),
	# so the native mix loop instead bleeds this armed residual out to zero across
	# the fade window (fft_emit_voice_declick_tail). The plain on-gated de-click at
	# key-on can't cover this because the retriggered voice is already STOPPED by the
	# time it re-keys. We hold the mutex across end+rebind+carry and the producer
	# renders under the same mutex, so the outgoing voices' last_out stays frozen at
	# their true residual until we read it. No-op unless the click mixer's fade is
	# enabled (parity-neutral). See Spu.carry_voice_declick.
	var old_click_voices: Array = _click_pair_voices_locked(_click_token)
	# Retrigger: key-off + free the previous click before firing the next. The
	# token is monotonic so a reaped/stale _click_token just no-ops in _end.
	if _click_token != 0:
		_end_effect_locked(_click_token)
		_click_token = 0
	var token := _begin_effect_locked()
	_sessions[token]["is_click"] = true   # route the first-pair bind to the click unit
	if _play_pair_locked(token, fb, pair_idx, sound_id):
		_click_token = token
		if not old_click_voices.is_empty() and not _click_units.is_empty():
			var new_click_voices: Array = _click_pair_voices_locked(token)
			if not new_click_voices.is_empty():
				var mixer: _Spu = _click_units[0]["mixer"]
				for i in range(mini(old_click_voices.size(), new_click_voices.size())):
					_arm_writes(_click_units[0])
					mixer.carry_voice_declick(int(old_click_voices[i]), int(new_click_voices[i]))
	else:
		_end_effect_locked(token)
		token = 0
	_audio_mutex.unlock()
	return token


func _click_pair_voices_locked(token: int) -> Array:
	## The two SPU voice indices [base+slot, base+slot+1] the click cast `token`
	## currently occupies on the reserved click mixer, or [] if it isn't bound to a
	## pair yet. Caller must hold _audio_mutex. Used by play_click's seam-carry.
	if token == 0:
		return []
	var s = _sessions.get(token)
	if s == null:
		return []
	var u = s.get("unit")
	var slot := int(s.get("last_slot_idx", -1))
	if u == null or slot < 0:
		return []
	var base := int(u["pool"].voice_for_slot(slot))
	return [base, base + 1]


func play_one_shot(feds_path: String, pair_idx: int, sound_id: int = -1) -> int:
	## FIRE-AND-FORGET game-event SFX (the SfxRouter path): play one pair and never
	## come back for it. Identical dispatch to audition(), but the session is MARKED
	## one-shot, which is a promise the caller makes and the reaper relies on — no
	## further pairs, no end_effect/orphan_effect — so _reap_dead_sessions can
	## reclaim the unit as soon as the cast is provably silent instead of holding it
	## for the full multi-pair grace.
	##
	## Why this is a separate entry and not a flag on audition(): audition()'s other
	## callers (SfxBankTestScene, FEDSTestScene) DO keep their token and end it, so
	## the promise is not true of that path. Making the lifecycle contract the name
	## of the function keeps a caller from getting the wrong one by default — same
	## reason play_click and begin_bg are their own entries.
	return _audition_impl(feds_path, pair_idx, sound_id, true)


func audition(feds_path: String, pair_idx: int, sound_id: int = -1) -> int:
	## Audition for the test scenes, whose caller KEEPS the token and ends it
	## (SfxBankTestScene / FEDSTestScene hold a sound and stop it). Game-event SFX
	## that never come back for their token want play_one_shot instead.
	## sound_id < 0 = default chan+0x92.
	return _audition_impl(feds_path, pair_idx, sound_id, false)


func _audition_impl(feds_path: String, pair_idx: int, sound_id: int, one_shot: bool) -> int:
	if not ready_ok:
		return 0
	# The three timers W11 turns on. See the _stat_aud_* block for why each bucket
	# names a different fix. t0->t1 is the parse, t1->t2 is the WAIT for the mutex
	# (nothing of ours runs in it), t2->t3 is our work under the lock.
	var _t0 := Time.get_ticks_usec()
	var fb = _FedsBank.load_from_file(feds_path)
	var _t1 := Time.get_ticks_usec()
	_stat_aud_load_us += _t1 - _t0
	if fb == null or pair_idx < 0 or pair_idx >= fb.num_pairs:
		_stat_aud_miss += 1
		push_warning("ExMateriaEffectSfx: cannot audition %s pair %d" % [feds_path, pair_idx])
		return 0
	_audio_mutex.lock()
	var _t2 := Time.get_ticks_usec()
	var token := _begin_effect_locked()
	_sessions[token]["one_shot"] = one_shot
	if not _play_pair_locked(token, fb, pair_idx, sound_id):
		_end_effect_locked(token)
		token = 0
	_audio_mutex.unlock()
	var _t3 := Time.get_ticks_usec()
	_stat_aud_n += 1
	_stat_aud_lock_us += _t2 - _t1
	_stat_aud_disp_us += _t3 - _t2
	return token


func audition_bank(feds_bank, pair_idx: int, sound_id: int = -1) -> int:
	## Audible one-shot audition of an ALREADY-PARSED bank (not a file). Mirrors
	## audition() but plays the given FedsBank object — used to hear a TRANSIENT bank
	## (e.g. the no-op-pruned pair, ADR-0085 amendment) without writing it to disk. The
	## caller must have capture_mode = false (this plays through the real producer).
	if not ready_ok or feds_bank == null:
		return 0
	if pair_idx < 0 or pair_idx >= feds_bank.num_pairs:
		push_warning("ExMateriaEffectSfx: cannot audition_bank pair %d" % pair_idx)
		return 0
	_audio_mutex.lock()
	var token := _begin_effect_locked()
	if not _play_pair_locked(token, feds_bank, pair_idx, sound_id):
		_end_effect_locked(token)
		token = 0
	_audio_mutex.unlock()
	return token


## --- Note-chip AUDITION CONSOLE (ADR-0085 2026-08-13, hold-to-play) -----------
##
## A managed, reliable single-note preview for the Effect Studio's note chip. The
## naive "poke ExMateriaAudioEngine.sfx_spu.key_on directly" approach is UNRELIABLE: (a) it
## races the producer thread (both must serialize on _audio_mutex), and (b) unit 0
## idles out of _unit_active when it has no session, so the producer stops ticking
## the SPU and the preview is silent after the first play. This routes the poke
## through a RESERVED unit kept force-active while sounding, under the mutex.

## Hold-to-play a single note: key it on and hold until audition_note_off(). Real
## pitch/adsr from the caller (the studio resolves them from the waveset instrument).
## tail<0 → a normal key_on (attack + sustain, hear the loop by holding); tail>=0 →
## key_on_with_addresses from (start_addr, loop_addr) to start AT the loop point (the
## pure ring, skipping the attack). Voices rotate so a fast re-press hits a fresh one.
func audition_note_on(instrument_idx: int, pitch: int, adsr1: int, adsr2: int,
		start_addr: int = -1, loop_addr: int = -1) -> void:
	if not ready_ok:
		return
	_audio_mutex.lock()
	if _audition_unit.is_empty():
		var m := _Spu.new()
		if not m.load_instruments(_audio_engine().waveset.descriptors(), _audio_engine().waveset.adpcm_data):
			_audio_mutex.unlock()
			push_warning("ExMateriaEffectSfx: audition unit instrument load failed")
			return
		m.reset()
		_audition_unit = _make_unit(m, _Pool.new(24, 0, 24))
	var mixer: _Spu = _audition_unit["mixer"]
	# A hold-to-play press is a main-thread poke, outside the scheduler's per-sub
	# stamping, so it has to carry its own frame — the unit's NEXT sub, which is
	# where the scheduler left the counter and is still ahead of the audio clock.
	_arm_writes(_audition_unit)
	# The audition unit may have been parked; keying it while idle would render
	# silence over the note. session_count below re-activates it for the scheduler,
	# but the flag has to lift now so the very first block mixes.
	if bool(_audition_unit.get("streaming", false)):
		mixer.set_stream_idle(false)
	# Only one preview sounds at a time: silence both pool voices, then key the next.
	for v in _AUDITION_VOICES:
		mixer.key_off(v)
	var voice: int = _AUDITION_VOICES[_audition_voice_i]
	_audition_voice_i = (_audition_voice_i + 1) % _AUDITION_VOICES.size()
	if start_addr >= 0:
		mixer.key_on_with_addresses(voice, instrument_idx, pitch, _AUDITION_VOL, _AUDITION_VOL,
				adsr1, adsr2, start_addr, loop_addr, false)
	else:
		mixer.key_on(voice, instrument_idx, pitch, _AUDITION_VOL, _AUDITION_VOL, adsr1, adsr2, false)
	# Force the unit ACTIVE so the producer keeps ticking its SPU while the note holds
	# (a real session_count the _unit_active gate honours — the fix for "silent after one").
	_audition_unit["session_count"] = 1
	_audition_unit["last_active_sub"] = _abs_sub
	_audio_mutex.unlock()


## Release the held audition (key-off → ADSR release fade). Drops the forced-active
## session but stamps last_active_sub so the idle tail lets the release ring out, then
## the producer idles the unit naturally.
func audition_note_off() -> void:
	if not ready_ok:
		return
	_audio_mutex.lock()
	if not _audition_unit.is_empty():
		var mixer: _Spu = _audition_unit["mixer"]
		_arm_writes(_audition_unit)
		for v in _AUDITION_VOICES:
			mixer.key_off(v)
		_audition_unit["session_count"] = 0
		_audition_unit["last_active_sub"] = _abs_sub
	_audio_mutex.unlock()


## --- The polyphonic keyboard (exmateria-etude) --------------------------------
##
## Same reserved unit, same mutex discipline, same force-active bookkeeping as
## the audition pair above — and voices 0..21, which that pair never touches. A
## consumer holding keys down and a consumer previewing a note are two different
## applications of one SPU, so nothing here reads or writes _AUDITION_VOICES.
##
## Sharing the unit means sharing `session_count`. This half writes the number of
## keys held; the audition half writes 1 or 0. Interleaving the two (an audition
## released while keys are down) would idle the unit out from under the held
## notes after the tail. No consumer does both, and the alternative — a second
## reserved unit — costs a whole SPU render to fix a case that does not arise.


## Map a MIDI velocity onto an SPU voice volume. Linear in amplitude, because the
## SPU's volume register IS an amplitude; whether a perceptual curve belongs here
## is a question about how hard the gate grades dynamics, and that is the
## rubric's business, not the voice's.
static func velocity_to_volume(velocity: int) -> int:
	return clampi(velocity, 0, 127) * MAX_VOICE_VOL / 127


## Sound a key and hold it until note_off(key). Polyphonic: every held key keeps
## its own voice, so releasing one leaves the rest ringing.
func note_on(key: int, instrument_idx: int, pitch: int, velocity: int,
		adsr1: int, adsr2: int) -> void:
	if not ready_ok:
		return
	_audio_mutex.lock()
	if _audition_unit.is_empty():
		_audio_mutex.unlock()
		return
	var mixer: _Spu = _audition_unit["mixer"]
	# A keypress is a main-thread poke, outside the scheduler's per-sub stamping,
	# so it has to carry its own frame — the unit's NEXT sub, which is where the
	# scheduler left the counter and is still ahead of the audio clock.
	_arm_writes(_audition_unit)
	# The unit may have been parked; keying it while idle would render silence
	# over the note. session_count below re-activates it for the scheduler, but
	# the flag has to lift now so the very first block mixes.
	if bool(_audition_unit.get("streaming", false)):
		mixer.set_stream_idle(false)
	var voice := _claim_note_voice(key)
	var vol := velocity_to_volume(velocity)
	mixer.key_on(voice, instrument_idx, pitch, vol, vol, adsr1, adsr2, false)
	# Force the unit ACTIVE so the producer keeps ticking its SPU while keys are
	# held (a real session_count the _unit_active gate honours).
	_audition_unit["session_count"] = _note_voices.size()
	_audition_unit["last_active_sub"] = _abs_sub
	_audio_mutex.unlock()


## Release one key (key-off → ADSR release fade), leaving every other held key
## sounding. Releases THAT key's voice, not the pool: without the key -> voice
## map a trill's overlapping note-offs cut the note that just started.
func note_off(key: int) -> void:
	if not ready_ok:
		return
	_audio_mutex.lock()
	_release_note_locked(key)
	_audio_mutex.unlock()


## Release every held key at once — scene teardown, a break's rewind, or a panic.
func all_notes_off() -> void:
	if not ready_ok:
		return
	_audio_mutex.lock()
	for key in _note_voices.keys():
		_release_note_locked(key)
	_audio_mutex.unlock()


## The voice a key is currently sounding on, or -1 if it is not down.
func note_voice(key: int) -> int:
	return int(_note_voices.get(key, -1))


## How many keys are down. The chord the gate is looking at is this wide.
func held_note_count() -> int:
	return _note_voices.size()


func _release_note_locked(key: int) -> void:
	if not _note_voices.has(key):
		return
	var voice := int(_note_voices[key])
	_note_voices.erase(key)
	_note_order.erase(key)
	if not _audition_unit.is_empty():
		var mixer: _Spu = _audition_unit["mixer"]
		_arm_writes(_audition_unit)
		mixer.key_off(voice)
		# Drop the forced-active session but stamp last_active_sub, so the idle
		# tail lets the release ring out and the producer idles the unit naturally.
		_audition_unit["session_count"] = _note_voices.size()
		_audition_unit["last_active_sub"] = _abs_sub


## Which voice this key should sound on. Called with the mutex held.
func _claim_note_voice(key: int) -> int:
	if _note_voices.has(key):
		# A re-press of a key already down (a keyboard that re-sends, or a trill
		# whose note-off has not arrived yet) retriggers its own voice rather than
		# leaking a second one that nothing will ever key off.
		_note_order.erase(key)
		_note_order.append(key)
		return int(_note_voices[key])
	var used := {}
	for v in _note_voices.values():
		used[v] = true
	for v in range(NOTE_VOICE_COUNT):
		if not used.has(v):
			_note_voices[key] = v
			_note_order.append(key)
			return v
	# Every voice is held. Steal the oldest press: a key that goes down and makes
	# no noise is the one failure an instrument may not have. The audition pair is
	# never a candidate — it is outside range(NOTE_VOICE_COUNT).
	var oldest: int = _note_order[0]
	var voice := int(_note_voices[oldest])
	_note_order.remove_at(0)
	_note_voices.erase(oldest)
	_note_voices[key] = voice
	_note_order.append(key)
	return voice


## --- Background-sound ({6B} BG Sound) channel ---------------------------------
##
## A bg cast is an ordinary FEDS-pair cast that (a) is tagged so it is never
## auto-reaped (looping ambients hold voices indefinitely; one-shots reap
## normally once their voices die), and (b) records its pool slot so the {6B}
## volume ramp can drive its SPU voices via set_voice_volume_lr — the exact
## mirror of the PSX driver's per-voice set-volume (FUN_80012b6c: vol<<8 into each
## matching voice). Returns a handle (token) for set_bg_gain/stop_bg.
func begin_bg(feds_path: String, pair_idx: int, sound_id: int) -> int:
	if not ready_ok:
		return 0
	var fb = _FedsBank.load_from_file(feds_path)
	if fb == null or pair_idx < 0 or pair_idx >= fb.num_pairs:
		push_warning("ExMateriaEffectSfx: cannot begin_bg %s pair %d" % [feds_path, pair_idx])
		return 0
	_audio_mutex.lock()
	var token := _begin_effect_locked()
	# Tag BEFORE dispatch so first-pair binding routes to a reserved ambient unit.
	_sessions[token]["is_bg"] = true
	if not _play_pair_locked(token, fb, pair_idx, sound_id):
		_end_effect_locked(token)
		token = 0
	_audio_mutex.unlock()
	return token


## Set the current volume (0..127, PSX byte scale) of a bg cast's voices —
## `vol<<8` into each voice's L/R, matching FUN_80012b6c. vol 0 keys the voices
## off (silence). No-op if the token is dead or never dispatched.
func set_bg_gain(token: int, vol_byte: int) -> void:
	if not ready_ok:
		return
	_audio_mutex.lock()
	var s = _sessions.get(token)
	if s != null and s["unit"] != null:
		var u = s["unit"]
		var pool = u["pool"]
		var mixer: _Spu = u["mixer"]
		var slot_idx := int(s.get("last_slot_idx", -1))
		if slot_idx >= 0:
			_arm_writes(u)
			var v := clampi(vol_byte, 0, 127) << 8
			# Stereo pair occupies slots [slot_idx, slot_idx+1] → two voices.
			mixer.set_voice_volume_lr(pool.voice_for_slot(slot_idx), v, v)
			mixer.set_voice_volume_lr(pool.voice_for_slot(slot_idx + 1), v, v)
	_audio_mutex.unlock()


## Stop a bg cast (key-off ring-out, per-handle — mirrors FUN_800440f4).
func stop_bg(token: int) -> void:
	end_effect(token)


## Ambient sub-level trim (0..1). Debug knob; 1.0 = no trim (default). Seats a
## persistent bed UNDER combat SFX.
##
## It used to scale the bed's int32 PCM before a second hand-rolled limiter. It is
## now the ambient players' volume_db — the same knob doing the same job as a
## LEVEL rather than as limiting, which is what the trim always actually was. Set
## on the players, not on the Ambient bus, so it still works in a host that
## declares no bus layout at all. The {6B} per-voice ramp applies on top.
func set_bg_level(level: float) -> void:
	if not ready_ok:
		_bg_level = clampf(level, 0.0, 1.0)
		return
	_audio_mutex.lock()
	_bg_level = clampf(level, 0.0, 1.0)
	var db := _bg_level_db()
	for u in _bg_units:
		var player: AudioStreamPlayer = u["player"]
		if player != null:
			player.volume_db = db
	_audio_mutex.unlock()


func get_bg_level() -> float:
	return _bg_level


func stop_all() -> void:
	"""End every cast on every unit (ring-out)."""
	if not ready_ok:
		return
	_audio_mutex.lock()
	_stop_all_locked()
	_audio_mutex.unlock()


func _stop_all_locked() -> void:
	for token in _sessions.keys():
		var session = _sessions[token]
		var p = session["play"]
		var u = session["unit"]
		if p != null:
			if u != null:
				_arm_writes(u)
			p.release_and_free()
		if u != null and session["entity"] != null:
			session["entity"].is_done = true
			u["list"].unlink(session["entity"])
	_sessions.clear()
	_click_token = 0
	for u in _units:
		u["session_count"] = 0
	for u in _bg_units:
		u["session_count"] = 0
	for u in _click_units:
		u["session_count"] = 0
	for u in _event_units:
		u["session_count"] = 0


func panic() -> void:
	"""Hard reset to silence: end all casts AND clear every unit's SPU voices/
	reverb. NOT used in the normal gameplay loop — scene transitions / tests only."""
	if not ready_ok:
		return
	_audio_mutex.lock()
	_stop_all_locked()
	# The reset below silences the keyboard's voices outright, so its key -> voice
	# map has to go with them: left behind, it would report keys as held that make
	# no sound and exhaust the pool on phantoms.
	_note_voices.clear()
	_note_order.clear()
	# reset() and set_irq_period_samples() are NOT queued register writes — they
	# mutate core_ directly, so they must not run while a _mix is in flight. The
	# audio lock is the mixer thread's own mutex; holding it is what makes this
	# safe. Each stream's clocks are rewound with it, so every unit re-arms with a
	# full lead rather than stamping into a timeline that no longer exists.
	AudioServer.lock()
	for unit in _all_units():
		var m: _Spu = unit["mixer"]
		m.reset()
		m.set_irq_period_samples(512)
		if bool(unit.get("streaming", false)):
			m.clear_deferred_commands()
			m.set_stream_idle(true)
			unit["sched_frame"] = SCHED_LEAD_FRAMES
	AudioServer.unlock()
	_abs_sub = 0
	# The 183/184 drift phase is part of the hard reset too: leaving it made an
	# offline capture's tail frame depend on how many subs had EVER rendered
	# before it (a ±1-frame ghost-length wobble between otherwise identical renders).
	_sample_acc = 0
	_audio_mutex.unlock()


## Render `n` whole IRQ sub-ticks, summed across active units, as interleaved
## stereo PCM16. Shared by live playback (producer thread) and the offline
## capture rig. Both paths lock the audio mutex — tests typically set
## capture_mode=true first to park the producer.
func render_subs(n: int) -> PackedInt32Array:
	## OFFLINE CAPTURE ONLY. Render `n` whole IRQ sub-ticks, summed across active
	## units, as interleaved stereo PCM16.
	##
	## This is no longer the live path — live audio renders per unit on the audio
	## thread (see _attach_stream). `D3` dec. 5 says the cross-unit sum is "deleted,
	## not ported", and in the LIVE path it is: Godot's bus mixer does it in float.
	## But the studio's deterministic renderers (SoundRenderQueue, SoundGhostProjector,
	## EffectSoundCaptureTest) pull PCM with no audio device and no bus to sum on, so
	## the sum survives HERE, explicitly marked as the offline half. Callers set
	## capture_mode = true first, which parks the scheduler.
	var out := PackedInt32Array()
	if not ready_ok:
		return out
	_audio_mutex.lock()
	for _i in range(n):
		out.append_array(_render_sub_pcm())
	_audio_mutex.unlock()
	return out


func _render_sub_pcm() -> PackedInt32Array:
	# Combined int32 sum (transient SFX + ambient beds) — the offline capture path.
	# Unchanged from before the stream move, deliberately: the capture tests compare
	# against goldens rendered by exactly this arithmetic.
	var split := _render_sub_split()
	return _sum_pcm(split["sfx"], split["bg"])


func _render_sub_split() -> Dictionary:
	# OFFLINE. Render one global 183/184-sample IRQ, returning the transient-SFX sum
	# and the ambient-bed sum as separate int32 streams. Advances the shared IRQ
	# clock once.
	var n := _advance_sub_locked()
	var sfx := _render_unit_group(_units, n)
	sfx = _sum_pcm(sfx, _render_unit_group(_click_units, n))
	sfx = _sum_pcm(sfx, _render_unit_group(_event_units, n))
	if not _audition_unit.is_empty():
		sfx = _sum_pcm(sfx, _render_unit_group([_audition_unit], n))
	var bg := _render_unit_group(_bg_units, n)
	_abs_sub += 1
	if sfx.is_empty():
		sfx.resize(n * 2)  # silence (shouldn't happen — unit 0 is always active)
	return {"sfx": sfx, "bg": bg, "n": n}


func _advance_sub_locked() -> int:
	# The IRQ clock both paths share: run the reapers on the render clock (~8x/sec)
	# and return this sub's sample count. Caller advances _abs_sub after using it.
	#
	# Two reapers, and they run here rather than only at bind time:
	#   - _reap_orphans: casts whose visual ended (orphan_sub set) and whose sound
	#     has now finished (or hit ORPHAN_MAX_SUBS).
	#   - _reap_dead_sessions: casts that are provably over (dispatched, idle past
	#     grace, no voices, sequence done) but were NEVER ended/orphaned. The
	#     fire-and-forget game-event SFX path (SfxRouter.audition) opens casts it
	#     never ends, and a missed EffectInstance orphan lands here too. Running this
	#     on the clock means they drain during lulls and after combat ends instead of
	#     sticking until the next cast arrives — so sessions return to ~0 when the
	#     battle goes quiet (#121).
	if _abs_sub % 30 == 0 and not _sessions.is_empty():
		var _tr0 := Time.get_ticks_usec()
		var _before := _sessions.size()
		_reap_orphans()
		_reap_dead_sessions()
		_stat_sched_reaps += 1
		_stat_sched_reap_us += Time.get_ticks_usec() - _tr0
		# Both reapers walk EVERY session, so one pass is 2N iterations.
		_stat_sched_walked += 2 * _before
		_stat_sched_killed += _before - _sessions.size()
	var n := _RuntimeC.SAMPLES_PER_IRQ_BASE
	_sample_acc += _RuntimeC.SAMPLES_PER_IRQ_REM
	if _sample_acc >= _RuntimeC.IRQ_HZ:
		n += 1
		_sample_acc -= _RuntimeC.IRQ_HZ
	return n


func _schedule_sub_locked() -> void:
	## LIVE. Advance the IRQ clock by one sub and STAMP each active unit's register
	## writes at the frame that sub begins on. Renders nothing — the audio thread
	## does that, inside each unit's stream.
	##
	## The sequencer runtime is untouched: it ticks in the same order and writes the
	## same registers it always did. All that changed is that a write is stamped and
	## queued instead of applied, and the samples between two writes are rendered by
	## the audio thread rather than by this one. That is what keeps a streamed render
	## bit-identical to a lockstep one (#385 task 4's Gate E guard).
	var n := _advance_sub_locked()
	_stamp_unit_group(_units, n)
	_stamp_unit_group(_click_units, n)
	_stamp_unit_group(_event_units, n)
	if not _audition_unit.is_empty():
		_stamp_unit_group([_audition_unit], n)
	_stamp_unit_group(_bg_units, n)
	_abs_sub += 1


func _stamp_unit_group(units: Array, n: int) -> void:
	# Tick the active units of one group, stamping their writes at this sub's frame,
	# and park the idle ones. Every unit's schedule frame advances whether or not it
	# ticked: an idle stream's audio clock keeps running too, so the two stay in step
	# and a unit that wakes is already at the right lead.
	for i in range(units.size()):
		var unit = units[i]
		var mixer: _Spu = unit["mixer"]
		var active := _unit_active(unit, i)
		if active:
			_stat_sched_entities += int(unit["list"].size())
			mixer.set_schedule_frame(int(unit["sched_frame"]))
			unit["rt"].tick_irq_start(_abs_sub)
			unit["rt"].tick(_abs_sub)
		if bool(unit.get("streaming", false)):
			# The idle claim is re-asserted every sub rather than only on the edge:
			# it is one relaxed atomic store, and making it edge-triggered would mean
			# tracking a previous-state flag that panic()/re-arm could desync.
			mixer.set_stream_idle(not active)
		unit["sched_frame"] = int(unit["sched_frame"]) + n


func _render_unit_group(units: Array, n: int) -> PackedInt32Array:
	# Sum the active units of one group into interleaved int32 PCM. Returns an EMPTY
	# array when no unit in the group is active (the ambient group is usually empty
	# — no bed playing — so the producer skips its limiter entirely).
	var mixed := PackedInt32Array()
	var have_mix := false
	for i in range(units.size()):
		var unit = units[i]
		if not _unit_active(unit, i):
			continue
		unit["rt"].tick_irq_start(_abs_sub)
		unit["rt"].tick(_abs_sub)
		var pcm: PackedInt32Array = unit["mixer"].render_interleaved_pcm16(n)
		if not have_mix:
			mixed = pcm
			have_mix = true
		else:
			var m := mini(mixed.size(), pcm.size())
			for s in range(m):
				mixed[s] += pcm[s]
	return mixed


func _sum_pcm(a: PackedInt32Array, b: PackedInt32Array) -> PackedInt32Array:
	# Sample-wise int32 sum of two interleaved PCM streams (either may be empty).
	if b.is_empty():
		return a
	if a.is_empty():
		return b
	var out := a.duplicate()
	var m := mini(out.size(), b.size())
	for s in range(m):
		out[s] += b[s]
	return out


func _unit_active(unit: Dictionary, _index: int) -> bool:
	# All units (including the base unit at index 0) follow the same gate:
	# active while a session is live, plus UNIT_IDLE_TAIL_SUBS more sub-ticks
	# so reverb/release tails decay naturally. When unit 0 falls past the tail,
	# the per-sub silence-fast-path in _render_sub_pcm fills the buffer with
	# zeros without touching the C++ SPU — kills ~5ms/frame of post-combat /
	# between-cast CPU that used to be the base unit's continuous tick.
	if int(unit["session_count"]) > 0:
		return true
	return (_abs_sub - int(unit["last_active_sub"])) < UNIT_IDLE_TAIL_SUBS


func _process(_delta: float) -> void:
	# Nothing to do here on the audio path. The scheduler thread stamps writes and
	# each unit's stream renders them on the audio thread, so the main thread has
	# neither a drain nor a refill to run — which is the point: the old hand-off
	# coupled device refill to the game-loop frame cadence and starved on any
	# >16 ms hitch (#123). All that is left is the optional live console monitor.
	if not ready_ok or capture_mode or not _live:
		return
	if audio_monitor_enabled:
		_monitor_tick(_delta)


func _monitor_tick(delta: float) -> void:
	## Live per-second audio diagnostics for the accumulation hunt. Prints current
	## STATE (units/voices/sessions — watch these climb if something leaks) and
	## cumulative event counts (preempts/cap_doublings/underruns), plus the true
	## final-mix peak/clip from a Master-bus tap.
	if _mon_cap == null:
		_mon_cap = AudioEffectCapture.new()
		AudioServer.add_bus_effect(0, _mon_cap)   # bus 0 = Master
	_mon_t += delta
	var navail := _mon_cap.get_frames_available()
	if navail > 0:
		var buf: PackedVector2Array = _mon_cap.get_buffer(navail)
		for fr in buf:
			var a := maxf(absf(fr.x), absf(fr.y))
			_mon_master_peak = maxf(_mon_master_peak, a)
			if a >= 0.999:
				_mon_master_clip += 1
	if _mon_t - _mon_last < 1.0:
		return
	_mon_last = _mon_t
	var s: Dictionary = debug_snapshot()
	var sc: Dictionary = s.get("scheduler", {})
	var rail: Dictionary = s.get("rail", {})
	print("[audiomon %5.0fs] units=%d voices=%d sessions=%d | preempts=%d cap_dbl=%d | sched lead=%.1fms late=%d dropped=%d streams=%d | rail peak=%.2f | master peak=%.2f clip/s=%d"
		% [_mon_t, s.get("units", []).size(), s.get("total_voices", 0), s.get("sessions", 0),
			s.get("preempts", 0), s.get("cap_doublings", 0),
			sc.get("lead_ms", 0.0), sc.get("late", 0), sc.get("dropped", 0), sc.get("streams", 0),
			rail.get("pre_clamp_peak", 0.0),
			_mon_master_peak, _mon_master_clip])
	_mon_master_peak = 0.0
	_mon_master_clip = 0



func _scheduler_main() -> void:
	## Keep every unit's register writes stamped SCHED_LEAD_FRAMES ahead of the
	## audio clock, one IRQ sub at a time. This is the whole live path now: no
	## render, no sum, no limiter, no ring buffer. Unit 0's stream is the reference
	## clock — see _behind_locked.
	##
	## FAIRNESS IS THE SHAPE OF THIS LOOP. Every iteration takes the mutex ONCE,
	## stamps at most SCHED_CATCHUP_MAX_SUBS subs, releases, and then ALWAYS
	## yields before trying again. The unconditional yield is the point, not an
	## idle optimisation: this loop used to re-acquire immediately whenever it was
	## `behind`, and a thread that unlocks and instantly re-locks beats a waiter
	## the kernel has only just woken. glibc mutexes are not FIFO, so that is a
	## barge and it can repeat indefinitely. Measured in GPUArena under a burst of
	## game-event SFX, a main-thread SfxRouter cast waited 3591 ms on
	## _audio_mutex.lock() inside one continuous `behind` streak, and the frame
	## went with it. Releasing and yielding bounds that wait at about one batch
	## plus one yield.
	##
	## The two knobs trade against each other and both matter:
	##  - SCHED_CATCHUP_MAX_SUBS caps how long ONE hold can be. Raising it is
	##    directly a worse worst-case wait for the main thread — at 8 subs and a
	##    full transient pool the hold measured ~57 ms.
	##  - the yield is SCHED_YIELD_USEC (not SCHED_IDLE_MS) whenever this wake
	##    actually stamped, because a full millisecond per sub would cap catch-up
	##    near 1000 subs/s against a 240/s requirement — enough to hold the lead,
	##    with no margin to refill it after a hitch. When the lead is already full
	##    there is nothing to be prompt about, so it sleeps SCHED_IDLE_MS.
	##
	## None of this makes the loop affordable at any unit count: stamping cost
	## scales with the number of ACTIVE units, and past roughly half the transient
	## pool it exceeds its 4.16 ms per-sub real-time budget however fairly it is
	## scheduled. Keeping the unit count down is the reserved lanes' job
	## (_pick_event_unit, _pick_bg_unit, _ensure_click_unit), not this loop's.
	while true:
		_audio_mutex.lock()
		var _th0 := Time.get_ticks_usec()
		if _sched_exit:
			_audio_mutex.unlock()
			return
		var stamped_any := false
		if not capture_mode and _live and not _units.is_empty():
			var stamped := 0
			while stamped < SCHED_CATCHUP_MAX_SUBS and _behind_locked():
				_schedule_sub_locked()
				stamped += 1
			stamped_any = stamped > 0
			_stat_sched_subs += stamped
		_stat_sched_holds += 1
		_stat_sched_hold_us += Time.get_ticks_usec() - _th0
		_audio_mutex.unlock()
		# ALWAYS yield. Sleeping only when the lead was full is what allowed the
		# barge; a short sleep after a stamp costs nothing and bounds the wait.
		if stamped_any:
			OS.delay_usec(SCHED_YIELD_USEC)
		else:
			OS.delay_msec(SCHED_IDLE_MS)


func _behind_locked() -> bool:
	## Is unit 0's stamped lead short of SCHED_LEAD_FRAMES? Caller holds
	## _audio_mutex. Unit 0's stream is the reference clock: it always exists, its
	## player always plays, and an idle stream still advances its audio frame, so
	## this paces correctly whether or not anything is sounding. A unit 0 with no
	## stream (offline/capture instance) has no clock to pace on and is treated as
	## always behind, exactly as before — SCHED_CATCHUP_MAX_SUBS now bounds what
	## that can cost per wake.
	if _units.is_empty():
		return false
	var unit0 = _units[0]
	if not bool(unit0.get("streaming", false)):
		return true
	return (int(unit0["sched_frame"]) - int(unit0["mixer"].get_audio_frame())) < SCHED_LEAD_FRAMES


func _park_streams_locked(park: bool) -> void:
	## Hand every unit's SPU back from the audio thread (park) or give it back
	## (unpark), KEEPING the players — unlike _detach_units_locked, which frees
	## them for teardown. Caller holds _audio_mutex.
	##
	## Parking takes the audio lock for the same reason stopping a stream does:
	## AudioServer::stop_playback_stream marks the playback FADE_OUT_TO_DELETION
	## and it is mixed once more, so stop() alone does not mean the audio thread
	## has let go. The lock is the mixer thread's own mutex.
	if park:
		AudioServer.lock()
		for unit in _all_units():
			if not bool(unit.get("streaming", false)):
				continue
			unit["player"].stop()
			unit["mixer"].set_deferred_mode(false, 0)
			unit["streaming"] = false
		AudioServer.unlock()
		return
	for unit in _all_units():
		if bool(unit.get("streaming", false)):
			continue
		var player: AudioStreamPlayer = unit["player"]
		if player == null:
			# Spawned WHILE parked, so it never got a stream at all — _make_unit
			# skips _attach_stream in capture_mode. Attaching only the units that
			# already had a player leaves those permanently silent: the typewriter
			# capture rig runs its offline arm first, which spawns the reserved click
			# unit, and its live arm then recorded 0.000 FS over Master.
			_attach_stream(unit)
			continue
		var mixer: _Spu = unit["mixer"]
		mixer.set_deferred_mode(true, QUEUE_CAPACITY)   # rewinds both clocks
		mixer.set_stream_idle(true)
		unit["streaming"] = true
		unit["sched_frame"] = SCHED_LEAD_FRAMES
		player.play()


func _detach_units_locked(units: Array) -> void:
	## Take these units' SPUs back from the audio thread and free their players.
	## Caller holds _audio_mutex.
	##
	## stop() is not enough on its own: AudioServer::stop_playback_stream marks the
	## playback FADE_OUT_TO_DELETION and the mixer runs it once more, so the audio
	## thread can still be inside render_audio_frames after stop() returns. Taking
	## the audio lock — the mixer thread's own mutex — is what guarantees it is not.
	## The late fade-out block then finds deferred mode off and renders silence.
	AudioServer.lock()
	for unit in units:
		if not bool(unit.get("streaming", false)):
			continue
		var player: AudioStreamPlayer = unit["player"]
		player.stop()
		unit["mixer"].set_deferred_mode(false, 0)
		unit["streaming"] = false
		remove_child(player)
		player.queue_free()
		unit["player"] = null
		unit["stream"] = null
	AudioServer.unlock()
