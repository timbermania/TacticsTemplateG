"""Source-delivery guards; tests use no ROM content and publish nothing."""
import json
from pathlib import Path
import tarfile
import tempfile
import sys
import unittest
from unittest.mock import patch
import zipfile

import package_release as release
from run_smoke import checked_run
import godot_cpp as dependency
import build_native
from test_dependency import fixture


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

    def test_export_engine_tracks_upstream_validation_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "export_presets.cfg").write_text("")
            for version in ("4.6.1.stable.official.old", "4.7.2.stable.custom.build", "4.8.dev.custom.build"):
                with self.subTest(version=version), patch("package_release.subprocess.check_output", return_value=version):
                    with self.assertRaisesRegex(ValueError, "official Godot 4.7.2"):
                        release.export_game(root, root, root / "godot", root, False)
            # A matching official engine proceeds to matching-template validation.
            with patch("package_release.subprocess.check_output", return_value="4.7.2.stable.official.test"):
                with self.assertRaisesRegex(ValueError, "Missing matching Godot template"):
                    release.export_game(root, root, root / "godot", root, False)

    def test_rejects_existing_private_audio_formats(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("SYSTEM.SED", "environment.sed", "E001.feds", "E002.FEDS"):
                (root / name).write_bytes(b"synthetic private audio")
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "ROM-format"):
                    release.safe_path(root, name)

    def test_rejects_existing_wrong_templates_before_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            preset = root / "export_presets.cfg"
            preset.write_text('custom_template/debug=""\ncustom_template/release=""\n')
            original = preset.read_text()
            for kind in ("debug", "release"):
                (root / f"windows_{kind}_x86_64.exe").write_bytes(b"old or custom template")
            with patch("package_release.subprocess.check_output", return_value="4.7.2.stable.official.test"), patch("package_release.run_godot") as run:
                with self.assertRaisesRegex(ValueError, "Template hash mismatch"):
                    release.export_game(root, root, root / "godot", root, False)
                run.assert_not_called()
                self.assertEqual(preset.read_text(), original)
                self.assertFalse((root / "game").exists())

    def test_template_checks_cover_both_variants_and_preset(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            source.mkdir()
            preset = source / "export_presets.cfg"
            original = 'custom_template/debug=""\ncustom_template/release=""\n'
            preset.write_text(original)
            for kind in ("debug", "release"):
                (root / f"windows_{kind}_x86_64.exe").write_bytes(b"fixture")
            def expected_digest(path):
                return release.TEMPLATE_SHA256["debug" if "debug" in path.name else "release"]
            with patch("package_release.subprocess.check_output", return_value="4.7.2.stable.official.test"), patch("package_release.run_godot", side_effect=RuntimeError("export reached")) as run:
                with patch("package_release.digest", side_effect=[release.TEMPLATE_SHA256["debug"], "wrong-release"]):
                    with self.assertRaisesRegex(ValueError, "Template hash mismatch"):
                        release.export_game(source, root, root / "godot", root, True)
                run.assert_not_called()
                self.assertEqual(preset.read_text(), original)
                with patch("package_release.digest", side_effect=expected_digest):
                    preset.write_text(original.replace('custom_template/release=""', 'custom_template/release="unverified.exe"'))
                    with self.assertRaisesRegex(ValueError, "Expected one empty release"):
                        release.export_game(source, root, root / "godot", root, False)
                    run.assert_not_called()
                    preset.write_text(original)
                    with self.assertRaisesRegex(RuntimeError, "export reached"):
                        release.export_game(source, root, root / "godot", root, False)
                    run.assert_called_once()
                    self.assertIn(str(root / "windows_release_x86_64.exe"), preset.read_text())

    def test_native_receipts_match_checkout(self):
        release.verify_native(release.ROOT)

    def test_effects_selection_is_required_and_verified_by_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            release.stage(release.ROOT, root / "source", release.MANIFEST)
            source = root / "source"
            effect = source / "addons/exmateria_effects/exmateria_effects.gd"
            original = effect.read_bytes()
            effect.write_bytes(original + b"changed")
            with self.assertRaisesRegex(ValueError, "Effects source hash mismatch"):
                release.stage(source, root / "mutated", source / "tools/audio/distribution-files.txt")
            effect.write_bytes(original)
            manifest = root / "incomplete.txt"
            manifest.write_text(release.MANIFEST.read_text().replace(
                "addons/exmateria_effects/exmateria_effects.gd\n", ""))
            with self.assertRaisesRegex(ValueError, "Missing Effects input"):
                release.stage(source, root / "incomplete", manifest)

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

    def test_runtime_stage_needs_no_dependency_or_download(self):
        with tempfile.TemporaryDirectory() as tmp, patch("godot_cpp.open_https", side_effect=AssertionError("network")):
            root = Path(tmp)
            release.stage(release.ROOT, root, release.MANIFEST)
            self.assertFalse((root / dependency.RELATIVE).exists())
            self.assertFalse((root / ".build").exists())
            release.verify_native(root)
            with self.assertRaisesRegex(ValueError, "materialized"):
                release.verify_native(root, require_dependency=True)
            # No fallback from source delivery to runtime-only staging.
            with self.assertRaisesRegex(ValueError, "unavailable offline"):
                release.stage(root, root / "source", root / "tools/audio/distribution-files.txt",
                              include_dependency=True, offline=True)

    def test_legacy_recipe_and_schema_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            release.stage(release.ROOT, root, release.MANIFEST)
            path = root / release.LEGACY_BUILDER
            path.write_bytes(path.read_bytes() + b"changed")
            with self.assertRaisesRegex(ValueError, "Native source changed"):
                release.verify_native(root)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            release.stage(release.ROOT, root, release.MANIFEST)
            path = root / "tools/audio/builds/linux-template_debug.json"
            receipt = json.loads(path.read_text())
            receipt["schema_version"] = 999
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, "schema"):
                release.verify_native(root)

    def test_package_pairs_addons_with_complete_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "delivery"
            # Real staging/packaging with tiny pinned source fixture, not a
            # network-dependent test or an unverified mocked source omission.
            root = Path(tmp) / "fixture-root"
            release.stage(release.ROOT, root, release.MANIFEST)
            archive, lock = fixture(root)
            dependency.provision(root, offline=True, archive=archive)
            for path in (root / "tools/audio/builds").glob("*.json"):
                receipt = json.loads(path.read_text())
                receipt["source_files"] = {n: h for n, h in receipt["source_files"].items()
                                           if not n.startswith(dependency.RELATIVE + "/")}
                receipt["source_files"].update({dependency.RELATIVE + "/" + n: h for n, h in lock["files"].items()})
                receipt["source_fingerprint"] = build_native.fingerprint(receipt["source_files"])
                path.write_text(json.dumps(receipt))
            with patch.object(release, "ROOT", root), patch.object(release, "MANIFEST", root / "tools/audio/distribution-files.txt"), patch("godot_cpp.open_https", side_effect=AssertionError("network")):
                release.package(output, offline=True)
            source_archive = output / "TacticsTemplateG-source.tar.gz"
            with zipfile.ZipFile(output / "TacticsTemplateG-audio-addons.zip") as archive:
                names = set(archive.namelist())
                self.assertIn("addons/exmateria_spu/bin/libexmateria_spu.windows.template_release.x86_64.dll", names)
                self.assertIn("LICENSES/GPL-3.0.txt", names)
                self.assertIn("THIRD_PARTY_NOTICES.txt", names)
                self.assertIn(release.digest(source_archive), archive.read("SOURCE.txt").decode())
                self.assertFalse(any("fft_smd.gdextension" in p or "/bin/libfftsmd" in p for p in names))
                # Existing audio-only installer scope is deliberately unchanged.
                self.assertFalse(any(p.startswith("addons/exmateria_effects/") for p in names))
            with tarfile.open(source_archive) as archive:
                names = {p.removeprefix("TacticsTemplateG-source/") for p in archive.getnames()}
                for name in ("src/utilities/utilities.gd", "project.godot", "FILES.sha256",
                             "tools/audio/build_native.py", "tools/audio/distribution-files.txt",
                             "third_party/exmateria-sound/src/shared/detail/fft_gauss_table.inc",
                             "third_party/exmateria-sound/extern/godot-cpp/gdextension/extension_api.json",
                             "docs/audio-installation.md", "docs/effects-installation.md",
                             "tools/effects/manifest.json", "tools/effects/upstream.json",
                             "tools/effects/verify_installation.py", "tools/effects/run_checks.py",
                             "tools/effects/native_regression.gd"):
                    self.assertIn(name, names)
                self.assertIn("tools/audio/godot_cpp.lock.json", names)
                self.assertIn("tools/audio/builds/original-build_native.py.txt", names)
                extracted = Path(tmp) / "extracted"
                archive.extractall(extracted, filter="data")
                complete = extracted / "TacticsTemplateG-source"
                lock = release.verify_effects(complete)
                effects = json.loads((complete / lock["manifest"]).read_text())
                self.assertEqual(len(effects), 225)
                self.assertTrue({row["destination"] for row in effects} <= names)
                self.assertIn("7933d1d42a89f1e81a99cb15ed61ce363314d12a",
                              (complete / "THIRD_PARTY_NOTICES.txt").read_text())
                with patch("godot_cpp.open_https", side_effect=AssertionError("network")):
                    release.verify_native(complete, require_dependency=True)
                    hashes, work, _ = build_native.prepare_build(complete, "linux", "template_debug", offline=True)
                    self.assertTrue((work / "extern/godot-cpp/gdextension/extension_api.json").is_file())
                    self.assertIn("tools/audio/godot_cpp.py", hashes)
                    (work / "extern/godot-cpp/generated.o").write_bytes(b"intermediate")
                    # Incremental work caches are not mistaken for source-tree tampering.
                    build_native.prepare_build(complete, "linux", "template_debug", offline=True)
                    # Future receipts capture current recipe inputs, with no legacy substitution.
                    for path in (complete / "tools/audio/builds").glob("*.json"):
                        receipt = json.loads(path.read_text())
                        receipt.update(schema_version=2, source_files=hashes,
                                       source_fingerprint=build_native.fingerprint(hashes))
                        path.write_text(json.dumps(receipt))
                    release.verify_native(complete, require_dependency=True)
                    script = complete / "tools/audio/build_native.py"
                    script.write_bytes(script.read_bytes() + b"changed")
                    with self.assertRaisesRegex(ValueError, "Native source changed"):
                        release.verify_native(complete, require_dependency=True)
                self.assertNotIn("path", names)
                self.assertFalse(any(".scratch/" in p or ".build/" in p or ".godot/" in p for p in names))


if __name__ == "__main__":
    unittest.main()
