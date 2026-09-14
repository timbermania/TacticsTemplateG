#!/usr/bin/env python3
"""Run content-free audio checks in a copied project, on a real Godot audio mixer."""
import argparse
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def checked_run(command, logfile, marker=None):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=120)
    logfile.write_text(result.stdout)
    errors = [line for line in result.stdout.splitlines()
              if "SCRIPT ERROR:" in line or line.startswith("ERROR:")
              or "ObjectDB instances leaked" in line or "resources still in use" in line]
    if result.returncode or errors or (marker and marker not in result.stdout):
        raise RuntimeError(f"Command failed: {command}\n{result.stdout}\nLog: {logfile}")
    print(f"PASS {logfile}")


def stage():
    project = ROOT / ".build/audio-smoke"
    if project.exists():
        shutil.rmtree(project)
    project.mkdir(parents=True)
    for name in ["exmateria_sound", "exmateria_spu"]:
        shutil.copytree(ROOT / "addons" / name, project / "addons" / name)
    (project / "tools/audio").mkdir(parents=True)
    for name in ["smoke.gd", "smoke.tscn"]:
        shutil.copy2(ROOT / "tools/audio" / name, project / "tools/audio" / name)
    (project / "project.godot").write_text('''config_version=5
[application]
config/name="Tactics Audio Smoke"
run/main_scene="res://tools/audio/smoke.tscn"
[autoload]
ExMateriaAudioEngine="*res://addons/exmateria_sound/runtime/audio_engine.gd"
ExMateriaEffectSfx="*res://addons/exmateria_sound/runtime/effect_sfx_engine.gd"
[display]
window/size/viewport_width=400
window/size/viewport_height=240
[rendering]
renderer/rendering_method="gl_compatibility"
''')
    return project


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--host", action="store_true", help="Also run scene in the full host project")
    args = parser.parse_args()
    godot = str(Path(args.godot).resolve())
    project = stage()
    logs = ROOT / ".build/audio-test-logs"
    logs.mkdir(exist_ok=True)
    checked_run([godot, "--path", str(project), "--editor", "--import"], logs / "import.log")
    checked_run([godot, "--path", str(project)], logs / "smoke.log", "AUDIO_SMOKE: PASS")
    if args.host:
        checked_run([godot, "--path", str(ROOT), "--editor", "--import"], logs / "host-import.log")
        checked_run([godot, "--path", str(ROOT), "res://tools/audio/smoke.tscn"],
                    logs / "host-smoke.log", "AUDIO_SMOKE: PASS")
