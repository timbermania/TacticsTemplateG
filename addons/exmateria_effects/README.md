# ExMateria Effects

**What a cast looks like.** The parsed `E###.BIN` file model, the cast that runs
it, the four channel subsystems, the particle pool, the TRAP family, the twelve
fold/native shaders and the engine-fold compositor. **Extraction #7** of the
`godot-learning` refactor — selected and audited at
[ADR-0286](../../docs/adr)/[0287](../../docs/adr)/[0288](../../docs/adr), moved
here at [ADR-0295](../../docs/adr/0295-the-forty-five-class-names-collapse-to-twenty-one-and-forty-eight-vault-notes-are-held-by-two-anchors.md).

The addon contains file models, cast/timeline playback, all currently implemented
callbacks, camera/color/sound/particle subsystems, native/fold renderers and all
three TRAP implementations. Ability selection is a host concern: the upstream
CombatLoop adapter now lives at `src/gpu/EffectManager.gd`, not in this addon.
Its formula/element, Break, Charge+N, charging-pose, line and orbital routing is
unchanged. A different game supplies its own visual requests to the primitives.

## The one global name

`ExMateriaEffects`, and nothing else
([ADR-0212](../../docs/adr/0212-a-count-of-one-was-never-the-invariant-the-addons-one-global-is-the-folder-named-facade.md)
dec. 1). Godot has no package scope — a `class_name` is engine-global, so every
one an addon declares lands in *your* project's global scope. This addon
declared **42** on the day it moved; they are all gone, and everything is a
constant on that one name. `tools/check_addon_globals.py` holds both directions:
nothing else here may declare a global, and nothing published may dangle.

The published surface is **21 names**, derived rather than assumed: a member is
published when something outside this addon reaches it. Fifteen further members
are reached only from this repo's own `tests/` and `tools/` and are deliberately
**not** published — they are bound by `res://` path instead, and every one of
those sites is declared in `tools/check_lattice_scene.py`'s criterion-4 register
rather than hidden. That register is therefore **non-zero for this addon by
decision** (ADR-0295 dec. 1).

| published | what it is |
|---|---|
| `ExMateriaEffects.EffectData` | the parsed effect — emitters, timeline, curves, keyframes |
| `ExMateriaEffects.EffectEmitter` | one emitter's configuration |
| `ExMateriaEffects.EffectCurve` | FFT curve data, 160 samples |
| `ExMateriaEffects.CurveExplode` | the ROM's shared 15-slot curve table, exploded per emitter |
| `ExMateriaEffects.TimelineData` | emitter start/stop timing |
| `ExMateriaEffects.PaletteData` / `.ScreenData` / `.CameraData` | the three keyframe data models |
| `ExMateriaEffects.EffectInstance` | one running effect, as a `Node3D` |
| `ExMateriaEffects.EffectsContent` | configured content-root and effect-directory resolution |
| `ExMateriaEffects.EffectPhase` | the timeline phase constants |
| `ExMateriaEffects.EffectEndModel` | the derived effect end — when the engine REAPS the cast |
| `ExMateriaEffects.PaletteSubsystem` / `.ScreenSubsystem` | two of the four channel runtimes |
| `ExMateriaEffects.PhaseBlock` | one phase's cursor + channel state |
| `ExMateriaEffects.EngineFoldCompositor` | native carrier producer or optional Forward+ fork fold |
| `ExMateriaEffects.UnifiedPrimStager` | the shared transparent-prim staging |
| `ExMateriaEffects.TrapEffect` / `.TrapChargeLineEffect` / `.TrapOrbitalEffect` | the TRAP family |
| `ExMateriaEffects.CinematicFacingResolver` | the effect camera's base yaw |

A consumer may alias one back to a bare local name, which is what keeps existing
use sites spelled the way they were ([ADR-0211](../../docs/adr) dec. 4):

```gdscript
const EffectData = ExMateriaEffects.EffectData
```

## Install

