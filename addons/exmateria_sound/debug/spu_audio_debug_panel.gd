extends PanelContainer

## Live sound / SPU tuning panel (AUDIO tab of the F3 overlay).
##
## THE PACKAGE'S HALF ONLY (ADR-0153 dec. 2/4, split at #409). The whole-game **volume
## slider** that used to sit at the top of this panel drives the Godot Master bus, which is
## the HOST's — it is now `MasterVolumeDebugPanel`, which sits beside this one in the same
## AUDIO tab and legitimately keeps `extends BaseDebugPanel`. A view splits where its
## subject splits: this half reads the package's own SFX engine (its reserved click mixer);
## the other half reached `MasterBus.get/set_master_volume`, which is host.
##
## A PLAIN `PanelContainer`, not a `BaseDebugPanel` subclass (ADR-0151, ADR-0153 dec. 4):
## this panel ships with the sound package, so it may not name a host debug symbol. The
## host's registration signature is duck-typed — `DebugOverlay.register_panel` touches only
## `panel_category`/`panel_title` and `DebugDashboard` guards every lifecycle call with
## `has_method` — so satisfying it costs the four widget helpers and the `_gui_input`
## override re-provided at the bottom of this file, and nothing else.
##
## Current knob: the typewriter-click retrigger DE-CLICK, on the `audio.click_retrigger_fade_ms`
## slug (ADR-0068 move 2). The SFX engine OWNS the value — it DECLARES the tunable and the
## host adapter binds it, so an override applies at boot in every scene — and this panel is
## just a VIEW (decision 12). The declared row itself is built by the HOST into `tunable_rows`
## below, because a row is a `TuneField` and `TuneField` is the host's.
##   0 ms  = disabled (original pop) · 3 ms = default · 5/10 = gentler residual ramp
## See `effect_sfx_engine.gd`'s click_retrigger_fade_ms and Spu.set_click_retrigger_fade_ms.

const SLUG := "audio.click_retrigger_fade_ms"
const _PRESETS := [0.0, 3.0, 5.0, 10.0]

## The debug category, as a STRING the host adapter maps. `DebugOverlay.Category` is a
## closed enum of 22 this package cannot extend (ADR-0140), so it declares a name instead.
const PANEL_CATEGORY := "audio"

## The two properties the host's registration signature reads off a panel. Declared as
## plain vars because the base class that used to declare them is host-side.
var panel_title := "Debug Panel"
var panel_category: int = 0

## Where the host builds the rows for this package's DECLARED tunables. Empty when the
## host declines to fill it (standalone use) — the panel is still whole without them.
var tunable_rows: VBoxContainer

var _live_label: Label

## The package's own SFX engine singleton, found by NODE PATH and cached.
##
## `ExMateriaEffectSfx` as a bare identifier is not a symbol this package declares — it is
## a name the HOST's `project.godot` autoload block creates. Writing it here made this
## file fail to parse in ANY other project, including the package's own:
##
##     godot --path exmateria-sound --check-only -s res://addons/exmateria_sound/debug/spu_audio_debug_panel.gd
##     Parse Error: Identifier "ExMateriaEffectSfx" not declared in the current scope.  x5
##
## which is goal #5's literal test ("ships to another tactics RPG with its interface
## intact") failing on the very panel ADR-0153 dec. 4 rewrote to satisfy it. A `/root/`
## lookup names no symbol, so it parses everywhere and simply returns null where the
## consumer did not autoload the engine — the no-op standalone behaviour this panel
## already documents for its write port.
##
## Deliberately UNTYPED: a `Node`-typed local cannot reach `ready_ok` or `write_tunable`
## without the static type, and the whole point is to not need it.
var _engine = null


func _sfx_engine():
	if _engine != null and is_instance_valid(_engine):
		return _engine
	# Not get_node(): the panel is built in setup(), which the host may call before it
	# mounts us, and a node outside the tree has no scene-tree-relative path.
	var loop := Engine.get_main_loop() as SceneTree
	_engine = loop.root.get_node_or_null(^"ExMateriaEffectSfx") if loop != null else null
	return _engine


