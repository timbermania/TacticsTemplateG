# Native build receipts

The four existing JSON receipts are unchanged records of the shipped binaries.
They record the complete godot-cpp file inventory before dependency externalization
and the SHA-256 of `tools/audio/build_native.py` as it existed during those builds.
That exact script is preserved as `original-build_native.py.txt` here.

The packaging verifier maps **only** that old script input to this archived copy
for legacy receipts (no schema version). All native and dependency file bytes
and the original fingerprint must still match; no replacement receipt or rebuild
is claimed. The captured dependency was 187 upstream files plus the local
`test/project/.gitignore` addition, now reconstructed by `godot_cpp.lock.json`.

New builds use schema version 2 and record the current build script, dependency
provisioner, lock file and build profile as recipe inputs. Historical recipes
are evidence, not the current entrypoint; use `../build_native.py` to rebuild.
Externalization starts from commit `48fee92097bd24baa1dda84cc158879ad6da638c`.
