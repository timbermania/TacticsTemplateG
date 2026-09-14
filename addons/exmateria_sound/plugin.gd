@tool
extends EditorPlugin
## ExMateria Sound — Godot editor plugin entry.
##
## **It registers two autoloads, and that is the point.** The docstring here used
## to say *"the runtime is autoload-free by design"*, and that was false: the
## always-on SFX driver and its SPU owner have to be singletons, so the CONSUMER
## was creating them — under names the consumer chose — while the addon reached
## for `/root/ExMateriaAudioEngine` and `/root/ExMateriaEffectSfx` by hardcoded string. The
## worst-behaved of the three global channels: the consumer picks the name and
## the addon hardcodes it anyway.
##
## Repo-root ADR-0003 decision 6 closes it — the root corpus, not godot-learning's;
## the two share one number space. Enabling the plugin adds:
##
##   ExMateriaAudioEngine   runtime/audio_engine.gd      — the shared waveset and
##                                                          the music/SFX SPUs
##   ExMateriaEffectSfx     runtime/effect_sfx_engine.gd — the always-on battle
##                                                          SFX driver
##
## **Order matters and is the call order below.** `ExMateriaEffectSfx._ready()`
## looks up `ExMateriaAudioEngine` and waits for its initialized signal when
## content is not ready, so the SPU owner is registered first.
## Local modification, 2026-09-13: content is supplied explicitly after boot.
##
## A consumer that would rather declare them itself still can — `godot-learning`
## does, to keep its own autoload ORDER explicit — but it must use these names.
## `tools/check_globals.py` holds that: an addon autoload the consumer names
## itself, under a name this file does not register, is a failure.
##
## Everything else in this addon is reached through `ExMateriaSound`, the one
## `class_name` it declares. See README.md for the public API.

const AUTOLOADS := [
	["ExMateriaAudioEngine", "res://addons/exmateria_sound/runtime/audio_engine.gd"],
	["ExMateriaEffectSfx", "res://addons/exmateria_sound/runtime/effect_sfx_engine.gd"],
]

## Only the ones THIS plugin added. Removing on the way out what a consumer
## declared on its own would delete their line from their project file.
var _added: Array[String] = []


func _enter_tree() -> void:
	for entry in AUTOLOADS:
		# A consumer that already declares the name (the in-repo game does, to
		# keep its own autoload order explicit) must not get a duplicate.
		if not ProjectSettings.has_setting("autoload/" + entry[0]):
			add_autoload_singleton(entry[0], entry[1])
			_added.append(entry[0])


func _exit_tree() -> void:
	for name in _added:
		remove_autoload_singleton(name)
	_added.clear()
