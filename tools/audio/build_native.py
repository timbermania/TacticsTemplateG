#!/usr/bin/env python3
"""Build only the shipping SPU from the vendored, offline source snapshot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "third_party/exmateria-sound"
PROFILE = ROOT / "tools/audio/spu_build_profile.json"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes():
    paths = [p for p in SOURCE.rglob("*") if p.is_file()]
    paths += [Path(__file__).resolve(), PROFILE]
    return {p.relative_to(ROOT).as_posix(): digest(p) for p in sorted(paths)}


def fingerprint(hashes):
    return hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()


def build(platform, target, jobs, mingw_prefix=None, llvm=False):
    hashes = source_hashes()
    work = ROOT / ".build/audio" / f"{platform}-{target}"
    # Never let deleted/changed inputs survive in an incremental work directory.
    stamp = work / ".input-fingerprint"
    if work.exists() and (not stamp.is_file() or stamp.read_text() != fingerprint(hashes)):
        shutil.rmtree(work)
    # Separate output trees prevent debug/release and platform object reuse.
    shutil.copytree(SOURCE, work, dirs_exist_ok=True)
    stamp.write_text(fingerprint(hashes))
    shutil.copy2(PROFILE, work / "spu_build_profile.json")
    extension = "so" if platform == "linux" else "dll"
    name = f"libexmateria_spu.{platform}.{target}.x86_64.{extension}"
    output = Path("addons/exmateria_spu/bin") / name
    command = ["scons", f"-j{jobs}", f"platform={platform}", f"target={target}",
               "arch=x86_64", "build_profile=spu_build_profile.json", str(output)]
    compiler = "g++" if platform == "linux" else "x86_64-w64-mingw32-g++"
    if platform == "windows":
        command += ["use_mingw=yes"]
        if llvm:
            command += ["use_llvm=yes"]
            compiler = "x86_64-w64-mingw32-clang++"
        if mingw_prefix:
            command += [f"mingw_prefix={mingw_prefix}"]
            compiler = str(Path(mingw_prefix) / "bin" / compiler)
    compiler_version = subprocess.check_output([compiler, "--version"], text=True)
    scons_version = "\n".join(subprocess.check_output(["scons", "--version"], text=True).splitlines()[:2])
    subprocess.run(command, cwd=work, check=True)
    if source_hashes() != hashes:
        raise RuntimeError("Source changed during the build; refusing to install binary")
    destination = ROOT / output
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(work / output, destination)
    receipt = {
        "binary": output.as_posix(), "sha256": digest(destination),
        "source_fingerprint": fingerprint(hashes), "source_files": hashes,
        "command": [c.replace(str(mingw_prefix), "${MINGW_PREFIX}") if mingw_prefix else c for c in command],
        "compiler": compiler_version.replace(str(mingw_prefix), "${MINGW_PREFIX}") if mingw_prefix else compiler_version,
        "scons": scons_version,
        "host": os.uname().sysname, "runtime_validation": "not established by build",
    }
    receipts = ROOT / "tools/audio/builds"
    receipts.mkdir(exist_ok=True)
    (receipts / f"{platform}-{target}.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Installed {destination.relative_to(ROOT)} sha256={receipt['sha256']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["linux", "windows"], required=True)
    parser.add_argument("--target", choices=["template_debug", "template_release"], required=True)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--mingw-prefix", help="Optional MinGW installation prefix for cross-compilation")
    parser.add_argument("--llvm", action="store_true", help="Use LLVM-MinGW for Windows")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    build(args.platform, args.target, args.jobs, args.mingw_prefix, args.llvm)
