## Per-music-entity state. Port of FFT's music entity struct at the head of
## the LIFO `DAT_80032A50`, allocated by FUN_80014278 with size
## `0x160 + 0xB0 * nchans` (so the per-channel pool sits at entity+0xB8 in
## the struct, stride 0xB0).
##
## FFT analogs (offsets are from the entity base):
##   +0x10  flag_word (bits 0x8000 active, 0x100 vol-ramp pending,
##                     0x4000 vol-instant, 0x2 SFX-mode marker)
##   +0x12  sequence_offset             (from SMD header byte 0x10)
##   +0x14  channel_count               (from SMD header byte 0x12 / 0x14)
##   +0x15  ppqn                        (from SMD header byte 0x13)
##   +0x16  nchans                      (from SMD header byte 0x14)
##   +0x18  voice_mask_base             (from SMD header byte 0x16)
##   +0x1A  initial_volume  (u16)       (header HALFWORD 0x18, read `lhu` at
##                                       0x80013728 -- not a byte; byte 0x19 is 0
##                                       in all 100 retail SMDs. Default 0x7F from
##                                       FUN_80013788. NOTHING in SCUS reads it --
##                                       it is not a loop point and not the master
##                                       volume; see +0x96 below and #619.)
##   +0x3A  subcounter_reload (u16)     (= 0x30 / ppqn; written by
##                                       FUN_800137D8; reloads +0x36
##                                       when subcounter wraps to 0)
##   +0x44..+0x50 are NOT master volume/pan. They are a libspu `SpuReverbAttr`,
##   filled by the header parser at 0x80013734-0x80013768 from four consecutive
##   header bytes and handed straight to FUN_80018140 (SetReverbAttr):
##     +0x44  reverb_mode     (s32)     (byte 0x1A, read SIGNED via `lb`; bounded
##                                       `slti < 0xA`, OR'd with 0x100 =
##                                       SPU_REV_MODE_CLEAR_WA; 4 in all 100
##                                       retail SMDs)
##     +0x48  reverb_depth    (u16)     (byte 0x1B << 8 -> DAT_8003704C ->
##                                       DAT_80037010/12 -> SPU 0x1F801D84/86,
##                                       the reverb OUTPUT volume L/R, with one
##                                       side conditionally negated by
##                                       FUN_8001848C per g_audio_enable_flags
##                                       bits 0x600/0x200)
##     +0x4C  reverb_delay    (u32)     (byte 0x1C; 0 in all 100 retail SMDs)
##     +0x50  reverb_feedback (u32)     (byte 0x1D; 0 in all 100 retail SMDs)
##   Opcode 0xB8 (FUN_8001608C, jumptable 0x80028BEC) rewrites the same three
##   fields mid-song and re-calls FUN_80018140 with mode = 0xA, which fails the
##   `< 0xA` bound and so leaves the preset alone.
##
##   The real master fields live much later in the struct, and the three setters
##   this docstring used to cite are theirs -- each is f(entity, level, fade) and
##   writes `level<<24` to a word whose HIGH halfword is the live value:
##     +0x96  master_vol_raw            (FUN_80012F08 -> +0x94; walker reads it
##                                       at 0x80017204)
##     +0xA2  master_transpose          (FUN_80013014 -> +0xA0; walker 0x80017348)
##     +0xAE  master_pan                (FUN_80013094 -> +0xAC; walker 0x80017218)
##   No SMD header byte reaches any of the three. See #619.
##   +0x74  sub_tick_acc    (s32)       (decremented per outer-IRQ tick;
##                                       when < 0 → fire body, += 0x10000)
##   +0x78  sub_tick_budget (s32)       (= tempo_byte * (entity+0x8a);
##                                       written by smd_tempo @ 0x80015CB0)
##   +0x7C  tempo_high      (u32)       (= tempo_byte << 16;
##                                       written by smd_tempo)
##   +0x8A  tick_rate_mul   (u16)       (multiplier consumed by smd_tempo;
##                                       implied = 0x100 from FFT init's
##                                       entity+0x78 = 0x6600 with
##                                       tempo_byte = 0x66 = 102. Writer
##                                       not yet identified in disasm —
##                                       likely a global init constant
##                                       rather than FUN_800137D8 output.)
##   +0xB8.. per-channel structs, stride 0xB0
##
## In Pass 6 this class is **shadow state**: Sequencer.load_trackset constructs
## one and populates the header / master fields, but Sequencer's own
## instance fields (tempo_bpm, samples_per_tick, master_vol, …) continue
## to drive behavior. Pass 7+ will migrate logic onto this object cluster-
## by-cluster.
##
## The per-channel pool isn't realised here yet — `channels` stays empty
## until the shared per-channel state (channel_state.gd / slot_state.gd)
## is wired in (Pass 7d/8). Music currently uses Sequencer.TrackState; the
## migration to ChannelState/SlotState happens during opcode-body adoption.

