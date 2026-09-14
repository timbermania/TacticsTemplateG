#!/usr/bin/env python3
"""Explicit, pinned godot-cpp provisioning for native builds/source delivery only."""
import argparse
import hashlib
import gzip
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
RELATIVE = "third_party/exmateria-sound/extern/godot-cpp"
LOCK = "tools/audio/godot_cpp.lock.json"
MAX_ARCHIVE = 8 * 1024 * 1024
MAX_FILE = 16 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
MAX_ENTRIES = 2048


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def no_links(path):
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError(f"Dependency symlink forbidden: {component}")


def relative_name(name):
    path = PurePosixPath(name)
    if (not name or "\\" in name or ":" in name or path.is_absolute()
            or any(part in {"", ".", "..", ".git"} for part in name.split("/"))):
        raise ValueError(f"Unsafe dependency path: {name}")
    return path


def read_lock(root):
    path = root / LOCK
    no_links(path)
    if path.stat().st_size > 256 * 1024:
        raise ValueError("Oversized godot-cpp lock")
    lock = json.loads(path.read_text())
    if (not isinstance(lock, dict) or lock.get("version") != 1
            or not isinstance(lock.get("revision"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", lock["revision"])):
        raise ValueError("Unsupported godot-cpp lock/version")
    expected_url = "https://codeload.github.com/godotengine/godot-cpp/tar.gz/" + lock["revision"]
    if lock.get("archive_url") != expected_url or not re.fullmatch(r"[0-9a-f]{64}", lock.get("archive_sha256", "")):
        raise ValueError("Invalid pinned godot-cpp archive")
    files, additions = lock.get("files"), lock.get("local_additions")
    if not isinstance(files, dict) or not files or len(files) > MAX_ENTRIES or not isinstance(additions, dict):
        raise ValueError("Invalid godot-cpp inventory")
    for name, expected in files.items():
        relative_name(name)
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError("Invalid godot-cpp file hash")
    for name, text in additions.items():
        if not isinstance(text, str) or hashlib.sha256(text.encode()).hexdigest() != files.get(name):
            raise ValueError("Invalid godot-cpp local addition")
    return lock


def verify_tree(tree, lock):
    no_links(tree)
    if not tree.is_dir():
        raise ValueError(f"Missing godot-cpp source: {tree}")
    actual = {}
    total = 0
    for count, path in enumerate(tree.rglob("*"), 1):
        if count > MAX_ENTRIES:
            raise ValueError("Dependency inventory exceeds entry budget")
        no_links(path)
        if path.is_dir():
            continue
        if not path.is_file() or path.stat().st_size > MAX_FILE:
            raise ValueError(f"Invalid dependency file: {path}")
        total += path.stat().st_size
        if total > MAX_TOTAL or len(actual) >= MAX_ENTRIES:
            raise ValueError("Dependency inventory exceeds budget")
        actual[path.relative_to(tree).as_posix()] = digest(path)
    if actual != lock["files"]:
        raise ValueError("godot-cpp source inventory/hash mismatch; refusing altered cache/source")
    return tree


class _BoundedReader:
    """Cap decompressed bytes, including hidden tar/PAX metadata, not just files."""
    def __init__(self, stream):
        self.stream = stream
        self.remaining = MAX_TOTAL + MAX_ENTRIES * 1024

    def read(self, size=-1):
        data = self.stream.read(min(size, self.remaining + 1) if size >= 0 else self.remaining + 1)
        self.remaining -= len(data)
        if self.remaining < 0:
            raise ValueError("Dependency archive exceeds decompressed byte budget")
        return data


def extract_archive(archive, destination, lock):
    """No extractall: validate names/types/budgets before creating regular files."""
    no_links(archive)
    if archive.stat().st_size > MAX_ARCHIVE or digest(archive) != lock["archive_sha256"]:
        raise ValueError("godot-cpp archive checksum/size mismatch")
    no_links(destination)
    destination.mkdir()  # Caller supplies a new directory, never overlay existing data.
    prefix = "godot-cpp-" + lock["revision"]
    seen = set()
    total = 0
    with gzip.open(archive, "rb") as compressed, tarfile.open(fileobj=_BoundedReader(compressed), mode="r|") as source:
        for entry in source:
            name = entry.name.rstrip("/") if entry.isdir() else entry.name
            relative_name(name)
            if name in seen or len(seen) >= MAX_ENTRIES:
                raise ValueError("Duplicate/excessive dependency archive entries")
            seen.add(name)
            if name != prefix and not name.startswith(prefix + "/"):
                raise ValueError("Dependency archive revision/root mismatch")
            if not entry.isdir() and not entry.isfile():
                raise ValueError("Dependency archive links/special files forbidden")
            if entry.isdir():
                continue
            relative = name[len(prefix) + 1:]
            if relative not in lock["files"] or relative in lock["local_additions"]:
                raise ValueError("Unexpected dependency archive file")
            total += entry.size
            if entry.size < 0 or entry.size > MAX_FILE or total > MAX_TOTAL:
                raise ValueError("Dependency archive exceeds extraction budget")
            with source.extractfile(entry) as stream:
                data = stream.read(MAX_FILE + 1)
            if len(data) != entry.size or hashlib.sha256(data).hexdigest() != lock["files"][relative]:
                raise ValueError("Dependency archive file hash mismatch")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(entry.mode & 0o777)
    for name, text in lock["local_additions"].items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8", newline="")
    return verify_tree(destination, lock)


class _HTTPSOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        # Check before urllib constructs/follows the next request, not only
        # after the final response (which could hide a downgrade in a chain).
        if urllib.parse.urlsplit(newurl).scheme.lower() != "https":
            raise ValueError("Dependency download must remain HTTPS")
        return super().redirect_request(request, response, code, message, headers, newurl)


def open_https(url, timeout=60):
    if urllib.parse.urlsplit(url).scheme.lower() != "https":
        raise ValueError("Dependency download must remain HTTPS")
    return urllib.request.build_opener(_HTTPSOnlyRedirect()).open(url, timeout=timeout)


def provision(root=ROOT, *, offline=False, archive=None):
    """Prefer complete release source; otherwise verify/use ignored cache.

    Only this explicit operation may download. Altered existing trees/archives
    fail closed; they are never silently repaired. Remove a bad cache manually.
    """
    lock = read_lock(root)
    included = root / RELATIVE
    no_links(included)
    if included.exists():
        return verify_tree(included, lock)
    cache = root / ".build/dependencies"
    no_links(cache)
    tree = cache / ("godot-cpp-" + lock["revision"])
    no_links(tree)
    if tree.exists():
        return verify_tree(tree, lock)
    cached_archive = cache / (lock["archive_sha256"] + ".tar.gz")
    no_links(cached_archive)
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".godot-cpp-", dir=cache) as temporary:
        temporary = Path(temporary)
        selected = archive or cached_archive
        if archive is None and not cached_archive.exists():
            if offline:
                raise ValueError("godot-cpp unavailable offline; explicitly provision it first")
            selected = temporary / "download.tar.gz"
            with open_https(lock["archive_url"], timeout=60) as response, selected.open("wb") as output:
                if not response.geturl().startswith("https://"):
                    raise ValueError("Dependency download must remain HTTPS")
                size = 0
                while chunk := response.read(64 * 1024):
                    size += len(chunk)
                    if size > MAX_ARCHIVE:
                        raise ValueError("Dependency download exceeds budget")
                    output.write(chunk)
        prepared = extract_archive(selected, temporary / "tree", lock)
        # Publish only after full archive + reconstructed inventory verification.
        if not cached_archive.exists():
            shutil.copyfile(selected, temporary / "verified.tar.gz")
            (temporary / "verified.tar.gz").rename(cached_archive)
        prepared.rename(tree)
    return tree


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Never download; require included source/cached archive")
    parser.add_argument("--archive", type=Path, help="Use a local archive, still enforcing pinned checksum")
    args = parser.parse_args()
    print(provision(offline=args.offline, archive=args.archive))
