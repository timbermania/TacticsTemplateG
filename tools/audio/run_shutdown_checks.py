#!/usr/bin/env python3
"""Exercise the host quit boundary with real synthetic native/WAV playback."""
import argparse
from pathlib import Path
import shutil
import subprocess
from run_smoke import ROOT, stage, checked_run


def configure(project):
    shutil.copy2(ROOT / "src/utilities/application_shutdown.gd", project / "shutdown.gd")
    fixture = project / "tools/audio/smoke.gd"
    text = fixture.read_text()
    start = text.index("\tAudioServer.lock()")
    end = text.index("\n\nfunc _check_scripts", start)
    text = text[:start] + '''\tcheck(failures.is_empty(), "fixture ready for shutdown")
\tif not failures.is_empty():
\t\tget_tree().quit(1)
\t\treturn
\tvar shutdown = load("res://shutdown.gd").new()
\tget_tree().root.add_child(shutdown)
\tif "--retained" in OS.get_cmdline_user_args():
\t\t_held_playback = player.get_stream_playback()
\t\tshutdown.shutdown_failed.connect(_expected_timeout)
\tif "--stopped" in OS.get_cmdline_user_args():
\t\tordinary.stop()
\t\tplayer.stop()
\tprint("SHUTDOWN_FIXTURE: ready")
\tif "--close" in OS.get_cmdline_user_args():
\t\tshutdown.notification(NOTIFICATION_WM_CLOSE_REQUEST)
\telse:
\t\tshutdown.request_quit()
\t\tshutdown.request_quit() # idempotence
''' + text[end:]
    text += '''
var _held_playback: AudioStreamPlayback

func _expected_timeout(_message: String) -> void:
\tvar lifetime: WeakRef = weakref(_held_playback)
\t_held_playback = null
\twhile lifetime.get_ref() != null:
\t\tawait get_tree().process_frame
\tprint("SHUTDOWN_TIMEOUT: safely refused exit")
\tget_tree().quit()
'''
    fixture.write_text(text)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--repeat", type=int, default=5)
    args = parser.parse_args()
    godot = str(args.godot.resolve())
    project = stage()
    configure(project)
    logs = ROOT / ".build/shutdown-check-logs"
    logs.mkdir(parents=True, exist_ok=True)
    checked_run([godot, "--path", str(project), "--editor", "--import"], logs / "import.log")
    for mode in ("active", "stopped", "close"):
        for trial in range(args.repeat):
            checked_run([godot, "--path", str(project), "--verbose", "--", "--" + mode],
                        logs / f"{mode}-{trial}.log", "APPLICATION_SHUTDOWN: drained")
    result = subprocess.run([godot, "--path", str(project), "--verbose", "--", "--retained"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
    (logs / "retained.log").write_text(result.stdout)
    errors = [line for line in result.stdout.splitlines() if line.startswith("ERROR:")
              or "SCRIPT ERROR:" in line or "ObjectDB instances leaked" in line]
    assert result.returncode == 0 and errors == [
        "ERROR: Shutdown blocked: audio playback still retained after cleanup"], errors
    assert "APPLICATION_SHUTDOWN: drained" not in result.stdout
    assert "SHUTDOWN_TIMEOUT: safely refused exit" in result.stdout
    print(f"PASS {logs / 'retained.log'} (expected refusal)")
