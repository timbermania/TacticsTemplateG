# Architecture — ExMateria-Sound

The package is layered. Knowing which layer you're in tells you which
language, where the file lives, whether it ships to a downstream game,
and what kind of change is appropriate.

```
┌─────────────────────────────────────────────────────────────────┐
│ L3 — Parity workspace                                           │
│   probes • orchestrator • render harness • diff/score tools     │
│   GDScript + Python + Lua                                       │
│   Lives in:  workspace/                                         │
│   Ships:     in the public ExMateria-Sound repo as reference;   │
│              NOT consumed by a game.                            │
└─────────────────────────────────────────────────────────────────┘
                       ▲  drives / validates
                       │
┌─────────────────────────────────────────────────────────────────┐
│ L2 — Runtime glue (the addon's GDScript surface)                │
│   opcode VM • sequencer dispatch • channel/slot state •         │
│   sound-track controller • parsers • tables                     │
│   GDScript                                                      │
│   Lives in:  addons/exmateria_sound/runtime/                    │
│              addons/exmateria_spu/runtime/                      │
│                (spu.gd, spu_sample.gd, ADSR)                    │
│   Ships:     YES (consumed by a game)                           │
└─────────────────────────────────────────────────────────────────┘
                       ▲  calls
                       │
┌─────────────────────────────────────────────────────────────────┐
│ L1 — Native core (SPU + sequencer core)                         │
│   SPU mixer • reverb • ADSR • pitch • sample/voice runtime •    │
│   sequencer-core • PSX ADPCM encoder (vendored, MIT)            │
│   C++ (src/native binding + src/shared portable core            │
│        + src/vendor third-party copies)                         │
│   Build artifacts:                                              │
│     addons/exmateria_spu/bin/libexmateria_spu.*   SHIPS          │
│     addons/exmateria_sound/bin/libfftsmd.*        monorepo-only  │
│   The seam is D1 (#374) dec. 5, held as two disjoint file       │
│   lists in SConstruct. libfftsmd carries FFTSmdSequencerNative   │
│   and statically re-links the SPU sources, because that class    │
│   embeds FFTSpuCoreRuntime by value and a plain struct has no    │
│   ClassDB identity to share across a GDExtension boundary.       │
│   Also published separately as ExMateria-SPU-Core (the C++      │
│   portable core only) for the DAW plugin's consumption.         │
└─────────────────────────────────────────────────────────────────┘
```

## FFT-driver logic vs PCSX-hardware logic

The layer model above captures *language* and *deployment*, but there's
a second axis that matters for *where logic belongs*:

- **FFT side** — the game's music driver. SMD bytecode interpreter,
  per-channel state, per-tick handlers, LFO state machine, walker,
  flush_tick, entity LL, opcode handlers. This is FFT-specific code
  modeling FFT's MIPS-side logic.
- **PCSX side** — the PSX SPU hardware itself. Voice register file,
  ADSR envelope ticking, sample interpolation, ADPCM decoding, reverb,
  PSX pitch table (raw_pitch → sinc). Hardware modeling.

**Game (Godot) deployment** keeps the split clean:
- FFT-side lives in GDScript (`runtime/sequencer/`, `runtime/shared/`,
  `runtime/effect_sound/`, `runtime/music/`). Music and SFX share the
  same per-tick engine (`runtime/shared/per_tick/advance_lfo.gd`,
  `flush_tick.gd`, `spu_irq_walker.gd`).
- PCSX-side lives in C++ (`src/shared/fft_spu_*`, `src/native/`).
  Compiled to `libexmateria_spu.*`.

  The `fft_` filename prefixes and the disassembly citations in
  `src/shared/` are PROVENANCE and stay. `B2`'s "no reference to FFT"
  clause binds the **installed tree** — `addons/exmateria_spu/` and every
  identifier it publishes (ClassDB names, entry symbol, library filename)
  — not the monorepo source, which is not in any release ZIP and which
  `fft-sound-driver/src/shared/` mirrors byte for byte.

