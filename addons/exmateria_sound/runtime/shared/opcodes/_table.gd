## The EFFECT-SOUND dispatch table. Dictionary[int, Callable] — the literal analog
## of FFT's smd_opcode_jumptable @ 0x80028B0C. One entry per implemented opcode byte
## (0x80..0xFF range); unhandled opcodes route to EffectSoundOpStubNoop.apply
## (= LAB_8001586c analog).
##
## IT WAS CALLED `SharedOpcodeTable`, AND IT IS NOT SHARED. Music has its own table,
## `sequencer/opcodes/_table.gd`; this one is preloaded by `shared/dispatcher.gd` and
## nothing else, and that dispatcher is preloaded by `effect_sound/play_sound.gd` and
## nothing else. Measured by what each table pulls in:
##
##     this table                31 effect_sound/opcodes/  +  32 shared/opcodes/
##     sequencer/opcodes/_table  37 sequencer/opcodes/     +  32 shared/opcodes/
##
## So the 32 handler files SITTING BESIDE THIS ONE genuinely are shared — both tables
## preload all of them — and that is exactly what made the old name misleading rather
## than merely stale: a reader who checks the neighbours finds the word justified.
##
## THE FILE'S LOCATION IS STILL WRONG AND IS NOT FIXED HERE. `shared/opcodes/_table.gd`
## and `shared/dispatcher.gd` belong under `effect_sound/`, which would match the
## `<subsystem>/opcodes/_table.gd` convention `sequencer/` already follows. That is a
## structural move inside the boundary #406 and ADR-0153 dec. 2 just settled, and it has
## to move as a PAIR — relocating the table alone would leave a `shared/` file preloading
## an `effect_sound/` one, which is worse than the name. Filed, not smuggled into a
## review-fix branch. The `class_name` is renamed because nothing reads it, so the rename
## costs nothing and stops the file asserting something untrue.
##
## Refactor Pass 3: every entry is a "passthrough" Callable that
## delegates to the existing `_op_*` method on the dispatcher
## instance. Pass 4 migrates each handler body out into its own
## opcodes/<name>.gd file and rebinds the table entry.
##
## All `apply` signatures are uniform:
##   func apply(dispatcher, channel, slot, op, voice_writes: bool)
##
## even when the handler doesn't need voice_writes — the unused
## parameter is prefixed `_voice_writes` to suppress GDScript warnings.
##
## Vault: [[Effect Sound Audio Divergence]]
## Vault: [[Effect Sound Parity Ladder]]
## Vault: [[SMD Opcodes]]

const _StubNoop = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/_stub_noop.gd")

# Migrated cluster — direct preloads of opcodes/<name>.gd.

# Migrated cluster — direct preloads of opcodes/<name>.gd.
const _Dynamics = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/dynamics.gd")
const _DynamicsAdd = preload("res://addons/exmateria_sound/runtime/shared/opcodes/dynamics_add.gd")
const _VolScale = preload("res://addons/exmateria_sound/runtime/shared/opcodes/vol_scale.gd")
const _VolLfoDepth = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/vol_lfo_depth.gd")
const _ArmSubslot1PitchLfo = preload("res://addons/exmateria_sound/runtime/shared/opcodes/arm_subslot1_pitch_lfo.gd")
const _E5_3param = preload("res://addons/exmateria_sound/runtime/shared/opcodes/e5_3param.gd")
const _SetSubslot1Active = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/set_subslot1_active.gd")
const _ClearSubslot1Active = preload("res://addons/exmateria_sound/runtime/shared/opcodes/clear_subslot1_active.gd")
const _Pan = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/pan.gd")
const _PanLfoDepth = preload("res://addons/exmateria_sound/runtime/shared/opcodes/pan_lfo_depth.gd")
const _LfoArmSubslot2 = preload("res://addons/exmateria_sound/runtime/shared/opcodes/lfo_arm_subslot2.gd")
const _PanLfo = preload("res://addons/exmateria_sound/runtime/shared/opcodes/pan_lfo.gd")
const _ClearSubslot2 = preload("res://addons/exmateria_sound/runtime/shared/opcodes/clear_subslot2.gd")
const _LfoSubslotSelect = preload("res://addons/exmateria_sound/runtime/shared/opcodes/lfo_subslot_select.gd")
const _LfoSubslotUpdate = preload("res://addons/exmateria_sound/runtime/shared/opcodes/lfo_subslot_update.gd")
const _LfoSubslotDynDepth = preload("res://addons/exmateria_sound/runtime/shared/opcodes/lfo_subslot_dyn_depth.gd")
const _LfoSubslotActivate = preload("res://addons/exmateria_sound/runtime/shared/opcodes/lfo_subslot_activate.gd")
const _LfoSubslotDynDisable = preload("res://addons/exmateria_sound/runtime/shared/opcodes/lfo_subslot_dyn_disable.gd")

