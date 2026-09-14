extends Control
## Host-owned audition UI. Reuses the configured extracted-asset cache; no game routing.

const Catalog = preload("res://src/audio_test/disc_audio_catalog.gd")
const Inputs = preload("res://src/audio_test/audition_inputs.gd")
const Music = preload("res://src/audio_test/audition_music.gd")
const SmdParser = preload("res://addons/exmateria_sound/runtime/smd_parser.gd")

var _catalog: Catalog
var _disc_button: Button
var _disc_music: OptionButton
var _disc_sfx: OptionButton
var _choices: Array = []
var _global_bank := false
var _bank_title: Label
var _choice: OptionButton
var _music: Music
var _bank = null
var _token := 0
var _status: Label
var _diagnostics: Label
var _cache_button: Button
var _system_button: Button
var _environment_button: Button
var _music_button: Button
var _sfx_button: Button
var _paths: Dictionary = {}
var _dialog: FileDialog
var _dialog_target := ""
var _column: VBoxContainer

func _ready() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	add_child(margin)
	var scroll := ScrollContainer.new()
	margin.add_child(scroll)
	_column = VBoxContainer.new()
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_column.add_theme_constant_override("separation", 12)
	scroll.add_child(_column)
	_label("Audio audition — Godot %s / GL Compatibility" % Engine.get_version_info().string)
	_label("Use the existing External Data setup to export/import private assets. Start with low system volume.\nMusic and SFX may play together. Effects audition individual pairs, not full timelines.")
	_cache_button = _button(_column, "Load configured extracted-asset cache / initialize (once per run)", load_cache)
	_path_row("disc", "Or read a private raw2352 Mode2/Form1 disc (not cooked ISO; read-only)")
	_paths.disc.text = GameData.external_data_paths["ROM_PATH"]
	_disc_button = _button(_column, "Read audio catalog / initialize from disc (once per run)", load_disc)
	_label("Music")
	_disc_music = OptionButton.new()
	_column.add_child(_disc_music)
	var music_row := HBoxContainer.new()
	_column.add_child(music_row)
	_music_button = _button(music_row, "Play selected music", play_disc_music)
	_button(music_row, "Stop music", stop_music)
	_label("Global SFX — choose a bank, then a sound below")
	var global_row := HBoxContainer.new()
	_column.add_child(global_row)
	_system_button = _button(global_row, "Game / System", func(): load_global_sfx(0))
	_environment_button = _button(global_row, "Environment", func(): load_global_sfx(1))
	_bank_title = _label("No SFX bank selected")
	_choice = OptionButton.new()
	_column.add_child(_choice)
	_choice.item_selected.connect(func(_index: int): _update_buttons())
	var sound_row := HBoxContainer.new()
	_column.add_child(sound_row)
	_sfx_button = _button(sound_row, "Play selected sound", play_pair)
	_button(sound_row, "Stop SFX", stop_sfx)
	_label("Effect SFX — loading an effect replaces the sound choices above")
	_disc_sfx = OptionButton.new()
	_column.add_child(_disc_sfx)
	_button(_column, "Load selected effect sounds", load_disc_sfx)
	var controls := HBoxContainer.new()
	_column.add_child(controls)
	_button(controls, "Stop all", stop_all)
	_button(controls, "Quit safely", quit_safely)
	_status = _label("Load the configured import cache, or select a private raw disc. No private data is bundled.")
	_diagnostics = _label("")
	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.file_selected.connect(func(path: String): _paths[_dialog_target].text = path)
	add_child(_dialog)
	ApplicationShutdown.shutdown_failed.connect(_on_shutdown_failed)
	_update_buttons()

func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_column.add_child(label)
	return label

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _path_row(key: String, title: String) -> void:
	_label(title)
	var row := HBoxContainer.new()
	_column.add_child(row)
	var field := LineEdit.new()
	field.placeholder_text = "Absolute path outside this project"
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	_paths[key] = field
	_button(row, "Browse…", func():
		_dialog_target = key
		_dialog.popup_centered_ratio(0.8)
	)

