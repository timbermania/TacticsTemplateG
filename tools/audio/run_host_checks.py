#!/usr/bin/env python3
"""Cold public-source import, isolated host regressions and real main-scene startup."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from package_release import ROOT, MANIFEST, stage


def run(command, env, log, marker=None):
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=180)
    log.write_text(result.stdout)
    failures = [line for line in result.stdout.splitlines()
                if line.startswith("ERROR:") or "SCRIPT ERROR:" in line
                or "ObjectDB instances leaked" in line]
    if result.returncode or failures or (marker and marker not in result.stdout):
        raise RuntimeError(f"Host check failed: {log}\n" + "\n".join(failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    args = parser.parse_args()
    godot = str(args.godot.resolve())
    logs = ROOT / ".build/host-check-logs"
    logs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tactics-host-check-") as temporary:
        base = Path(temporary)
        source = base / "source"
        stage(ROOT, source, MANIFEST)
        env = dict(os.environ, XDG_DATA_HOME=str(base / "data"), XDG_CONFIG_HOME=str(base / "config"))
        run([godot, "--path", str(source), "--editor", "--import"], env, logs / "import.log")
        run([godot, "--path", str(source), "--script", "res://tools/audio/host_regression.gd", "--quit-after", "120",
             "--", str(base / "data")], env, logs / "regression.log", "HOST_REGRESSION: PASS")
        run([godot, "--path", str(source), "--quit-after", "120", "--verbose"],
            env, logs / "startup.log")
    print(f"HOST_CHECKS: PASS ({logs})")


if __name__ == "__main__":
    main()
