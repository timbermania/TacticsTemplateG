#!/usr/bin/env python3
"""Validate the host audition UI using private-free fixtures and isolated user data."""
import argparse
import os
from pathlib import Path
import tempfile

from package_release import ROOT, MANIFEST, stage
from run_host_checks import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    args = parser.parse_args()
    godot = str(args.godot.resolve())
    logs = ROOT / ".build/audition-check-logs"
    logs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tactics-audition-check-") as temporary:
        base = Path(temporary)
        source = base / "source"
        data = base / "data"
        data.mkdir()
        stage(ROOT, source, MANIFEST)
        env = dict(os.environ, XDG_DATA_HOME=str(data), XDG_CONFIG_HOME=str(base / "config"))
        run([godot, "--path", str(source), "--editor", "--import"], env, logs / "import.log")
        for mode in ("lifetime", "active", "stopped", "window"):
            log = logs / f"{mode}.log"
            run([godot, "--path", str(source), "--verbose", "--script",
                 "res://tools/audio/audition_regression.gd", "--", str(data), mode],
                env, log, "AUDITION_REGRESSION: PASS")
            if "APPLICATION_SHUTDOWN: drained" not in log.read_text():
                raise RuntimeError(f"Shutdown did not drain: {log}")
        for mode in ("active", "stopped", "window"):
            log = logs / f"disc-{mode}.log"
            run([godot, "--path", str(source), "--verbose", "--script",
                 "res://tools/audio/disc_audio_regression.gd", "--", str(data), mode],
                env, log, "DISC_AUDIO_REGRESSION: PASS")
            if "APPLICATION_SHUTDOWN: drained" not in log.read_text():
                raise RuntimeError(f"Shutdown did not drain: {log}")
    print(f"AUDITION_CHECKS: PASS ({logs})")


if __name__ == "__main__":
    main()
