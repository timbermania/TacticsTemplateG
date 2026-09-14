extends RefCounted
## The four per-effect artifacts the sound walker consumes, READ OFF `EffectData`
## instead of parsed a second time.
##
## Shape-compatible with `exmateria_sound`'s `EffectJSONLoader.LoadedEffect`, which is
## what `EffectSoundController.load_effect()` reads: the same four fields, the same two
## predicates, the same raw dictionaries. Nothing here is a new format.
##
## 🔴 **THIS EXISTS BECAUSE THE LOADER WAS THE SECOND PARSE OF FILES `EffectData`
## ALREADY HELD, AND THE RE-POINTS THAT FOLLOWED IT WERE THE UNDO.** `EffectJSONLoader.
## load_dir(dir)` opened `sound.json`, `sound_containers.json`, `timeline.json` and
## `feds.bin` — from the SAME `data_path` `EffectData.load_from_directory` had just been
## given (`EffectInstance.gd:299` and `:405` are handed one argument). `EffectInstance.
## _load_effect_sound` then spent three re-points putting `EffectData`'s objects back
## over the loader's, because ADR-0085's single-source rule requires the Effect Studio's
## edits to reach playback and a second parse is by construction a stale copy. Every one
## of those re-points was repairing damage the line above it had done.
##
## Reading `EffectData` directly is not a re-point — there is only ever one object. The
## studio edits `data.sound` / `data.sound_containers` in place through the
## `EffectEditSession` choke point and a structural FEDS verb REPLACES `data.feds_bank`
## with a freshly built object (ADR-0085); both reach playback on the next `build()`
## with nothing to remember to re-bind. That is the failure mode the `_live_feds_bank()`
## docstring below `_load_effect_sound` records paying for once already.
##
## ⚠️ `has_sound()` is DELIBERATELY BUG-COMPATIBLE with the loader's, gating on the FEDS
## bank rather than on the schedule. It is wrong — a walker that refuses to run because
## an AUDIO artifact is absent is why the event stream cannot be published without the
## audio package — and ADR-0318 dec. 2 is where it changes. It does not change here,
## because this file is a de-duplication and a de-duplication that also alters a
## predicate is not one.
##
## No `class_name` — instantiated by path, per the ADR-0004 cache pattern.

# { "phase1": [...], "phase2": [...], "for_each": [...] } — sound.json, verbatim.
var sound_tracks: Dictionary = {}
# { "containers": [ {mode, id_a, id_b, id_c, index}, ... ] } — sound_containers.json.
var sound_containers: Dictionary = {}
# timeline.json's `header` — phase1_duration / spawn_delay / phase2_delay /
# stc_fire_sub_tick. Passed RAW so the walker's own per-key defaults apply; the parsed
# `TimelineData` fields beside it use different ones (`spawn_delay` defaults 0 there and
# 1 in the walker).
var timeline_header: Dictionary = {}
# The sound package's `FedsBank`, or null. UNTYPED for `SfxPort`'s reason: annotating it
# would name that package's type from inside this addon.
var feds_bank = null


static func from_effect_data(data):
	## Build the walker's input from an already-loaded `EffectData`. `data` is untyped
	## to avoid a load-order cycle — `EffectData` preloads nothing from `cast/`, and
	## keeping it that way is cheaper than proving it stays true.
	var s = load("res://addons/exmateria_effects/cast/EffectSoundSchedule.gd").new()
	if data == null:
		return s
	if data.sound is Dictionary:
		s.sound_tracks = data.sound
	if data.sound_containers is Dictionary:
		s.sound_containers = data.sound_containers
	if data.timeline and data.timeline.header is Dictionary:
		s.timeline_header = data.timeline.header
	s.feds_bank = data.feds_bank
	return s


func has_sound() -> bool:
	## See the ⚠️ in the header: this is the loader's predicate, unchanged, and
	## ADR-0318 dec. 2 is where it stops being defined on the audio artifact.
	return feds_bank != null and feds_bank.num_pairs > 0


func script_is_three_phase() -> bool:
	## A 3-phase effect populates both phase1 and for_each tracks; a 1-phase effect
	## only has for_each.
	var p1 = sound_tracks.get("phase1", [])
	return p1 is Array and not (p1 as Array).is_empty()
