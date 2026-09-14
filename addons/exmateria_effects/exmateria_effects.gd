class_name ExMateriaEffects
extends RefCounted

## The whole public surface of `addons/exmateria_effects`, and the only name it
## puts in your project.
##
## Godot has no package scope: a `class_name` is engine-global, so every one an
## addon declares lands in YOUR global scope — and when you declare a colliding
## one, the ADDON's file is what fails to parse, pointing your error at a file
## you did not write. This addon declared **42** of them on the day it moved
## (`Particle`, `EffectData`, `ScreenData`, `CameraData`, `TrapEffect`,
## `CallbackManager` — generic English every particle system has its own reason
## to want), and ADR-0212 dec. 1 rules that the fix is the FOLDER-NAMED façade
## rather than a count.
##
## A script constant is a full type — annotation, `is` check, `.new()`, and the
## static calls a file model is mostly made of:
##
##     var data := ExMateriaEffects.EffectData.new()
##
## and a consumer may alias one back to a bare local name, which is what keeps
## every existing use site spelled the way it was (ADR-0211 dec. 4):
##
##     const EffectData = ExMateriaEffects.EffectData
##
## **This list IS the supported surface.** 21 rows, derived rather than assumed
## (gl-ADR-0295 dec. 1): a member is published when something outside this addon
## reaches it. Measured on the move commit, 17 of the 21 have a PRODUCTION namer
## in `src/` and four do not — `PaletteSubsystem`, `ScreenSubsystem` and
## `UnifiedPrimStager` are named from `tests/`, `tools/` and sibling addons, and
## `PhaseBlock` is named from NOWHERE outside this addon today. Each of the four
## says so on its own row rather than being quietly dropped, because the ADR's
## derivation counted them and a silent 20 would be the number moving without a
## sentence.
##
## 🔴 FIFTEEN FURTHER MEMBERS ARE REACHED ONLY FROM `tests/` AND `tools/` AND ARE
## DELIBERATELY NOT HERE (gl-ADR-0295 dec. 1). They are bound by in-addon
## `res://` path instead, which is `tools/check_lattice_scene.py` criterion 4's
## axis, and every one of those sites is DECLARED there. So criterion 4 is **not
## 0** for this addon at the move and that is the designed outcome — extraction
## #4 took the opposite reading of the same trade, both are defensible, and what
## is not is arriving at pass 9 with the number unexplained.
##
## 🔴 THIS IS THE SYMBOL SURFACE, NOT THE COUPLING SURFACE (ADR-0211 dec. 3,
## ADR-0212 dec. 4). The path channel is `check_lattice_scene.py` criterion 4 and
## the install channel is `check_addon_install.py` axis B. Say the other numbers
## too; neither is recoverable from this file.
##
## 🔴 AND THE SHADER `#include` CHANNEL IS NOT HERE EITHER (ADR-0212 dec. 5). The
## twelve shaders that moved with this addon declare no `class_name`, carry none
## of the collision hazard this file exists for, and no GDScript constant can
## route a preprocessor include.
##
## Nothing here is instantiated. `ExMateriaEffects.new()` gives you an empty
## RefCounted; the class exists to be a namespace, not an object.


# --- the file model: what a parsed E###.BIN is -----------------------------

## The parsed effect — emitters, timeline, curves, palette/screen/camera
## subsystem keyframes and the frameset header — loaded from the pre-converted
## JSON the extractor writes. The widest name this addon publishes.
## Host use: `src/effects/studio/EffectStudioPage.gd` binds it as
## `EffectDataClass` and the Effect Studio's whole edit session is built on it;
## `src/scenes/EffectViewerScene.gd` loads one per preview. 106 test files name
## it, which is the largest test-side fan-out of any row here.
const EffectData = preload("res://addons/exmateria_effects/file_model/EffectData.gd")

## One emitter's configuration, pre-converted to Godot units by the parser —
## anchor mode, spawn rate, the curve indices and the life window.
## Host use: `src/effects/studio/EffectScoreModel.gd` scores an emitter's
## authored fields against the simulation.
const EffectEmitter = preload("res://addons/exmateria_effects/file_model/EffectEmitter.gd")

## FFT curve data: 160 samples, normalised 0–1. The ROM's shared 15-slot curve
## table, one slot at a time.
## Host use: five studio files bind it as `EffectCurveClass` —
## `src/effects/studio/ColourRibbon.gd`, `EffectKeyframeInspector.gd`,
## `EffectStudioPage.gd`, `SequenceCellColour.gd` and `ColourKeyframeSession.gd`.
const EffectCurve = preload("res://addons/exmateria_effects/file_model/EffectCurve.gd")

