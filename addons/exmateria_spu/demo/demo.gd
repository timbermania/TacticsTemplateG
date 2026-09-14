extends Control

## ExMateria SPU — the ten-second demo.
##
## Press play. A PlayStation sound chip starts playing a piece it wrote into its
## own RAM at boot: no audio files, no ISO, no downloads, nothing on disk but
## this script and its neighbour. Every sound you hear went through the same 24
## ADPCM voices, hardware ADSR envelopes, noise LFSR and reverb tank a PSX had.
##
## Three objects make the sound. [ExMateriaSpu.Spu] holds the registers. An
## [ExMateriaSpuStream] renders it on the audio thread. An [AudioStreamPlayer]
## plays that stream. Everything else on this screen is a register write.
##
## The scheduler in [method _schedule_ahead] is the part worth reading. Rather
## than writing registers "now" and hoping the mixer catches up, it runs a third
## of a second ahead of the audio clock and STAMPS each write with the frame it
## belongs at; the audio thread renders up to that frame, applies the write, and
## carries on. That is why the live output is sample-for-sample identical to an
## offline [method ExMateriaSpu.Spu.render_deferred_pcm16] — and it is why the demo's test
## can assert against the same score you are listening to.

const _Spu = preload("res://addons/exmateria_spu/runtime/spu.gd")

const SONG_SCRIPT := "res://addons/exmateria_spu/demo/demo_song.gd"

## How far ahead of the audio clock to stamp register writes. It has to clear
## one mix block plus the output device's latency; everything above that is
## just how long a button press takes to be heard.
const TARGET_LEAD_SECONDS := 0.30

## Sized off the measured high-water mark: a whole 18-second loop is 552 writes,
## and the scheduler only ever holds a third of a second of them.
const QUEUE_CAPACITY := 2048
const QUEUE_RESERVE := 128

var _spu := _Spu.new()
var _song: RefCounted = null
var _stream: ExMateriaSpuStream = null
var _player: AudioStreamPlayer = null

var _events: Array = []
var _cursor := 0
var _loop_base := 0
var _sched_frame := 0
var _playing := false
var _muted := {}

@onready var _play_button: Button = %PlayButton
@onready var _reverb_toggle: CheckButton = %ReverbToggle
@onready var _noise_slider: HSlider = %NoiseSlider
@onready var _noise_value: Label = %NoiseValue
@onready var _status: Label = %Status
@onready var _part_toggles := {
	%BassToggle: 0,
	%PadToggle: 0,
	%LeadToggle: 0,
	%DrumsToggle: 0,
}


func _ready() -> void:
	_song = load(SONG_SCRIPT).new()

	# Synthesise the samples and upload them. Roughly ten milliseconds — which
	# is the whole reason this demo can ship without a single audio file.
	if not _song.upload(_spu):
		_status.text = "The SPU refused the sample upload. See the console."
		_play_button.disabled = true
		return
	_events = _song.events()

	_stream = ExMateriaSpuStream.new()
	_stream.set_mixer(_spu.get_native())
	_player = AudioStreamPlayer.new()
	_player.stream = _stream
	_player.bus = &"Master"
	add_child(_player)

	# The enum values are the song's, not this scene's; bind them here so the
	# toggles below can name a part without knowing what number it is.
	_part_toggles[%BassToggle] = _song.Part.BASS
	_part_toggles[%PadToggle] = _song.Part.PAD
	_part_toggles[%LeadToggle] = _song.Part.LEAD
	_part_toggles[%DrumsToggle] = _song.Part.DRUMS
	for toggle in _part_toggles:
		toggle.toggled.connect(_on_part_toggled.bind(_part_toggles[toggle]))

	_play_button.pressed.connect(_on_play_pressed)
	_reverb_toggle.toggled.connect(_on_reverb_toggled)
	_noise_slider.value = _song.DEFAULT_NOISE_CLOCK
	_noise_slider.value_changed.connect(_on_noise_clock_changed)
	_noise_value.text = str(_song.DEFAULT_NOISE_CLOCK)

	start()


func _exit_tree() -> void:
	stop()


## Hand the SPU to the audio thread and start the loop from the top.
func start() -> void:
	if _playing or _events.is_empty():
		return
	_cursor = 0
	_loop_base = 0
	_sched_frame = 0

	# set_deferred_mode also clears the command ring and rewinds both clocks, so
	# frame 0 below really is the first frame the audio thread will render.
	_spu.set_deferred_mode(true, QUEUE_CAPACITY)
	_schedule_ahead()          # never let the stream reach a frame with no registers written
	_player.play()
	_playing = true
	_play_button.text = "Stop"


