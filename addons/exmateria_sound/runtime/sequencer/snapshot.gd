extends RefCounted
## Reflective snapshot/restore for [Sequencer] — the seek primitive the package
## lacked, built for `exmateria-etude`'s break-and-rewind.
##
## Builds `docs/adr/0188-the-sequencer-learns-to-go-backwards.md` (accepted
## 2026-09-07, previously not built) — ticket #974.
##
## ADDITIVE. Nothing existing is edited beyond three new methods on `Sequencer`
## that delegate here; no field is renamed, no behaviour changes on a path that
## does not call `snapshot()`. `godot-learning` never calls it.
##
## ## Why reflective
##
## A hand-written field list over ~135 mutable fields per track — 69 on
## `ChannelState`, 66 on `SlotState`, plus `TrackState`'s and the sequencer's own,
## across a median 19 tracks — **fails silently**. Miss `octave` or
## `instrument_idx` and the rewound bar plays in the wrong register or the wrong
## timbre, subtly, with no error. `channel_state.gd` is mid-migration ("Pass 7.D",
## "Pass 8 phase 2"), so fields are actively being added. `get_property_list()`
## picks up a field added tomorrow today.
##
## ## What reflection cannot see, and the tripwire for it
##
## Reflection covers value-typed properties. An **Object**-typed property is a
## reference into another object's state, and following one blindly would walk
## into the SPU, the waveset and the score. So objects are handled by name, in one
## of two ways, and `coverage()` reports any property that is in neither list.
##
## `SequencerSnapshotDifferentialTest` asserts that report is EXACTLY the known
## set — which is the part that keeps this honest. The differential test alone
## catches a missed field only if some song exercises it; the coverage assertion
## catches a new object field the day it is declared, whether or not anything
## plays it.
##
##   CAPTURED (recursed into): `TrackState.ctx.channel`, `TrackState.ctx.slot`,
##     `Sequencer.music_entity`, `Sequencer._flush_tick`.
##   INERT (deliberately not captured), each for a stated reason:
##     `mixer` / `waveset` / `native_sequencer` — hardware and assets, not position.
##     `tracks` — walked explicitly, per track.
##     `_irq_walker`, `_music_slot_pool` — verified STATELESS: each holds only a
##       back-pointer to the pool/sequencer and a mixer handle (`spu_irq_walker.gd`
##       and `music_slot_pool.gd` declare no other fields), so there is nothing in
##       them to rewind.
##     `_runtime` — the alternate driver, unused on the GDScript music path.
##     `events` (on TrackState) — THE SCORE. Shared, never mutated; copying it per
##       bar would be the most expensive thing here and would buy nothing.
##     `debug_trace` / `spu_trace_order` / `debug_trace_enabled` — diagnostics.
##       Restoring them would rewind the very trace the differential test is
##       collecting, which would make the guard measure itself.
##     `disabled_opcodes` — a probe configuration, not a position in a song.
##
## ## Restore is IN PLACE
##
## Every captured object is written field-by-field back into the object that is
## already there; no object is ever replaced. That is what keeps
## `_flush_tick._pending_kon_dict` / `_deferred_kon_dict` correct — they hold
## `voice_idx -> SlotState` references into the live slots, and a restore that
## swapped SlotState instances would leave them pointing at orphans.

const _SS = preload("res://addons/exmateria_sound/runtime/shared/slot_state.gd")

## Properties on `Sequencer` that are objects and are NOT part of a song position.
## Anything object-typed and not in here or in the recursed set is a coverage fault.
const SEQ_INERT_OBJECTS := [
	"mixer", "waveset", "native_sequencer", "tracks",
	"_irq_walker", "_music_slot_pool", "_runtime",
]
## Objects on `Sequencer` this module walks into.
const SEQ_CAPTURED_OBJECTS := ["music_entity", "_flush_tick"]

## Value-typed sequencer properties that are diagnostics or configuration rather
## than position. See the header for why each one is excluded.
const SEQ_SKIP_VALUES := {
	"debug_trace": true, "spu_trace_order": true, "debug_trace_enabled": true,
	"debug_runtime_poll_enabled": true, "disabled_opcodes": true,
}

const TRACK_INERT_OBJECTS := ["ctx"]
const TRACK_SKIP_VALUES := {"events": true}