## The **curve explode** (ADR-0089 curve-ownership amendment dec. 2) — what load
## does to the ROM's shared 15-slot curve table, so an edit to one emitter's
## curve cannot silently move another's.
## Host use: `src/effects/studio/CurveChannel.gd`, `CurveShapeSet.gd`,
## `EffectEditSession.gd` and `ColourKeyframeSession.gd` each alias it bare.
const CurveExplode = preload("res://addons/exmateria_effects/file_model/CurveExplode.gd")

## Emitter start/stop timing — when an emitter begins and stops spawning.
## Host use: `src/effects/studio/ParticleTimelineChannel.gd` binds it as
## `_TimelineData`; 47 test files name it.
const TimelineData = preload("res://addons/exmateria_effects/file_model/TimelineData.gd")

## Parsed palette-subsystem keyframes — channels 0–2 (affected units, caster,
## target) of the ADR-0067 unified colour stack.
## Host use: `src/effects/studio/PaletteChannel.gd` and
## `src/effects/studio/EffectScoreModel.gd`.
const PaletteData = preload("res://addons/exmateria_effects/file_model/PaletteData.gd")

## Parsed screen-subsystem keyframes — the background gradient behind the map.
## Host use: `src/debug/ColorTimelineModel.gd` reads it bare;
## `src/effects/studio/ScreenChannel.gd`, `ScreenTweenProjector.gd`,
## `SpacerVerdicts.gd` and `EffectStudioPage.gd` bind it as `ScreenDataClass`.
const ScreenData = preload("res://addons/exmateria_effects/file_model/ScreenData.gd")

## Parsed camera-subsystem keyframes — angle, position and zoom.
## Host use: `src/effects/studio/CameraLowering.gd` binds it as
## `CameraDataClass` to lower an authored camera track onto the PSX curve.
const CameraData = preload("res://addons/exmateria_effects/file_model/CameraData.gd")


# --- the cast: an effect while it is running -------------------------------

## One running effect — its manager, renderer, subsystems and controls, as a
## `Node3D` you add to a scene. 930 lines, the largest member.
## Host use: `src/scenes/EffectViewerScene.gd` binds it as `EffectInstanceClass`;
## `src/debug/EffectViewerPanel.gd` and `src/gpu/CombatLoop.gd` name it in the
## combat path.
const EffectInstance = preload("res://addons/exmateria_effects/cast/EffectInstance.gd")

## Content-root resolution for callers initializing EffectInstance. Host use:
## `src/gpu/EffectManager.gd`, the CombatLoop ability adapter (not shipped here).
## Ability/formula/charge routing belongs to the host, not particle playback.
const EffectsContent = preload("res://addons/exmateria_effects/install/EffectsContent.gd")

## The timeline phase constants — `FOR_EACH`, the wind-down and the rest of the
## execution model every subsystem keys its channels by.
## Host use: `src/debug/ColorTimelineModel.gd`, `src/debug/EffectTimelineModel.gd`,
## `src/debug/EffectTimelineView.gd`, `src/effects/studio/ColorLowering.gd`,
## `EffectScoreModel.gd` and `SpacerVerdicts.gd`.
const EffectPhase = preload("res://addons/exmateria_effects/cast/EffectPhase.gd")

## The **derived effect end** — the frame at which the real engine would REAP the
## cast, which is NOT the last authored keyframe.
## Host use: `src/effects/studio/EffectStudioPage.gd` binds it as `EndModel` to
## draw where the cast actually ends.
const EffectEndModel = preload("res://addons/exmateria_effects/cast/EffectEndModel.gd")


# --- the subsystems: the four channel runtimes -----------------------------

## Runtime processor for palette-subsystem keyframes — map and unit tinting,
## the combat-effect driver of the unified colour stack.
## ⚠️ NO PRODUCTION NAMER TODAY, and it is published anyway: `tests/PaletteSubsystemTest.gd`
## and `tests/UnitTintOverlayTest.gd` are **test-only namers** (ADR-0211 dec. 5 — a
## test-only host use is a real host use), and `addons/exmateria_battlefield`'s own
## façade USED to cite this member as a **sibling namer** (ADR-0212 dec. 7) for its
## illumination builder; 🟢 #1192 deleted that builder on 2026-09-12 after measuring
## it unreached, so that citation is gone and the test-only namers above are the whole
## of this member's outside use. That addon's façade FILE is deliberately not named
## here: a citation naming another façade goes stale in `test_check_addon_globals`'s
## seeded tree, where every façade is replaced.
const PaletteSubsystem = preload("res://addons/exmateria_effects/subsystem/PaletteSubsystem.gd")