- Third-party C++ lives in `src/vendor/`, one directory per upstream
  project, copied VERBATIM — a diff against upstream must come back
  empty, and anything we need to change goes in a wrapper under
  `src/native/`. Today that is PCSX-Redux's MIT-licensed PSX ADPCM
  encoder, behind `ExMateriaSpu.Sample.from_pcm16()` (`D7` #380 dec. 5).
  Only the SPU library links it; `src/vendor/README.md` records the
  provenance and `addons/exmateria_spu/NOTICE` carries the licence into
  the ZIP, which is the only artifact most users ever see.

**DAW (VST3) deployment** has no GDScript runtime, so it gets a
**separate** C++ FFT-driver port:
- `src/shared/fft_smd_sequencer_core.cpp` + `fft_spu_lfo_tools.cpp`
  (`fft_tick_pitch_lfo` and friends) are the DAW's port of the FFT
  music driver. They sit in `src/shared/` today; long-term goal is to
  extract them into `fft-plugin/` itself so `src/shared/` becomes
  purely PCSX-hardware code.
- The two FFT-driver implementations (GDScript for game, C++ for DAW)
  produce the same audio for the same SMD input — both implement FFT's
  `LAB_80017690` / `LAB_80017744` / `FUN_80014590` / `FUN_80017118`
  faithfully. They're parallel implementations driven by the DAW's
  no-GDScript constraint, not tech debt.

The `_use_native_core` opt-in mode (set via `Sequencer.set_use_native_
core(true)`) lets Godot music run through the C++ sequencer instead of
the GDScript one — useful for cross-checking the two implementations
match. Default for Godot is GDScript.

## What ships where

| Public artifact | Source root | Layers | Notes |
|----|----|----|----|
| **ExMateria-Sound** (`timbermania/ExMateria-Sound`) | `exmateria-sound/` | L1 + L2 + L3 | One repo, **two** addon folders, **two** release ZIPs. `exmateria_sound-vX.Y.Z.zip` vendors `addons/exmateria_spu/` inside it, byte-identical to the standalone `exmateria_spu-vX.Y.Z.zip` — CI diffs them before publishing. |
| **ExMateria-SPU-Core** (`timbermania/ExMateria-SPU-Core`) | `exmateria-sound/src/shared/` | L1 portable core only | C++ headers + .cpp. Published on its own; **no longer vendored by the DAW plugin** (#607). |
| **ExMateria-DAW-Plugin** (`timbermania/ExMateria-DAW-Plugin`) | `fft-plugin/` (+ vendored `fft-sound-driver`) | DAW-only C++ | Links the `fft::sound_driver` target; the publish manifest stages `fft-sound-driver/` into `vendor/fft-sound-driver/`, which is the path `fft-plugin/CMakeLists.txt` falls back to outside the monorepo (#620). Currently music-only; effect-sound L2 has no C++ analog yet. |

## The addon contract — what a game consumes

A downstream game (e.g. `godot_learning/`) pulls in **both** addon
folders — `exmateria_sound` names the global `Spu` in 11 files, and a
missing global `class_name` is a GDScript *parse* error, so half an
install is a cascade no guard can intercept. That is why the Sound ZIP
vendors the SPU one. The public surface:

- `AssetPaths.configure(sound_dir, effect_dir, parsed_effect_dir)` — or
  rely on `EXMATERIA_ASSETS_DIR` env. See `runtime/asset_paths.gd`.
- `SoundTrackController` — primary scene-level driver.
- `SMDPlayer` — music playback in isolation.
- `EffectSoundResolver` — `sound_id → bank` lookup.
- The native classes registered by `exmateria_spu.gdextension` (read-only
  in 99% of game code).

Everything under `runtime/effect_sound/` is internal. Game code does
not poke at `dispatcher.gd`, `flush_tick.gd`, `pool.gd`, etc.

## What the workspace is for

`workspace/` is L3 — the parity rig. It exists because every change to
L2 has to be rooted in either FFT disassembly or a PCSX-Redux capture
divergence. The workspace provides:

- **Probes** (Lua loaded into PCSX-Redux) that capture runtime state at
  exact instrumented breakpoints.
- **Orchestrator** (Python) that drives PCSX, loads probes, captures
  WAVs + JSONL traces, renders the Godot side end-to-end, and scores
  the diff.
- **Harness** (GDScript) that drives the addon's runtime under
  reproducible conditions, with the same `cadence` clock PCSX uses, so
  per-voice traces line up.
- **Diff / score tools** (Python) that compare PCSX vs Godot row by row.
- **Architecture map** (`workspace/ARCHITECTURE_MAP.md`) that pairs
  every FFT disassembly entity with its Godot analog. This is the
  source of truth for any "what does X correspond to" question and
  must stay co-located with the harness — the harness work is built
  on top of it.

A game does not need any of this to ship. The workspace exists to
make the addon trustworthy.

## Asset injection

`runtime/asset_paths.gd` resolves the FFT-extract tree without baking
in any user-specific path. Resolution order:

1. `EXMATERIA_ASSETS_DIR` env var.
2. Standard exmateria data dir (XDG / AppData / macOS Library).
3. Walk up for `project-assets/fft-extract/` (monorepo dev fallback).

The repo never assumes one specific machine layout — `AssetPaths` is
the only place that knows. Same code ships to a game; same code is
used by the workspace harness.

## Disassembly addresses, not line numbers

Cite Ghidra exports by **address**: `0x80015874`, `FUN_80017118`,
`ram:80029060`. Line numbers in `*_disassembly.txt` drift across
regenerations.

Exports live under `project-assets/fft-rom/`:
- SCUS covers `0x80010000 – 0x80066FFF`
- BATTLE.BIN covers `0x80067800+`

Regenerate via `fft-ghidra/tools/export_ghidra_text.sh`.

## Native build (L1)

SCons-driven from `exmateria-sound/`. Requires the `extern/godot-cpp`
submodule:

```bash
git submodule update --init exmateria-sound/extern/godot-cpp
cd exmateria-sound && scons platform=linux target=template_debug
# Windows: scons platform=windows target=template_debug
```

Output lands at `addons/exmateria_spu/bin/libexmateria_spu.*` and
`addons/exmateria_sound/bin/libfftsmd.*` (both gitignored). Each addon's
`.gdextension` points at its own.

Build against the godot-cpp branch matching the OLDEST Godot you support:
a 4.5-built library will not load in Godot 4.4, and reports
`Attempt to get non-existent interface function: get_godot_version2`
rather than anything about versions.

## Why the package is still called `exmateria-sound`

Historical misnomer — the package does effects too. The cost of
renaming (CLAUDE.md churn, external bookmarks, memory entries, etc.)
exceeds the value, so the directory stays as is. Scope is documented
in the README. The published *addon* is `exmateria_sound`, which
accurately reflects what it does.
