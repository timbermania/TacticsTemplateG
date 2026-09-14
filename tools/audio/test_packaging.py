"""Source-delivery guards; tests use no ROM content and publish nothing."""
import json
from pathlib import Path
import tarfile
import tempfile
import sys
import unittest
import zipfile

import package_release as release
from run_smoke import checked_run


class DistributionTests(unittest.TestCase):
    def test_rejects_rom_private_and_escaping_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("WAVESET.WD", "music.SMD", "feds.bin", "path", "../private.gd",
                         "/tmp/private.gd", "assets/data.gd", "overrides/a.gd", ".godot/a.gd"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    release.safe_path(root, name)

    def test_rejects_symlinked_file_and_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "file.gd").write_text("extends Node\n")
            (root / "link.gd").symlink_to(root / "file.gd")
            (root / "directory").mkdir()
            (root / "directory/a.gd").write_text("extends Node\n")
            (root / "link").symlink_to(root / "directory", target_is_directory=True)
            for name in ("link.gd", "link/a.gd"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    release.safe_path(root, name)

    def test_runner_rejects_leak_warning_even_after_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            command = [sys.executable, "-c", "print('AUDIO_SMOKE: PASS'); print('WARNING: ObjectDB instances leaked at exit')"]
            with self.assertRaises(RuntimeError):
                checked_run(command, Path(tmp) / "log.txt", "AUDIO_SMOKE: PASS")

    def test_native_receipts_match_checkout(self):
        release.verify_native(release.ROOT)

    def test_source_and_binary_mutation_block_distribution(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp)
            release.stage(release.ROOT, staged, release.MANIFEST)
            receipt = json.loads((staged / "tools/audio/builds/linux-template_debug.json").read_text())
            for name in (receipt["binary"], "third_party/exmateria-sound/src/native/exmateria_psx_spu.cpp"):
                path = staged / name
                original = path.read_bytes()
                path.write_bytes(original + b"modified")
                with self.subTest(name=name), self.assertRaises(ValueError):
                    release.verify_native(staged)
                path.write_bytes(original)

    def test_package_pairs_addons_with_complete_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "delivery"
            release.package(output)
            source_archive = output / "TacticsTemplateG-source.tar.gz"
            with zipfile.ZipFile(output / "TacticsTemplateG-audio-addons.zip") as archive:
                names = set(archive.namelist())
                self.assertIn("addons/exmateria_spu/bin/libexmateria_spu.windows.template_release.x86_64.dll", names)
                self.assertIn("LICENSES/GPL-3.0.txt", names)
                self.assertIn("THIRD_PARTY_NOTICES.txt", names)
                self.assertIn(release.digest(source_archive), archive.read("SOURCE.txt").decode())
                self.assertFalse(any("fft_smd.gdextension" in p or "/bin/libfftsmd" in p for p in names))
            with tarfile.open(source_archive) as archive:
                names = {p.removeprefix("TacticsTemplateG-source/") for p in archive.getnames()}
                for name in ("src/utilities/utilities.gd", "project.godot", "FILES.sha256",
                             "tools/audio/build_native.py", "tools/audio/distribution-files.txt",
                             "third_party/exmateria-sound/src/shared/detail/fft_gauss_table.inc",
                             "third_party/exmateria-sound/extern/godot-cpp/gdextension/extension_api.json",
                             "docs/audio-installation.md"):
                    self.assertIn(name, names)
                self.assertNotIn("path", names)
                self.assertFalse(any(".scratch/" in p or ".build/" in p or ".godot/" in p for p in names))


if __name__ == "__main__":
    unittest.main()
