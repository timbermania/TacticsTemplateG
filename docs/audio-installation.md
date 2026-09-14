# Audio engine source and distribution

This commit installs the self-contained ExMateria sound/SPU addons and matching
native source from upstream `4ca5c30abdb8423931155d44dd38f9b4fa76cb0e`, with local
deferred-initialization and lifetime hardening. Host autoload wiring is separate.
No ROM content or private cache is included. The optional native SMD accelerator
is absent. Linux and Windows x86_64 debug/release SPU binaries have matching
source/build receipts under `tools/audio/builds/`; no native inputs were changed
for the upstream Godot 4.7 port.

Native diagnostics are serialized with the audio mixer. The shipped binaries
and their historical matching-source receipts are unchanged. Host integration
and audition regression coverage are introduced by the following commits.

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

Use official Godot 4.7.2 for the content-free addon smoke test:

```sh
python tools/audio/run_smoke.py --godot /path/to/Godot_v4.7.2-stable_linux.x86_64
python -m unittest discover -s tools/audio -p test_dependency.py
python -m unittest discover -s tools/audio -p test_packaging.py
```

No real-disc, Windows runtime, matching-template game export, or release
approval is implied by the source or synthetic checks.

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
