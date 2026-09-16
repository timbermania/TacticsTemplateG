#!/usr/bin/env python3
"""Vendor (or verify) the upstream GDScript `E###.BIN` reader into TacticsG.

The reader lives in the upstream addon (`addons/exmateria_effects/file_model/`), but this
repo's addon install is PINNED at a revision that predates it, and nothing under `addons/`
may move. So the closure is vendored into `src/file_formats/vfx/effect_bin/` instead, with
exactly ONE mechanical edit: the `preload()` root.

That single-edit rule is the whole point, and it is what `--check` measures: re-apply the
rewrite to the recorded upstream bytes and the result must equal the vendored file. A drift
that is not the rewrite is a drift, and it fails. Without `--upstream` the check falls back
to the recorded hashes, so it still runs in a checkout that has no monorepo beside it.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "tools/effects/effect_bin_vendor.json"

## Where the vendored closure lands, and the `preload()` root it is rewritten to.
VENDOR_DIR = "src/file_formats/vfx/effect_bin"
UPSTREAM_ROOT = "res://addons/exmateria_effects/file_model/"
VENDOR_ROOT = f"res://{VENDOR_DIR}/"

## source (relative to the upstream project root) -> destination (relative to VENDOR_DIR)
FILES = {
    "addons/exmateria_effects/file_model/EffectBinHeader.gd": "EffectBinHeader.gd",
    "addons/exmateria_effects/file_model/EffectBinLayout.gd": "EffectBinLayout.gd",
    "addons/exmateria_effects/file_model/EffectBinReader.gd": "EffectBinReader.gd",
    # The TGA encoder the extract's `texture.tga` is written through. Upstream keeps it in
    # `src/`, not in the addon, so it is vendored from there — same rule, same check.
    "src/effects/studio/TextureTga.gd": "TextureTga.gd",
}
for _r in (
    "Animation", "Camera", "Containers", "Curves", "Emitters", "Flags", "Frames",
    "Palette", "ParticleTimeline", "Screen", "Script", "Sound", "SoundDef", "Texture",
    "TimeScale",
):
    FILES[f"addons/exmateria_effects/file_model/readers/EffectRead{_r}.gd"] = \
        f"readers/EffectRead{_r}.gd"

## The upstream project root inside the monorepo checkout.
SOURCE_PREFIX = "godot-learning/"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def rewrite(data: bytes) -> bytes:
    """The ONE mechanical edit: repoint `preload()` at the vendored location."""
    return data.replace(UPSTREAM_ROOT.encode(), VENDOR_ROOT.encode())


def upstream_bytes(upstream: Path, revision: str, source: str) -> bytes:
    """The file's bytes AT THE PINNED REVISION — git objects, never the working tree."""
    return subprocess.run(
        ["git", "-C", str(upstream), "show", f"{revision}:{SOURCE_PREFIX}{source}"],
        check=True, capture_output=True,
    ).stdout


def vendor(upstream: Path, revision: str) -> dict:
    rows = []
    for source, dest in sorted(FILES.items()):
        raw = upstream_bytes(upstream, revision, source)
        out = rewrite(raw)
        target = ROOT / VENDOR_DIR / dest
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(out)
        rows.append({
            "source": SOURCE_PREFIX + source,
            "destination": f"{VENDOR_DIR}/{dest}",
            "upstream_sha256": digest(raw),
            "vendored_sha256": digest(out),
            "bytes": len(out),
        })
    return {
        "schema_version": 1,
        "repository": "https://github.com/timbermania/fft-monorepo",
        "revision": revision,
        "source_prefix": SOURCE_PREFIX,
        "vendor_dir": VENDOR_DIR,
        "rewrite": {"from": UPSTREAM_ROOT, "to": VENDOR_ROOT},
        "file_count": len(rows),
        "files": rows,
    }


def check(upstream: Path | None) -> list[str]:
    """Every way the vendored tree disagrees with the lock, as sentences."""
    problems = []
    lock = json.loads(LOCK.read_text())
    if lock["schema_version"] != 1:
        return ["Unsupported effect_bin vendor lock schema"]
    rows = lock["files"]
    if len(rows) != lock["file_count"]:
        problems.append("lock file_count disagrees with the row count")
    for row in rows:
        target = ROOT / row["destination"]
        if not target.is_file():
            problems.append(f"missing vendored file: {row['destination']}")
            continue
        data = target.read_bytes()
        if digest(data) != row["vendored_sha256"]:
            problems.append(f"vendored file edited since vendoring: {row['destination']}")
        if UPSTREAM_ROOT.encode() in data:
            problems.append(f"unrewritten preload root in {row['destination']}")
        if upstream is not None:
            source = row["source"][len(lock["source_prefix"]):]
            raw = upstream_bytes(upstream, lock["revision"], source)
            if digest(raw) != row["upstream_sha256"]:
                problems.append(f"upstream bytes changed at the pin: {row['source']}")
            elif digest(rewrite(raw)) != row["vendored_sha256"]:
                problems.append(
                    f"vendored file is not upstream-plus-the-rewrite: {row['destination']}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--upstream", type=Path,
                    help="monorepo checkout; compares git objects at the pinned revision")
    ap.add_argument("--revision", help="upstream revision to vendor from (with --write)")
    ap.add_argument("--write", action="store_true",
                    help="re-vendor and rewrite the lock (otherwise verify only)")
    args = ap.parse_args()

    if args.write:
        if not args.upstream or not args.revision:
            print("--write needs --upstream and --revision", file=sys.stderr)
            return 2
        lock = vendor(args.upstream, args.revision)
        LOCK.write_text(json.dumps(lock, indent=2) + "\n")
        print(f"vendored {lock['file_count']} files at {args.revision[:12]}")
        return 0

    problems = check(args.upstream)
    for p in problems:
        print(f"FAIL {p}")
    scope = "against upstream" if args.upstream else "against recorded hashes only"
    print(f"effect_bin vendor: {'FAIL' if problems else 'PASS'} ({scope})")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