# Migrated cluster — direct preloads of opcodes/<name>.gd.
const _PitchBendSet = preload("res://addons/exmateria_sound/runtime/shared/opcodes/pitch_bend_set.gd")
const _PitchBendAdd = preload("res://addons/exmateria_sound/runtime/shared/opcodes/pitch_bend_add.gd")
const _PitchBendRel = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/pitch_bend_rel.gd")
const _PitchBendAdd16bit = preload("res://addons/exmateria_sound/runtime/shared/opcodes/pitch_bend_add_16bit.gd")
const _PortamentoInit = preload("res://addons/exmateria_sound/runtime/shared/opcodes/portamento_init.gd")
const _Chan6Bit2Toggle = preload("res://addons/exmateria_sound/runtime/shared/opcodes/chan6_bit2_toggle.gd")
const _Detune = preload("res://addons/exmateria_sound/runtime/shared/opcodes/detune.gd")
const _PitchLfoDepth = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/pitch_lfo_depth.gd")
const _PitchLfoInit = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/pitch_lfo_init.gd")
const _Lfo = preload("res://addons/exmateria_sound/runtime/shared/opcodes/lfo.gd")
const _FlagSetDa = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/flag_set_da.gd")
const _FlagClearDb = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/flag_clear_db.gd")
const _PortaStop = preload("res://addons/exmateria_sound/runtime/shared/opcodes/porta_stop.gd")

# Migrated cluster — direct preloads of opcodes/<name>.gd.
const _InstrumentReload = preload("res://addons/exmateria_sound/runtime/shared/opcodes/instrument_reload.gd")
const _AdsrAttack = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/adsr_attack.gd")
const _Adsr2Sustain = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/adsr2_sustain.gd")
const _AdsrRelease = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/adsr_release.gd")
const _AdsrDecaySustain = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/adsr_decay_sustain.gd")
const _AdsrModeC9 = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/adsr_mode_c9.gd")
const _AdsrModeCa = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/adsr_mode_ca.gd")

# Migrated cluster — direct preloads of opcodes/<name>.gd.
const _Byte7a = preload("res://addons/exmateria_sound/runtime/shared/opcodes/byte_7a.gd")
const _Instrument = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/instrument.gd")
const _Byte76 = preload("res://addons/exmateria_sound/runtime/shared/opcodes/byte_76.gd")

# Migrated cluster — direct preloads of opcodes/<name>.gd.
const _SlurOn = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/slur_on.gd")
const _SlurOff = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/slur_off.gd")
const _FmodEnable = preload("res://addons/exmateria_sound/runtime/shared/opcodes/fmod_enable.gd")
const _FmodDisable = preload("res://addons/exmateria_sound/runtime/shared/opcodes/fmod_disable.gd")
const _NoiseEnable = preload("res://addons/exmateria_sound/runtime/shared/opcodes/noise_enable.gd")
const _Adsr1HighArm = preload("res://addons/exmateria_sound/runtime/shared/opcodes/adsr1_high_arm.gd")
const _NoiseEnableNoArm = preload("res://addons/exmateria_sound/runtime/shared/opcodes/noise_enable_no_arm.gd")
const _NoiseDisable = preload("res://addons/exmateria_sound/runtime/shared/opcodes/noise_disable.gd")
const _ReverbOn = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/reverb_on.gd")
const _ReverbOff = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/reverb_off.gd")

# Pass 4a — bytecode-flow opcodes migrated to opcodes/*.gd.
const _Rest             = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/rest.gd")
const _Fermata          = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/fermata.gd")
const _Endbar           = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/endbar.gd")
const _SaveLoopTarget   = preload("res://addons/exmateria_sound/runtime/shared/opcodes/save_loop_target.gd")
const _Octave           = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/octave.gd")
const _RaiseOctave      = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/raise_octave.gd")
const _LowerOctave      = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/lower_octave.gd")
const _Repeat           = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/repeat.gd")
const _Coda             = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/coda.gd")
const _RepeatBreak      = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/repeat_break.gd")
const _NopSled          = preload("res://addons/exmateria_sound/runtime/effect_sound/opcodes/nop_sled.gd")


# Each passthrough is a static function that takes the uniform 5-arg
# signature and calls the corresponding instance method on `dispatcher`.
# Naming convention: `_pt_<opcode_hex>` so the table is grep-able by
# opcode byte. Pass 4 deletes these one cluster at a time as bodies
# move into opcodes/<name>.gd.
#
# (Yes, 63 trampolines is verbose. Pass 4 deletes them all and replaces
# with direct preloads of EffectSoundOp<X>.apply. This is the scaffold.)


# Pass 4a migrated bytecode-flow opcodes (0x80, 0x81, 0x90, 0x91, 0x94,
# 0x95, 0x96, 0x98, 0x99, 0x9A, 0x9B) out of dispatcher.gd into
# opcodes/<name>.gd. Trampolines removed; table entries below resolve
# directly to `Callable(_<X>, "apply")`.

