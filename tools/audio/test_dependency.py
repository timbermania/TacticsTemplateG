"""Pinned provisioning tests use tiny generated archives, never network/private data."""
import hashlib
import gzip
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import godot_cpp as dependency

REVISION = "1" * 40
PREFIX = "godot-cpp-" + REVISION


def fixture(root, entries=None):
    """Write synthetic pinned archive/lock. Override entries for adversarial tar tests."""
    files = {"gdextension/extension_api.json": b"{}\n", "LICENSE.md": b"synthetic license\n"}
    archive = root / "fixture.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        for name, content, kind in entries if entries is not None else [(PREFIX + "/" + n, b, tarfile.REGTYPE) for n, b in files.items()]:
            entry = tarfile.TarInfo(name)
            entry.type = kind
            entry.size = len(content) if kind == tarfile.REGTYPE else 0
            entry.linkname = "../../outside" if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE) else ""
            tar.addfile(entry, io.BytesIO(content) if kind == tarfile.REGTYPE else None)
    additions = {"test/project/.gitignore": "# synthetic local addition\n"}
    lock = {"version": 1, "revision": REVISION,
            "archive_url": "https://codeload.github.com/godotengine/godot-cpp/tar.gz/" + REVISION,
            "archive_sha256": dependency.digest(archive), "local_additions": additions,
            "files": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}
    lock["files"].update({name: hashlib.sha256(text.encode()).hexdigest() for name, text in additions.items()})
    (root / dependency.LOCK).parent.mkdir(parents=True, exist_ok=True)
    (root / dependency.LOCK).write_text(json.dumps(lock))
    return archive, lock


