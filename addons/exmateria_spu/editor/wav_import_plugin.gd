@tool
extends EditorImportPlugin

## `.wav` -> PSX ADPCM, in the Import dock.
##
## The runtime already encodes: [method ExMateriaSpu.Sample.from_wav] runs at
## roughly 1800x realtime, so nothing here is about speed. It is about the dock
## being where a Godot user expects to say "this file loops at sample 1400".
##
## [b]This importer is opt-in, and that is a decision, not an oversight.[/b] It
## registers BELOW Godot's built-in WAV importer ([method _get_priority] returns
## 0.5), so a `.wav` in a project that merely has this addon enabled still
## imports as an [AudioStreamWAV]. Producing a PSX sample takes selecting
## "ExMateria SPU Sample" in the Import dock. See
## `docs/adr/0008-an-installed-addon-does-not-own-wav.md` in the monorepo: an
## addon is a component in someone's project, not that project's audio policy,
## and moving opt-in -> hijack later would silently reimport every `.wav` a
## consumer owns.
##
## The three options are the author-time half of a sample -- the half that is
## not in the recording. Everything else the resource carries is derived.

const _Sample = preload("res://addons/exmateria_spu/runtime/spu_sample.gd")

## No loop: the encoder marks the final block OneShotEnd and playback stops.
const LOOP_DISABLED := 0
## Loop forward from [constant OPT_LOOP_BEGIN], to the end of the sample.
const LOOP_FORWARD := 1
## Loop where the file's own RIFF `smpl` chunk says, if it has one.
const LOOP_DETECT := 2

## RIFF `smpl` loop types, from the spec's `dwType`. Only FORWARD is a loop the
## SPU's block flags can express; the rest are refused rather than silently
## flattened into one. 3-31 are reserved and 32+ are manufacturer-specific, so
## anything not named here is refused by the same rule and reported by number.
const SMPL_LOOP_FORWARD := 0
const SMPL_LOOP_PINGPONG := 1
const SMPL_LOOP_BACKWARD := 2

const OPT_LOOP_MODE := "edit/loop_mode"
const OPT_LOOP_BEGIN := "edit/loop_begin"
const OPT_TUNE_CENTS := "pitch/tune_cents"


func _get_importer_name() -> String:
	return "exmateria_spu.sample"


func _get_visible_name() -> String:
	return "ExMateria SPU Sample"


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["wav"])


func _get_save_extension() -> String:
	return "res"


func _get_resource_type() -> String:
	return "Resource"


## Below Godot's own WAV importer, which sits at 1.0. ADR-0008.
func _get_priority() -> float:
	return 0.5


func _get_import_order() -> int:
	return 0


func _get_preset_count() -> int:
	return 1


func _get_preset_name(_preset_index: int) -> String:
	return "Default"


## Godot's own WAV importer names its loop rows `edit/loop_mode` and
## `edit/loop_begin`, so a stranger has already met these two.
##
## What is NOT here is as decided as what is:
##
## [b]No `edit/loop_end`.[/b] The encoder always marks the sample's final block
## LoopEnd -- a PSX loop runs to the end of the sample, full stop. A field that
## looked like Godot's and silently did nothing would be worse than its absence.
##
## [b]No ping-pong and no backward.[/b] [AudioStreamWAV] has them; PSX ADPCM's
## block flags cannot express them. That is why "Detect From WAV" REFUSES a
## `smpl` record whose `dwType` is anything but forward, and says so, rather
## than importing it as the forward loop the file did not ask for.
##
## [b]`pitch/tune_cents` is ADDITIVE, not an override.[/b] `from_wav` already
## derives [member ExMateriaSpu.Sample.base_pitch_cents] from the source rate
## (a 22050 Hz file measures -1200.0). An absolute field pre-filled with that
## value is more informative exactly once and then rots: it freezes into the
## `.import`, and dropping in a 44100 Hz version of the same recording leaves
## the sample an octave off with nothing on screen to say why. Cents rather than
## a root-note field because the resource publishes exactly one unit for this
## quantity, and float because 1/256 of a semitone is 0.390625 cents.
func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	return [
		{
			"name": OPT_LOOP_MODE,
			"default_value": LOOP_DISABLED,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": "Disabled,Forward,Detect From WAV",
		},
		{
			"name": OPT_LOOP_BEGIN,
			"default_value": 0,
			"property_hint": PROPERTY_HINT_RANGE,
			"hint_string": "0,4294967295,1,or_greater",
		},
		{
			"name": OPT_TUNE_CENTS,
			"default_value": 0.0,
			"property_hint": PROPERTY_HINT_RANGE,
			"hint_string": "-4800,4800,0.001,or_less,or_greater",
		},
	]


func _get_option_visibility(_path: String, option_name: StringName, options: Dictionary) -> bool:
	# A loop point with the loop switched off is a field that cannot mean
	# anything. Hiding it is also what retires the -1 sentinel the runtime API
	# has to apologise for in its docstring.
	if option_name == OPT_LOOP_BEGIN:
		return int(options.get(OPT_LOOP_MODE, LOOP_DISABLED)) == LOOP_FORWARD
	return true


