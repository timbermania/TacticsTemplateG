#!/usr/bin/env python3
"""Headful official 4.7.2 GL cold host/native checks in fresh isolated staging.

Never imports the checkout or accesses normal userdata; no native build/download.
Linux runner records strict diagnostics, original exits, wall time and sampled RSS.
Only its own timed-out child can be terminated. Existing audio remains idle.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from verify_installation import ROOT, verify

# `package_release` is a sibling now: it moved out of `tools/audio/` with the
# removal of the ExMateria Sound/SPU addons, which is also why this no longer
# has to put another tool directory on `sys.path` to reach it.
from package_release import MANIFEST, stage

ERRORS = ("SCRIPT ERROR:", "ERROR:", "SHADER ERROR:", "ObjectDB instances leaked",
          "resources still in use", "PROBE: FAIL", "EFFECTS_HOST_STARTUP: FAIL")


def isolated_env(base):
    env = os.environ.copy()
    for key, directory in (("HOME", "home"), ("XDG_DATA_HOME", "data"),
                           ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"),
                           ("__GL_SHADER_DISK_CACHE_PATH", "nvidia"),
                           ("MESA_SHADER_CACHE_DIR", "mesa")):
        path = base / directory
        path.mkdir(parents=True)
        env[key] = str(path)
    return env


def checked_run(command, env, log, markers=(), timeout=180):
    start = time.monotonic()
    peak = 0
    timed_out = False
    with log.open("w") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                   env=env, start_new_session=True)
        while process.poll() is None:
            try:
                status = Path(f"/proc/{process.pid}/status").read_text()
                rss = next(int(line.split()[1]) for line in status.splitlines()
                           if line.startswith("VmRSS:"))
                peak = max(peak, rss)
            except (FileNotFoundError, ProcessLookupError, StopIteration):
                pass
            if time.monotonic() - start > timeout:
                timed_out = True
                process.terminate()
                try:
                    process.wait(5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            time.sleep(0.05)
    text = log.read_text(errors="replace")
    diagnostics = [line for line in text.splitlines() if any(error in line for error in ERRORS)]
    missing = [marker for marker in markers if marker not in text]
    result = dict(command=command, exit_code=process.returncode, timeout=timed_out,
                  wall_seconds=round(time.monotonic() - start, 3),
                  peak_sampled_rss_kib=peak, diagnostics=diagnostics, missing_markers=missing,
                  strict_pass=process.returncode == 0 and not timed_out and not diagnostics and not missing)
    log.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    if not result["strict_pass"]:
        raise RuntimeError(f"Effects check failed: {log}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--logs", type=Path, default=ROOT / ".build/effects-check-logs",
                        help="New directory for retained logs/metrics/synthetic screenshot")
    args = parser.parse_args()
    lock = verify(allow_import_metadata=True)
    godot = args.godot.resolve()
    if hashlib.sha256(godot.read_bytes()).hexdigest() != lock["profile"]["engine_linux_x86_64_sha256"]:
        raise ValueError("Use the pinned official Godot 4.7.2 Linux x86_64 executable")
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        raise ValueError("Headful display required (no headless/Dummy override)")
    logs = args.logs.resolve()
    logs.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="tactics-effects-check-") as temporary:
        base = Path(temporary)
        env = isolated_env(base / "userdata")
        version = subprocess.check_output([str(godot), "--version"], env=env, text=True).strip()
        if version != lock["profile"]["engine_version"]:
            raise ValueError(f"Wrong engine version: {version}")
        (logs / "engine.json").write_text(json.dumps({"version": version, "profile": lock["profile"]}, indent=2) + "\n")
        host = base / "host"
        stage(ROOT, host, MANIFEST)
        native = base / "native"
        rows = json.loads((host / lock["manifest"]).read_text())
        for row in rows:
            source = host / row["destination"]
            destination = native / row["destination"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        for relative in ("src/utilities/application_shutdown.gd", "tools/effects/native_regression.gd",
                         "tools/effects/native_regression.tscn"):
            destination = native / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(host / relative, destination)
        shutil.copy2(host / "tools/effects/native_project.godot.txt", native / "project.godot")
        def run(project, name, arguments, markers=()):
            return checked_run([str(godot), "--path", str(project), *arguments], env,
                               logs / f"{name}.log", markers)
        run(host, "host-cold-import", ["--editor", "--import"])
        # Test-only autoload triggers graceful exit while running the real main scene.
        project = host / "project.godot"
        text = project.read_text()
        project.write_text(text.replace("[autoload]\n", '[autoload]\nEffectsStartupCheck="*res://tools/effects/host_startup.gd"\n', 1))
        run(host, "host-startup", ["--verbose"], ["EFFECTS_HOST_STARTUP: PASS", "APPLICATION_SHUTDOWN: drained"])
        native_env = isolated_env(base / "native-userdata")
        env = native_env
        run(native, "native-cold-import", ["--editor", "--import"])
        for name in ("native-regression", "native-repeat"):
            run(native, name, ["--verbose"], ["PROBE: PASS", "APPLICATION_SHUTDOWN: drained"])
        for screenshot in (base / "native-userdata").rglob("native-probe.png"):
            shutil.copy2(screenshot, logs / "native-probe.png")
    print(f"EFFECTS_CHECKS: PASS ({logs})")


if __name__ == "__main__":
    main()
