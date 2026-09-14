#!/usr/bin/env python3
"""Stage allowlisted files, verify native provenance, and pair binaries with source.

Default: addon installer ZIP plus full game/addon corresponding-source archive.
--export-game: also export the Windows game from that SAME clean snapshot.
Never publishes or uploads. Raw editor exports bypass these checks: do not ship them.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

import godot_cpp
from build_native import RECIPE_INPUTS

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "tools/audio/distribution-files.txt"
FORBIDDEN = {".wd", ".smd", ".sed", ".feds", ".bin", ".iso", ".cue", ".img", ".chd", ".vag"}
# Extracted from the official archive after checking its SHA-512 against the
# release's SHA512-SUMS.txt (2026-09-13). These pins establish release consistency,
# trusting Godot's GitHub release over HTTPS; they are not independent signatures.
TEMPLATE_ARCHIVE_URL = "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz"
TEMPLATE_ARCHIVE_SHA512 = "ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079"
TEMPLATE_SHA256 = {
    "debug": "51498b72b3a237f882ebd7d1787f06a4bc1eaf0572daab93837adcfd3cfdc107",
    "release": "d34d36f3be1a6c49c56525ae86469b92e4f417ddf0b43cf00dd80c385c4b0562",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_path(root, relative):
    path = PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError(f"Unsafe distribution path: {relative}")
    if relative == "path" or path.suffix.lower() in FORBIDDEN:
        raise ValueError(f"ROM-format content forbidden: {relative}")
    if any(p in {".git", ".godot", ".build", ".scratch", "project-assets", "overrides", "assets"}
           for p in path.parts):
        raise ValueError(f"Private/generated directory forbidden: {relative}")
    current = root
    for part in path.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError(f"Symlink forbidden: {relative}")
    if not current.is_file():
        raise ValueError(f"Missing distribution input: {relative}")
    return current


# Original build recipe is evidence for unchanged historical receipts, not a
# claim that these binaries were rebuilt using today's dependency provisioner.
LEGACY_BUILDER = "tools/audio/builds/original-build_native.py.txt"
LEGACY_BUILDER_SHA256 = "5a7d44a34d43735bbf77e1bf426a05e4ece14c9b384bbd05025742ceca364298"


def verify_native(root, *, require_dependency=False):
    lock = godot_cpp.read_lock(root)
    dependency = root / godot_cpp.RELATIVE
    godot_cpp.no_links(dependency)
    materialized = dependency.exists()
    if materialized:
        godot_cpp.verify_tree(dependency, lock)
    elif require_dependency:
        raise ValueError("Complete corresponding source requires materialized godot-cpp")
    # Runtime staging checks the receipt against the pinned inventory, without
    # fetching dependency bytes. Source delivery additionally checks those bytes.
    dependency_hashes = {godot_cpp.RELATIVE + "/" + name: value for name, value in lock["files"].items()}
    native_paths = set()
    for path in (root / "third_party/exmateria-sound").rglob("*"):
        godot_cpp.no_links(path)
        if path.is_file() and not path.is_relative_to(dependency):
            native_paths.add(path.relative_to(root).as_posix())
    for platform in ("linux", "windows"):
        for target in ("template_debug", "template_release"):
            path = safe_path(root, f"tools/audio/builds/{platform}-{target}.json")
            receipt = json.loads(path.read_text())
            binary = safe_path(root, receipt["binary"])
            if digest(binary) != receipt["sha256"]:
                raise ValueError(f"Binary hash mismatch: {binary}")
            hashes = receipt["source_files"]
            version = receipt.get("schema_version", 1)
            if version == 1:
                recipe = {"tools/audio/build_native.py", "tools/audio/spu_build_profile.json"}
                if hashes.get("tools/audio/build_native.py") != LEGACY_BUILDER_SHA256:
                    raise ValueError("Unknown historical build recipe; cannot substitute archived script")
            elif version == 2:
                recipe = set(RECIPE_INPUTS)
            else:
                raise ValueError("Unsupported native receipt schema")
            if native_paths | set(dependency_hashes) | recipe != set(hashes):
                raise ValueError("Native source inventory changed; rebuild all variants")
            for relative, expected in hashes.items():
                if relative in dependency_hashes:
                    actual = dependency_hashes[relative]  # verify_tree checked materialized bytes above
                else:
                    source = LEGACY_BUILDER if version == 1 and relative == "tools/audio/build_native.py" else relative
                    actual = digest(safe_path(root, source))
                if actual != expected:
                    raise ValueError(f"Native source changed; rebuild: {relative}")
            fingerprint = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
            if fingerprint != receipt["source_fingerprint"]:
                raise ValueError(f"Invalid source fingerprint: {path}")


def stage(root, destination, manifest, *, include_dependency=False, offline=False):
    paths = [line for line in manifest.read_text().splitlines() if line and not line.startswith("#")]
    if len(paths) != len(set(paths)):
        raise ValueError("Duplicate distribution path")
    for relative in paths:
        source = safe_path(root, relative)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    # The allowlist itself travels in corresponding source; no Git checkout needed.
    target = destination / "tools/audio/distribution-files.txt"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(manifest, target)
    if include_dependency:
        dependency = godot_cpp.provision(root, offline=offline)
        shutil.copytree(dependency, destination / godot_cpp.RELATIVE)
    verify_native(destination, require_dependency=include_dependency)


def zip_tree(destination, root, paths):
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(paths):
            archive.write(path, path.relative_to(root))


def run_godot(command, logfile):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=180)
    logfile.write_text(result.stdout)
    if result.returncode or any(line.startswith("ERROR:") or "SCRIPT ERROR:" in line
                                for line in result.stdout.splitlines()):
        raise RuntimeError(f"Godot failed; release blocked. See {logfile}\n{result.stdout[-6000:]}")


def export_game(source, output, godot, templates, debug):
    version = subprocess.check_output([str(godot), "--version"], text=True).strip()
    if not version.startswith("4.7.2.stable.official."):
        raise ValueError("Use the unmodified official Godot 4.7.2 export engine and matching templates")
    preset = source / "export_presets.cfg"
    text = preset.read_text()
    for kind in ("debug", "release"):
        template = templates / f"windows_{kind}_x86_64.exe"
        if not template.is_file():
            raise ValueError(f"Missing matching Godot template: {template}")
        if digest(template) != TEMPLATE_SHA256[kind]:
            raise ValueError(f"Template hash mismatch; use official Godot 4.7.2 templates: {template}")
        setting = f'custom_template/{kind}=""'
        if text.splitlines().count(setting) != 1:
            raise ValueError(f"Expected one empty {kind} custom template setting in the guarded preset")
        text = text.replace(setting, f'custom_template/{kind}={json.dumps(str(template))}')
    preset.write_text(text)
    game = output / "game"
    game.mkdir()
    run_godot([str(godot), "--path", str(source), "--editor", "--import"], output / "game-import.log")
    run_godot([str(godot), "--path", str(source), "--export-debug" if debug else "--export-release",
               "Windows Desktop", str(game / "TacticsTemplateG.exe")], output / "game-export.log")
    # Engine notices come from an empty project: game autoloads need no content.
    notice_project = source.parent / "engine-notices"
    notice_project.mkdir()
    (notice_project / "project.godot").write_text('config_version=5\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    shutil.copy2(source / "tools/audio/engine_notices.gd", notice_project / "engine_notices.gd")
    run_godot([str(godot), "--path", str(notice_project), "--script", "res://engine_notices.gd",
               "--", str(game / "GODOT-NOTICES.txt")], output / "engine-notices.log")
    shutil.copytree(source / "LICENSES", game / "LICENSES")
    for name in ("LICENSE.txt", "THIRD_PARTY_NOTICES.txt", "SOURCE.txt"):
        shutil.copy2(output / name if name == "SOURCE.txt" else source / name, game / name)
    (game / "EXPORT-ENGINE.json").write_text(json.dumps({
        "version": version, "editor_sha256": digest(godot),
        "template_archive_url": TEMPLATE_ARCHIVE_URL,
        "template_archive_sha512": TEMPLATE_ARCHIVE_SHA512,
        "template_sha256": digest(templates / f"windows_{'debug' if debug else 'release'}_x86_64.exe"),
    }, indent=2) + "\n")
    zip_tree(output / "TacticsTemplateG-windows.zip", game, [p for p in game.rglob("*") if p.is_file()])


def package(output, export=False, godot=None, templates=None, debug=False, offline=False):
    output.mkdir(parents=True, exist_ok=False)
    try:
        with tempfile.TemporaryDirectory(prefix="tactics-distribution-") as tmp:
            source = Path(tmp) / "source"
            source.mkdir()
            stage(ROOT, source, MANIFEST, include_dependency=True, offline=offline)
            files = sorted(p for p in source.rglob("*") if p.is_file())
            (source / "FILES.sha256").write_text("".join(
                f"{digest(p)}  {p.relative_to(source).as_posix()}\n" for p in files))
            archive = output / "TacticsTemplateG-source.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(source, arcname="TacticsTemplateG-source")
            source_notice = ("Corresponding source for this distribution is provided alongside it:\n"
                             f"{archive.name}\nSHA256: {digest(archive)}\n"
                             "Distribute both downloads together with equivalent access.\n"
                             "See docs/audio-installation.md in the source for build instructions.\n")
            (output / "SOURCE.txt").write_text(source_notice)
            (source / "SOURCE.txt").write_text(source_notice)
            addon_paths = [p for base in (source / "addons/exmateria_sound", source / "addons/exmateria_spu", source / "LICENSES")
                           for p in base.rglob("*") if p.is_file()]
            addon_paths += [source / n for n in ("LICENSE.txt", "THIRD_PARTY_NOTICES.txt", "SOURCE.txt")]
            zip_tree(output / "TacticsTemplateG-audio-addons.zip", source, addon_paths)
            if export:
                export_game(source, output, godot, templates, debug)
            (output / "SHA256SUMS").write_text("".join(f"{digest(p)}  {p.name}\n"
                for p in sorted(output.iterdir()) if p.is_file() and p.suffix in {".zip", ".gz"}))
    except Exception:
        (output / "RELEASE-BLOCKED.txt").write_text("Packaging/export failed. Do not distribute partial output; inspect command logs.\n")
        raise
    print(f"Created paired binary/source artifacts in {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New, empty/nonexistent distribution directory")
    parser.add_argument("--export-game", action="store_true")
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--templates", type=Path)
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--offline", action="store_true", help="Require included/cached godot-cpp for complete source")
    args = parser.parse_args()
    if args.export_game and (not args.godot or not args.templates):
        parser.error("--export-game requires --godot and --templates")
    package(args.output.resolve(), args.export_game,
            args.godot.resolve() if args.godot else None,
            args.templates.resolve() if args.templates else None, args.debug, args.offline)
