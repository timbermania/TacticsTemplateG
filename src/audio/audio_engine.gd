extends Node
## AudioEngine (autoload singleton, accessed globally as `AudioEngine`).
##
## Owns the game's shared FFT audio assets, built ONCE from the loaded ROM:
##   - waveset:   one WavesetParser (the WAVESET.WD instrument bank)
##   - music_spu: the native SPU core that plays music (driven by MusicPlayer)
##   - sfx_spu:   the native SPU core that plays effect sounds (E### FEDS + the
##                global SFX banks, driven by EffectSoundPlayer)
##
## Two SPUs = 48 voices total, each with its own reverb tank, sharing one
## instrument bank. Unlike godot-learning (which loads WAVESET.WD off disk at
## boot), this project sources the bytes from RomReader, so initialization is
## deferred until a ROM is loaded — call ensure_ready() before first use.
##
## Spu and WavesetParser come from the vendored exmateria_sound addon.

const WAVESET_FILE_NAME: String = "WAVESET.WD"

var waveset: WavesetParser
var music_spu: Spu
var sfx_spu: Spu
var ready_ok: bool = false


## Builds the shared waveset + SPUs from the currently loaded ROM. Safe to call
## repeatedly; only does work the first time it succeeds. Returns false if no
## ROM is loaded yet (WAVESET.WD missing) or the native core fails.
func ensure_ready() -> bool:
	if ready_ok:
		return true

	if not RomReader.file_records.has(WAVESET_FILE_NAME):
		push_error("AudioEngine: %s not found — load a ROM before playing sound." % WAVESET_FILE_NAME)
		return false

	waveset = WavesetParser.new()
	if not waveset.parse(RomReader.get_file_data(WAVESET_FILE_NAME)):
		push_error("AudioEngine: failed to parse %s." % WAVESET_FILE_NAME)
		return false

	music_spu = Spu.new()
	sfx_spu = Spu.new()
	if not music_spu.load_instruments(waveset) or not sfx_spu.load_instruments(waveset):
		push_error("AudioEngine: failed to load instruments into the SPU cores.")
		return false

	ready_ok = true
	print("[AudioEngine] ready — shared waveset + music/sfx SPUs (48 voices)")
	return true


## Drop cached state so the next ensure_ready() rebuilds from a freshly loaded
## ROM (e.g. after the user loads a different ISO).
func reset() -> void:
	ready_ok = false
	waveset = null
	music_spu = null
	sfx_spu = null