# ──────── Header fields ────────
var flag_word: int = 0
var sequence_offset: int = 0
var channel_count: int = 0
var ppqn: int = 0
var nchans: int = 0
var voice_mask_base: int = 0
# NOT entity+0x1A -- that is the header's initial_volume (see the map above).
# FFT's loop point is a per-CHANNEL field at chan+0x1C, set by opcode 0x91 and
# read by 0x90; TrackState carries the live one. This entity-level copy has no
# writer and no reader.
var loop_point: int = 0

# entity+0x00 — next-pointer in FFT's LL allocator (FUN_80014278 prepend
# semantic). Tracked as a u32 absolute PSX RAM address solely for
# debugging / diagnostic emission; SharedEntityList provides the actual
# Godot-side linkage.
var entity_addr: int = 0

# entity+0x32..0x38 — SMD playback-position counters maintained by FFT's
# per-entity advancer. Stored as shadow state when a secondary entity is
# seeded from a savestate (MUSIC_ITER30_SECOND_MUSIC_ENTITY_REFACTOR.md
# §1.2): the secondary may be deep into the SMD (pass=7, measure=3,
# subcounter=5 on observed MUSIC_34 captures) while the primary is at
# pass=1. Godot's renderer currently doesn't read these — TrackState
# carries event_idx + loop_stack as the Godot-side position — but
# storing the savestate values lets future passes wire byte-offset
# rebase onto the secondary's tracks without re-extracting the JSON.
var pass_counter: int = 0
var measure: int = 0
var subcounter: int = 0
var max_measure: int = 0
var wrap_reset: int = 0
var wrap_reset_input: int = 0
var post_cadence_flag: int = 0
var gate: int = 0

# True when this entity was constructed via from_seed_dict() from the
# secondary_entity JSON block — i.e. the orphan music entity discovered
# by sstate_entity_extract.extract_with_orphans. The primary entity is
# constructed by Sequencer.load_trackset from the SMD header and has this
# flag false.
var is_secondary: bool = false

# ──────── Master fields ────────
var master_vol_raw: int = 0x7F00       # FFT default seed via FUN_800137D8
var master_pan: int = 0
var master_reverb: int = 0
var master_4C: int = 0

# ──────── Tempo accumulators ────────
# Sequencer.tempo_bpm / samples_per_tick are the *Godot* representation;
# `sub_tick_*` mirror FFT's raw accumulator math. Both populated for now.
var sub_tick_acc: int = 0x10000
var sub_tick_budget: int = 0x6600        # = 0x6600 default per FUN_800137D8
var tempo_high: int = 0
# entity+0x8a — multiplier consumed by smd_tempo. Init default 0x100
# so that smd_tempo's `tempo_byte * tick_rate` write matches FFT's
# 0x6600 init when tempo_byte=0x66 (the default tempo). Subcounter-
# reload (0x30/ppqn) lives at entity+0x3a, not +0x8a.
var tick_rate: int = 0x100
# entity+0x3a — subcounter reload value used by spu_updater_tick at
# LAB_80014CEC. Reloads entity+0x36 each time the subcounter hits 0.
# = 0x30 / ppqn (so for music PPQ=48 → 1; for PPQ=24 → 2).
var subcounter_reload: int = 1

# ──────── Per-channel pool ────────
# Populated by Pass 7+ when ChannelState/SlotState consumes music-side
# tick state. Empty in Pass 6.
var channels: Array = []

# ──────── Pass 8 phase 4 — Runtime backref + track surface ────────
# Backref to the owning Sequencer (the music-side equivalent of
# play_sound.gd's _dispatchers reference). Variant-typed to avoid the
# Sequencer ↔ MusicEntityState preload cycle. Runtime.gd's catchup
# iter needs sequencer.master_vol + the AdvanceTrack reference for
# per-track bytecode advance.
var owning_sequencer = null