# --- channel-state ---

# --- SPU-mode flags ---

# --- ADSR cluster ---

# --- pitch / portamento ---

# --- dynamics / pan / sub-slot ---


# Cached on first build(). Static — all dispatcher instances share it.
static var _TABLE: Dictionary = {}


static func build() -> Dictionary:
	if not _TABLE.is_empty():
		return _TABLE
	_TABLE = {
		0x80: Callable(_Rest,           "apply"),
		0x81: Callable(_Fermata,        "apply"),
		0x90: Callable(_Endbar,         "apply"),
		0x91: Callable(_SaveLoopTarget, "apply"),
		0x94: Callable(_Octave,         "apply"),
		0x95: Callable(_RaiseOctave,    "apply"),
		0x96: Callable(_LowerOctave,    "apply"),
		0x98: Callable(_Repeat,         "apply"),
		0x99: Callable(_Coda,           "apply"),
		0x9A: Callable(_RepeatBreak,    "apply"),
		0x9B: Callable(_NopSled,        "apply"),
		0xA9: Callable(_Byte7a, "apply"), 0xAC: Callable(_Instrument, "apply"), 0xAD: Callable(_Byte76, "apply"),
		0xB0: Callable(_SlurOn, "apply"), 0xB1: Callable(_SlurOff, "apply"), 0xB2: Callable(_FmodEnable, "apply"), 0xB3: Callable(_FmodDisable, "apply"),
		0xB4: Callable(_NoiseEnable, "apply"), 0xB5: Callable(_Adsr1HighArm, "apply"), 0xB6: Callable(_NoiseEnableNoArm, "apply"), 0xB7: Callable(_NoiseDisable, "apply"),
		0xBA: Callable(_ReverbOn, "apply"), 0xBB: Callable(_ReverbOff, "apply"),
		0xC0: Callable(_InstrumentReload, "apply"), 0xC2: Callable(_AdsrAttack, "apply"), 0xC4: Callable(_Adsr2Sustain, "apply"), 0xC5: Callable(_AdsrRelease, "apply"),
		0xC7: Callable(_AdsrDecaySustain, "apply"), 0xC9: Callable(_AdsrModeC9, "apply"), 0xCA: Callable(_AdsrModeCa, "apply"),
		0xD0: Callable(_PitchBendSet, "apply"), 0xD1: Callable(_PitchBendAdd, "apply"), 0xD2: Callable(_PitchBendRel, "apply"), 0xD3: Callable(_PitchBendAdd16bit, "apply"),
		0xD4: Callable(_PortamentoInit, "apply"), 0xD5: Callable(_Chan6Bit2Toggle, "apply"), 0xD6: Callable(_Detune, "apply"), 0xD7: Callable(_PitchLfoDepth, "apply"),
		0xD8: Callable(_PitchLfoInit, "apply"), 0xD9: Callable(_Lfo, "apply"), 0xDA: Callable(_FlagSetDa, "apply"), 0xDB: Callable(_FlagClearDb, "apply"),
		0xDC: Callable(_PortaStop, "apply"),
		0xE0: Callable(_Dynamics, "apply"), 0xE1: Callable(_DynamicsAdd, "apply"), 0xE2: Callable(_VolScale, "apply"), 0xE3: Callable(_VolLfoDepth, "apply"),
		0xE4: Callable(_ArmSubslot1PitchLfo, "apply"), 0xE5: Callable(_E5_3param, "apply"), 0xE6: Callable(_SetSubslot1Active, "apply"), 0xE7: Callable(_ClearSubslot1Active, "apply"),
		0xE8: Callable(_Pan, "apply"), 0xEB: Callable(_PanLfoDepth, "apply"), 0xEC: Callable(_LfoArmSubslot2, "apply"), 0xED: Callable(_PanLfo, "apply"),
		0xEF: Callable(_ClearSubslot2, "apply"),
		0xF0: Callable(_LfoSubslotSelect, "apply"), 0xF1: Callable(_LfoSubslotUpdate, "apply"), 0xF2: Callable(_LfoSubslotDynDepth, "apply"),
		0xF6: Callable(_LfoSubslotActivate, "apply"), 0xF7: Callable(_LfoSubslotDynDisable, "apply"),
	}
	return _TABLE


static func dispatch(opcode: int, dispatcher, channel, slot, op,
		voice_writes: bool) -> void:
	## FFT analog: `jal smd_opcode_jumptable[opcode - 0x80]` at PC
	## 0x800154E4. Indexed lookup → indirect call → unknowns fall to
	## the LAB_8001586c shared stub.
	var table: Dictionary = build()
	var cb: Callable = table.get(opcode, Callable())
	if cb.is_valid():
		cb.call(dispatcher, channel, slot, op, voice_writes)
	else:
		_StubNoop.apply(dispatcher, channel, slot, op, voice_writes)
