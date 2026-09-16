# Effects installation — selected native GL foundation

## Scope and provenance

Installed from `timbermania/fft-monorepo` commit
`7f140717604a7906cfaf03bd9556a34d6800ccce`, against target baseline
`3a9cdffc128fbe9caa13ba8fa3b9cb721bc647b6`. This is **installation and
configuration only**, not gameplay integration, full addon support, fold parity,
or release approval. The host remains official Godot **4.7.2 GL Compatibility**.

`tools/effects/manifest.json` records each exact source/destination, full revision,
SHA-256, byte count and selection role. Its hash and profile contract are locked
in `tools/effects/upstream.json`. All **241 files / 993,824 bytes** were extracted
with `git show <pin>:<source>` and verified before installation; no upstream
working-tree bytes were copied. The selection contains 71 Effects, 17 platform,
22 schema and 4 render source/resource files (114 total), plus 115 committed UID
sidecars and 12 README/plugin metadata files. One schema header,
`colour_model/color_stack.gdshaderinc`, is deliberately retained for the future
host receiving-shader contract; the other 113 files form the facade/autoload
resource closure. Lazy optional resource names and their bytes remain intact.

**This pin is the first one the install model could actually reach.** The previous
pin's Effects package declared `exmateria_almanac` in `deps=` and read it from
`cast/EffectManager.gd`, and two of that package's files —
`abilities/AbilityDatabase.gd` and `abilities/AbilityView.gd` — are gitignored
ROM-derived sources whose façade hard-preloads them. Because this installer obtains
bytes only through `git show <rev>:<path>`, **no revision could supply them**, so
pulling `EffectManager` into the closure was structurally impossible rather than
merely undesirable. Upstream ADR-0364 cut that edge: the ability lookup is now a
host capability on the existing `CastHost` contract, and `deps=` reads
`exmateria_platform exmateria_render exmateria_schema` — all three already here.
The selection consequently gains `cast/EffectManager.gd`, `install/CastHost.gd`
and `cast/AbilityVisual.gd`, which is why the façade export count moves below.

No almanac, battlefield, upstream host/game/editor assets, BIN tooling, ROM data
or extracted content was added. The selected packages' original README/plugin
files describe a broader installation and still truthfully declare `engine="fork"`;
this document governs the narrower host profile. Do not enable those plugins or
copy their entire packages to follow their full-install instructions.

**Audio is unchanged:** both existing addon trees, all four native libraries,
receipts, source inputs, dependency lock, deferred readiness, audition, cache and
shutdown behavior are preserved. See [audio-installation.md](audio-installation.md)
for their independent pins, APIs, historical results and outstanding risks.
No new native Effects library, audio refresh, bank initialization or download occurs.

## Explicit configuration

The host adds only these autoloads, after the existing audio autoloads:

- `EffectMultiMeshPool`: `addons/exmateria_effects/render/EffectMultiMeshPool.gd`
- `ScreenEffectOverlay`: `addons/exmateria_effects/overlay/ScreenEffectOverlay.gd`
- `TintedSurfaces`: `addons/exmateria_effects/overlay/TintedSurfaces.gd`

`pixel_aspect`, `psx_fx_stretch` and `psx_cursor_stretch` are float shader globals
with value `1.0`, declared before cold import. The last declaration shares an
include with FX stretch; it does not install cursor behavior. Other Platform
plugin globals are not required by this selection. Existing project settings,
plugins, GL renderer, main scene and ApplicationShutdown order are retained.
No new plugin, PSXDisplay, CompositorAutopilot or production compositor setup is enabled.

The public `ExMateriaEffects` facade now carries **24 exports**, re-counted rather
than carried over: the previous pin's 21 plus `EffectManager`, `CastHost` and
`AbilityVisual`, which the almanac cut made obtainable. It still imports no host
Battlefield. The project **does not yet request visual playback**. A future owning playback scene must create one
`ExMateriaEffects.EngineFoldCompositor`, add it to the tree, then check
`setup_native(in_tree_camera)` succeeds before playback. Keep that producer and
camera alive for the cast. Do not call default fold `setup()` on stock Godot.
Only the synthetic test currently exercises the native setup seam.

### Unsupported optional fork resources