# Reference to Sequencer.tracks. Both fields point at the same Array;
# Runtime.gd iterates through `tracks` so it doesn't need a backref
# detour through owning_sequencer when only the track list matters.
var tracks: Array = []

# All-tracks-done gate. Updated by Runtime._run_music_entity_iter at
# the end of each catchup pass; Runtime uses this to skip dead
# entities during the per-entity loop.
var all_tracks_done: bool = false


## True when this entity's per-IRQ catchup body should run — mirrors
## the FFT bgez at PC 0x80014BC4 (`slot+0x10 < 0` ↔ active). The
## primary music entity has no Godot-side gate model (its FFT gate
## flips to negative when load_trackset starts playing), so it's
## unconditionally treated as active. A secondary entity (built via
## apply_seed_dict from a savestate) honors its captured `gate` field:
## value < 0 → active (catchup runs), value >= 0 → inactive (catchup
## skipped, mirroring PCSX's bgez branch-taken path).
##
## With this gate, the per_entity_iter probe fires for both entities
## (PCSX BP @ 0x80014BBC fires BEFORE the gate check), but
## per_entity_pass / per_channel_tick_entry / lfo_subslot probes fire
## only for active entities — closing the count over-fire when a
## secondary entity is registered but inactive in the savestate.
func is_active() -> bool:
	if not is_secondary:
		return true
	return gate < 0


func _gather_active_slots() -> Array:
	## Returns the active TrackState.ctx.slot list. Used by
	## Runtime.UnifiedSlotPool.active_slots() to feed flush_tick +
	## walker.
	var out: Array = []
	for ts in tracks:
		if ts == null or ts.ctx == null:
			continue
		if ts.done:
			continue
		if ts.voice_idx < 0:
			continue
		out.append(ts.ctx.slot)
	return out


## Apply a JSON seed dict from extract_music_entity_state.py's
## `secondary_entity` block onto an existing MusicEntityState. The
## seeder lives as an instance method (not a static factory) because
## GDScript 4 can't resolve the self class_name inside its own static
## bodies; callers `var ent = MusicEntityState.new(); ent.apply_seed_dict(...)`.
##
## Seeds the FFT-shadow fields (tempo accumulators, pass/measure/
## subcounter, channel_count, addr) but does NOT populate tracks[] /
## channels[] — that's caller-driven so the harness can decide track
## binding strategy. Callers must set `owning_sequencer`, `tracks`,
## and any per-channel state themselves before pushing the entity onto
## SharedEntityList.
func apply_seed_dict(seed: Dictionary) -> void:
	is_secondary = true
	entity_addr = int(seed.get("entity_addr", 0)) & 0xFFFFFFFF
	channel_count = int(seed.get("channel_count", 0))
	nchans = channel_count
	# Tempo cluster — same fields the primary-entity seeder writes in
	# render_music_wav.gd. Match the s32 / u32 / u16 widths used by
	# FFT (smd_tempo writes entity+0x78 as s32, entity+0x7c as u32,
	# entity+0x8a as u16).
	sub_tick_acc = int(seed.get("sub_tick_acc", sub_tick_acc))
	sub_tick_budget = int(seed.get("sub_tick_budget", sub_tick_budget))
	tempo_high = int(seed.get("tempo_high", tempo_high)) & 0xFFFFFFFF
	tick_rate = int(seed.get("tick_rate_mul", tick_rate)) & 0xFFFF
	# SMD playback-position cluster.
	pass_counter = int(seed.get("pass", 0))
	measure = int(seed.get("measure", 0))
	subcounter = int(seed.get("subcounter", 0))
	max_measure = int(seed.get("max_measure", 0))
	wrap_reset = int(seed.get("wrap_reset", 0))
	wrap_reset_input = int(seed.get("wrap_reset_input", 0))
	post_cadence_flag = int(seed.get("post_cadence_flag", 0))
	gate = int(seed.get("gate", 0))
	# all_tracks_done starts false so Runtime's catchup loop visits the
	# entity at least once per IRQ. If the harness binds an empty
	# tracks[], the post-iter "all done" sweep flips this to true on
	# the next tick, but the entity still walks (Runtime gates on
	# entity-done AFTER the catchup body, not before).
	all_tracks_done = false
