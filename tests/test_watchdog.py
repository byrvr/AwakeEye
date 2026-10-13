import os
import pathlib
import shlex
import signal
import subprocess
import sys
import tempfile
import time

GENERATOR = pathlib.Path(sys.argv[1]).resolve()
IDENTITY = "lease identity ' quoted $() ; harmless"

def wait_until(predicate, seconds=3):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("Timed out waiting for watchdog cleanup")

def run_case(name, mode="normal", terminate_watchdog=False, identity=IDENTITY, conflicting_session=False):
    with tempfile.TemporaryDirectory(prefix="kya-watchdog-test-") as temp:
        root = pathlib.Path(temp)
        (root / "lease").write_text("active")
        (root / "identity").write_text(identity + "\n")
        (root / "state").write_text("1")  # Takeover must end at 0 even if already on.
        root_q = shlex.quote(str(root))
        scripts = {
            "ps": f"#!/bin/sh\n[ -f {root_q}/lease ] || exit 1\n/bin/cat {root_q}/identity\n",
            "caffeinate": f"#!/bin/sh\nwhile [ -f {root_q}/lease ]; do /bin/sleep 0.02; done\n",
            "pmset": f"#!/bin/sh\n/usr/bin/printf '%s\\n' \"$3\" >> {root_q}/calls\n"
                + ("[ \"$3\" = 1 ] && exit 1\n" if mode == "enable_failure" else "")
                + ("[ \"$3\" = 0 ] && exit 1\n" if mode == "cleanup_failure" else "")
                + (f"[ \"$3\" = 1 ] && /bin/rm -f {root_q}/lease\n" if mode == "lease_dies_during_enable" else "")
                + f"/usr/bin/printf '%s' \"$3\" > {root_q}/state\nexit 0\n",
        }
        for filename, content in scripts.items():
            path = root / filename
            path.write_text(content)
            path.chmod(0o700)
        script = subprocess.check_output([str(GENERATOR), str(root)], text=True)
        # Refuse to run if an effectful production command or shared path was
        # missed by the source generator's substitutions.
        assert "/usr/bin/pmset" not in script
        assert "/usr/bin/caffeinate" not in script
        assert "/bin/ps" not in script
        assert "/usr/bin/logger" not in script
        assert "/private/tmp/keepingyouawake-redbull" not in script
        script = script.replace("watch_lease() {", "watch_lease() {\n  set -x")
        script = script.replace("watch_lease </dev/null >/dev/null 2>&1 &", f"watch_lease </dev/null >{root_q}/watchdog.log 2>&1 &")
        syntax = subprocess.run(["/bin/sh", "-n"], input=script, text=True, capture_output=True)
        assert syntax.returncode == 0, syntax.stderr
        result = subprocess.run(["/bin/sh", "-c", script], text=True, capture_output=True, timeout=15)
        if identity != IDENTITY:
            assert result.returncode == 70, (result.returncode, result.stderr)
            assert not (root / "calls").exists()
            assert (root / "state").read_text() == "1"
        elif mode not in ("normal", "cleanup_failure"):
            assert result.returncode != 0, result.stdout
            wait_until(lambda: (root / "state").read_text() == "0")
            assert (root / "calls").read_text().splitlines() == ["1", "0"]
        else:
            parts = result.stdout.strip().split(" ")
            assert result.returncode == 0 and parts[0] == "KYA_READY", result
            directory = pathlib.Path(parts[2])
            assert (directory / "ready").is_file()
            assert (root / "state").read_text() == "1"
            if conflicting_session:
                second = subprocess.run(["/bin/sh", "-c", script], text=True, capture_output=True, timeout=15)
                assert second.returncode == 77, second
                assert (root / "calls").read_text().splitlines() == ["1"]
            if terminate_watchdog:
                os.kill(int(parts[1]), signal.SIGTERM)
            else:
                (root / "lease").unlink()
            if mode == "cleanup_failure":
                wait_until(lambda: (directory / "cleanup-failed").is_file(), seconds=7)
                assert (root / "calls").read_text().splitlines() == ["1", "0", "0", "0", "0", "0"]
                assert (root / "lock").is_dir()
                assert (root / "state").read_text() == "1"
                import shutil
                shutil.rmtree(directory)
            else:
                try:
                    wait_until(lambda: not directory.exists())
                except AssertionError:
                    print((root / "watchdog.log").read_text())
                    raise
                assert (root / "state").read_text() == "0"
                assert not (root / "lock").exists()
                assert (root / "calls").read_text().splitlines() == ["1", "0"]
        print(f"PASS {name}")

run_case("session end / app crash lease exit")
run_case("watchdog termination trap", terminate_watchdog=True)
run_case("identity mismatch refuses activation", identity="reused or unrelated process")
run_case("failed pmset enable restores0", mode="enable_failure")
run_case("lease exit during activation restores0", mode="lease_dies_during_enable")
run_case("second instance cannot take an active global override", conflicting_session=True)
run_case("failed cleanup retries, reports marker, and blocks overlapping sessions", mode="cleanup_failure")
