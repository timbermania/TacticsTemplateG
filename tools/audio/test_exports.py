#!/usr/bin/env python3
"""Export and run the content-free scene in debug/release templates (not the game)."""
import argparse
import os
from pathlib import Path
import subprocess
from run_smoke import ROOT, checked_run, stage


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--templates", type=Path, required=True)
    parser.add_argument("--wine", help="Optional Wine command to run Windows exports; not a hardware verdict")
    parser.add_argument("--shutdown", action="store_true", help="Exercise the host shutdown boundary instead of fixture delay")
    args = parser.parse_args()
    godot = str(args.godot.resolve())
    templates = args.templates.resolve()
    project = stage()
    if args.shutdown:
        from run_shutdown_checks import configure
        configure(project)
    logs = ROOT / (".build/shutdown-export-logs" if args.shutdown else ".build/audio-export-logs")
    logs.mkdir(exist_ok=True)
    checked_run([godot, "--path", str(project), "--editor", "--import"], logs / "import.log")
    for platform in ("linux", "windows"):
        if platform == "windows" and not args.wine:
            print("SKIP Windows runtime (pass --wine to exercise under Wine)")
            continue
        for target in ("debug", "release"):
            template = templates / (f"linux_{target}.x86_64" if platform == "linux" else f"windows_{target}_x86_64.exe")
            preset = f'''[preset.0]
name="Smoke"
runnable=true
include_filter=""
exclude_filter=""
platform="{'Linux' if platform == 'linux' else 'Windows Desktop'}"
export_filter="all_resources"
[preset.0.options]
custom_template/{target}="{template}"
binary_format/architecture="x86_64"
binary_format/embed_pck=true
application/modify_resources=false
'''
            (project / "export_presets.cfg").write_text(preset)
            output = ROOT / ".build/audio-exports" / f"{platform}-{target}"
            output.mkdir(parents=True, exist_ok=True)
            binary = output / ("smoke.x86_64" if platform == "linux" else "smoke.exe")
            checked_run([godot, "--path", str(project), f"--export-{target}", "Smoke", str(binary)],
                        logs / f"{platform}-{target}-export.log")
            command = [str(binary)]
            if platform == "windows":
                os.environ["WINEPREFIX"] = str(ROOT / ".build/audio-wine")
                os.environ["WINEDEBUG"] = "-all"
                command.insert(0, args.wine)
            else:
                binary.chmod(0o755)
            checked_run(command, logs / f"{platform}-{target}-runtime.log", "APPLICATION_SHUTDOWN: drained" if args.shutdown else "AUDIO_SMOKE: PASS")
