# Audio installation

## Upstream integration validation

Ported onto upstream `815d4b8` with its Godot 4.7 settings, lazy resource
loading, VFX MapData adapters and export options preserved. Official Godot
4.7.2 (archive verified against the official SHA-512 sums) passes Linux
content-free real-mixer smoke, isolated host regression/startup checks,
graceful shutdown checks, and disc/cache audition (ten lifetime/playback/close
cases). Seven packaging regressions pass, including rejection of obsolete/custom
export engines. Cache tests exercise upstream's real `index_data()` entrypoint,
including lazy gameplay indexing and tile mesh initialization. Native source,
four binaries and receipts are unchanged. Historical 4.6.1/Wine release results below do not establish current
exported-game, Windows, or real-content compatibility. No release is approved.

## Installed scope

`addons/exmateria_sound/` and `addons/exmateria_spu/` are real, self-contained
files captured from upstream commit `4ca5c30abdb8423931155d44dd38f9b4fa76cb0e`.
There is no dependency on a developer's monorepo checkout. The native SPU is
rebuilt from the recorded source inputs; the optional native SMD accelerator is absent.
The committed Linux/Windows x86_64 binaries work without downloading build
dependencies. Only native rebuilding or complete source packaging provisions
the pinned godot-cpp dependency; opening/running Godot never does.

The project retains upstream **Godot 4.7 / GL Compatibility**. Both plugins are enabled,
and `ExMateriaAudioEngine` precedes `ExMateriaEffectSfx` in the autoload list.
Missing user content is normal: neither autoload starts playback or allocates
SPUs/streams at boot. The SPU addon does not take over the audio device or change
ordinary WAV importing. Existing `Utilities.play_audio_one_shot` is unchanged.

**Not connected to gameplay:** ROM audio provisioning, music selection,
UI/game-event sound routing, or effects. The standalone audition scene below
now supports an explicit private raw-disc selection. Legacy VFX visual algorithms
are unchanged; existing quit paths use the graceful shutdown boundary. The host owns buses and volume policy; absent `Music`, `SFX`, or `Ambient` buses fall back to Master.
No new bus layout, gain boost, or limiter is installed in this phase.

## Deferred initialization

On the main thread, after autoloads enter the scene tree, supply privately
obtained WAVESET.WD bytes explicitly:

```gdscript
var bytes := FileAccess.get_file_as_bytes(private_waveset_path)
var result := ExMateriaAudioEngine.initialize_from_bytes(bytes)
if result != OK:
    # Report the content/setup failure in the host's UI.
    print("Audio initialization failed: ", error_string(result))
```

This installation does **not** make that call for the game. No automatic search,
project setting, hardcoded `res://assets/music/` path, or ROM extraction is used
by these autoloads. The standalone host audition scene can extract audio bytes
on explicit user selection, without calling the gameplay ROM loader. The upstream
demo's separate `AssetPaths` search remains available to developers; it does not configure autoload initialization.

The interface returns `OK` on success, `ERR_INVALID_DATA` for malformed/empty
input or banks exceeding the native SPU's `MAX_BANK_BYTES` capacity, `ERR_CANT_CREATE` for native instrument upload failure,
`ERR_UNCONFIGURED` outside the tree, or `ERR_UNAUTHORIZED` off the main thread.
Failures leave the engine idle and may be retried. Success sets `ready_ok` and
emits `initialized` once; the SFX autoload initializes in response. Consumers
should check both autoloads' `ready_ok` before playback.

Once ready, a further call returns `ERR_ALREADY_IN_USE`, even for identical
bytes. Live bank replacement is deliberately unsupported: audio threads own the
existing SPUs. Restart the application to choose another bank. Do not call
`_ready()` manually. The parser validates the descriptor area and sample spans
before allocating or reading descriptors. Engine initialization itself writes no private bytes.