1. Copy `addons/exmateria_effects/` — and its `deps=` (`exmateria_schema`,
   `exmateria_platform`, `exmateria_render`, `exmateria_sound`; sound requires
   `exmateria_spu`) — into your project.
2. **Open the project, enable Platform and Effects plugins, then reload.** Godot imports and
   compiles shaders when the project OPENS; a first enable in a bare project
   logs shader compile errors for names the plugin has not provided yet
   (ADR-0203 dec. 6).
3. Enabling registers three autoloads — `EffectMultiMeshPool`,
   `ScreenEffectOverlay`, `TintedSurfaces`. A project that declares them itself
   keeps its own lines; the plugin only adds what is missing.
4. Preserve an existing sound/SPU installation and its startup/shutdown ownership;
   do not overwrite its source or native binaries to install Effects.
5. **Declare `exmateria_effects/content_root`** — see *Content the host must
   supply* below. Without it nothing loads, and you get one `push_error` saying so.

## Content the host must supply

**This addon ships no ROM-derived content, and it never can.** The per-effect `E###`
directories (emitters, curves, framesets, the per-callback payloads) and the `TRAP1`
indexed texture with its palette are extracted from a disc the repo does not
redistribute; `assets/effects/` is gitignored outright. ADR-0202 dec. 5 calls this Class
B and rules that the *hardcoding* was the defect while the *dependency* is a legitimate
contract — so the addon stopped naming `res://assets/` and takes a search root from the
host instead ([#1224](https://github.com/timbermania/fft-monorepo/issues/1224)'s sibling
item; the register rows were seeded by
[#1225](https://github.com/timbermania/fft-monorepo/issues/1225)).

Declare it in the consuming project's `project.godot`:

```
[exmateria_effects]

content_root="res://assets/"
```

`EffectsContent` resolves every subpath against that root:

| subpath | what needs it |
|---|---|
| `effects/E###` | host passes `EffectsContent.effect_dir(name)` to `EffectInstance.initialize` |
| `effects/E###/callbacks/CB##/callback_data.json` | `EffectCallback` (the per-callback ROM payload) |
| `effects/trap/emitters.json` | `TrapEffect` |
| `effects/trap/frames.json` | `TrapEffect` |
| `effects/trap/animations.json` | `TrapEffect` |
| `effects/trap/element_config.json` | `TrapEffect` |
| `sprites/textures/TRAP1.tga` | `TrapEffect` (the indexed atlas) |
| `sprites/textures/TRAP1.palette.tga` | `TrapEffect` (its CLUT) |

**A project that omits the key gets one `push_error` naming it**, not a silent empty
load — that legibility is dec. 5's stated goal, and it is why the setting's default is
empty rather than `res://assets/`. A default pointing at the host's own layout would
also have left the literal inside an addon file, where the install register still scores
it.

⚠️ **ADR-0142 makes the CONTENT un-shippable; it does not make the LITERAL permanent.**
The register rows this replaced said the TRAP texture pair was *"PERMANENT under
ADR-0142 rather than targeted at zero"*. That conflated two claims: a content root
removes every literal without moving one ROM-derived byte, so the dependency survives as
this documented install step and the install register reaches 0.

## Native producer setup (no host autopilot)

`EngineFoldCompositor` extends **Node**, not `CompositorEffect`. Transparent
pooled particles still need this producer in native mode. This standalone recipe
is **only for non-fold-capable renderers**, including GL Compatibility. Add exactly
one to the scene/world that owns playback, after installing the three autoloads:

```gdscript
var producer := ExMateriaEffects.EngineFoldCompositor.new()
add_child(producer)
if not producer.setup_native(camera): # once, with an in-tree Camera3D in this world
    producer.queue_free()
    return # rejected; do not start playback without a producer
```

On an accepted renderer this selects native shaders and creates no FoldSurface/
compositor bracket. It supports GL Compatibility without a RenderingDevice.
`setup_native` returns false and warns **before changing any producer state** when
`Fold.owns()` is true: callbacks independently use that predicate and would join
a held-out layer with no seed/resolve bracket. **Fork Forward+ callers must use
`setup(camera)` with the default `native_blend=false` instead.** Missing camera or
pool also returns false (with the existing setup warning).

The producer processes
after pool writers (priority 1000); keep it alive while casts run and free it
with the owning scene. Do not also attach the upstream CompositorAutopilot.
The existing `native_blend=true; setup(camera)` comparison override remains
available for pooled-carrier tests/debugging; it does **not** reroute callbacks
and is not a complete standalone playback recipe on a fold-capable renderer.
Native blending is not display-space fold parity. The complete install still
declares `engine="fork"` for its fold resources and existing rig; native setup
alone does **not** certify a particular stock engine version or export template.

## Playback and receiving channels

Create `ExMateriaEffects.EffectInstance`, parent it to the scene, then call
`initialize(name, ExMateriaEffects.EffectsContent.effect_dir(name), caster_position,
512)`. Check its boolean result; on failure free the instance. Set its world
position, `set_anchors` and (when following units) `attach_anchors_to_units` /
`set_unit_targets` using the host's Node3Ds. The host owns completion polling
(`is_timeline_finished()`, `get_active_particle_count()`, `get_effect_frame()`),
channel lifetime and cleanup; EffectInstance does not emit `animation_finished`
(the TRAP primitives do). Cancellation frees the cast and preserves its existing audio
orphan/teardown behavior. The host owns action progression, not this addon.
TRAP callers select `TrapEffect`'s handler/element or `TrapChargeLineEffect` /
`TrapOrbitalEffect` explicitly; no ability database is needed for playback.

Authored camera tracks still run and emit camera signals. The host must consume
the camera controller pose, manage camera takeover/restore and, for unit-anchored
facing, inject the resolver below. Omitting Almanac/Battlefield disables no
camera/callback/tint/TRAP channel. Accepted standalone native setup shares the
non-fold-capable route with callbacks; a pooled `native_blend` override on fork
Forward+ does not make that guarantee.

Tint requires **receiving materials**, not just a populated ColorStack. Register
compatible map materials with the `TintedSurfaces` autoload's
`register_surface(TintedSurfaces.SURFACE_MAP, material)` and unit/surface materials with
`register_surface(surface_id, material)`, using the same opaque tokens as the
cast's target bindings. Unregister non-map surfaces when removed. Receiving shaders must implement
the schema's `colour_model/color_stack.gdshaderinc` / `color_layer_*` contract.
The reserved `SURFACE_MAP` token without any registered materials is not visible
tint. Platform supplies the shader globals; the host must also maintain compatible
map/unit/particle depth and camera scale conventions.

## Portable cinematic terrain query

```gdscript
# terrain_column(grid_x: int, grid_z: int) -> Dictionary
# Return {"exists": false, "world_y": 0.0} for absent columns, otherwise
# {"exists": true, "world_y": rendered_ground_height_in_world_space}.
var facing := ExMateriaEffects.CinematicFacingResolver.new(world_node, terrain_column)
camera_controller.facing_resolver = facing
```

The resolver floors world X/Z (including negative coordinates), samples the
column's **lowest present ground level**, and compares its rendered tile-top Y
against the sightline. Zero height is not absence. Upstream supplies
`src/gpu/CinematicTerrainQuery.gd`'s `sample_column.bind(map)`, using
`ground_at(x,z)` followed by `world_position_at(cell.grid).y` exactly as before;
a column with only level 1 is still present. An invalid Callable preserves the
old null-map base-yaw fallback; returning absent for every column is appropriate
only for a genuinely empty terrain, not as an integration shortcut.

The four candidates, authored pitch, 0.5-unit march, 48-unit range, 16-unit relief
exit, epsilon and all-blocked fallback are unchanged. Unit occlusion is still
**physics**, separate from terrain: an in-tree `world_node`, layer-mask **4**
Area3Ds, a focused unit child named `SelectionArea` whose RID is excluded, and
nearby units in the same World3D. A host with different collision conventions
must adapt those inputs; omitting unit colliders is not equivalent behavior.
