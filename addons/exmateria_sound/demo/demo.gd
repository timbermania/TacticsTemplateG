extends Control

## ExMateria Sound — the demo scene, and the honest message when it cannot run.
##
## This addon ships no game data and never will: the music it plays is Final
## Fantasy Tactics', and the sequences and samples come off a disc you own and
## extracted yourself. So this scene has two jobs, and the second one is the
## one that matters more often.
##
## When the assets resolve, it plays them: [AssetPaths] finds `SOUND/`, an
## [SMDPlayer] loads `WAVESET.WD` and a `MUSIC_nn.SMD`, and the same SPU core
## the generic addon exposes renders it.
##
## When they do not, it says so precisely — which of the three resolution routes
## was tried, what each one yielded, and what the file it wanted was called.
## "Could not load assets" is not a message; it is a shrug. The one below is
## meant to be actionable without reading any source.
##
## The generic [b]exmateria_spu[/b] demo next door needs none of this: it
## synthesises everything it plays. If you are here to hear the SPU rather than
## this game's music, open that one instead.

const _AssetPaths = preload("res://addons/exmateria_sound/runtime/asset_paths.gd")
const _SMDPlayer = preload("res://addons/exmateria_sound/runtime/smd_player.gd")

const SPU_DEMO_SCENE := "res://addons/exmateria_spu/demo/demo.tscn"
const WAVESET_NAME := "WAVESET.WD"

@onready var _status: RichTextLabel = %Status
@onready var _track_picker: OptionButton = %TrackPicker
@onready var _play_button: Button = %PlayButton
@onready var _recheck_button: Button = %RecheckButton
@onready var _spu_demo_button: Button = %SpuDemoButton

var _player: _SMDPlayer = null
var _sound_dir := ""
var _tracks: PackedStringArray = PackedStringArray()
var _waveset_loaded := false


func _ready() -> void:
	_play_button.pressed.connect(_on_play_pressed)
	_recheck_button.pressed.connect(_refresh)
	_spu_demo_button.pressed.connect(_on_open_spu_demo)
	_spu_demo_button.disabled = not ResourceLoader.exists(SPU_DEMO_SCENE)
	_refresh()


func _exit_tree() -> void:
	if _player != null and _player.is_playing():
		_player.stop_music()


## Resolve the assets, then either wire the player up or explain what is missing.
func _refresh() -> void:
	if _player != null and _player.is_playing():
		_player.stop_music()
	_track_picker.clear()
	_tracks = PackedStringArray()
	_waveset_loaded = false

	var report := _resolve()
	_status.text = report["message"]
	var usable: bool = report["usable"]
	_track_picker.disabled = not usable
	_play_button.disabled = not usable
	if not usable:
		_play_button.text = "Play"
		return

	_sound_dir = report["sound_dir"]
	_tracks = report["tracks"]
	for name in _tracks:
		_track_picker.add_item(name)
	_track_picker.select(mini(_track_picker.item_count - 1, _default_track_index()))
	_play_button.text = "Play"


