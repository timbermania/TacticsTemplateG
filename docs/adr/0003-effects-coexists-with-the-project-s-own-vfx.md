# ExMateria Effects coexists with the project's own VFX; it does not replace it

`src/battle/effects_playback.gd` owns the addon's playback for one battle — the
compositor producer, the per-battle host, and the `EffectManager` over them — and
its `enabled` flag is **false by default**. Installing the node changes nothing
until a caller opts in. TacticsTemplateG's own VFX (`src/file_formats/vfx/`, the
`trap_*` family, `VfxConstants`, the `effect_particle_*` shaders) remains the live
path and is untouched. Nothing in this pass deletes, bypasses or re-points it.

Replacement was the alternative and is rejected for now, on two facts rather than
on caution. First, the addon has never rendered a frame in this project, so
replacing would delete a working system in favour of an unproven one. Second, the
comparison that would justify replacing cannot currently be run: this checkout has
**zero** `*.map_data.tres`, so no map or battle renders, and standing that pipeline
up (`RomReader.export_map()` / `export_maps()` then `GameData.index_data()`) is its
own piece of work. A decision to replace should be made against a side-by-side
picture, and that picture is not yet obtainable.

The trade this accepts: two VFX systems exist and can drift. That is priced and
bounded — the addon path is off, so drift costs nothing until someone turns it on,
and the probe below asserts the project's own `TrapEffectInstance` is still there,
so a later pass cannot delete it quietly while claiming coexistence.

## The host translation lives on the host side

`src/battle/effects_cast_host.gd` implements the addon's `CastHost`. The addon sees
no TacticsTemplateG type: `Unit`, `TerrainTile` and `FftAbilityData` are translated
here, which is what the contract is for.

**The element needs no conversion, and that is the interesting part.**
`TrapEffectData.ELEMENT_TO_TRAP_ID` already maps this project's `Action.ElementTypes`
**bitfield** to exactly the 1–8 the addon's handlers take (FIRE=1 … DARK=8). Upstream
ADR-0364 decided the addon would ask for an element **id** rather than the list of
element **names** its own data happened to carry, and this is that decision meeting a
second host: TacticsTemplateG stores no element name anywhere, so a names interface
could not have been answered without inventing data. All eight are checked.

**The charging pose is inverted, because the two sides store opposite ends of the same
mapping.** The addon asks for a charging *pose* and derives the TRAP handler itself;
this project's ROM tables (`charging_vfx_ids` → `shared_vfx_handler_ids`) give the
*handler* directly. `HANDLER_TO_CHARGING_POSE` therefore inverts the addon's own
routing — handler 4 → pose 1 (spell charge lines), handler 22 → pose 2 (orbital
summon orbs), anything else → pose 0 (standard charge particles) — rather than
inventing a pose this project does not store. Charge+N is deliberately absent from
that table: the addon routes those by ability id, before pose is consulted.

## Every refusal is loud, because every failure here is quiet by design

`begin()` returns false and sets `unavailable_reason` rather than half-building. It
refuses, in order, on: disabled, no battle manager in the scene, no in-tree camera,
and no content root. `setup_native(camera)` is **checked** and its refusal disables
playback — the default fold `setup()` is never called, because this project runs
stock GL where the fold bracket does not exist. An unchecked `setup_native` plus an
unset content root are the two documented ways this integration renders nothing
while looking installed, so both are turned into stated refusals.

## The probe, and why its exit code is not its verdict

`tools/effects/ttg_integration_probe.tscn` runs 31 checks, including `begin()`
reaching a checked `setup_native()` and standing up a real `EffectManager` — the
seam `docs/effects-installation.md` says only the synthetic test exercises.

It is scored by `tools/effects/run_integration_probe.py`, which requires the
`PROBE: PASS` marker, **exactly 31 `PROBE: ok` lines**, and no `PROBE: FAIL`. The
middle requirement is not ceremony. Seeding the host to drop its ability-id range
check made the probe throw `Out of bounds get index '-1'` and abort at check **16 of
31**; a GDScript runtime error kills the method, not the process, so the engine
exited **0** having printed no verdict. Counting the checks is what catches that,
and it was measured, not predicted.

It is a scene and not a `--script` run for a related reason: under `--script` the
engine registers no autoloads, so the host — which legitimately names `RomReader` —
reports `Identifier not found` and `can_instantiate()` false. A `--script` probe
reports a broken host whether or not the host is broken. Nor does it trust `load()`:
a script with a parse error still returns a non-null `GDScript`, measured here when
`effects_playback.gd` printed "loaded ok" in the same run the engine printed
"Failed to load script … Parse error". Every check asserts a symbol or a behaviour.

## What is still not done

Content provisioning, ability/action → visual routing at the real call sites
(`show_shared_vfx`, `show_projectile`), the terrain-column callable, unit layer-4 /
SelectionArea occlusion, cinematic camera adapters, tint registrations, and
audio/timing. `docs/effects-installation.md` carries that list. This ADR fixes the
shape the integration takes; it does not claim the integration is finished, and no
effect has yet been drawn in a battle.
