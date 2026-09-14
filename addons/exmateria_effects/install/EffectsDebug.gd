extends RefCounted

## `Effects`' diagnostics, read through the PLATFORM PORT instead of the host's
## `Debug` system (#1218, 2026-09-12).
##
## WHAT THIS SEVERS. `check_addon_portability.py` arm 1 scored **61 lines** across
## **19 of this addon's members** reaching `Debug` through `DebugConfig`, and that
## was 61 of the addon's 67 — 91% of the whole reach number on one identifier.
## Every one of the 61 gates a `print`. Not one is behaviour a consuming project
## has to supply, and an addon that will not parse in a project without a
## `DebugConfig` autoload fails goal #5 for a verbosity flag. ADR-0141 makes a
## logging sink non-counting for the SELECTION question and it counts for the
## INSTALL one, which is the difference the two registers exist to keep apart —
## the stranger rig declared 17 of its 21 failures on exactly these lines.
##
## 🔴 THE FLAGS WERE ALREADY TUNABLES; NOTHING NEW IS INVENTED HERE. All four
## properties this file replaces are `DebugConfig` *facades over `Tune`* —
## `DebugConfig`'s own `particle_debug_enabled` is literally `_dbg_get(false,
## "debug.particle_debug_enabled")` (`src/debug/DebugConfig`, lines 88-90), an
## ADR-0068 slug with a code default. So the addon was reaching a host autoload to
## read a registry the platform port already exposes. Reading the slug directly is
## the same value from the same registry with one fewer dependency, and
## `addons/exmateria_sprite_rig/install/RigDebug.gd` is the precedent this file is
## TRANSCRIBED from rather than adapted (ADR-0288 dec. 1/2, #1218).
##
## 🔴 `TunePort`, NOT `Tune`. `Tune` is a host autoload and naming it is
## standalone-parse debt (`check_addon_portability` arm 2) even though arm 1
## cannot see it — `platform` is a tier, not a system. `TunePort` is the port
## ADR-0175 dec. 2 built for exactly this, with a defined absent behaviour.
##
## 🔴 TWO OF THE FOUR ARE HOST-WIDE AND STAY SHARED SLUGS. `iteration` and
## `camera` are read outside this membership by `CombatLoop`, `CinematicManager`,
## `Projectile3D`, `GPUVisualBridge`, `DebugOverlay`, `DistanceFieldGenerator`
## and `Sprite Rig`'s own `RigDebug`; `particle` and `timeline` have no production
## reader outside this addon and the host keeps only the `LoggingDebugPanel`
## re-export. Either way the value lives in ONE registry under ONE spelling — a
## second spelling would be a second registry, which is the mistake this shape
## exists to avoid.
##
## Nothing here is instantiated; the class is a namespace of statics.

const TunePort = ExMateriaPlatform.TunePort

## The slugs. Spelled `debug.*` because that is what `src/debug/DebugConfig`
## already registers them as — see the second red note above.
const SLUG_PARTICLE := "debug.particle_debug_enabled"
const SLUG_ITERATION := "debug.iteration_debug_enabled"
const SLUG_TIMELINE := "debug.timeline_debug_enabled"
const SLUG_CAMERA := "debug.camera_debug_enabled"


## Bind at class load — the house shape for a static-only tunable owner
## (ADR-0173, `check_tune_owner_self_registration.py` S1), and the same one
## `addons/exmateria_sprite_rig/install/RigDebug.gd` uses.
static func _static_init() -> void:
	if Engine.is_editor_hint():
		return
	register_tunables()


## Register all four slugs (ADR-0068 R2) so the readers below can PULL-read.
##
## 🔴 THIS IS NOT OPTIONAL BOILERPLATE — WITHOUT IT EVERY READER BELOW ASSERTS.
## `get_value` is R5's pull-read and it asserts a prior `bind`; the four slugs
## used to be bound only LAZILY, by `src/debug/DebugConfig`'s own `_dbg_get`
## (`if not Tune.is_registered(slug): Tune.bind(...)`) on its first read of the
## matching property. So a slug was registered only if the HOST had happened to
## read it first — the exact host-order dependency this severance exists to
## remove. `RigDebug.gd`'s own header records the two-line assert-then-crash this
## produced on `res://tests/UnitDisplayPaintGoldenTest.tscn` when it was skipped.
##
## Two binds for one slug is the SUPPORTED shape, not a collision: `Tune._register`
## is first-write-wins and `bind` records each distinct use-site (M3). Whichever of
## this file and `DebugConfig` runs first wins, and they declare the same literals
## deliberately, so the winner does not matter. All four bind as `false` because
## `DebugConfig` routes all four through `_dbg_get`/`_dbg_set` with `false` as the
## code default; a rival type here would make the two disagree about the slug.
static func register_tunables() -> void:
	if Engine.is_editor_hint():
		return
	TunePort.bind(SLUG_PARTICLE, false)
	TunePort.bind(SLUG_ITERATION, false)
	TunePort.bind(SLUG_TIMELINE, false)
	TunePort.bind(SLUG_CAMERA, false)