func stop() -> void:
	_playing = false
	if _player == null:
		return
	# Godot keeps mixing a stopped playback for one more block, so stop() alone
	# does not mean the audio thread has let go of this SPU. Taking the audio
	# lock does: it is the mutex the mixer thread holds.
	AudioServer.lock()
	_player.stop()
	_spu.set_deferred_mode(false, 0)
	AudioServer.unlock()
	if is_instance_valid(_play_button):
		_play_button.text = "Play"


func is_playing() -> bool:
	return _playing


## What the audio thread has actually DONE since [method start] — frames it has
## rendered, and voices sounding as of its last block.
##
## Deliberately separate from [method is_playing], which is only this scene's
## own flag. A stream nobody pulls leaves both of these at zero while the flag
## says yes, so these are what a test should ask.
func audio_frames_rendered() -> int:
	return _spu.get_audio_frame()


func voices_sounding() -> int:
	return _spu.get_audio_active_voices()


## Walk the score, stamping each write with the frame it lands on, until either
## the lead is long enough or the command ring is nearly full. The ring bound is
## what makes a burst of writes shorten the lead rather than lose a note.
func _schedule_ahead() -> void:
	var target_lead := int(_Spu.SAMPLE_RATE * TARGET_LEAD_SECONDS)
	var audio_frame := _spu.get_audio_frame()
	while (_sched_frame - audio_frame) < target_lead:
		if _spu.get_deferred_free_slots() < QUEUE_RESERVE:
			return
		var ev: Dictionary = _events[_cursor]
		_sched_frame = _loop_base + int(ev["frame"])
		if not _is_silenced(ev):
			_spu.set_schedule_frame(_sched_frame)
			_song.apply(_spu, ev)
		_cursor += 1
		if _cursor >= _events.size():
			_cursor = 0
			_loop_base += int(_song.LOOP_FRAMES)


## Two reasons to withhold a write.
##
## A muted part swallows its key-ons and nothing else — key-offs still go
## through, because dropping those is how a mute leaves a note stuck on forever.
##
## And the score's Part.NONE events are one-time setup (see demo_song.gd): they
## are never undone, so applying them again each time round the loop would do
## nothing except overwrite whatever the listener had set on the noise slider.
func _is_silenced(ev: Dictionary) -> bool:
	if int(ev["part"]) == _song.Part.NONE:
		return _loop_base > 0
	return ev["method"] == &"key_on" and _muted.get(ev["part"], false)


## Register writes the listener makes. They are stamped at the scheduler's
## frontier like every other write, so a click is heard one lead later — the
## queue is in frame order, and the price of that order is exactly the lead.
##
## That is TARGET_LEAD_SECONDS plus however far the last event overshot it, and
## the events are up to an eighth note apart, so in practice it runs a little
## over half a second. The readout on screen shows the real number rather than
## the target, because the real one is what you are hearing.
func _write_live(method: StringName, args: Array) -> void:
	if not _playing:
		return
	_spu.set_schedule_frame(_sched_frame)
	_spu.callv(method, args)


func _on_play_pressed() -> void:
	if _playing:
		stop()
	else:
		start()


func _on_part_toggled(pressed: bool, part: int) -> void:
	_muted[part] = not pressed


func _on_reverb_toggled(pressed: bool) -> void:
	_write_live(&"set_reverb_enabled", [pressed])


func _on_noise_clock_changed(value: float) -> void:
	_noise_value.text = str(int(value))
	_write_live(&"set_noise_clock", [int(value)])


func _process(_delta: float) -> void:
	if not _playing:
		return
	_schedule_ahead()
	var audio_frame := _spu.get_audio_frame()
	var stats := _spu.get_deferred_stats()
	var bar_frames: int = int(_song.STEPS_PER_BAR) * int(_song.STEP_FRAMES)
	var bar := (audio_frame / bar_frames) % int(_song.BARS) + 1
	_status.text = (
			"bar %d of %d   voices sounding %d of 24   scheduler lead %d ms\n"
			+ "command queue %d of %d used, high water %d, %d late, %d dropped"
	) % [
		bar, int(_song.BARS),
		_spu.get_audio_active_voices(),
		int(float(_sched_frame - audio_frame) * 1000.0 / _Spu.SAMPLE_RATE),
		int(stats["capacity"]) - int(stats["free_slots"]), int(stats["capacity"]),
		int(stats["high_water"]), int(stats["overdue"]), int(stats["overflow"]),
	]
