@tool
extends EditorPlugin
## ExMateria SPU — Godot editor plugin entry.
##
## Nothing to install and no autoloads: enabling the plugin loads the
## GDExtension, which registers FOUR classes — ExMateriaPsxSpu,
## ExMateriaSpuAdpcm, ExMateriaSpuStream and ExMateriaSpuPlayback — beside the
## ONE this addon declares by `class_name`, `ExMateriaSpu` in
## `exmateria_spu.gd`. Five global names, which
## `workspace/acceptance/stranger_spu/main.gd` counts against the README on
## every run — and against this sentence, since #383 corrected the README's
## number and left this docstring saying seven.
##
## `ExMateriaSpu.Spu`, `.Sample` and `.ADSR` are constants ON that façade, not
## names of their own. `class_name` cannot declare a dotted name at all, which
## is the whole reason the façade exists (ADR-0003). Everything the addon
## contains is reached through it: `ExMateriaSpu.Spu.new()`.
##
## It also registers the `.wav` import plugin, which adds no global name at all:
## `editor/wav_import_plugin.gd` deliberately declares no `class_name`, so the
## footprint above is still the whole footprint. That is why this file reaches
## it by `preload` — the alternative is spending a sixth global name on a script
## only the editor ever loads.
##
## See README.md for the public API.

const WavImportPlugin := preload("res://addons/exmateria_spu/editor/wav_import_plugin.gd")

var _wav_importer: EditorImportPlugin


func _enter_tree() -> void:
	_wav_importer = WavImportPlugin.new()
	add_import_plugin(_wav_importer)


func _exit_tree() -> void:
	if _wav_importer != null:
		remove_import_plugin(_wav_importer)
		_wav_importer = null