func _start_music(bytes: PackedByteArray, title: String) -> void:
	var problem := Inputs.smd_error(bytes)
	if not problem.is_empty():
		_status.text = problem
		return
	var parsed = SmdParser.parse(bytes)
	if parsed == null:
		_status.text = "SMD parser rejected this sequence."
		return
	if _music == null:
		_music = Music.new()
		add_child(_music)
		_music.attach_shared_engine(ExMateriaAudioEngine.music_spu, ExMateriaAudioEngine.waveset)
		_music.debug_stats_updated.connect(func(summary: String): _diagnostics.text = summary)
		_music.playback_finished.connect(func(): _status.text = "Music finished.")
	_music.stop_music()
	_music.smd_file = parsed
	_music.seq.load_trackset(parsed.to_trackset())
	_music.play_music()
	_status.text = "Music started: " + title

func stop_music() -> void:
	if is_instance_valid(_music):
		_music.stop_music()
	_diagnostics.text = ""

func _clear_bank() -> void:
	stop_sfx()
	_bank = null
	# Cached catalog results own their arrays; clearing one would erase its IDs.
	_choices = []
	_choice.clear()
	_global_bank = false
	_bank_title.text = "No SFX bank selected"
	_update_buttons()

func _accept_bank(result: Dictionary) -> void:
	if result.has("error"):
		_status.text = result.error
		return
	_bank = result.bank
	_choices = result.choices
	_global_bank = result.global
	var first := -1
	for i in range(_choices.size()):
		var entry: Dictionary = _choices[i]
		var title := "Sound ID %d" % entry.sound_id if _global_bank else "Pair %d" % entry.pair
		if entry.single_track >= 0:
			title += " — channel %d only" % entry.single_track
		if not entry.error.is_empty():
			title += " — " + entry.error
		elif first == -1:
			first = i
		_choice.add_item(title)
		_choice.set_item_disabled(i, not entry.error.is_empty())
	_choice.select(first)
	_status.text = "Loaded SFX choices (original global IDs preserved). No effect timeline is loaded."
	if not result.diagnostics.is_empty():
		_status.text += "\n" + "\n".join(result.diagnostics)
	_update_buttons()

func play_pair() -> void:
	if not ExMateriaEffectSfx.ready_ok or _bank == null:
		_status.text = "Initialize WAVESET.WD and load an SFX bank first."
		return
	var index := _choice.selected
	if index < 0 or index >= _choices.size() or not _choices[index].error.is_empty():
		_status.text = "This sound ID/pair is empty or invalid; select an enabled choice."
		return
	var sid: int = _choices[index].sound_id if _global_bank else -1
	var problem := Inputs.sound_id_error(_bank, sid)
	if not problem.is_empty():
		_status.text = problem
		return
	stop_sfx()
	_token = ExMateriaEffectSfx.begin_effect()
	if _token != 0 and not ExMateriaEffectSfx.play_pair(_token, _bank, _choices[index].pair, sid, _choices[index].single_track):
		stop_sfx()
	_status.text = ("Sound ID %d" % sid if _global_bank else "Effect pair %d" % _choices[index].pair) + " started; Stop SFX releases it." if _token != 0 else "SFX engine rejected this sound. See debugger output for details."

func stop_sfx() -> void:
	var sfx := get_node_or_null("/root/ExMateriaEffectSfx")
	if _token != 0 and sfx != null:
		sfx.end_effect(_token)
	_token = 0

func stop_all() -> void:
	stop_music()
	stop_sfx()
	_status.text = "Stopped music and released SFX (release tails may remain)."

func quit_safely() -> void:
	# Do not free players before the shutdown boundary records their playbacks.
	ApplicationShutdown.request_quit()

func _on_shutdown_failed(message: String) -> void:
	_status.text = message + ". Application remains paused; see debugger output."

