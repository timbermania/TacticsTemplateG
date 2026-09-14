extends Control
## Standalone host-owned audition UI. No path persistence or game routing.

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
var _choice: OptionButton
var _music: Music
var _bank = null
var _token := 0
var _status: Label
var _diagnostics: Label
var _pair: SpinBox
var _sound_id: SpinBox
var _initialize_button: Button
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
	_label("Private files stay outside the project. Nothing is copied or saved. Start with low system volume.\nMusic and SFX may play together. This tests individual pairs, not a full effect timeline.")
	_path_row("disc", "Optional private disc: raw2352 Mode2/Form1 only (not cooked ISO)")
	_disc_button = _button(_column, "Read audio catalog / initialize from disc (once per run)", load_disc)
	_disc_music = OptionButton.new()
	_column.add_child(_disc_music)
	_button(_column, "Play selected disc music", play_disc_music)
	_disc_sfx = OptionButton.new()
	_column.add_child(_disc_sfx)
	_button(_column, "Load selected disc SYSTEM / ENV / effect", load_disc_sfx)
	_label("Manual file controls (still available):")
	_path_row("waveset", "WAVESET.WD")
	_initialize_button = _button(_column, "Initialize instrument bank (once per run)", initialize_bank)
	_path_row("music", "Music: MUSIC_*.SMD")
	var music_row := HBoxContainer.new()
	_column.add_child(music_row)
	_music_button = _button(music_row, "Load / play music", play_music)
	_button(music_row, "Stop music", stop_music)
	_path_row("feds", "SFX: ENV.SED / feds.bin / *.feds / E###.BIN")
	_button(_column, "Load SFX bank", load_sfx_bank)
	_choice = OptionButton.new()
	_column.add_child(_choice)
	_choice.item_selected.connect(func(index: int): _pair.value = _choices[index].pair)
	var pair_row := HBoxContainer.new()
	_column.add_child(pair_row)
	var pair_label := Label.new()
	pair_label.text = "Pair (zero-based)"
	pair_row.add_child(pair_label)
	_pair = SpinBox.new()
	_pair.min_value = 0
	_pair.max_value = 0
	_pair.value_changed.connect(_pair_changed)
	pair_row.add_child(_pair)
	var sid_label := Label.new()
	sid_label.text = "Sound ID (-1 = engine default)"
	pair_row.add_child(sid_label)
	_sound_id = SpinBox.new()
	_sound_id.min_value = -1
	_sound_id.max_value = 65535
	_sound_id.value = -1
	pair_row.add_child(_sound_id)
	_sfx_button = _button(pair_row, "Play pair", play_pair)
	_button(pair_row, "Stop SFX", stop_sfx)
	var controls := HBoxContainer.new()
	_column.add_child(controls)
	_button(controls, "Stop all", stop_all)
	_button(controls, "Quit safely", quit_safely)
	_status = _label("Select a private raw disc or WAVESET.WD to begin. No private data is bundled.")
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

func _read(key: String) -> Dictionary:
	var result := Inputs.read_private(_paths[key].text)
	if result.has("error"):
		_status.text = result.error
	return result

func initialize_bank() -> void:
	if ExMateriaAudioEngine.ready_ok:
		_status.text = "Already initialized. Restart the application to change WAVESET.WD."
		return
	var result := _read("waveset")
	if result.has("error"):
		return
	var error := ExMateriaAudioEngine.initialize_from_bytes(result.bytes)
	_status.text = "Instrument bank initialized. Choose music or an SFX bank." if error == OK else "Initialization failed: " + error_string(error)
	_update_buttons()

func play_music() -> void:
	if not ExMateriaAudioEngine.ready_ok:
		_status.text = "Initialize WAVESET.WD first."
		return
	var result := _read("music")
	if result.has("error"):
		return
	_start_music(result.bytes, _paths.music.text.get_file())

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

func load_sfx_bank() -> void:
	_clear_bank()
	var result := _read("feds")
	if result.has("error"):
		return
	var filename: String = _paths.feds.text.get_file().to_upper()
	_accept_bank(Inputs.feds(result.bytes, filename == "SYSTEM.SED" or filename == "ENV.SED"))

func _clear_bank() -> void:
	stop_sfx()
	_bank = null
	# Cached catalog results own their arrays; clearing one would erase its IDs.
	_choices = []
	_choice.clear()
	_global_bank = false
	_pair.max_value = 0
	_sound_id.editable = true
	_sound_id.value = -1
	_update_buttons()

