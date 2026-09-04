#!/usr/bin/env python3
"""Install a matched Aston Denial policy update without restarting the session."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    stage = Path(sys.argv[1]).resolve(strict=True)
    boot, expected_old, expected_new = sys.argv[2:5]
    assert os.geteuid() == 0
    assert stage.parent == Path("/var/lib/denial/policy-updates")
    assert Path("/proc/sys/kernel/random/boot_id").read_text().strip() == boot
    assert Path("/proc/device-tree/compatible").read_bytes().split(b"\0")[0] == b"oneplus,aston"
    assert output("uname", "-m") == "aarch64"
    binary = stage / "deniald"
    assert digest(binary) == expected_new
    assert "AArch64" in output("readelf", "-h", str(binary))
    assert digest(Path("/usr/bin/deniald")) == expected_old
    pid = output("systemctl", "show", "denial.service", "-p", "MainPID", "--value")
    assert pid != "0"
    assert digest(Path(f"/proc/{pid}/exe")) == expected_old
    argv = Path(f"/proc/{pid}/cmdline").read_bytes().rstrip(b"\0").decode().split("\0")
    assert argv[0] == "/usr/bin/deniald"
    assert argv[argv.index("--flutter-renderer") + 1] == "impeller"
    bundle_index = argv.index("--flutter-bundle") + 1
    original_bundle = Path(argv[bundle_index]).resolve(strict=True)
    if original_bundle.parent != Path("/home/logix/denial/bundles"):
        previous_stage = original_bundle.parent
        assert original_bundle.name == "flutter-bundle"
        assert previous_stage.parent == Path("/var/lib/denial/policy-updates")
        previous_manifest = json.loads((previous_stage / "manifest.json").read_text())
        assert previous_manifest["binary"] == expected_old
        for name, expected in previous_manifest["files"].items():
            member = (previous_stage / name).resolve(strict=True)
            assert member.is_relative_to(previous_stage)
            assert digest(member) == expected
    bundle = stage / "flutter-bundle"
    assert not bundle.exists()
    shutil.copytree(original_bundle, bundle)
    for source in original_bundle.rglob("*"):
        if source.is_file():
            assert digest(source) == digest(bundle / source.relative_to(original_bundle))
    assert (bundle / "lib/libapp.so").is_file()
    assert (bundle / "lib/libflutter_engine.so").is_file()
    assert (bundle / "data/flutter_assets").is_dir()
    if len(sys.argv) > 5:
        shell = Path(sys.argv[5]).resolve(strict=True)
        expected_app, expected_engine = sys.argv[6:8]
        assert shell == stage / "shell"
        assert digest(shell / "lib/libapp.so") == expected_app
        assert "AArch64" in output("readelf", "-h", str(shell / "lib/libapp.so"))
        assert digest(bundle / "lib/libflutter_engine.so") == expected_engine
        # Keep the exact engine/ICU and a recoverable copy of the prior shell.
        # Only the new, not-yet-active bundle is changed here.
        (bundle / "lib/libapp.so").replace(stage / "libapp.so.previous")
        (bundle / "data/flutter_assets").replace(stage / "flutter_assets.previous")
        shutil.copy2(shell / "lib/libapp.so", bundle / "lib/libapp.so")
        shutil.copytree(shell / "flutter_assets", bundle / "data/flutter_assets")
    shutil.copy2("/usr/bin/deniald", stage / "deniald.previous")
    argv[bundle_index] = str(bundle)
    # Quote every argument for systemd, not for a shell. Existing arguments
    # containing specifiers are rejected rather than reinterpreted.
    assert all("%" not in arg and "\n" not in arg for arg in argv)
    command = " ".join(json.dumps(arg) for arg in argv)
    override = Path("/etc/systemd/system/denial.service.d/95-policy-update.conf")
    if override.exists():
        assert original_bundle.name == "flutter-bundle"
        assert original_bundle.parent.parent == Path("/var/lib/denial/policy-updates")
        assert override.read_bytes() == (
            original_bundle.parent / "95-policy-update.conf"
        ).read_bytes(), "policy override differs from the running bundle"
        shutil.copy2(override, stage / "95-policy-update.conf.previous")
    override.parent.mkdir(parents=True, exist_ok=True)
    contents = "[Service]\nExecStart=\nExecStart=" + command + "\n"
    (stage / "95-policy-update.conf").write_text(contents)
    records = {
        str(path.relative_to(stage)): digest(path)
        for path in stage.rglob("*") if path.is_file()
    }
    (stage / "manifest.json").write_text(json.dumps({
        "boot_id": boot, "baseline_binary": expected_old,
        "binary": expected_new, "preserved_bundle": str(original_bundle),
        "files": records,
    }, indent=2) + "\n")
    # Atomic replacement leaves the executable mapped by the current session
    # intact. All shell and engine files live in a new immutable bundle.
    candidate = Path("/usr/bin/deniald.policy-new")
    assert not candidate.exists()
    shutil.copy2(binary, candidate)
    candidate.chmod(0o755)
    candidate.replace("/usr/bin/deniald")
    shutil.copy2(stage / "95-policy-update.conf", override)
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    assert output("systemctl", "show", "denial.service", "-p", "MainPID", "--value") == pid
    assert digest(Path(f"/proc/{pid}/exe")) == expected_old
    print("Installed matched policy update; active session was not restarted.")
    print("Rollback executable and manifest:", stage)


if __name__ == "__main__":
    main()