Effect playback requires privately provisioned FEDS/effect artifacts. The host
now has the pair-audition scene below; timed effect/gameplay integration still
needs a later adapter. No second effect-schedule walker is installed.

## Real-content audition scene

Open `src/audio_test/audio_test.tscn` in the original project using official
Godot 4.7.2 and press **F6**. The main game scene is unchanged.

1. In the existing **External Data** setup, select your private disc and an
   export directory **outside this repository**, then export assets. New exports
   include audio under `<EXPORT_PATH>/sound/`. Import that directory (the existing
   `IMPORT_PATH` setting), then click **Load configured extracted-asset cache /
   initialize** in the audition scene. Old exports without audio need re-export.
2. Alternatively, browse to a private disc and click **Read audio catalog /
   initialize from disc**. This route is read-only; it neither writes the cache
   nor changes saved paths. The disc field initially shows configured `ROM_PATH`.
   Only raw **2352-byte Mode2/Form1 sectors with a 24-byte header and 2048-byte
   payload** are supported, not cooked 2048 ISO or other sector layouts.
3. Click **Game / System** or **Environment**, choose a **Sound ID**, then
   **Play selected sound**. These adjacent controls load global banks directly;
   unavailable banks are disabled with a reason in the tooltip/status. Global
   IDs retain original gain lookup: ID N maps to addon pair N-1, disabled holes
   are not renumbered, and single-channel entries play only their present channel.
   Nonempty global ID 0 remains diagnosed as unsupported. Pair-index and gain-ID
   spinboxes are no longer exposed for global sounds.
4. Choose music and **Play selected music**, or choose an effect and **Load
   selected effect sounds**. Effect loading replaces the sound choices above
   with zero-based pairs; these use the engine-default sound ID (-1). The manual
   WAVESET/SMD/FEDS file controls are removed. No full effect timeline is loaded.
5. Music and SFX can play together. **Stop SFX** releases the audition token;
   **Stop all** stops music and releases SFX. Release/reverb tails may remain.
6. Initialization is once per **application run**. Cache/disc or WAVESET replacement
   after success is rejected; stop and rerun F6 to select another source. Failed
   initialization may be retried with another source. Use **Quit safely** or close
   the window; editor force-stop and process termination bypass graceful shutdown.

No unattended disc extraction, full effect timelines/JSON, or gameplay sound
routing is installed. Private files must remain physically outside this repository.

### Existing extracted-asset cache integration

`RomReader.export_data()` now calls the audio-only exporter using the disc path
selected by the existing loader. It reuses the bounded installed disc parser,
not the donor's old engine or a second gameplay parser. The existing gameplay
export still performs its heavyweight ROM load; the audition scene does not.
Audio export errors and unavailable entries appear on the export button/tooltip,
including per-ID diagnostics from partially usable global banks. Catalog and
whole-file warnings are deduplicated; global ID holes remain diagnostic entries.
Confirmed zero-byte source `E###.BIN` placeholders are omitted from export warnings
and indexed cache choices. Nonempty effects that fail extraction still warn; stale
raw FEDS files for omitted placeholders are preserved but cannot become indexed choices.

The raw layout is compatible with the donor cache:

- `sound/WAVESET.WD`, `sound/MUSIC_*.SMD`
- `sound/SYSTEM.SED`, `sound/ENV.SED`
- `sound/feds/E###.feds`
- `sound/catalog.json`: versioned availability/error index with SHA-256 byte hashes

`GameData.index_data()` imports an audio catalog without initializing playback.
The scene reuses it through `get_audio_catalog()`, also supporting F6 before the
full asset import has completed. Global bank tables are checked at catalog load;
WAVESET/music/effect bytes are bounded, read lazily and retained on first use.
Changing `IMPORT_PATH` invalidates the GameData catalog; an already initialized
scene keeps its existing source until restart. Re-import assets to refresh an
export changed on disk. No additional settings or competing storage location exist.