## Every walker flag, armed on restore so the hardware is re-told everything.
##
## The walker only writes FLAGGED registers, so after a rewind the SPU knows
## nothing of the recovered pitch, volume, ADSR or instrument — it is still
## holding whatever the abandoned future left there. Arming all nine and draining
## them inside `apply` puts the re-stage burst at the restore rather than smearing
## it into the first tick afterwards, which is also what lets the differential
## test compare post-restore ticks cleanly.
const RESTAGE_FLAGS := (
	_SS.WALKER_FLAG_VOL_LR_RAW | _SS.WALKER_FLAG_VOL_LR_SWEEP | _SS.WALKER_FLAG_PITCH
	| _SS.WALKER_FLAG_SAMPLE_ADDR | _SS.WALKER_FLAG_ADSR1_HIGH | _SS.WALKER_FLAG_ADSR1_MID
	| _SS.WALKER_FLAG_ADSR2_HIGH | _SS.WALKER_FLAG_ADSR2_LOW | _SS.WALKER_FLAG_ADSR1_LOW
)


## Capture the sequencer's whole position — ~3,200 property reads at 24 tracks.
##
## Cheap enough to take once a bar, but only since the property-list cache below:
## measured on `MUSIC_66` while building #1037, the uncached walk cost **39 ms** a
## snapshot, which against the etude's 25 ms lead is a hitch once a bar rather than a
## cost. See `_value_names`.
static func capture(seq) -> Dictionary:
	var snap := {
		"seq": _read(seq, SEQ_SKIP_VALUES),
		"music_entity": _read(seq.music_entity, {}, true) if seq.music_entity != null else {},
		"flush_tick": _read(seq._flush_tick, {}, true) if seq._flush_tick != null else {},
		"tracks": [],
	}
	for ts in seq.tracks:
		var t := {
			"track": _read(ts, TRACK_SKIP_VALUES),
			"channel": {},
			"slot": {},
		}
		if ts.ctx != null:
			t["channel"] = _read(ts.ctx.channel, {}, true)
			t["slot"] = _read(ts.ctx.slot, {}, true)
		snap["tracks"].append(t)
	return snap


## Put the sequencer back where the snapshot found it, then re-tell the hardware.
##
## SPU voice state is deliberately NOT reconstructed (ADR-0188): rewinding keys
## every voice off rather than rebuilding ADPCM read pointers and envelope phases,
## so a note sustaining ACROSS the bar line is lost. At a bar line most voices are
## re-keyed anyway, and the fidelity is not worth coupling this to the native SPU's
## internals.
static func apply(seq, snap: Dictionary) -> void:
	_write(seq, snap.get("seq", {}))
	if seq.music_entity != null:
		_write(seq.music_entity, snap.get("music_entity", {}))
	if seq._flush_tick != null:
		_write(seq._flush_tick, snap.get("flush_tick", {}))

	var rows: Array = snap.get("tracks", [])
	for i in range(mini(rows.size(), seq.tracks.size())):
		var ts = seq.tracks[i]
		var row: Dictionary = rows[i]
		_write(ts, row.get("track", {}))
		if ts.ctx != null:
			_write(ts.ctx.channel, row.get("channel", {}))
			_write(ts.ctx.slot, row.get("slot", {}))

	# Silence the abandoned future before re-staging the recovered present.
	for ts in seq.tracks:
		if ts.voice_idx >= 0:
			seq.mixer.key_off(ts.voice_idx)

	# Re-tell the hardware everything, and drain it here so the burst belongs to
	# the restore rather than to the next tick.
	#
	# ONLY WHERE THE WALKER WILL ACTUALLY LOOK. `SpuIrqWalker.tick` skips any slot
	# whose `active_word` bit 0 is clear (its own gate, mirroring FFT
	# FUN_80014590 @ ram:80014638) and never reaches `clear_walker_flags` for it.
	# Arming a skipped slot would therefore leave the flags set forever — state the
	# straight-through run does not have, so a rewound sequencer would differ from
	# it in a field nothing ever reads. And there is nothing lost: the walker is the
	# only thing that would push those registers, so a slot it does not visit cannot
	# be re-staged in the first place.
	for ts in seq.tracks:
		if ts.ctx == null or ts.voice_idx < 0 or ts.done:
			continue
		if (ts.ctx.slot.active_word & 0x1) == 0:
			continue
		ts.ctx.slot.walker_flag_word |= RESTAGE_FLAGS
	if seq._irq_walker != null:
		seq._irq_walker.tick(0)
		seq._irq_walker.tick(1)


