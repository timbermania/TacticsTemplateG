class_name ExMateriaSound
extends RefCounted

## The whole public surface of `addons/exmateria_sound`, and the only name it
## puts in your project.
##
## Godot has no namespaces: a `class_name` is engine-global, so every one an
## addon declares lands in YOUR global scope — and when you declare a colliding
## one, the ADDON's file is what fails to parse, pointing your error at a file
## you did not write. This addon declared **148** of them before `#383`. It now
## declares one, and reaches its own internals by `preload` path. See
## `docs/adr/0003-an-installed-addon-owns-five-global-names.md`.
##
## A script constant is a full type — annotation, `is` check, `.new()`:
##
##     var player: ExMateriaSound.SMDPlayer = ExMateriaSound.SMDPlayer.new()
##     add_child(player)
##
## **This list IS the supported surface.** Not the README's table beside it, and
## not "whatever happens to be reachable": if a script is not named here, it is
## internal, whatever its visibility says. `tools/check_globals.py` holds both
## directions — nothing else may declare a global, and nothing named here may
## dangle.
##
## Nothing here is instantiated. `ExMateriaSound.new()` gives you an empty
## RefCounted; the class exists to be a namespace, not an object.

# --- music -----------------------------------------------------------------

## Music playback. A `Node` — `add_child()` it.
const SMDPlayer = preload("res://addons/exmateria_sound/runtime/smd_player.gd")

## Resolve an extracted disc tree.
const AssetPaths = preload("res://addons/exmateria_sound/runtime/asset_paths.gd")

# --- the file formats ------------------------------------------------------

const WavesetParser = preload("res://addons/exmateria_sound/runtime/waveset_parser.gd")
const SMDParser = preload("res://addons/exmateria_sound/runtime/smd_parser.gd")
const FedsBank = preload("res://addons/exmateria_sound/runtime/feds_bank.gd")

# --- the sequencing layer --------------------------------------------------

const Sequencer = preload("res://addons/exmateria_sound/runtime/sequencer.gd")
const SoundOpcodes = preload("res://addons/exmateria_sound/runtime/sound_opcodes.gd")
const PitchTable = preload("res://addons/exmateria_sound/runtime/pitch_table.gd")
const Trackset = preload("res://addons/exmateria_sound/runtime/trackset.gd")

# --- the effect-SFX layer --------------------------------------------------

const EffectSoundController = preload("res://addons/exmateria_sound/runtime/effect_sound_controller.gd")
const EffectSoundResolver = preload("res://addons/exmateria_sound/runtime/effect_sound_resolver.gd")
const EffectJSONLoader = preload("res://addons/exmateria_sound/runtime/effect_json_loader.gd")
const EffectPlaySound = preload("res://addons/exmateria_sound/runtime/effect_sound/play_sound.gd")

# --- the opcode VM ---------------------------------------------------------

## The opcode VM's entry point.
const SharedDispatcher = preload("res://addons/exmateria_sound/runtime/shared/dispatcher.gd")

# --- optional --------------------------------------------------------------

## An in-game diagnostics panel. Optional: nothing else here refers to it.
const SpuAudioDebugPanel = preload("res://addons/exmateria_sound/debug/spu_audio_debug_panel.gd")

# --- re-exported from exmateria_spu ----------------------------------------
#
# Repo-root ADR-0003 decision 4 (the root corpus, not godot-learning's — two ADR
# sets share one number space). `exmateria_sound` VENDORS `exmateria_spu` (D2 #375 C1),
# so the SPU addon is present whenever this one is and the re-export can never
# dangle. `ExMateriaSpu.Spu` and `ExMateriaSound.Spu` are the same script;
# neither is the "real" one.

const Spu = preload("res://addons/exmateria_spu/runtime/spu.gd")
const Sample = preload("res://addons/exmateria_spu/runtime/spu_sample.gd")
const ADSR = preload("res://addons/exmateria_spu/runtime/adsr.gd")