## Every slug this file owns, for the guard that checks the set (#1218).
##
## 🔴 A TYPO IN A SLUG LITERAL BINDS A *NEW* SLUG RATHER THAN FAILING. `Tune.bind`
## registers whatever string it is handed, so `debug.particle_debug_enabeld` would
## register cleanly, read `false` forever, and silently detach this addon's
## verbosity from the host panel that scrubs it. Nothing in the tree caught that
## before `tests/DebugLoggingFlagsTunableTest.gd` grew its `EffectsDebug` arm, and
## the arm is set-equal in both directions against `DebugConfig`'s own properties.
static func slugs() -> Array[String]:
	return [SLUG_PARTICLE, SLUG_ITERATION, SLUG_TIMELINE, SLUG_CAMERA]


## Read one flag, re-declaring it first if the registry has forgotten it.
##
## 🔴 `_static_init()` IS NOT ENOUGH, AND SHIPPING THIS FILE WITHOUT THIS GUARD BROKE
## TWENTY-ODD TESTS. `Tune.reset()` does `_registry.clear()` — it drops the DECLARATIONS,
## not just the overrides — and R5's pull-read asserts a prior `bind`. So a one-time bind
## at class load is only safe until something resets the registry, after which every read
## here throws
##
##     [Tune] get_value(debug.particle_debug_enabled) before its bind — a read requires
##     a prior bind() (R5)
##     Invalid call. Nonexistent 'bool' constructor.
##
## the second line being the type default constructed from the failed read's `null`.
##
## THE PROPERTY THIS REPLACED ALWAYS HAD THE GUARD, which is what made #1218's
## "test-transparent" claim true for the tests it was checked against and false for these:
## `src/debug/DebugConfig.gd`'s `_dbg_get` is `if not Tune.is_registered(slug):
## Tune.bind(...)` then read — a LAZY, self-healing declaration. #1218 replaced it with a
## strict pull-read and verified transparency against the thirteen tests that WRITE these
## flags, none of which resets the registry. The twenty that do were only caught by the
## first full-suite run of the sequence, at #658's commit. `Tune.is_registered`'s own
## docstring prescribes exactly this shape and says why the guard rather than an
## unconditional `bind`: the `get_stack` cost is then paid once per reset, not per read,
## and `particle()` is read per frame from `EffectMultiMeshPool`.
static func _read(slug: String) -> bool:
	if not TunePort.is_registered(slug):
		TunePort.bind(slug, false)
	return bool(TunePort.get_value(slug, false))


## Particle-system tracing — emitters, pools, the multimesh renderer, TRAP.
## 26 of the 61 call sites.
static func particle() -> bool:
	return _read(SLUG_PARTICLE)


## Verbose per-frame iteration tracing. Host-wide; shared with `CombatLoop` and
## `Sprite Rig`. 24 of the 61.
##
## ⚠️ ONLY `particle` AND `timeline` ACTUALLY REGRESSED, and the reason is #1218 dec. 2's
## own measurement: `iteration` and `camera` still have host readers, so `DebugConfig`'s
## lazy `_dbg_get` re-declares those two after any reset. The two flags whose production
## readers moved ENTIRELY into this addon lost their only self-healer. A severance can
## remove a safety net that was never named in the thing being severed.
static func iteration() -> bool:
	return _read(SLUG_ITERATION)


## Effect timeline / phase-block / callback-schedule tracing. 9 of the 61.
static func timeline() -> bool:
	return _read(SLUG_TIMELINE)


## Cinematic camera tracing. Host-wide; shared with `CinematicManager`. 2 of the 61.
static func camera() -> bool:
	return _read(SLUG_CAMERA)
