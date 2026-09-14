"""Pinned-source/profile and strict-runner regressions; no Godot or network needed."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from verify_installation import ROOT, verify
from run_checks import checked_run, isolated_env
from package_release import MANIFEST, stage


class EffectsTests(unittest.TestCase):
    def test_installed_selection_matches_lock_and_allowlist(self):
        lock = verify(allow_import_metadata=True)
        rows = json.loads((ROOT / lock["manifest"]).read_text())
        self.assertEqual(len(rows), 225)
        self.assertEqual(sum(row["bytes"] for row in rows), 965928)
        allowed = set(MANIFEST.read_text().splitlines())
        self.assertTrue({row["destination"] for row in rows} <= allowed)
        for path in (ROOT / "tools/effects").iterdir():
            if path.is_file():
                self.assertIn(path.relative_to(ROOT).as_posix(), allowed)
        self.assertIn("docs/effects-installation.md", allowed)

    def test_mutations_and_unselected_inputs_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage(ROOT, root, MANIFEST)
            name = "addons/exmateria_effects/exmateria_effects.gd"
            path = root / name
            original = path.read_bytes()
            path.write_bytes(original + b"changed")
            with self.assertRaisesRegex(ValueError, "source hash mismatch"):
                verify(root)
            path.unlink()
            with self.assertRaisesRegex(ValueError, "Missing Effects input"):
                verify(root)
            path.symlink_to(ROOT / name)
            with self.assertRaisesRegex(ValueError, "symlink"):
                verify(root)
            path.unlink()
            path.write_bytes(original)
            extra = root / "addons/exmateria_effects/unselected.gd"
            extra.write_text("extends Node\n")
            with self.assertRaisesRegex(ValueError, "Unexpected Effects files"):
                verify(root)
            extra.unlink()
            sidecar = root / "addons/exmateria_render/fold_bracket/foldsurface_seed.glsl.import"
            sidecar.write_text("synthetic Godot-generated metadata")
            with self.assertRaisesRegex(ValueError, "Unexpected Effects files"):
                verify(root)  # Never ship generated sidecars in the source selection.
            verify(root, allow_import_metadata=True)
            sidecar.unlink()
            path = root / "tools/effects/manifest.json"
            path.write_bytes(path.read_bytes() + b" ")
            with self.assertRaisesRegex(ValueError, "manifest hash mismatch"):
                verify(root)

    def test_profile_mutations_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stage(ROOT, root, MANIFEST)
            project = root / "project.godot"
            original = project.read_text()
            for before, after in (
                ('EffectMultiMeshPool="*', 'EffectMultiMeshPool="'),
                ('"gl_compatibility"', '"forward_plus"'),
                ('"value": 1.0', '"value": 0.0'),
                ('enabled=PackedStringArray(', 'enabled=PackedStringArray("res://addons/exmateria_effects/plugin.cfg", '),
            ):
                with self.subTest(before=before):
                    project.write_text(original.replace(before, after, 1))
                    with self.assertRaises(ValueError):
                        verify(root)
            project.write_text(original)
            verify(root)

    def test_strict_runner_rejects_zero_exit_errors_leaks_and_missing_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for index, message in enumerate(("ERROR: synthetic", "SCRIPT ERROR: synthetic",
                    "SHADER ERROR: synthetic", "WARNING: ObjectDB instances leaked at exit",
                    "ERROR: resources still in use", "PROBE: FAIL synthetic", "no success")):
                command = [sys.executable, "-c", f"print({message!r})"]
                if message != "no success":
                    command[-1] += "; print('PROBE: PASS')"
                with self.subTest(message=message), self.assertRaises(RuntimeError):
                    checked_run(command, os.environ.copy(), root / f"{index}.log", ["PROBE: PASS"])
                result = json.loads((root / f"{index}.json").read_text())
                self.assertEqual(result["exit_code"], 0)
                self.assertFalse(result["strict_pass"])
            with self.assertRaises(RuntimeError):
                checked_run([sys.executable, "-c", "print('PASS'); raise SystemExit(7)"],
                            os.environ.copy(), root / "exit.log", ["PASS"])
            with self.assertRaises(RuntimeError):
                checked_run([sys.executable, "-c", "import time; time.sleep(30)"],
                            os.environ.copy(), root / "timeout.log", timeout=0.1)
            self.assertTrue(json.loads((root / "timeout.json").read_text())["timeout"])
            self.assertTrue(checked_run([sys.executable, "-c", "print('PASS')"],
                os.environ.copy(), root / "pass.log", ["PASS"])["strict_pass"])

    def test_environment_isolates_user_and_shader_caches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = isolated_env(root)
            for key in ("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
                        "__GL_SHADER_DISK_CACHE_PATH", "MESA_SHADER_CACHE_DIR"):
                self.assertTrue(Path(env[key]).is_relative_to(root))
            for key in ("DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"):
                self.assertEqual(env.get(key), os.environ.get(key))


if __name__ == "__main__":
    unittest.main()