Stock Godot cannot instantiate `CompositorRenderLayer` from schema's
`compositing_key/fold_layer.tres`. The three `effect_fold_*.gdshader` resources and
`callbacks/effect_callback_fold.gdshader` reject `compositor_layer` when bound.
They are retained unchanged: cold import/preloading them is not compilation or
full fork support. `setup_native()` avoids their binding and does not construct
FoldSurface's RenderingDevice bracket. Full plugin/editor-preview/export paths
may reach them; these paths are **not certified** by this installation.

### Pending host work (not part of this pass)

- Explicit private content root and `effects/E###`, callback payload and TRAP
  texture/table layout; no content search, importer or root setting was invented.
  **Partly done for TRAP only.** `src/battle/effects_demo_scene.tscn` declares a
  content root at runtime and plays real TRAP handlers, which needs only the ten
  `effects/trap/*.json` tables and `TRAP1.tga`/`TRAP1.palette.tga` (~660 KB) — NOT
  the 224 MB of per-effect `E###` directories that spell and cinematic casts need.
  Copy those from the monorepo's `godot-learning/assets/` into a gitignored
  `content/` (`content/effects/trap/`, `content/sprites/textures/`) and run the
  scene. The addon loads the textures with `load()`, i.e. `ResourceLoader`, so the
  content must live under `res://` and be imported — an absolute or external path
  will not work.
- Ability/action-to-visual routing, real timelines, callbacks/TRAP and timing.
- ~~Owning scene/camera lifecycle and checked native setup before real playback.~~
  **Done** — `src/battle/effects_playback.gd` owns the producer/host/manager for one
  battle and checks `setup_native(in_tree_camera)`; `src/battle/effects_cast_host.gd`
  implements the `CastHost` contract (roster, arena bounds, ability visuals). Both are
  **opt-in**: `enabled` is false by default, so this COEXISTS with the project's own
  VFX rather than replacing it. See `docs/adr/0003-*.md`. Content provisioning and the
  routing at the real call sites are still open — see the remaining items here.
- Terrain-column callable (`{exists, world_y}` at floored world X/Z), unit
  layer-4/SelectionArea occlusion and cinematic camera/framing adapters.
- Receiving map/unit tint registrations and compatible depth/tint shaders.
  **Shared map/unit/legacy depth shader edits require separate approval.**
- Gameplay audio/timing integration and content-loaded lifecycle validation.

No action, content importer, camera, tint, audio integration, legacy removal or
shared host shader change is implemented here. Accepted GL blend appearance
differences do not excuse missing effects, shader failures or gameplay regressions.

## Reproducible verification

```sh
# No network, dependency build/materialization, Godot import or writes:
python tools/effects/verify_installation.py
# Additionally compare every input and GPL text against pinned Git objects:
python tools/effects/verify_installation.py --upstream /path/to/fft-monorepo
python -m unittest discover -s tools/effects -p 'test_*.py'
python -m unittest discover -s tools/audio -p 'test_packaging.py'
python -m unittest discover -s tools/audio -p 'test_dependency.py'

# Linux x86_64, real display and exact pinned official 4.7.2 executable:
python tools/effects/run_checks.py --godot /path/to/Godot_v4.7.2-stable_linux.x86_64
```

The static verifier checks the full file inventory/hashes, retained GPL text,
explicit autoloads, nonzero globals and native GL/no-new-plugin configuration.
CLI/root checks tolerate only Godot's generated `.import` sidecars for the two
selected GLSL files; source staging excludes those sidecars and enforces the exact
241-file inventory. No generated cache or metadata is deleted or rewritten.
Optional Git verification is read-only and never trusts a modified upstream tree.
Engine executable SHA-256, version, release archive URL and SHA-512 are recorded
in the lock. The archive was matched against official release sums and the
executable against its ZIP member; this is HTTPS release provenance, not an
independently signed trust chain. Other executable hashes/platforms are rejected
by this bounded Linux runner rather than silently claimed equivalent.

The headful runner copies the explicit public-source allowlist to a fresh
system temporary directory. It cold-imports the **full host**, runs existing host
regressions, and starts the unchanged real main scene with a test-only exit
observer. That observer checks idle audio/native registration and the Effects
autoloads, then requests the existing graceful shutdown. A separate empty-cache
minimal native project preserves the synthetic compatibility probe: 24 exports,
checked native setup, 64 pool slots, visible mix/add/sub/add25 carriers, callback
triangle, all 28 registered callback IDs, framebuffer contributions, slot return
and drained shutdown. It repeats the runtime once with warm caches.