## Runtime processor for the SCREEN channel — the background gradient, mirroring
## the PSX applier `FUN_80090258 @0x80090258`.
## ⚠️ NO PRODUCTION NAMER TODAY. `tests/ScreenSubsystemTest.gd` and
## `tests/EffectSubsystemMuteTest.gd` are **test-only namers**, and
## `addons/exmateria_schema`'s façade cites this member as the owner of a
## `ColorStack`, which is a **sibling namer** relationship (ADR-0212 dec. 7).
const ScreenSubsystem = preload("res://addons/exmateria_effects/subsystem/ScreenSubsystem.gd")

## One phase's worth of cursor + channel state for a subsystem.
## 🔴 NO NAMER AT ALL OUTSIDE THIS ADDON, MEASURED ON THE MOVE COMMIT. gl-ADR-0295
## dec. 1 derived it as production-reached; the reach it counted is a `PhaseBlock`
## inside a `"""` block in `src/gpu/CombatLoop.gd`, which is prose. It is published
## because the ADR's list is the acceptance criterion and a row is cheaper to drain
## than to re-argue — the honest reading is that the surface is 20 names plus this
## one, and the next pass may delete it.
const PhaseBlock = preload("res://addons/exmateria_effects/subsystem/PhaseBlock.gd")


# --- the render path -------------------------------------------------------

## The live engine-fold combat compositor — Forward+ only, and the ONLY
## display-space compositor since #228 Phase 3 retired the raw-RD GLSL one.
## Host use: `src/effects/CompositorAutopilot.gd` (a host autoload) constructs it
## and re-attaches it to the live camera across scene changes.
const EngineFoldCompositor = preload("res://addons/exmateria_effects/render/EngineFoldCompositor.gd")

## The transparent-prim staging every display-space compositor producer shares —
## one 24-float record and the parallel arrays, in one place.
## ⚠️ ITS TEST-ONLY NAMER MOVED IN AT #1249, AND WHAT IS LEFT IS A QUESTION THIS FILE
## CANNOT SETTLE. `addons/exmateria_effects/tests/UnifiedPrimStagerTest.gd` is now an
## **in-addon namer**, which `check_addon_globals.py` reports and scores nothing
## (ADR-0217 dec. 5). `addons/exmateria_battlefield/cursor/TileCursorCompositor.gd` and
## `addons/exmateria_sprite_rig/crystal/CrystalSpriteCompositor.gd` remain as
## **sibling namers** — which is what makes the record shared rather than this addon's
## private detail — but BOTH are comments, not code. So by this file's own derivation
## rule (*a member is published when something outside this addon reaches it*) the name
## no longer qualifies and the surface should read 20, not 21. Unpublishing changes the
## SUPPORTED SURFACE, which gl-ADR-0295 dec. 1 owns, so #1249 records the consequence
## and leaves the decision.
const UnifiedPrimStager = preload("res://addons/exmateria_effects/render/UnifiedPrimStager.gd")


# --- the TRAP family -------------------------------------------------------

## The TRAP particle system — hit clouds, charge particles and the sprite
## effects, with the PSX particle physics. 1,027 lines.
## Host use: `src/scenes/TrapViewerScene.gd` and `src/debug/TrapViewerPanel.gd`
## both alias it bare.
const TrapEffect = preload("res://addons/exmateria_effects/trap/TrapEffect.gd")

## Spell charge lines (PSX TRAP handler 4) — lines contracting from a ring
## toward the caster's head.
## Host use: `src/scenes/TrapViewerScene.gd`.
const TrapChargeLineEffect = preload("res://addons/exmateria_effects/trap/TrapChargeLineEffect.gd")

## The orbital summon orb (PSX TRAP handler 22) — three concentric rings of ten
## particles orbiting the caster.
## Host use: `src/scenes/TrapViewerScene.gd`.
const TrapOrbitalEffect = preload("res://addons/exmateria_effects/trap/TrapOrbitalEffect.gd")


# --- the cinematic camera --------------------------------------------------

## Resolves the effect camera's base YAW so the focused unit is not hidden — the
## Godot heir to the ROM's `calc_facing_angles` (`0x801aac28`).
## Host use: `src/gpu/CinematicManager.gd` binds it as
## `CinematicFacingResolverClass`.
const CinematicFacingResolver = preload("res://addons/exmateria_effects/camera/CinematicFacingResolver.gd")