## Everything the scene knows about where the data is or is not, as one report.
## Kept separate from the UI so the message and the decision come from the same
## walk — a screen that says "found" while the loader says "missing" is worse
## than no screen at all.
func _resolve() -> Dictionary:
	var lines: Array[String] = []
	var env := OS.get_environment("EXMATERIA_ASSETS_DIR")
	var standard := _AssetPaths.standard_assets_dir()
	var root := _AssetPaths.assets_root()

	# The routes are tried in order and the first answer wins, so a report that
	# says "not found" for a route nothing ever ran is a lie. Say which one
	# answered and which were never consulted.
	var standard_has_sound := standard != "" and DirAccess.dir_exists_absolute(standard.path_join("SOUND"))
	var answered := 1 if env != "" else (2 if standard_has_sound else (3 if root != "" else 0))
	lines.append("[b]Where this scene looked[/b], in order, first answer wins")
	lines.append("1. [code]EXMATERIA_ASSETS_DIR[/code] — %s" % (
			("[color=#8fd9a8]set to %s[/color]" % env) if env != "" else "[color=#8d98b3]not set[/color]"))
	lines.append("2. the standard data directory — %s" % (
			_skipped(answered, 2) if answered < 2
			else (_dir_note(standard.path_join("SOUND")) if standard != ""
					else "[color=#8d98b3]no home directory to derive one from[/color]")))
	lines.append("3. a [code]project-assets/fft-extract/[/code] beside the project — %s" % (
			_skipped(answered, 3) if answered < 3 and answered != 0
			else ("[color=#8fd9a8]found[/color]" if root != "" else "[color=#8d98b3]not found[/color]")))

	if root == "":
		lines.append("")
		lines.append("[b]No extracted disc tree was found, so there is nothing to play.[/b]")
		lines.append(_how_to_supply_assets())
		return {"usable": false, "message": "\n".join(lines), "sound_dir": "", "tracks": PackedStringArray()}

	var sound_dir: String = root.path_join("SOUND")
	var waveset: String = sound_dir.path_join(WAVESET_NAME)
	lines.append("")
	lines.append("[b]Resolved to[/b] [code]%s[/code]" % sound_dir)

	if not FileAccess.file_exists(waveset):
		lines.append("")
		lines.append("[color=#f0a0a0]…but there is no [code]%s[/code] in it.[/color] That file is the instrument bank; without it every note would be silent, so the scene stops here rather than playing nothing." % WAVESET_NAME)
		lines.append(_how_to_supply_assets())
		return {"usable": false, "message": "\n".join(lines), "sound_dir": sound_dir, "tracks": PackedStringArray()}

	var tracks := _list_tracks(sound_dir)
	if tracks.is_empty():
		lines.append("")
		lines.append("[color=#f0a0a0]…and the instrument bank is there, but no [code]MUSIC_nn.SMD[/code] sequences are.[/color] The bank holds the sounds; the sequences say when to play them. Both come out of the same [code]SOUND/[/code] directory.")
		lines.append(_how_to_supply_assets())
		return {"usable": false, "message": "\n".join(lines), "sound_dir": sound_dir, "tracks": PackedStringArray()}

	lines.append("[color=#8fd9a8]%s and %d sequences are present.[/color] Pick one and press play." % [WAVESET_NAME, tracks.size()])
	return {"usable": true, "message": "\n".join(lines), "sound_dir": sound_dir, "tracks": tracks}


## A route that never ran did not "fail"; saying so is what keeps this report
## worth reading when someone is debugging their own paths.
func _skipped(answered: int, route: int) -> String:
	return "[color=#8d98b3]not consulted — route %d answered first[/color]" % answered


func _dir_note(path: String) -> String:
	if DirAccess.dir_exists_absolute(path):
		return "[color=#8fd9a8]%s exists[/color]" % path
	return "[color=#8d98b3]no %s[/color]" % path


func _how_to_supply_assets() -> String:
	return ("\n[b]What it wants[/b]\nA directory holding [code]SOUND/%s[/code] and "
			+ "[code]SOUND/MUSIC_nn.SMD[/code], extracted from a Final Fantasy Tactics disc you own. "
			+ "Point [code]EXMATERIA_ASSETS_DIR[/code] at it and restart, or put it at the standard "
			+ "data directory above.\n\n"
			+ "This addon ships none of that on purpose, and nothing here will download it.\n\n"
			+ "[b]If you came to hear the SPU rather than this game[/b]\n"
			+ "[code]%s[/code] plays a piece it synthesises at boot and needs no files at all. "
			+ "The button below opens it.") % [WAVESET_NAME, SPU_DEMO_SCENE]


func _list_tracks(sound_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(sound_dir)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not d.current_is_dir() and name.to_upper().begins_with("MUSIC_") and name.to_upper().ends_with(".SMD"):
			out.append(name)
		name = d.get_next()
	d.list_dir_end()
	out.sort()
	return out


## MUSIC_31 is the one the addon's own README reaches for, so start there when
## it is present rather than on whatever sorts first.
func _default_track_index() -> int:
	for i in range(_tracks.size()):
		if _tracks[i].to_upper().begins_with("MUSIC_31"):
			return i
	return 0


func _on_play_pressed() -> void:
	if _player != null and _player.is_playing():
		_player.stop_music()
		_play_button.text = "Play"
		return
	if _tracks.is_empty():
		return

	if _player == null:
		_player = _SMDPlayer.new()
		add_child(_player)

	# The instrument bank is megabytes and does not change between tracks, so
	# it is loaded once and kept; only the sequence is swapped.
	if not _waveset_loaded:
		if not _player.load_waveset(_sound_dir.path_join(WAVESET_NAME)):
			_status.text = "[color=#f0a0a0]%s is present but would not parse.[/color] See the console." % WAVESET_NAME
			return
		_waveset_loaded = true

	var track: String = _tracks[maxi(_track_picker.selected, 0)]
	if not _player.load_smd(_sound_dir.path_join(track)):
		_status.text = "[color=#f0a0a0]%s would not parse.[/color] See the console." % track
		return
	_player.play_music()
	_play_button.text = "Stop"


func _on_open_spu_demo() -> void:
	if _player != null and _player.is_playing():
		_player.stop_music()
	get_tree().change_scene_to_file(SPU_DEMO_SCENE)