An index is authoritative when present. Missing/invalid entries never fall back
to stale raw files, and malformed/unsupported metadata requires re-export rather
than silent legacy discovery. Raw-only legacy sound directories are supported
with an explicit no-integrity-index diagnostic. Export preserves unrelated files,
uses unique temporary files and atomic per-file renames, and publishes the index
last. This is **not a transactional directory snapshot**: after interruption, old
index hashes detect changed bytes on their first load and require re-export.
A first export writes an incomplete marker before any raw files, so interruption
cannot masquerade as a legacy cache. Already loaded bytes remain an in-memory
snapshot until re-import/restart. Crash leftovers are not deleted automatically.

Cache paths/filenames are checked for containment; symlinked paths are refused.
Limits: 32 MiB per raw file, 256 KiB index, 2048 entries, 256 MiB total exported or
retained raw payloads (parsed objects use additional memory). Individual optional extraction failures are indexed/diagnosed;
missing WAVESET prevents playback initialization. The cache integrity hashes are
consistency checks, not authentication or a hostile-filesystem sandbox.

The host reader validates ISO9660 CD001 primary volume descriptors and reads
only directory metadata, SOUND files, the known BATTLE effect header-pointer
table, and selected effect header/sound spans. It never reads a whole disc or
constructs gameplay/VFX objects. Limits: 1 GiB image, 32 MiB individual file,
256 KiB individual directory, 4 MiB total directory data, 8192 directory
records, eight directory levels. File reads return exactly declared bytes
across sector boundaries. Referenced sectors are checked for raw sync,
Mode2/Form1, and duplicated subheaders; this is not ECC/EDC verification.

Effect extraction uses the existing `BattleBinData` executable layout:
**0x14d8d0, 511 contiguous u32 pointers, minus 0x801c2500**. Its old comment
says eight bytes per entry, but executable code uses four. `E000.BIN` maps to
index 0, `E001.BIN` to 1, independently of directory order. The table is read
once; only a selected effect's ten-word header and bounded sound section are
read subsequently. There is no heuristic CODE-header scan in the disc path.
Other game revisions/layouts are **not assumed supported**: invalid table
pointers or missing FEDS sections disable choices with diagnostics. This
structural check is not revision fingerprinting or real-disc compatibility QA.
The internal byte adapter retains its bounded E### header heuristic for tests;
there is no manual E### file control.

