#!/usr/bin/env python3
"""Verify selected committed Effects bytes and explicit native host configuration.

No downloads, imports, writes or dependency provisioning. Optional --upstream
compares git objects at the lock's pin, never the upstream working tree.
"""
import argparse
import configparser
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ADDONS = ("exmateria_effects", "exmateria_platform", "exmateria_render", "exmateria_schema")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_file(root, relative):
    path = PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts or not path.parts or path.as_posix() != relative:
        raise ValueError(f"Unsafe Effects path: {relative}")
    current = root
    for part in path.parts:
        current /= part
        if current.is_symlink():
            raise ValueError(f"Effects symlink forbidden: {relative}")
    if not current.is_file():
        raise ValueError(f"Missing Effects input: {relative}")
    return current


def verify(root=ROOT, upstream=None, *, allow_import_metadata=False):
    root = Path(root)
    lock = json.loads(safe_file(root, "tools/effects/upstream.json").read_text())
    if lock["schema_version"] != 1:
        raise ValueError("Unsupported Effects lock schema")
    manifest = safe_file(root, lock["manifest"]).read_bytes()
    if digest(manifest) != lock["manifest_sha256"]:
        raise ValueError("Effects manifest hash mismatch")
    rows = json.loads(manifest)
    names = [r["destination"] for r in rows]
    if len(names) != lock["file_count"] or len(set(names)) != len(names):
        raise ValueError("Effects inventory count/duplicates mismatch")
    if sum(r["bytes"] for r in rows) != lock["total_bytes"]:
        raise ValueError("Effects inventory byte count mismatch")
    for row in rows:
        name = row["destination"]
        if not any(name.startswith(f"addons/{addon}/") for addon in ADDONS):
            raise ValueError(f"Outside selected Effects packages: {name}")
        if (row["repository"] != "upstream" or row["revision"] != lock["revision"]
                or row["source"] != lock["source_prefix"] + name):
            raise ValueError(f"Effects provenance mismatch: {name}")
        data = safe_file(root, name).read_bytes()
        if len(data) != row["bytes"] or digest(data) != row["sha256"]:
            raise ValueError(f"Effects source hash mismatch: {name}")
        if upstream:
            committed = subprocess.check_output([
                "git", "-C", str(upstream), "show", f'{lock["revision"]}:{row["source"]}'])
            if committed != data:
                raise ValueError(f"Effects committed source mismatch: {name}")
    actual = set()
    for addon in ADDONS:
        for path in (root / "addons" / addon).rglob("*"):
            if path.is_symlink():
                raise ValueError(f"Effects symlink forbidden: {path}")
            if path.is_file():
                actual.add(path.relative_to(root).as_posix())
    # A developer's normal Godot import creates these sidecars, not new sources.
    # CLI/root checks may tolerate them; source-distribution staging stays exact.
    generated = {name + ".import" for name in names if name.endswith(".glsl")} if allow_import_metadata else set()
    if actual - generated != set(names):
        raise ValueError(f"Unexpected Effects files: {sorted(actual - set(names) - generated)}")
    license_info = lock["license"]
    license_bytes = safe_file(root, license_info["installed"]).read_bytes()
    if digest(license_bytes) != license_info["sha256"]:
        raise ValueError("Effects GPL license hash mismatch")
    if upstream and subprocess.check_output([
            "git", "-C", str(upstream), "show", f'{lock["revision"]}:{license_info["source"]}']) != license_bytes:
        raise ValueError("Effects upstream license mismatch")
    config = configparser.ConfigParser(interpolation=None, strict=True)
    config.optionxform = str
    # Godot object/input syntax is not INI. Parse only the simple relevant sections.
    text = safe_file(root, "project.godot").read_text()
    section = None
    selected = []
    for line in text.splitlines():
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
        if section in {"autoload", "rendering", "editor_plugins"}:
            selected.append(line)
    config.read_string("\n".join(selected))
    profile = lock["profile"]
    for name, path in profile["autoloads"].items():
        if config.get("autoload", name, fallback=None) != f'"*res://{path}"':
            raise ValueError(f"Effects autoload mismatch: {name}")
    for key in ("renderer/rendering_method", "renderer/rendering_method.mobile"):
        if config.get("rendering", key, fallback=None) != json.dumps(profile["renderer"]):
            raise ValueError(f"Effects renderer mismatch: {key}")
    plugins = config.get("editor_plugins", "enabled", fallback="")
    if any(f"addons/{addon}/plugin.cfg" in plugins for addon in ADDONS):
        raise ValueError("Selected Effects profile must not enable full plugins")
    # Shader globals use JSON-compatible dictionaries, allowing multiline formatting.
    globals_text = text.split("[shader_globals]\n", 1)[-1].split("\n[", 1)[0]
    decoder = json.JSONDecoder()
    for name, value in profile["shader_globals"].items():
        matches = list(re.finditer(r"^" + re.escape(name) + r"\s*=\s*", globals_text, re.M))
        if len(matches) != 1:
            raise ValueError(f"Effects shader global missing/duplicate: {name}")
        setting, _ = decoder.raw_decode(globals_text[matches[0].end():])
        if setting != {"type": "float", "value": value}:
            raise ValueError(f"Effects shader global mismatch: {name}")
    return lock


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--upstream", type=Path, help="Optional local Git repository with pinned objects")
    args = parser.parse_args()
    lock = verify(args.root, args.upstream, allow_import_metadata=True)
    print(f'EFFECTS_INSTALLATION: PASS ({lock["file_count"]} files, {lock["total_bytes"]} bytes)')


if __name__ == "__main__":
    main()