class DependencyTests(unittest.TestCase):
    def test_https_redirects_are_checked_before_following(self):
        handler = dependency._HTTPSOnlyRedirect()
        request = dependency.urllib.request.Request("https://example.test/archive")
        for target in ("http://example.test/archive", "ftp://example.test/archive"):
            with self.subTest(target=target), patch("urllib.request.HTTPRedirectHandler.redirect_request") as follow:
                with self.assertRaisesRegex(ValueError, "remain HTTPS"):
                    handler.redirect_request(request, None, 302, "Found", {}, target)
                follow.assert_not_called()
        # An allowed HTTPS hop must not permit a later HTTP downgrade.
        request = handler.redirect_request(request, None, 302, "Found", {}, "https://other.test/archive")
        with self.assertRaisesRegex(ValueError, "remain HTTPS"):
            handler.redirect_request(request, None, 302, "Found", {}, "http://other.test/archive")
        with patch("godot_cpp.urllib.request.build_opener") as build:
            with self.assertRaisesRegex(ValueError, "remain HTTPS"):
                dependency.open_https("http://example.test/archive")
            build.assert_not_called()
            dependency.open_https("https://example.test/archive", timeout=7)
            self.assertIsInstance(build.call_args.args[0], dependency._HTTPSOnlyRedirect)
            build.return_value.open.assert_called_once_with("https://example.test/archive", timeout=7)

    def test_local_provision_and_cached_offline_reuse(self):
        with tempfile.TemporaryDirectory() as tmp, patch("godot_cpp.open_https", side_effect=AssertionError("network")):
            root = Path(tmp)
            archive, lock = fixture(root)
            with self.assertRaisesRegex(ValueError, "unavailable offline"):
                dependency.provision(root, offline=True)
            tree = dependency.provision(root, offline=True, archive=archive)
            self.assertEqual(dependency.provision(root, offline=True), tree)
            self.assertEqual(len(lock["files"]), len([p for p in tree.rglob("*") if p.is_file()]))
            (tree / "LICENSE.md").write_text("altered")
            with self.assertRaisesRegex(ValueError, "inventory/hash"):
                dependency.provision(root)

    def test_explicit_download_verifies_bytes_and_reuses_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, lock = fixture(root)
            response = io.BytesIO(archive.read_bytes())
            response.geturl = lambda: lock["archive_url"]
            with patch("godot_cpp.open_https", return_value=response) as download:
                tree = dependency.provision(root)
                download.assert_called_once_with(lock["archive_url"], timeout=60)
            import shutil
            shutil.rmtree(tree)
            with patch("godot_cpp.open_https", side_effect=AssertionError("network")):
                dependency.provision(root, offline=True)  # verified cached archive, not tree
        for data in (b"wrong archive", b"oversized"):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                _, lock = fixture(root)
                response = io.BytesIO(data)
                response.geturl = lambda: lock["archive_url"]
                with patch("godot_cpp.open_https", return_value=response), patch.object(dependency, "MAX_ARCHIVE", 5 if data == b"oversized" else dependency.MAX_ARCHIVE), self.assertRaises(ValueError):
                    dependency.provision(root)
                self.assertFalse((root / ".build/dependencies" / PREFIX).exists())

    def test_archive_digest_and_bad_version_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, lock = fixture(root)
            archive.write_bytes(archive.read_bytes() + b"modified")
            with self.assertRaisesRegex(ValueError, "checksum"):
                dependency.provision(root, offline=True, archive=archive)
            lock["version"] = 2
            (root / dependency.LOCK).write_text(json.dumps(lock))
            with self.assertRaisesRegex(ValueError, "lock/version"):
                dependency.provision(root, offline=True, archive=archive)
            self.assertFalse((root / ".build/dependencies" / PREFIX).exists())

    def test_rejects_unsafe_archive_members_even_with_matching_archive_hash(self):
        entries = [("/escape", b"", tarfile.REGTYPE),
                   (PREFIX + "/../escape", b"", tarfile.REGTYPE),
                   (PREFIX + "/C:\\escape", b"", tarfile.REGTYPE),
                   ("godot-cpp-" + "2" * 40 + "/LICENSE.md", b"", tarfile.REGTYPE),
                   (PREFIX + "/LICENSE.md", b"", tarfile.SYMTYPE),
                   (PREFIX + "/LICENSE.md", b"", tarfile.LNKTYPE),
                   (PREFIX + "/LICENSE.md", b"", tarfile.FIFOTYPE),
                   (PREFIX + "/unexpected", b"", tarfile.REGTYPE)]
        for entry in entries:
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive, lock = fixture(root, [entry])
                with self.assertRaises(ValueError):
                    dependency.extract_archive(archive, root / "tree", lock)

    def test_rejects_duplicate_missing_and_changed_files(self):
        valid = (PREFIX + "/LICENSE.md", b"synthetic license\n", tarfile.REGTYPE)
        for entries in ([valid, valid], [], [(valid[0], b"wrong", valid[2])]):
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive, lock = fixture(root, entries)
                with self.assertRaises(ValueError):
                    dependency.extract_archive(archive, root / "tree", lock)

    def test_budgets_and_corrupt_gzip(self):
        for limit in ("MAX_FILE", "MAX_TOTAL", "MAX_ENTRIES", "MAX_ARCHIVE"):
            with self.subTest(limit=limit), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive, lock = fixture(root)
                with patch.object(dependency, limit, 1), self.assertRaises(ValueError):
                    dependency.extract_archive(archive, root / "tree", lock)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, lock = fixture(root)
            archive.write_bytes(b"not gzip")
            lock["archive_sha256"] = dependency.digest(archive)
            with self.assertRaises((tarfile.ReadError, gzip.BadGzipFile)):
                dependency.extract_archive(archive, root / "tree", lock)

    def test_decompressed_metadata_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, lock = fixture(root)
            with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as tar:
                entry = tarfile.TarInfo(PREFIX + "/LICENSE.md")
                entry.pax_headers = {"comment": "x" * 10000}
                entry.size = 0
                tar.addfile(entry, io.BytesIO())
            lock["archive_sha256"] = dependency.digest(archive)
            with patch.object(dependency, "MAX_TOTAL", 1), patch.object(dependency, "MAX_ENTRIES", 1), self.assertRaisesRegex(ValueError, "decompressed"):
                dependency.extract_archive(archive, root / "tree", lock)

    def test_included_source_is_offline_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp, patch("godot_cpp.open_https", side_effect=AssertionError("network")):
            root = Path(tmp)
            archive, lock = fixture(root)
            included = root / dependency.RELATIVE
            included.parent.mkdir(parents=True)
            dependency.extract_archive(archive, included, lock)
            self.assertEqual(dependency.provision(root, offline=True), included)
            (included / "extra.txt").write_text("unexpected")
            with self.assertRaises(ValueError):
                dependency.provision(root)
            self.assertFalse((root / ".build").exists())

    def test_symlinked_cache_root_archive_and_tree_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, lock = fixture(root)
            link = root / "archive-link"
            link.symlink_to(archive)
            with self.assertRaises(ValueError):
                dependency.extract_archive(link, root / "tree", lock)
            tree = dependency.provision(root, offline=True, archive=archive)
            (tree / "LICENSE.md").unlink()
            (tree / "LICENSE.md").symlink_to(archive)
            with self.assertRaises(ValueError):
                dependency.provision(root)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive, _ = fixture(root)
            (root / ".build").symlink_to(root, target_is_directory=True)
            with self.assertRaises(ValueError):
                dependency.provision(root, offline=True, archive=archive)


if __name__ == "__main__":
    unittest.main()
