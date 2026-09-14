#!/usr/bin/env python3
"""Build the shipping SPU; explicitly provision pinned godot-cpp when needed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import godot_cpp

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


RECIPE_INPUTS = ("tools/audio/build_native.py", "tools/audio/spu_build_profile.json",
                 "tools/audio/godot_cpp.py", godot_cpp.LOCK)


def source_hashes(root, dependency):
    source = root / "third_party/exmateria-sound"
    godot_cpp.verify_tree(dependency, godot_cpp.read_lock(root))
    hashes = {}
    for path in source.rglob("*"):
        godot_cpp.no_links(path)
        if path.is_file() and not path.is_relative_to(root / godot_cpp.RELATIVE):
            hashes[path.relative_to(root).as_posix()] = digest(path)
    for name in godot_cpp.read_lock(root)["files"]:
        hashes[godot_cpp.RELATIVE + "/" + name] = digest(dependency / name)
    for name in RECIPE_INPUTS:
        godot_cpp.no_links(root / name)
        hashes[name] = digest(root / name)
    return dict(sorted(hashes.items()))


def fingerprint(hashes):
    return hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()


def prepare_build(root, platform, target, *, offline=False):
    dependency = godot_cpp.provision(root, offline=offline)
    hashes = source_hashes(root, dependency)
    work = root / ".build/audio" / f"{platform}-{target}"
    godot_cpp.no_links(work)
    # Never let deleted/changed inputs survive in an incremental work directory.
    stamp = work / ".input-fingerprint"
    if work.exists() and (not stamp.is_file() or stamp.read_text() != fingerprint(hashes)):
        shutil.rmtree(work)
    for path in work.rglob("*"):
        godot_cpp.no_links(path)
    shutil.copytree(root / "third_party/exmateria-sound", work, dirs_exist_ok=True)
    shutil.copytree(dependency, work / "extern/godot-cpp", dirs_exist_ok=True)
    # The reusable work tree may also contain SCons-generated bindings/objects.
    # Exact inventory validation applies to source, not those intermediates.
    for name, expected in godot_cpp.read_lock(root)["files"].items():
        if digest(work / "extern/godot-cpp" / name) != expected:
            raise ValueError("Staged godot-cpp source hash mismatch")
    stamp.write_text(fingerprint(hashes))
    shutil.copy2(root / "tools/audio/spu_build_profile.json", work / "spu_build_profile.json")
    return hashes, work, dependency


def build(platform, target, jobs, mingw_prefix=None, llvm=False, offline=False):
    hashes, work, dependency = prepare_build(ROOT, platform, target, offline=offline)
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
    if source_hashes(ROOT, dependency) != hashes:
        raise RuntimeError("Source changed during the build; refusing to install binary")
    destination = ROOT / output
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(work / output, destination)
    receipt = {
        "schema_version": 2,
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
    parser.add_argument("--offline", action="store_true", help="Require included/cached godot-cpp; no download")
    parser.add_argument("--llvm", action="store_true", help="Use LLVM-MinGW for Windows")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    build(args.platform, args.target, args.jobs, args.mingw_prefix, args.llvm, args.offline)