Discovery, global SED semantics and sound-section extraction selectively adapt
[timbermania's PR #3](https://github.com/mrgudenheim/TacticsTemplateG/pull/3),
commit `0ebc36fcbaac56dd30e02bf1b2707c71140bc2d0`. Its MIT provenance is retained
in `THIRD_PARTY_NOTICES.txt` and root `LICENSE.txt`. Its old addon, native
binaries and gameplay ROM pipeline were **not** imported. Cache persistence now
uses a host-owned adapter with the donor-compatible raw-file layout above.

Container/table validation is not a sandbox for hostile sound bytecode, and
pair playback is not proof of FFT timing or sound parity.

`src/audio_test/audition_music.gd` adapts the captured music player's lifecycle:
it breaks the unused sequencer's pool back-reference before shared-engine
attachment, unlinks its music entity and breaks back-references on exit, and
avoids calling a player already freed by `ApplicationShutdown`. It depends on
captured addon internals and must be reviewed when updating that addon.
A narrow local GDScript fix in `effect_sfx_engine.gd` clears entity-to-cast
ownership after unlinking stopped casts and stops remaining casts after joining
the scheduler on exit. These fixes were exposed by actual SMD/FEDS API calls
with synthetic files; no native sources, binaries, or receipts changed.
The SPU GDScript wrapper also snapshots native debug counters/voice state under
`AudioServer.lock()`: the scheduler mutex alone does not serialize mixer writes.
SFX diagnostic callers retain the existing scheduler-then-audio lock order.
A two-thread regression verifies snapshots block while the mixer lock is held;
live/stopped snapshot/reset checks run alongside real-mixer playback and shutdown.
This does not make arbitrary concurrent direct native/synchronous-render calls safe.

```sh
python tools/audio/run_audition_checks.py --godot /path/to/Godot_v4.7.2-stable_linux.x86_64
```

This stages allowlisted source and synthetic inputs under temporary directories
with isolated user data. Checks cover malformed/missing inputs, raw/DATA/CODE
FEDS containers, initialization gating, music/SFX start-stop-reload, unused
music-player lifetime, and active/stopped/window-close shutdown. Additional
synthetic raw-disc runs cover cross-sector exact reads, descriptors and sector
layouts, XA system-use fields and multi-block directory padding, malformed
directory extents/cycles/budgets, missing banks, original SED IDs/gains/holes/
single channels, lazy BATTLE-based effects, automatic selector population,
repeated bank loads and global/effect/global switching, music/SFX play-stop,
and once-only disc/cache initialization. Cache checks cover raw export/import
roundtrips, reuse through upstream GameData indexing and the actual scene,
preservation of lazy gameplay indexes/tile meshes, legacy reads, stale
absent entries, malformed/oversized/unsafe indexes, changed/missing bytes,
interrupted first/re-exports, write failures, preservation of unrelated files,
symlink refusal, and Environment playback after the source disc is removed.
All disc images are generated from synthetic bytes inside temporary staging;
no real user path or private content is accessed by these tests. Verbose logs
under `.build/audition-check-logs/` must contain PASS and drained markers and no
script errors or leaked resources. Music/effect fixtures use rests for control
flow and lifecycle; global-bank fixtures additionally contain generated notes
and a generated ADPCM instrument, checked for nonzero real-mixer output with
music stopped. This is **not real-content listening or channel/gain parity**.
`run_smoke.py` separately checks synthetic WAV/SPU mixer coexistence.
Real-content listening, Windows, and newer engines beyond the tested 4.7.2
editor still require manual QA.

## Native source and builds

- Sources/headers/tables and original SConstruct:
  `third_party/exmateria-sound/` (ignored by Godot's resource scanner).
- godot-cpp is **not checked into Git**. `tools/audio/godot_cpp.lock.json` pins
  upstream commit `e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77` (Godot 4.5 API),
  the codeload archive URL, SHA-256
  `d4c03daf46c8bef4544614182b0762c3e32789151c7f8f44e8eb2053d5cddeba`,
  and all 188 reconstructed file hashes. All 187 upstream files match the
  original captured inputs byte-for-byte. The sole local addition,
  `test/project/.gitignore`, is reproduced verbatim from the lock to preserve
  the original framework Info.plist source files.
- Native build/source-package commands explicitly provision this dependency into
  ignored `.build/dependencies/`; initial provisioning needs HTTPS access.
  Source bundles instead contain the complete tree at
  `third_party/exmateria-sound/extern/godot-cpp/` and work offline.
  No submodule setup is needed. Cloning and running uses committed `.dll`/`.so`
  files and **does not provision/download anything**.
- `tools/audio/spu_build_profile.json` includes the audio classes and their
  prerequisites (`AudioFrame` and `OS` must not be omitted). Only the SPU target
  is built, not `libfftsmd`.
- Dependencies: Python 3.11+ (`hashlib.file_digest`; source-bundle tests require
  Python 3.12+ or a 3.11 patch release with `tarfile` extraction filters),
  SCons (tested 4.10.1), C++20 compiler. Linux tested with
  GCC 16.2.1; see receipts for the exact compiler output. Use at most two jobs by
  default; this workstation is memory-constrained.

From the project root or extracted corresponding-source root:

```sh
# Optional explicit preparation (build/package commands also provision as needed):
python tools/audio/godot_cpp.py
# Local archive from another machine is accepted only if its pinned hash matches:
python tools/audio/godot_cpp.py --offline --archive /outside/project/godot-cpp.tar.gz
# --offline on provisioning, build, or package forbids downloading. It requires
# complete included source, a verified cached tree, or a verified cached archive.

python tools/audio/build_native.py --platform linux --target template_debug
python tools/audio/build_native.py --platform linux --target template_release

# MINGW_PREFIX points to an extracted LLVM-MinGW toolchain, not to a source checkout.
python tools/audio/build_native.py --platform windows --target template_debug \
  --llvm --mingw-prefix "$MINGW_PREFIX"
python tools/audio/build_native.py --platform windows --target template_release \
  --llvm --mingw-prefix "$MINGW_PREFIX"
```

Windows builds were cross-compiled with LLVM-MinGW 20250910, UCRT x86_64.
The exact toolchain download URL and SHA256 are in `tools/audio/upstream.json`.
Unpack it outside public distribution inputs. GCC MinGW is also accepted by the
build script without `--llvm`, but was not tested here. GNU/Linux standard
runtime libraries and the MinGW/LLVM standard compiler/OS runtimes are treated
as System Libraries. Their notices are preserved in `LICENSES/toolchain/`.
The complete non-system linked dependency, godot-cpp, is included in every
corresponding-source bundle, not merely referenced by URL.

Builds use separate `.build/audio/<platform>-<target>/` directories. A changed
source/profile/build-script fingerprint discards that target's previous build
tree, preventing stale headers from surviving deletion. Output goes to
`addons/exmateria_spu/bin/`; a receipt in `tools/audio/builds/` records every
native source input's hash, the command, compiler, and output hash. These are
matching-source records, not a promise of bit-for-bit reproducibility (PE
linker timestamps can differ). Never pair an old binary with changed native
inputs; rebuild it. No unknown upstream prebuilt binary was retained.

Dependency externalization did **not** rebuild or relabel the existing binaries.
All four historical receipt JSON files remain unchanged. Their original build
script is preserved byte-for-byte at `tools/audio/builds/original-build_native.py.txt`;
legacy verification maps only that recorded recipe input to its archived copy.
All other native inputs, the reconstructed dependency inventory and original
fingerprints must still match. New actual builds emit schema-2 receipts including
the current script, provisioner and lock as recipe inputs. See
`tools/audio/builds/README.md`; old receipts are not claims about today's tools.

Provisioning verifies the pinned compressed archive and every reconstructed file,
rejects traversal, symlinks/hardlinks/special files, duplicate/unexpected names,
and bounds compressed/decompressed data, entries and file sizes. Existing altered
caches or included source fail closed rather than silently repairing/fetching.
Remove only your bad dependency cache manually before retrying. Cache publication
uses temporary directories; no downloader/extractor runs from Godot or test-stage
startup. The checks assume a locally trusted filesystem, not protection against
another process racing filesystem changes. HTTPS/codeload and the committed pins
are the trust anchor; the archive is not independently signed.

Runtime test staging validates native bytes and receipts against the pinned
source inventory without fetching/materializing godot-cpp. Release staging goes
further: it requires and validates the actual full dependency tree, includes it
and these tools in the source archive, and fails rather than omitting it. Tests
use generated tiny dependency archives and prohibit network access; validation
of the real pinned archive and complete offline source-build preparation is a
separate explicit check. Run dependency and packaging regressions with:

```sh
python -m unittest discover -s tools/audio -p 'test_dependency.py'
python -m unittest discover -s tools/audio -p 'test_packaging.py'
```


Only **Linux and Windows x86_64**, debug and release, are declared by the local
GDExtension descriptor. macOS/ARM are not supplied. The local compatibility
minimum is 4.6, retained from the original installation (the host now targets 4.7); upstream's 4.4 claim does not
apply to this build.

## Validation

Use the official Godot 4.7.2 binary, **without `--headless`**. The tests open a
small real window and exercise the real audio mixer; a dummy audio driver is
not evidence for the mixer assertions.

```sh
python tools/audio/run_smoke.py --godot /path/to/Godot_v4.7.2-stable_linux.x86_64
python tools/audio/test_exports.py \
  --godot /path/to/Godot_v4.7.2-stable_linux.x86_64 \
  --templates /path/to/extracted/templates --wine /usr/bin/wine
python -m unittest discover -s tools/audio -p 'test_packaging.py'
```

The first command copies only the two addons and the test into an isolated
project. It loads their scripts, rejects absent/malformed content, retries with
synthetic WAVESET data, checks one-time initialization and SFX readiness, renders
nonzero native PCM, and measures WAV/SPU output through AudioEffectCapture on
the same Godot bus. All samples are synthesized, not ROM-derived.

The second exports that **test scene**, not the game, using official matching
Linux/Windows debug/release templates. Wine uses `.build/audio-wine`, never the
user's default prefix. Passing Windows under Wine is not Windows-hardware QA.
The test explicitly rejects the Dummy audio driver. It frees its players/SFX
fixture and allows 200 ms for Godot's audio-thread fade-out cleanup before exit;
the runner rejects leaked-instance warnings as well as errors and missing PASS.
Logs are retained in `.build/audio-test-logs/` and `.build/audio-export-logs/`.
`--host` on the first command additionally checks the full host project and is
strict: existing host import errors make it fail rather than disappear.

### Historical 4.6.1 release-readiness follow-up

Cold full-game import and Windows export now pass after repairing the GameData
UID registration, obsolete scenario save-path constant, legacy map-data adapter,
and Vector3iEdit's pre-ready exported property access.

The isolated no-content main scene now exits without errors or ObjectDB leaks.
GameData treats a missing configuration as first-run state, validates partial or
malformed JSON without overwriting it, and retains diagnostics for unreadable
files. FftAnimation no longer owns a strong reference to itself; a lifetime
regression covers this host leak independently of the audio addon.

Run the clean public-source host checks without touching normal user data:

```sh
python tools/audio/run_host_checks.py --godot /path/to/Godot_v4.7.2-stable_linux.x86_64
```

Logs are under `.build/host-check-logs/`. The runner rejects script errors,
missing regression PASS markers, and ObjectDB leak warnings. Existing empty-BMP
and unconfigured ActionButton construction warnings remain; these are not leak
or error diagnostics. The six packaging checks and standalone Linux/Windows
(Wine) debug/release audio smoke tests were rerun successfully.

**Underlying abrupt-exit risk:** a minimal synthetic native-stream `stop()` followed
immediately by `quit()` still crashed in three of five verbose trials (one
additional trial leaked without crashing). Logs: `.build/audio-exit-probes/`.
Host first-run fixes alone do not resolve this separate active-audio/engine
cleanup risk. The approved normal-quit boundary below addresses orderly host
exit; native binaries and engine remain unchanged. The actual Windows
release executable from `dist/game-readiness-03/` was launched with a fresh
`.build/host-wine` prefix and `--quit-after 120 --verbose`: exit code 0, no script
errors or leaked resources; the two construction warnings above remain.
Log: `.build/host-check-logs/windows-startup.log`. This is a bounded no-content
startup check, not gameplay validation or Windows hardware QA. Repackage after
remaining fixes; this candidate is not approved for publication.

### Normal application shutdown

The host now owns `ApplicationShutdown` (`src/utilities/application_shutdown.gd`).
Window close and existing host quit buttons/runners call `request_quit()`.
Repeated requests are ignored. It pauses scene processing, records weak
references to current in-tree player playbacks, removes the SFX producer (whose
exit hook joins its scheduler and detaches native mixers), stops/frees remaining
players, and waits until the recorded playback objects are actually released.
There is no fixed success delay. After five seconds of retained playback it
emits `shutdown_failed`, logs an error, and leaves the application paused rather
than forcing unsafe teardown. Callers must not retain playback objects across
shutdown. No automatic recovery or resume-after-shutdown is supported.

This covers ordinary AudioStreamPlayer/2D/3D nodes owned by the scene tree.
Future detached players, custom audio producers, capture instances or retained
playback handles require explicit integration. Forced process termination and
direct `SceneTree.quit()` (including CLI `--quit-after`) bypass this boundary;
the underlying engine/native abrupt-exit behavior is not claimed fixed.

```sh
python tools/audio/run_shutdown_checks.py --godot /path/to/Godot_v4.7.2-stable_linux.x86_64
python tools/audio/test_exports.py --shutdown \
  --godot /path/to/Godot_v4.7.2-stable_linux.x86_64 \
  --templates /path/to/templates --wine /usr/bin/wine
```

Fifteen verbose real-mixer runs passed across active playback, already-stopped
playback and close notification. A retained-playback negative test confirms
that timeout refuses exit; the fixture then releases its handle before exiting.
Linux and Windows-under-Wine debug/release exported shutdown fixtures also pass.
Logs: `.build/shutdown-check-logs/` and `.build/shutdown-export-logs/`.
Windows hardware and content-loaded gameplay still require manual QA.

**Candidate 04 remains QA-blocked:** final Windows-under-Wine game checks found
40 `GL_INVALID_VALUE` shader/program-handle errors on warm-cache startup.
Moving only the isolated test prefix's shader cache yields a clean cold run;
the immediate next run reproduces all 40 errors. Candidate 03 also reproduces
them, independently of the shutdown change. Logs:
`.build/host-check-logs/cache-cold.log`, `cache-warm.log`, and
`game-readiness-03-repeat.log`. No production cache policy was changed and no
user cache was removed. `dist/game-candidate-04/QA-PENDING.txt` records the block;
its archives passed SHA256SUMS verification but are not approved for publication.

### Historical installation results (2026-09-13)

The following records the installation before the release-readiness fixes above.

- Standalone 4.6.1 editor import and content-free audio/mixer smoke: **pass**;
  five consecutive verbose runs passed after explicit fixture drain.
- Six packaging/runner regression checks: **pass**. Source archive extracted,
  per-file checksums verified, and Linux debug rebuilt from that standalone
  source tree with the same binary SHA256.
- Linux x86_64 exported debug and release smoke: **pass**.
- Windows x86_64 exported debug and release smoke under Wine: **pass**.
- No unresolved ExMateria/FFTSpu/fftshared symbols in Linux libraries. Windows
  imports are UCRT and KERNEL32, with no additional non-system DLL required.
- Host smoke scene reaches `AUDIO_SMOKE: PASS` and calls the unchanged Utilities
  helper. Full-host startup is **not clean**: baseline data-path/empty-BMP errors
  and shutdown resource leaks remain.
- Full project import fails in both this tree and an untouched `816ad4d` copy:
  initial GameData UID resolution, missing `Scenario.SAVE_DIRECTORY_PATH`, and
  legacy `MapData`/`FftMapData` test-script mismatches. These are not audio changes.
- **Full-game release remains blocked** by these baseline errors; no clean
  full-game export or Windows hardware run is claimed. Private FFT music/effect
  playback and sound parity were not tested. No ROM content was copied.

A native pool/flush reference cycle found by the standalone shutdown check was
fixed locally after stopping the SFX scheduler; the standalone test now exits
without leaked-resource diagnostics **after draining its fixture as described
above**. That is separate from the host's existing leaks. Upstream parity
algorithms and native sources were not changed.

**Abrupt exit remains a known runtime risk:** repeatedly calling `stop()` and
immediately `SceneTree.quit()` on Godot 4.6.1 leaked pending playback objects;
with native playbacks, verbose ObjectDB cleanup sometimes crashed. A separate
plain-WAV-only project (no addons) reproduced the leaked WAV/playback references
in 3 of 4 runs. Freeing the test fixture and allowing fade-out cleanup avoided
the race in repeated checks. This installation does not change the host's quit
policy or claim to fix the engine's exit ordering. Resolve graceful application
shutdown before enabling live audio in the full game/releasing it. The default
no-content autoloads are idle. Diagnostic logs from this session:
`/tmp/tactics-smoke-leaks-*.log`, `/tmp/tactics-wav-only-exit-*.log`, and
`/tmp/tactics-grace-exit-*.log`.

Offline capture instances and live voice-mode switching are inherited surfaces,
not validated by this installation; their discarded pool/flush ownership cycles
still need a separate lifecycle pass before capture/editor integration.

## Licenses and distribution

The approved policy treats the combined game/audio distribution as GPL-3.0
covered. Root `LICENSE.txt` retains the original MIT grant; it has not been
replaced or purportedly revoked. `THIRD_PARTY_NOTICES.txt` identifies adapted
PCSX SPU code (Pete Bernert), Gaussian-table provenance (Chris Moeller and the
libopenspc credit), Dr. Hell/Neill Corlett credits, the MIT ADPCM encoder,
godot-cpp, and standard runtime licenses. Both full GPL texts, MIT notices, and
original PCSX reference headers/sources are under `LICENSES/`. Historical
comparison sources are evidence, not a claim about the original port revision.

Create an addon installer and **full game/addon corresponding source together**:

```sh
python tools/audio/package_release.py --output dist/audio-install
```

The new output directory contains `TacticsTemplateG-audio-addons.zip`,
`TacticsTemplateG-source.tar.gz`, `SOURCE.txt`, and `SHA256SUMS`. Distribute the
source archive alongside the binary ZIP with equivalent download access.
The ZIP carries licenses/notices and the source archive's exact hash; the source
includes game/addon scripts, local changes, native and materialized dependency sources, build
scripts/profile, export configuration, and instructions. `FILES.sha256` inside
it identifies the exact snapshot. A native-only source archive is not a substitute.

The packager copies only explicit `tools/audio/distribution-files.txt` entries,
never arbitrary files from the working directory. It rejects symlinks, missing
inputs, stale native receipts, known ROM formats and private directories. New
files must be deliberately reviewed and added to the allowlist. It is a guard,
not a content-license classifier: disguised or newly edited content still needs
human review. The original extensionless `path` file is a GIF of an FFT sprite;
it remains in the checkout but is specifically excluded from all release/source
bundles, as are private ROM banks/maps/sprites and local extraction caches.
No GPL permission is claimed for that media.

After unrelated host failures are repaired, full Windows game packaging uses:

```sh
python tools/audio/package_release.py --output dist/game-release --export-game \
  --godot /path/to/Godot_v4.7.2-stable_linux.x86_64 \
  --templates /path/to/extracted/templates
```

This imports/exports the same clean source snapshot, captures engine notices
from the selected official 4.7.2 engine into `GODOT-NOTICES.txt`, and places source
delivery instructions/licenses next to the executable. The engine executable
and selected template are hashed. Before modifying presets or invoking export,
both Windows x86_64 templates must match the official 4.7.2 SHA-256 pins in
`tools/audio/package_release.py`; existing older/custom templates are rejected.
The pins were derived from `Godot_v4.7.2-stable_export_templates.tpz` after checking
its SHA-512 against the same GitHub release's `SHA512-SUMS.txt`. This trusts the
Godot release over HTTPS, not an independent signature. Archive origin/hash also
travel in `EXPORT-ENGINE.json`. These checks align the selected engine notices
with the template release; they do not substitute for Windows execution QA.
The format denylist rejects `.sed` and `.feds` as well as the earlier private
formats, even if accidentally added to the allowlist. Private content must not
be placed in that staging tree. Errors create
`RELEASE-BLOCKED.txt`: **do not distribute partial output**. Bare editor exports
bypass this process and are not approved release artifacts. `export_presets.cfg`
also excludes known content/build/source directories as defense in depth.

This is a practical source-delivery and provenance workflow, not legal
certification or a claim that every inherited asset's history was audited.