HOME, XDG data/config/cache and NVIDIA/Mesa shader cache paths are isolated;
DISPLAY and runtime audio/display connections are retained. The checkout's
`.godot` and normal userdata are never opened. Only a timed-out child owned by
the runner can be terminated (180-second limit). Logs/JSON metrics and a synthetic
screenshot remain in a **new** `.build/effects-check-logs` directory (or `--logs`);
staging/userdata are discarded. Each process records original exit, timeout,
wall time and 50-ms sampled peak RSS, not an exact high-water or gameplay benchmark.
Nonzero exits, errors/shader errors, leaked-instance/resource diagnostics, failed
assertions and missing success markers fail the runner even if Godot exits zero.
Existing non-error warnings and verbose unclaimed StringNames are retained rather
than hidden. No private data or live audio is used. The existing host regression
retains its 120-frame safety cap; actual main-scene and native checks self-exit
through ApplicationShutdown without a CLI quit shortcut.

### Checked installation results

Official `4.7.2.stable.official.ed1daf0bf`, NVIDIA OpenGL 3.3 Compatibility:

| Run | Exit / strict result | Seconds | Peak sampled RSS KiB |
| --- | --- | ---: | ---: |
| Full host cold import | 0 / PASS | 5.922 | 1,272,556 |
| Existing host regression | 0 / PASS | 1.606 | 304,984 |
| Real main scene / graceful startup | 0 / PASS | 2.458 | 347,840 |
| Native fixture cold import | 0 / PASS | 4.969 | 1,170,804 |
| Native pool/callback/framebuffer / graceful exit | 0 / PASS | 1.907 | 322,884 |
| Native warm repeat | 0 / PASS | 1.506 | 256,148 |

13 packaging, 10 dependency and 5 Effects tool regressions also passed without
network or native compilation. No error/shader-error/ObjectDB-leak/resource-in-use
diagnostics occurred in the positive engine runs. Host cold import retains
warnings for the two preexisting ignored editor plugins (Todo_Manager/script-ide)
absent from the public allowlist, plus a scan-thread-aborted warning; Godot removes
those two enabled entries only in its isolated staged copy. Actual target plugin
settings are untouched. Host regression intentionally diagnoses malformed path
configuration. Verbose shutdown records 48 host / 11 native unclaimed StringNames;
this is not a zero-bookkeeping-residue claim. Initial run evidence is under
`/tmp/tacticsg-effects-installation-checks/` on the validation workstation; rerun
the command above for independently reproducible logs, not that temporary path.

This only establishes the measured native synthetic boundary and content-free
host startup. It does not establish PSX color correctness, real callback/timeline
behavior, terrain/unit occlusion, full receiving tint, active mixer behavior,
Windows/Wine, exported-game support, visual parity or release readiness.

## Source delivery and licensing

The existing combined GPL-3.0 source-delivery policy in
`docs/audio-installation.md` remains in force, now including the selected Effects
and shared packages. Original MIT grants and all prior third-party notices remain.
Upstream root LICENSE exactly matches the existing `LICENSES/GPL-3.0.txt`;
`THIRD_PARTY_NOTICES.txt` records the new pin and bounded selection.

The explicit `tools/audio/distribution-files.txt` allowlist includes all 241
inputs and Effects verification/docs/tests/lock. Source staging rejects missing,
altered or symlinked allowlisted inputs, extra Effects files in the staged tree,
and incorrect native-profile settings, alongside the existing native receipt and
private-format checks. Non-allowlisted checkout files are omitted from staging;
root verification separately rejects extra checkout files and symlinks. Full paired
source archives contain these sources and the materialized pinned godot-cpp tree;
the audio-only installer ZIP remains audio-only and is **not an Effects installer**.
No separate Effects binary bundle or replacement native-only source process was
introduced. Packaging tests use synthetic dependency fixtures offline and are not
a new release build. Do not distribute bare Godot exports or partial/QA-blocked
artifacts; no release/export approval follows from this foundation.