func _import(source_file: String, save_path: String, options: Dictionary,
		_platform_variants: Array[String], _gen_files: Array[String]) -> Error:
	var probe := _probe_wav(source_file)

	var mode := int(options.get(OPT_LOOP_MODE, LOOP_DISABLED))
	var loop_at := -1
	if mode == LOOP_FORWARD:
		loop_at = maxi(0, int(options.get(OPT_LOOP_BEGIN, 0)))
	elif mode == LOOP_DETECT:
		loop_at = int(probe.get("loop_begin", -1))
		if loop_at < 0:
			var refused := int(probe.get("refused_loop_type", -1))
			if refused >= 0:
				push_warning("%s: the file's `smpl` loop is dwType %d (%s). PSX ADPCM block flags encode a forward loop and nothing else, so the loop was REFUSED and the file imported as a one-shot. Set the mode to Forward to loop it anyway."
						% [source_file, refused, _loop_type_name(refused)])
			else:
				push_warning("%s: loop mode is \"Detect From WAV\" and the file has no `smpl` loop. Imported as a one-shot." % source_file)

	# The downmix is the one thing `from_wav` does silently that a person would
	# want told: it succeeds, produces a mono sample, and says nothing. The
	# chunk walk above already has the channel count, so this costs nothing.
	if int(probe.get("channels", 1)) > 1:
		push_warning("%s is %d-channel; PSX ADPCM is mono, so the channels were averaged."
				% [source_file, int(probe.get("channels", 1))])

	var sample := _Sample.from_wav(source_file, loop_at)
	if sample == null:
		# `from_wav` has already pushed the specific reason -- not a RIFF, or
		# 8/24/32-bit, or no data chunk. A second message here would be a worse
		# copy of one that is already in the Output panel. Returning an error
		# rather than an empty resource is what makes the dock show a failure.
		return ERR_FILE_UNRECOGNIZED
	sample.base_pitch_cents += float(options.get(OPT_TUNE_CENTS, 0.0))
	return ResourceSaver.save(sample, save_path + "." + _get_save_extension())


## `fmt `'s channel count and `smpl`'s first loop start, walked HERE rather than
## in [method ExMateriaSpu.Sample._parse_wav].
##
## Teaching the runtime parser about `smpl` would change a published API that
## shipped without it, and this ticket is meant to be purely additive on that
## binding. The cost is that the file is chunk-walked twice; the alternative --
## parsing PCM here and calling `from_pcm16` -- puts a SECOND WAV parser in the
## tree that can drift from the first, over a file the encoder chews at 1800x
## realtime.
##
## `MIDIUnityNote` is read by nothing, deliberately. `numSampleLoops > 0` is a
## positive signal: nothing writes a loop into a file unless someone authored
## one. `MIDIUnityNote = 60` is indistinguishable from "the exporter left it at
## its default", and acting on it would shift pitch by octaves on files where
## nobody meant anything by it.
##
## `dwType` IS read, and it is the difference between a positive signal and a
## misread one. A record that says ping-pong is still an authored loop — someone
## meant it — and it is the one thing #421 decision 2 names as unencodable.
## Reading `numSampleLoops` and `dwStart` while skipping the field between them
## turned "the SPU cannot do ping-pong" into "the SPU quietly does something
## else", which is worse than the feature being absent.
func _probe_wav(path: String) -> Dictionary:
	# `refused_loop_type` is absent unless a loop was found AND rejected, so
	# "no loop at all" and "a loop this format cannot hold" stay distinguishable
	# to the caller — they are different things to tell a person.
	var out := {"channels": 1, "loop_begin": -1}
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 12 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" \
			or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return out
	var pos := 12
	while pos + 8 <= bytes.size():
		var id := bytes.slice(pos, pos + 4).get_string_from_ascii()
		var size := int(bytes.decode_u32(pos + 4))
		var body := pos + 8
		if body + size > bytes.size():
			size = bytes.size() - body
		if id == "fmt " and size >= 16:
			out["channels"] = int(bytes.decode_u16(body + 2))
		elif id == "smpl" and size >= 36:
			# 28: numSampleLoops. 36: the first loop record, whose `type` is at
			# +4 and whose `start` is at +8 and is a SAMPLE index -- the same
			# unit `from_wav` takes.
			var loops := int(bytes.decode_u32(body + 28))
			if loops > 0 and size >= 36 + 24:
				var loop_type := int(bytes.decode_u32(body + 36 + 4))
				if loop_type == SMPL_LOOP_FORWARD:
					out["loop_begin"] = int(bytes.decode_u32(body + 36 + 8))
				else:
					out["refused_loop_type"] = loop_type
		# Chunks are word-aligned: an odd size is followed by a pad byte.
		pos = body + size + (size & 1)
	return out


## For the refusal message. The number is what the file actually holds and is
## printed either way; the word is there so a person reading the Output panel
## does not have to look the spec up.
func _loop_type_name(dw_type: int) -> String:
	match dw_type:
		SMPL_LOOP_PINGPONG:
			return "ping-pong"
		SMPL_LOOP_BACKWARD:
			return "backward"
		_:
			return "reserved or manufacturer-specific"
