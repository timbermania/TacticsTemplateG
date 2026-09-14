extends Node

## ExMateriaAudioEngine (Autoload Singleton)
## Accessed globally as: ExMateriaAudioEngine
##
## Local modification, 2026-09-13: explicit, deferred content initialization.
## Owns the game's static audio assets, initialized ONCE by the host and held for the
## game's lifetime (no per-play instrument reload):
##   - waveset:   one shared WavesetParser (the WAVESET.WD instrument bank)
##   - music_spu: the SPU that plays music (driven by MusicPlayer/SMDPlayer)
##   - sfx_spu:   the SPU that plays effect sounds (E###.BIN + global SFX banks,
##                driven by ExMateriaEffectSfx — the one always-on SFX driver)
##
## Two fixed SPUs = 48 voices total, each with its own reverb tank. They share
## the single instrument bank. The 24-voice cap is an internal detail of one
## native SPU unit, not a global limit — see project memory / the Spu class.
##
## THE SPU HALF ONLY (ADR-0153 dec. 2, split at #409). The Godot **Master-bus**
## rack that used to live here — the Amplify-before-HardLimiter chain, the +9 dB
## boost curve and the `UserSettings` persistence — is the HOST's and moved to
## `MasterBus`. The line is: this package owns the SPUs, the host owns the bus.
## Nothing in this file names a host symbol, which is what makes it liftable.
##
## Hosts must wait for initialized / ready_ok before using either SPU.
## No file discovery, ROM extraction, or bus configuration happens here.

const _Spu = preload("res://addons/exmateria_spu/runtime/spu.gd")
const _WavesetParser = preload("res://addons/exmateria_sound/runtime/waveset_parser.gd")

signal initialized

var waveset := _WavesetParser.new()
var music_spu: _Spu
var sfx_spu: _Spu
var ready_ok := false


## Call on the main thread after the autoload enters the tree. Failed attempts
## leave the engine idle and may be retried. Success is permanent for this
## instance: replacing a bank while audio threads own its SPUs is not supported.
## The host supplies private WAVESET.WD bytes; nothing is persisted or exported.
func initialize_from_bytes(data: PackedByteArray) -> Error:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		return ERR_UNAUTHORIZED
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	if ready_ok:
		return ERR_ALREADY_IN_USE
	var candidate := _WavesetParser.new()
	if not candidate.parse(data) or candidate.adpcm_data.size() > _Spu.MAX_BANK_BYTES:
		# The native uploader clips oversized banks rather than failing. Reject
		# them here so readiness never promises instruments that were not loaded.
		return ERR_INVALID_DATA
	var new_music := _Spu.new()
	var new_sfx := _Spu.new()
	if not new_music.load_instruments(candidate.descriptors(), candidate.adpcm_data) \
			or not new_sfx.load_instruments(candidate.descriptors(), candidate.adpcm_data):
		return ERR_CANT_CREATE
	waveset = candidate
	music_spu = new_music
	sfx_spu = new_sfx
	ready_ok = true
	initialized.emit()
	print("[ExMateriaAudioEngine] ready — shared waveset + music/sfx SPUs (48 voices)")
	return OK
