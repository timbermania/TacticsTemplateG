#!/usr/bin/env python3
"""Stage allowlisted files, verify the Effects installation, and pair binaries with source.

Default: a full game/addon corresponding-source archive.
--export-game: also export the Windows game from that SAME clean snapshot.
Never publishes or uploads. Raw editor exports bypass these checks: do not ship them.

🔴 THIS LIVED IN `tools/audio/` AND WAS NEVER AUDIO-ONLY. It is the project's single
release-packaging entry point: it owns the distribution allowlist, which covers every
shipped tree, and its `stage()` verifies the Effects installation. `tools/effects/
run_checks.py` used to insert `tools/audio` on `sys.path` purely so `test_installation.py`
could import it from here. When the ExMateria Sound/SPU addons were removed the audio
tooling went with them, so the packager moved to the tree that actually still needs it
and the sys.path hop is gone.

WHAT CAME OUT WITH THE ADDONS: `verify_native()` (the SPU binary/source receipts), the
`godot-cpp` dependency provisioning, and the audio-addons installer ZIP. All three were
about the native SPU extension, which no longer exists here.

⚠️ THE PAIRED-SOURCE APPARATUS BELOW IS NO LONGER A LICENCE OBLIGATION. The source
tarball, `FILES.sha256` and `SOURCE.txt` existed to satisfy GPL-3's corresponding-source
requirement, which came from the removed audio addons and from the Effects selection's
upstream root licence. Both are gone — the project is MIT throughout. This keeps
producing them anyway, because a reproducible source snapshot pinned beside the binary
is worth having on its own terms; it is now a choice and can be dropped without a
licence consequence.
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

from verify_installation import verify as verify_effects

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "tools/effects/distribution-files.txt"
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


def stage(root, destination, manifest):
    paths = [line for line in manifest.read_text().splitlines() if line and not line.startswith("#")]
    if len(paths) != len(set(paths)):
        raise ValueError("Duplicate distribution path")
    for relative in paths:
        source = safe_path(root, relative)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    # The allowlist itself travels in corresponding source; no Git checkout needed.
    target = destination / "tools/effects/distribution-files.txt"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(manifest, target)
    verify_effects(destination)


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
    shutil.copy2(source / "tools/effects/engine_notices.gd", notice_project / "engine_notices.gd")
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


def package(output, export=False, godot=None, templates=None, debug=False):
    output.mkdir(parents=True, exist_ok=False)
    try:
        with tempfile.TemporaryDirectory(prefix="tactics-distribution-") as tmp:
            source = Path(tmp) / "source"
            source.mkdir()
            stage(ROOT, source, MANIFEST)
            files = sorted(p for p in source.rglob("*") if p.is_file())
            (source / "FILES.sha256").write_text("".join(
                f"{digest(p)}  {p.relative_to(source).as_posix()}\n" for p in files))
            archive = output / "TacticsTemplateG-source.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(source, arcname="TacticsTemplateG-source")
            source_notice = ("Corresponding source for this distribution is provided alongside it:\n"
                             f"{archive.name}\nSHA256: {digest(archive)}\n"
                             "Distribute both downloads together with equivalent access.\n"
                             "See docs/effects-installation.md in the source for scope.\n")
            (output / "SOURCE.txt").write_text(source_notice)
            (source / "SOURCE.txt").write_text(source_notice)
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
    args = parser.parse_args()
    if args.export_game and (not args.godot or not args.templates):
        parser.error("--export-game requires --godot and --templates")
    package(args.output.resolve(), args.export_game,
            args.godot.resolve() if args.godot else None,
            args.templates.resolve() if args.templates else None, args.debug)
