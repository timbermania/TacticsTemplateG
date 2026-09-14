# ExMateria Sound — Godot 4 addon

Final Fantasy Tactics (PSX) music and battle-effect SFX for Godot 4, sequenced
the way the game's own driver does it, on top of a real PlayStation 1 SPU.

**This addon does not contain an SPU.** It is the FFT layer over
[`exmateria_spu`](../exmateria_spu/README.md), which is where the 24 voices, the
ADSR envelopes, the reverb tank and all of the native code live. Nothing here
plays a sound without it — see [Install](#install), which is about that and
almost nothing else.

> **Pre-release (`0.1.x`).** Names still move between releases: `0.1.1` shipped
> a `SoundTrackController` that is now `EffectSoundController`, and the same
> release shipped one addon where there are now two. Pin a version.
>
> **The music path works standalone. The effect-SFX path does not** — it needs
> per-effect artifacts this addon does not ship, and an autoload you have to
> register. See [Effect SFX](#effect-sfx).

## Install

### One download, two addon folders

The `exmateria_sound-vX.Y.Z.zip` release **vendors `addons/exmateria_spu/`
inside it**. Unzip it into your Godot project root and you get both folders:

```
addons/exmateria_spu/      the PSX SPU, and the only native code involved
addons/exmateria_sound/    this addon — GDScript, all of it
```

Then enable **both** plugins in **Project → Project Settings → Plugins**, and
restart the editor once so the SPU's GDExtension registers.

There is no install order to get wrong and no version skew to manage, because
there is only one download. If you also install the standalone
`exmateria_spu-vX.Y.Z.zip`, the `addons/exmateria_spu/` files are byte-identical
and simply overwrite each other; the release workflow refuses to publish if they
ever differ.

> ⚠️ **No release of this two-addon shape exists yet.** The latest published
> ZIP is `v0.1.1` (2026-05-29), which is the older *single* addon: it carries
> `addons/exmateria_sound/fft_spu.gdextension` and
> `addons/exmateria_sound/bin/libfftspu.*`, neither of which exists in this tree
> any more. Everything below describes the current source, which ships next.

### This addon ships no binary, and needs none

`addons/exmateria_sound/` in a published install contains **no `bin/` directory
and no `.gdextension` file**. It is 155 `.gd` files and nothing else. Every
native symbol it uses comes from `addons/exmateria_spu/`.

That is worth saying plainly because the previous release was the opposite, and
because it moves the thing that can go wrong: a broken install is never a
missing `addons/exmateria_sound/bin/`. It is one of the two below.

### What a broken install looks like

Both failures are GDScript **parse** errors — a missing dependency is not
recoverable at run time, so there is no partial fallback and no music-only
degradation. Re-measured 2026-08-27 on stock Godot 4.5, on the published tree,
with the same `can_instantiate()` census the healthy-install row below uses.
(The counts here previously read 15 and 18; both came from an instrument this
document never named, and neither survived being re-run.)

**1. You installed this addon without `exmateria_spu`.** 11 of the 153 scripts
fail, `runtime/smd_player.gd` among them, so the music path is gone:

```
SCRIPT ERROR: Parse Error: Preload file "res://addons/exmateria_spu/runtime/spu.gd" does not exist.
SCRIPT ERROR: Parse Error: Identifier "ExMateriaSpuStream" not declared in the current scope.
```

Fix: unzip `exmateria_spu` beside it. Since `#383` this addon reaches the SPU by
**path**, not by global name, so the first line names the missing file outright
instead of a vanished identifier. `ExMateriaSpuStream` is still an identifier
because it is a GDExtension class, and ClassDB has no path to name.

**2. You have both folders, but `addons/exmateria_spu/bin/` is empty.** This is
what a `git clone` gives you — `bin/` is gitignored, so a clone is *source*, not
an install. 5 files fail across the two addons — `smd_player.gd`,
`effect_sfx_engine.gd`, and three of the SPU addon's own — and the first line
names the cause:

```
ERROR: GDExtension dynamic library not found: 'res://addons/exmateria_spu/exmateria_spu.gdextension'.
SCRIPT ERROR: Parse Error: Identifier "ExMateriaPsxSpu" not declared in the current scope.
```

Fix: install from a release ZIP, or build the library yourself — see
[Building](../exmateria_spu/README.md#building) in the SPU addon's README, which
is where the build lives.

### A healthy install

Both folders present, the SPU library built or unzipped:

| | |
|---|---|
| `addons/exmateria_sound` | 155 of 155 scripts load |
| `addons/exmateria_spu` | 8 of 8 scripts load |
| registered | `ExMateriaPsxSpu`, `ExMateriaSpuStream`, `ExMateriaSpuAdpcm` |
| **not** registered | `FFTSmdSequencerNative` |

That last row is deliberate rather than missing. The C++ SMD sequencer is a
monorepo-only development accelerator; its `.gdextension` is withheld from the
published tree, so `runtime/sequencer.gd` finds no such class and runs its
GDScript driver — which is the path the reference game has always used, because
the native one never received the end-of-note release-rate force and clicks on
retrigger.

### Platforms

`addons/exmateria_spu/exmateria_spu.gdextension` is the descriptor that matters,
and what it *declares* is ahead of what has been *run*:

| target | declared | ever built | run on hardware |
|---|---|---|---|
| Linux x86_64 | yes | **yes**, locally and in the `v0.1.1` release | **yes** — stock Godot 4.5 and 4.7 |
| Linux arm64 | yes | no. A matrix row exists; no release has used it | no |
| Windows x86_64 | yes | in `v0.1.1`, from source that has since changed — see below | no |
| Windows arm64 | yes | no, and **no matrix row would** | no |
| macOS | yes, as a `.framework` | no, and **the build emits a `.dylib`** | no |

"Ever built" is the honest column and it is mostly empty, for one reason worth
stating plainly: **the two-addon release workflow has never run.** The only
release that exists is `v0.1.1`, from before the split. Its matrix produced
Linux x86_64 and Windows x86_64 and nothing else, so every other row below is a
declaration waiting on a tag.

Three rows are claims about things that do not work, and they are in the table
rather than left out:

- **macOS cannot load.** The descriptor names
  `libexmateria_spu.macos.template_debug.framework`; `SConstruct` calls
  `env.SharedLibrary()`, which on macOS produces a `.dylib`. The declared path
  will not exist.
- **Windows arm64 cannot be produced.** The release matrix is Linux x86_64,
  Linux arm64, Windows x86_64 and macOS. Nothing builds a Windows arm64 DLL, so
  those two declared entries have no possible file behind them.
- **The Windows x86_64 build is unverified against the current source.** DLLs
  did ship in `v0.1.1`, but the vendored PSX ADPCM encoder landed three months
  after that release, and it *throws* — while godot-cpp disables exceptions on
  MSVC with `_HAS_EXCEPTIONS=0`, a preprocessor switch no `/EH` flag undoes.
  `SConstruct` strips that define back out for the one vendored translation
  unit, and **no build has yet exercised it**. Treat Windows as untested until a
  release proves otherwise.

### Godot version

`compatibility_minimum` is **`4.4`** on both addons, and the release workflow
builds against godot-cpp `godot-4.4-stable`. Build against the godot-cpp branch
matching the **oldest** Godot you intend to support: a library built against
godot-cpp 4.5 will not load in Godot 4.4, and says so as
`Attempt to get non-existent interface function: get_godot_version2` rather than
anything mentioning versions.

## Try it first

`addons/exmateria_sound/demo/demo.tscn` runs straight away. When it can find an
extracted disc tree it lists the `MUSIC_nn.SMD` sequences it found and plays the
one you pick. When it cannot, it says which of the three resolution routes below
it tried, what each one yielded, which routes were never consulted because an
earlier one answered, and the name of the file it wanted — rather than "could
not load assets", which is a shrug rather than a message.

Either way it points at `addons/exmateria_spu/demo/demo.tscn`, the generic SPU
demo, which synthesises everything it plays and needs no assets at all. If you
have no disc, start there — it is the half of this project that needs nothing
from you.

## FFT assets — what you have to supply

**This addon ships no game data, and none of it can be downloaded.** You need a
personally extracted PSX disc. Specifically:

| you need | for |
|---|---|
| `SOUND/WAVESET.WD` | the instrument bank. Nothing plays without it |
| `SOUND/MUSIC_nn.SMD` | one sequence per track |
| `EFFECT/` + parsed per-effect artifacts | battle SFX only — and see [Effect SFX](#effect-sfx) |

`exmateria_spu` needs **none** of this. If you only want a PSX SPU, you are in
the wrong README.

`ExMateriaSound.AssetPaths` resolves the tree, in this order:

1. `EXMATERIA_ASSETS_DIR`, if set — points at the extracted tree.
2. The standard exmateria data dir: `$XDG_DATA_HOME/exmateria/assets`
   (Linux/BSD, falling back to `~/.local/share/exmateria/assets`),
   `~/Library/Application Support/exmateria/assets` (macOS),
   `%APPDATA%\exmateria\assets` (Windows). Route 2 only answers if a `SOUND/`
   subdirectory is actually there.
3. Walking up from the project directory for `project-assets/fft-extract/` —
   the monorepo development layout.

Every `ExMateriaSound.AssetPaths` call also takes explicit paths, so you can ignore all three.

## Public API

### The supported surface

**One global name, `ExMateriaSound`, and fifteen constants on it.** A script
constant is a full type: it works as an annotation, in an `is` check and for
`.new()`. Everything else in this addon is internal, whatever its visibility
says — and since `#383` that is enforced rather than asked for.

| | |
|---|---|
| `ExMateriaSound.SMDPlayer` | music playback. A `Node`; `add_child()` it |
| `ExMateriaSound.AssetPaths` | resolve an extracted disc tree |
| `ExMateriaSound.WavesetParser` · `ExMateriaSound.SMDParser` · `ExMateriaSound.FedsBank` | the file formats |
| `ExMateriaSound.Sequencer` · `ExMateriaSound.SoundOpcodes` · `ExMateriaSound.PitchTable` · `ExMateriaSound.Trackset` | the sequencing layer |
| `ExMateriaSound.EffectSoundController` · `ExMateriaSound.EffectSoundResolver` · `ExMateriaSound.EffectJSONLoader` · `ExMateriaSound.EffectPlaySound` | the effect-SFX layer |
| `ExMateriaSound.SharedDispatcher` | the opcode VM's entry point |
| `ExMateriaSound.SpuAudioDebugPanel` | an optional in-game diagnostics panel |

`ExMateriaSound` also re-exports the SPU addon's three: `ExMateriaSound.Spu`,
`.Sample` and `.ADSR` are the same scripts `ExMateriaSpu` names.

> **This table used to carry a warning, and the warning is what got fixed.** It
> read: *"'Private' is not yet enforced. This addon currently declares 148
> global `class_name`s; the fifteen above are the supported ones. The other 133
> are in your project's global namespace today and will collide with anything
> you name `Runtime`, `Sequencer` or `SharedOpDetune`."* It declares **one**
> now. The collision was never hypothetical: when your `class_name` wins the
> global cache, it is the ADDON's file that fails to parse, so the error points
> at a file you did not write.

`ExMateriaSpu` — and `ExMateriaSpu.Spu`, `.Sample` and `.ADSR` hanging off it —
plus the GDExtension's `ExMateriaSpuStream`, `ExMateriaPsxSpu` and
`ExMateriaSpuAdpcm` belong to `exmateria_spu` and are documented in
[its README](../exmateria_spu/README.md).

### Music playback — works standalone

```gdscript
var player := ExMateriaSound.SMDPlayer.new()
add_child(player)
player.load_waveset(ExMateriaSound.AssetPaths.default_waveset_path())   # SOUND/WAVESET.WD
player.load_smd(ExMateriaSound.AssetPaths.default_smd_path(31))         # SOUND/MUSIC_31.SMD
player.play_music()
```

`load_waveset` and `load_smd` return `bool`, and both must succeed before
`play_music()`. Also on `ExMateriaSound.SMDPlayer`: `stop_music()`, `is_playing()`,
`load_feds_pair()`, `attach_shared_engine()`, and the `playback_finished` and
`debug_stats_updated` signals.

### Effect SFX

**This path is not usable from the addon alone**, for two independent reasons,
and both have to be dealt with:

1. **The artifacts are not published.** It consumes a per-effect directory
   holding `sound_containers.json`, `sound.json`, `timeline.json` and
   `feds.bin`, produced by the monorepo's parsers
   (`godot-learning/tools/parse_all_feds.py` and friends). Without them,
   `ExMateriaSound.EffectJSONLoader.load_dir` returns an empty `LoadedEffect` and `has_sound()`
   is `false`.
2. **`ExMateriaEffectSfx` is an autoload, and enabling the plugin adds it.**
   Since `#383` `plugin.gd` registers two, in this order —
   `ExMateriaAudioEngine` (the shared waveset and the SPUs) then
   `ExMateriaEffectSfx` (the always-on SFX driver), which looks the first up at
   `/root/ExMateriaAudioEngine` and `push_error`s if it is absent or not ready.
   The names carry the prefix because they are the addon's, not yours: it used
   to be *you* who named them and *this addon* that hardcoded whatever you
   picked. Declare them yourself if you want to control autoload order — under
   these names. The `ExMateriaSound.EffectSoundController` example below needs
   neither autoload; the full `ExMateriaEffectSfx` path needs both.

Given such a directory, the shape is:

```gdscript
extends Node

var player: ExMateriaSound.SMDPlayer            # add_child()-ed elsewhere; ExMateriaSound.SMDPlayer IS a Node
var controller: ExMateriaSound.EffectSoundController
var feds_path: String
var frame: int = 0

func play_effect(effect_dir: String, target_count: int) -> bool:
    var loaded := ExMateriaSound.EffectJSONLoader.load_dir(effect_dir)
    if not loaded.has_sound():
        return false
    feds_path = effect_dir.path_join("feds.bin")

    # ExMateriaSound.EffectSoundController is RefCounted, NOT a Node — never add_child() it.
    controller = ExMateriaSound.EffectSoundController.new()
    if not controller.load_effect(loaded):
        return false
    controller.pair_triggered.connect(_on_pair_triggered)
    controller.finished.connect(_on_finished)
    controller.start(target_count)   # target_count = units this cast hits
    frame = 0
    return true

# Drive it at 30 Hz from your own clock — the addon owns no timer.
func tick() -> void:
    controller.update(frame, controller.fire_sub_tick)
    frame += 1

func _on_pair_triggered(pair_idx: int, _from_channel: int,
                        _sound_id: int, _from_phase: String) -> void:
    if player.load_feds_pair(feds_path, pair_idx):
        player.play_music()

func _on_finished() -> void:
    controller = null
```

`ExMateriaSound.EffectSoundController.is_finished()` reports completion; `finished` fires
alongside it.

**Known limitation:** one `ExMateriaSound.Sequencer` is live at a time on this path, so a
second `pair_triggered` replaces the first. Effects that fire sounds with gaps
(E001 Cure) are fine; dense effects (E019 Fire 4) lose triggers. The
`ExMateriaEffectSfx` path does not have this limitation — it gives each concurrent
sound its own SPU — which is the other reason it exists.

### Sound resolution

`ExMateriaSound.EffectSoundResolver` maps a timeline `sound_id` to a `feds` pair index through
the per-effect mode containers. `ExMateriaSound.EffectSoundController` builds and drives one
internally — you rarely need your own:

```gdscript
func pair_for(effect_dir: String, container_idx: int, timeline_sound_id: int) -> int:
    var loaded := ExMateriaSound.EffectJSONLoader.load_dir(effect_dir)
    # from_sound_containers has no declared return type, so `:=` cannot infer one.
    var resolver = ExMateriaSound.EffectSoundResolver.from_sound_containers(loaded.sound_containers)
    return resolver.resolve(container_idx, timeline_sound_id)
```

### Audio buses

The addon plays on **named** Godot buses instead of putting everything on
`Master`:

| stream | bus | constant |
|---|---|---|
| `.SMD` music (`ExMateriaSound.SMDPlayer`) | `Music` | `ExMateriaSound.SMDPlayer.OUTPUT_BUS` |
| effect SFX (`ExMateriaEffectSfx`) | `SFX` | `ExMateriaEffectSfx.OUTPUT_BUS` |
| ambient beds (`ExMateriaEffectSfx.begin_bg`) | `Ambient` | `ExMateriaEffectSfx.BG_OUTPUT_BUS` |

**You do not have to declare those buses.** Godot's `AudioStreamPlayer.bus`
getter resolves an unknown bus name to `Master`, so an untouched project sounds
exactly as it did before — naming them only *offers* you the split. To take it,
add an `AudioBusLayout` (Godot's **Audio** bottom panel) with `Music` and `SFX`
sending to `Master`, and point
`Project Settings → Audio → Buses → Default Bus Layout` at it; then your own
mixer ducks the score without touching the SFX, and vice versa.

The addon puts **no effects on those buses** and leaves them at unity — they are
routing, not processing. Any limiting or master gain is yours to place.

**Place something.** One SPU renders each concurrent sound and Godot sums them
in float on the bus, so nothing clips at the sum — but nothing bounds it either,
and the level a busy scene reaches is higher than you might expect. Measured on
the reference game with a *mid-size* effect (one that peaks at 0.69 played
alone), the `SFX` bus carries:

| concurrent sounds | 1 | 2 | 3 | 4 | 6 |
|---|---|---|---|---|---|
| bus peak | 0.69 | 1.42 | 2.13 | 2.84 | 4.26 |

A limiter on `Master` alone will therefore duck your **music** by up to 12.6 dB
whenever combat gets busy. The reference host puts an `AudioEffectHardLimiter`
at a **0 dB** ceiling on each of `Music`, `SFX` and `Ambient` — 0 dB so a lone
full-scale sound sits exactly *at* the ceiling and passes untouched — and keeps
a second one at −0.3 dB on `Master` as the device guard.

### How the SPU reaches Godot

Music **and** effect SFX both play through `ExMateriaSpuStream`, a native
`AudioStream` whose `_mix` renders the 24-voice SPU directly on the audio
thread. There is no ring buffer to keep fed: the GDScript driver stays in charge
— it decides which SPU registers to write and when — but it *stamps* each write
with the frame it belongs at and queues it ahead of the audio clock, and the
audio thread applies each write at exactly that frame on its way through the
block.

**One stream per SPU.** Music has one. Effect SFX has one per concurrent sound,
because each cast gets its own SPU — which is also the parity boundary: the PSX
has a single SPU, so summing several of them was never PSX-accurate, and the sum
belongs to Godot's bus mixer. A unit holding no live sound parks its stream,
which keeps its clock running but skips the mix entirely, so silent units cost
nothing.

**The scheduling lead differs by kind, and it is not an oversight:**

| path | lead | constant |
|---|---|---|
| music | 2.0 s | `ExMateriaSound.SMDPlayer.TARGET_LEAD_SECONDS` |
| effect SFX | 6 sub-ticks, ~25 ms | `ExMateriaEffectSfx.SCHED_LEAD_SUBS` |

A song has no responsiveness requirement, so music buys the largest margin it
can: at 2.0 s a scene load that blocks the main thread for over a second still
drops nothing. SFX cannot, because a cue stamped at frame F *sounds* at frame F
— for SFX the lead is the input latency. That is also why SFX keeps its own
scheduler thread rather than scheduling from `_process`: the reference game runs
at 15 fps, a 66 ms frame, longer than the whole SFX budget.

Why the stream is C++ and not GDScript: a GDScript `_mix` receives the output
buffer as a raw pointer marshalled to `TYPE_INT` and cannot write one sample
into it. `AudioStreamGenerator` + `push_buffer` is not a shortcut somebody took,
it is the only mechanism GDScript has.

For a host this changes nothing you have to act on. What you get is that a busy
main thread can no longer starve the music: the render is not on your thread any
more. The samples are unchanged, and that is checked rather than asserted —
`workspace/regression/stream_parity/` renders each song both ways and diffs them
sample for sample at five audio block sizes, with a deliberately mis-stamped arm
that must diverge.

## What you should NOT poke at

`runtime/effect_sound/`, `runtime/shared/` and `runtime/sequencer/` (dispatcher,
flush_tick, pool, opcode tables) are the internal opcode VM. Names mirror FFT
semantics on purpose, so that probe-driven debugging stays legible; that is not
an invitation. `debug/` is a diagnostics panel, not an API.

## License

GPL-3.0 —
[LICENSE](https://github.com/timbermania/ExMateria-Sound/blob/main/LICENSE).

The link is absolute on purpose. A relative one resolves inside a checkout of
the published repo and **not** inside your project, because the release ZIP
carries the two `addons/` folders and nothing above them.

The `exmateria_spu` addon beside this one also contains MIT-licensed
third-party code — the PSX ADPCM encoder — and its notice ships with it, at
`addons/exmateria_spu/NOTICE`.

## Source

Developed in the `timbermania/ExMateria-Sound` repo (this repo). For the SPU C++
core only, with no Godot addon around it, see
[`timbermania/ExMateria-SPU-Core`](https://github.com/timbermania/ExMateria-SPU-Core).