func _update_buttons() -> void:
	_disc_button.disabled = ExMateriaAudioEngine.ready_ok
	_cache_button.disabled = ExMateriaAudioEngine.ready_ok
	_music_button.disabled = not ExMateriaAudioEngine.ready_ok
	var index := _choice.selected
	_sfx_button.disabled = not ExMateriaEffectSfx.ready_ok or _bank == null or index < 0 or index >= _choices.size() or not _choices[index].error.is_empty()
	for i in range(2):
		var button := _system_button if i == 0 else _environment_button
		button.disabled = _catalog == null or not _catalog.globals[i].error.is_empty()
		button.tooltip_text = "Load an audio source first." if _catalog == null else _catalog.globals[i].error

func _exit_tree() -> void:
	stop_sfx()

func load_disc() -> void:
	if ExMateriaAudioEngine.ready_ok:
		_status.text = "Already initialized. Restart the application to change discs or WAVESET.WD."
		return
	var candidate := Catalog.new()
	if not candidate.open_private(_paths.disc.text):
		_status.text = candidate.error
		return
	_initialize_catalog(candidate, "Disc")

func load_cache() -> void:
	if ExMateriaAudioEngine.ready_ok:
		_status.text = "Already initialized. Restart the application to change audio sources."
		return
	var candidate = GameData.get_audio_catalog()
	if candidate == null:
		_status.text = GameData.audio_import_error + "\nUse External Data setup to export audio and configure IMPORT_PATH."
		return
	_initialize_catalog(candidate, "Extracted cache")

func _initialize_catalog(candidate: Catalog, source: String) -> void:
	_clear_bank()
	_catalog = candidate
	_disc_music.clear()
	_disc_sfx.clear()
	for entry in _catalog.music:
		_disc_music.add_item(entry.name)
		_disc_music.set_item_disabled(_disc_music.item_count - 1, not entry.error.is_empty())
	for entry in _catalog.effects:
		_disc_sfx.add_item(entry.name + (" — " + entry.error if not entry.error.is_empty() else ""))
		_disc_sfx.set_item_disabled(_disc_sfx.item_count - 1, not entry.error.is_empty())
	var result := _catalog.waveset_bytes()
	if result.has("error"):
		_status.text = result.error
	else:
		var code := ExMateriaAudioEngine.initialize_from_bytes(result.bytes)
		_status.text = source + " audio initialized. Click Game / System or Environment, select a sound, then Play selected sound." if code == OK else source + " WAVESET initialization failed: " + error_string(code)
	if source == "Disc":
		_status.text += "\nKnown BATTLE.BIN table layout only; other revisions are not assumed supported."
	if not _catalog.diagnostics.is_empty():
		_status.text += "\n" + "\n".join(_catalog.diagnostics)
	_update_buttons()

func play_disc_music() -> void:
	if _catalog == null or not ExMateriaAudioEngine.ready_ok:
		_status.text = "Load an audio source and initialize WAVESET.WD first."
		return
	var index := _disc_music.selected
	var result := _catalog.load_music(index)
	if result.has("error"):
		_status.text = result.error
		if index >= 0:
			_disc_music.set_item_disabled(index, true)
		return
	_start_music(result.bytes, _catalog.music[index].name)

func load_disc_sfx() -> void:
	_clear_bank()
	if _catalog == null or _disc_sfx.selected < 0:
		_status.text = "Load an audio source and select an effect first."
		return
	var index := _disc_sfx.selected
	var result := _catalog.load_effect(index)
	if result.has("error"):
		_disc_sfx.set_item_disabled(index, true)
	_accept_bank(result)
	if _bank != null:
		_bank_title.text = _catalog.effects[index].name + " — effect pairs"

func load_global_sfx(index: int) -> void:
	_clear_bank()
	if _catalog == null or index < 0 or index >= _catalog.globals.size():
		_status.text = "Load an audio source first."
		return
	_accept_bank(_catalog.globals[index].result)
	if _bank != null:
		_bank_title.text = "Game / System — sound IDs" if index == 0 else "Environment — sound IDs"
	_status.text = ("Game / System: " if index == 0 else "Environment: ") + _status.text