func _accept_bank(result: Dictionary) -> void:
	if result.has("error"):
		_status.text = result.error
		return
	_bank = result.bank
	_choices = result.choices
	_global_bank = result.global
	_sound_id.editable = not _global_bank
	_pair.max_value = _bank.num_pairs - 1
	var first := -1
	for i in range(_choices.size()):
		var entry: Dictionary = _choices[i]
		var title := "Sound ID %d (pair %d)" % [entry.sound_id, entry.pair] if _global_bank else "Pair %d" % entry.pair
		if entry.single_track >= 0:
			title += " — channel %d only" % entry.single_track
		if not entry.error.is_empty():
			title += " — " + entry.error
		elif first == -1:
			first = i
		_choice.add_item(title)
		_choice.set_item_disabled(i, not entry.error.is_empty())
	_pair.value = maxi(0, first)
	_pair_changed(_pair.value)
	_status.text = "Loaded SFX choices (original global IDs preserved). No effect timeline is loaded."
	if not result.diagnostics.is_empty():
		_status.text += "\n" + "\n".join(result.diagnostics)
	_update_buttons()

func _pair_changed(value: float) -> void:
	var index := int(value)
	if index < 0 or index >= _choices.size():
		return
	_choice.select(index)
	if _global_bank:
		_sound_id.value = _choices[index].sound_id
	_update_buttons()

func play_pair() -> void:
	if not ExMateriaEffectSfx.ready_ok or _bank == null:
		_status.text = "Initialize WAVESET.WD and load an SFX bank first."
		return
	var index := int(_pair.value)
	if index < 0 or index >= _choices.size() or not _choices[index].error.is_empty():
		_status.text = "This sound ID/pair is empty or invalid; select an enabled choice."
		return
	var sid: int = _choices[index].sound_id if _global_bank else int(_sound_id.value)
	var problem := Inputs.sound_id_error(_bank, sid)
	if not problem.is_empty():
		_status.text = problem
		return
	stop_sfx()
	_token = ExMateriaEffectSfx.begin_effect()
	if _token != 0 and not ExMateriaEffectSfx.play_pair(_token, _bank, index, sid, _choices[index].single_track):
		stop_sfx()
	_status.text = "SFX pair %d started; Stop SFX releases it." % int(_pair.value) if _token != 0 else "SFX engine rejected this pair. See debugger output for details."

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
	_initialize_button.disabled = ExMateriaAudioEngine.ready_ok
	_music_button.disabled = not ExMateriaAudioEngine.ready_ok
	_sfx_button.disabled = not ExMateriaEffectSfx.ready_ok or _bank == null or _choices.is_empty() or not _choices[int(_pair.value)].error.is_empty()

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
	_clear_bank()
	_catalog = candidate
	_disc_music.clear()
	_disc_sfx.clear()
	for entry in _catalog.music:
		_disc_music.add_item(entry.name)
		_disc_music.set_item_disabled(_disc_music.item_count - 1, not entry.error.is_empty())
	for entry in _catalog.globals:
		_disc_sfx.add_item(entry.name + (" — " + entry.error if not entry.error.is_empty() else ""))
		_disc_sfx.set_item_disabled(_disc_sfx.item_count - 1, not entry.error.is_empty())
	for entry in _catalog.effects:
		_disc_sfx.add_item(entry.name + (" — " + entry.error if not entry.error.is_empty() else " (lazy sound section)"))
		_disc_sfx.set_item_disabled(_disc_sfx.item_count - 1, not entry.error.is_empty())
	var result := _catalog.waveset_bytes()
	if result.has("error"):
		_status.text = result.error
	else:
		var code := ExMateriaAudioEngine.initialize_from_bytes(result.bytes)
		_status.text = "Disc audio initialized. Choose disc music or an SFX bank/effect." if code == OK else "Disc WAVESET initialization failed: " + error_string(code)
	_status.text += "\nKnown BATTLE.BIN table layout only; other revisions are not assumed supported."
	if not _catalog.diagnostics.is_empty():
		_status.text += "\n" + "\n".join(_catalog.diagnostics)
	_update_buttons()

func play_disc_music() -> void:
	if _catalog == null or not ExMateriaAudioEngine.ready_ok:
		_status.text = "Read a disc catalog and initialize WAVESET.WD first."
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
		_status.text = "Read a disc catalog and select an SFX bank/effect first."
		return
	var index := _disc_sfx.selected
	var result: Dictionary
	if index < _catalog.globals.size():
		result = _catalog.globals[index].result
	else:
		result = _catalog.load_effect(index - _catalog.globals.size())
	if result.has("error"):
		_disc_sfx.set_item_disabled(index, true)
	_accept_bank(result)