func setup() -> void:
	panel_title = "Sound / SPU"
	_build_ui()
	_refresh_live_label()


func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(300, 0)
	add_child(vbox)

	add_section_title(vbox, "Typewriter click de-click (retrigger fade)")
	add_label(vbox, "0 ms = OFF (original pop) · 3 ms = default")

	# The declared tunables' rows land here, built by the host adapter after setup().
	tunable_rows = VBoxContainer.new()
	vbox.add_child(tunable_rows)

	# Quick A/B presets — write the slug through the package's host-filled write port, so
	# the engine and every other view of the slug resync (and standalone it is a no-op).
	var presets := HBoxContainer.new()
	vbox.add_child(presets)
	add_label(presets, "Presets:", 90)
	for ms in _PRESETS:
		var btn := Button.new()
		btn.text = "%d" % int(ms)
		btn.pressed.connect(func() -> void:
			var e = _sfx_engine()
			if e != null:
				e.write_tunable(SLUG, ms)
			_refresh_live_label())
		presets.add_child(btn)

	add_separator(vbox)
	_live_label = Label.new()
	_live_label.text = ""
	vbox.add_child(_live_label)

	add_separator(vbox)
	add_print_values_button(vbox)


func on_shown() -> void:
	# The click unit spawns lazily on the first blip, so the live readout can change
	# after this panel is built — refresh whenever it's shown.
	_refresh_live_label()


func _refresh_live_label() -> void:
	if _live_label == null:
		return
	# Show the value actually armed on the click mixer if it has spawned, so the user
	# can confirm the coalesced knob reached the native core.
	var armed := "click unit not spawned yet (types a line to arm)"
	# -1.0 = the engine has not spawned its reserved click unit yet; the engine owns
	# the shape of that unit, so it answers the question rather than exposing it.
	if _has_engine():
		var ms: float = _sfx_engine().armed_click_retrigger_fade_ms()
		if ms >= 0.0:
			armed = "armed on click mixer: %.1f ms" % ms
	_live_label.text = armed


func _has_engine() -> bool:
	var e = _sfx_engine()
	return e != null and e.ready_ok


func _on_print_values() -> void:
	# The LIVE engine value, not the registry's: this panel confirms what actually
	# arrived, and reading it here needs no host symbol.
	var e = _sfx_engine()
	if e == null:
		print("[SpuAudioDebugPanel] %s — no SFX engine autoloaded in this project" % SLUG)
		return
	print("[SpuAudioDebugPanel] %s = %.1f" % [SLUG, e.click_retrigger_fade_ms])


#region Host-signature reprovisions (ADR-0153 dec. 4)
## The four widget helpers and the input handling this panel used to inherit from
## `BaseDebugPanel`. Authored, not moved — ADR-0153 dec. 9 counts them separately.


func _gui_input(event: InputEvent) -> void:
	# Consume mouse buttons so they never reach the game, and let ESC drop focus.
	if event is InputEventMouseButton:
		accept_event()
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		var focused := get_viewport().gui_get_focus_owner()
		if focused and is_ancestor_of(focused):
			focused.release_focus()
			accept_event()


func add_separator(parent: Control) -> HSeparator:
	var sep := HSeparator.new()
	sep.custom_minimum_size.y = 6
	parent.add_child(sep)
	return sep


func add_label(parent: Control, text: String, min_width: float = 0) -> Label:
	var label := Label.new()
	label.text = text
	if min_width > 0:
		label.custom_minimum_size.x = min_width
	parent.add_child(label)
	return label


func add_section_title(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	parent.add_child(label)
	return label


func add_print_values_button(parent: Control, text: String = "Print Values") -> Button:
	var btn := Button.new()
	btn.text = text
	btn.pressed.connect(_on_print_values)
	parent.add_child(btn)
	return btn

#endregion
