# Audio installation

## Upstream integration validation

Ported onto upstream `815d4b8` with its Godot 4.7 settings, lazy resource
loading, VFX MapData adapters and export options preserved. Official Godot
4.7.2 (archive verified against the official SHA-512 sums) passes Linux
content-free real-mixer smoke and isolated host regression/startup checks.
Native source, four binaries and their receipts are unchanged. Historical
4.6.1/Wine release results below do not establish current exported-game,
Windows, or real-content compatibility. No release is approved.

## Installed scope

`addons/exmateria_sound/` and `addons/exmateria_spu/` are real, self-contained
files captured from upstream commit `4ca5c30abdb8423931155d44dd38f9b4fa76cb0e`.
There is no dependency on a developer's monorepo checkout. The native SPU is
rebuilt from the recorded source inputs; the optional native SMD accelerator is absent.
The committed binaries require no dependency download to open/run Godot; only
explicit native builds and complete-source packaging provision godot-cpp.

The project retains upstream **Godot 4.7 / GL Compatibility**. Both plugins are enabled,
and `ExMateriaAudioEngine` precedes `ExMateriaEffectSfx` in the autoload list.
Missing user content is normal: neither autoload starts playback or allocates
SPUs/streams at boot. The SPU addon does not take over the audio device or change
ordinary WAV importing. Existing `Utilities.play_audio_one_shot` is unchanged.

**Not connected:** ROM provisioning, music selection, UI/game-event sound
routing, or effects. No legacy VFX files were changed. The host owns buses and
volume policy; absent `Music`, `SFX`, or `Ambient` buses fall back to Master.
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
by these autoloads. The upstream demo's separate `AssetPaths` search remains
available to developers; it does not configure autoload initialization.

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
before allocating or reading descriptors. No private bytes are saved to disk.

Effect playback will additionally require privately provisioned FEDS/effect
artifacts and a later effects adapter. Installing this module does not supply
them or create a second effect-schedule walker.

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