## Which object-typed properties this module saw and what it did with each.
## `unhandled` must always be empty — a name appearing there is a field somebody
## added that snapshot/restore silently does not cover.
static func coverage(seq) -> Dictionary:
	var captured: Array = []
	var inert: Array = []
	var unhandled: Array = []
	for p in seq.get_property_list():
		if (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var name: String = str(p["name"])
		var v = seq.get(name)
		if not (v is Object):
			continue
		if SEQ_CAPTURED_OBJECTS.has(name):
			captured.append(name)
		elif SEQ_INERT_OBJECTS.has(name):
			inert.append(name)
		else:
			unhandled.append(name)
	var track_unhandled: Array = []
	for ts in seq.tracks:
		for p in ts.get_property_list():
			if (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
				continue
			var name: String = str(p["name"])
			if not (ts.get(name) is Object):
				continue
			if not TRACK_INERT_OBJECTS.has(name) and not track_unhandled.has(name):
				track_unhandled.append(name)
		break   # every TrackState has the same script, so one is representative
	return {
		"captured": captured,
		"inert": inert,
		"unhandled": unhandled,
		"track_unhandled": track_unhandled,
	}


## Every script variable of `obj` that is not skipped.
##
## `keep_object_refs` says what to do with an Object-valued property. Inside the
## state graph (channel, slot, music entity, flush) an object field is a POINTER TO
## ANOTHER PART OF THE SAME SEQUENCER — `SlotState.last_kon_channel` is a
## `ChannelState` next door — and rewinding it means restoring which one it points
## at, so the reference is captured verbatim (never copied: restore is in place, so
## the objects it names are still there). At the `Sequencer` / `TrackState` level an
## object field is instead the mixer, the waveset or the score, so those are named
## explicitly and `coverage()` is the tripwire for a new one.
## Script-variable names per SCRIPT, so `get_property_list()` is walked once per
## class instead of once per object per snapshot.
##
## THIS IS WHERE THE COST WAS. `capture()` reads ~57 objects (the sequencer, two of
## its members, and three per track over ~19 tracks), and `get_property_list()`
## allocates a fresh Array of Dictionaries describing every property — engine
## properties included — on each one. Measured on `MUSIC_66` while building #1037,
## that made a snapshot **39 ms**, against a 25 ms scheduling lead: a hitch every bar
## rather than a cost. The list is identical for every instance of a class, so it is
## computed once and keyed by script. Same names, same order, same snapshot — this
## changes speed and nothing else.
##
## Keyed by SCRIPT rather than by class name so a subclass (a test's recording
## sequencer, say) does not inherit its parent's list and silently lose its own
## fields.
static var _name_cache: Dictionary = {}


static func _value_names(obj) -> PackedStringArray:
	var key = obj.get_script()
	if key != null and _name_cache.has(key):
		return _name_cache[key]
	var names := PackedStringArray()
	for p in obj.get_property_list():
		if (int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		names.append(str(p["name"]))
	if key != null:
		_name_cache[key] = names
	return names


static func _read(obj, skip: Dictionary, keep_object_refs: bool = false) -> Dictionary:
	var out := {}
	if obj == null:
		return out
	for name in _value_names(obj):
		if skip.has(name):
			continue
		var v = obj.get(name)
		if v is Object:
			if keep_object_refs:
				out[name] = v
			continue
		# FAST PATH FOR SCALARS, and it is worth 14 ms. Almost all of the ~2,900
		# fields are ints and floats, and a static call into this script costs ~7 us
		# apiece — measured while building #1037, `_copy` alone was 19 ms of a 21 ms
		# snapshot, more than the etude's whole 25 ms scheduling lead. Containers
		# still go through `_copy`, so what must be duplicated is still defined in
		# exactly one place; this only skips the call where there is nothing to copy.
		var t := typeof(v)
		if t == TYPE_INT or t == TYPE_FLOAT or t == TYPE_BOOL or t == TYPE_NIL:
			out[name] = v
		else:
			out[name] = _copy(v)
	return out


static func _write(obj, fields: Dictionary) -> void:
	if obj == null:
		return
	for name in fields:
		obj.set(name, _copy(fields[name]))


## Copy a container so the snapshot cannot alias live state.
##
## PACKED ARRAYS MUST BE COPIED, and ADR-0188 says they need not: "Packed arrays
## are value types in GDScript and copy on assignment." **They do not, on this
## path.** `obj.get("lfo_sub_accumulator")` hands back a Variant that shares the
## array's buffer, and the sequencer then mutates it ELEMENT-WISE
## (`channel.lfo_sub_countdown[0] = n`), which writes straight through to the
## buffer the snapshot is holding. The snapshot therefore tracked the live pitch
## LFO instead of freezing it, and a rewind restored the values it had wandered to.
##
## The differential test caught exactly this, on the pitch LFO of one track: after
## a rewind, `lfo_sub_step_current` had the wrong SIGN and `lfo_sub_accumulator`
## was zero, so one pitch register write went missing per affected tick. It is the
## silent, subtle, wrong-register failure the ADR built this whole reflective
## design to prevent — hiding in the ADR's own stated exception.
static func _copy(v):
	match typeof(v):
		TYPE_ARRAY, TYPE_DICTIONARY:
			return v.duplicate(true)
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_VECTOR4_ARRAY, \
		TYPE_PACKED_COLOR_ARRAY:
			return v.duplicate()
		_:
			return v
