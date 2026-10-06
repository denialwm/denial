#!/usr/bin/env python3
"""Activate a staged Dart profile bundle while retaining Aston's DRM session.

Run on Aston as root, after staging an immutable bundle and manifest. This
command accepts only an engine already resident in the current compositor.
It never restarts a service, kills a process, or replaces a mapped file.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import stat
import subprocess
import time


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def output(*command):
    return subprocess.check_output(command, text=True, timeout=10).strip()


def mapped_files(pid, filename):
    paths = set()
    for line in Path(f"/proc/{pid}/maps").read_text().splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) == 6 and Path(fields[5]).name == filename:
            paths.add(Path(fields[5]))
    return paths


def activate(stage, check_only):
    require(os.geteuid() == 0, "Run this command as root on Aston")
    require(
        Path("/proc/device-tree/compatible").read_bytes().split(b"\0")[0]
        == b"oneplus,aston",
        "The connected machine is not Aston",
    )
    require(output("uname", "-m") == "aarch64", "Expected AArch64")
    stage = stage.resolve(strict=True)
    require(
        stage.parent == Path("/var/lib/denial/policy-updates"),
        "Bundle must be staged in /var/lib/denial/policy-updates",
    )
    manifest = json.loads((stage / "manifest.json").read_text())
    require(manifest["mode"] == "profile", "Only Dart profile updates are supported")
    require(manifest["stage"] == str(stage), "Manifest names a different stage")
    pid = str(int(manifest["pid"]))
    require(int(pid) > 1, "Invalid compositor PID")
    proc = Path(f"/proc/{pid}")
    uid = proc.stat().st_uid
    account = pwd.getpwuid(uid)
    home = Path(account.pw_dir)
    settings = home / ".config/denial/settings.json"
    socket = Path(f"/run/user/{uid}/denial/control.sock")
    require(stat.S_ISSOCK(socket.stat().st_mode), "Native control socket is absent")
    control = [
        "runuser", "-u", account.pw_name, "--", "/usr/bin/denialctl",
        "--socket", str(socket), "--json", "--no-wait", "ui",
    ]

    def unchanged_session():
        require(
            Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            == manifest["boot_id"],
            "Device boot changed; stop remote work",
        )
        require(
            output("systemctl", "show", "denial.service", "-p", "MainPID", "--value")
            == pid,
            "Compositor process changed; stop remote work",
        )
        require(
            digest(proc / "exe") == manifest["compositor_sha256"],
            "Compositor differs from the matched bundle",
        )
        require(
            digest(settings) == manifest["settings_sha256"],
            "Shell settings changed since this update was prepared",
        )

    def status():
        state = json.loads(output(*control, "status"))
        # Service authentication tokens must never enter receipts or stdout.
        state["vm_service_uri"] = bool(state.get("vm_service_uri"))
        return state

    unchanged_session()
    before = status()
    require(before["operation"] == "idle", "A native UI operation is in progress")
    require(
        before["active_mode"] in ("official_optimized", "custom_optimized"),
        "Leave live JIT development before applying a profile bundle",
    )
    bundle = stage / "bundle"
    members = list(bundle.rglob("*"))
    require(bundle.is_dir() and not bundle.is_symlink(), "Invalid bundle directory")
    require(
        all(not p.is_symlink() and (p.is_file() or p.is_dir()) for p in members),
        "Bundle contains links or special files",
    )
    require(
        all(p.stat().st_mode & 0o222 == 0 for p in [bundle, *members]),
        "Staged bundle must be immutable",
    )
    actual = {str(p.relative_to(stage)): digest(p) for p in members if p.is_file()}
    require(actual == manifest["files"], "Staged bundle does not match its manifest")
    engine = bundle / "lib/libflutter_engine.so"
    app = bundle / "lib/libapp.so"
    require(digest(engine) == manifest["engine_sha256"], "Engine hash mismatch")
    require(digest(app) == manifest["app_sha256"], "Dart AOT hash mismatch")
    for member in (engine, app):
        require("AArch64" in output("readelf", "-h", str(member)), "Wrong ELF architecture")
    resident = [
        p for p in mapped_files(pid, engine.name)
        if p.is_file() and digest(p) == manifest["engine_sha256"]
    ]
    require(resident, "Native engine is not resident; keep this engine update offline")
    require(
        any(
            digest(p.parent.parent / "data/icudtl.dat")
            == digest(bundle / "data/icudtl.dat")
            for p in resident
        ),
        "ICU differs from the resident engine bundle",
    )
    alias = home / ".cache/denial/ui-development/profile/bundle"
    require(alias.is_symlink(), "Profile alias must already be an established symlink")
    previous = alias.resolve(strict=True)
    require(
        (previous / "workspace.path").read_bytes()
        == (bundle / "workspace.path").read_bytes(),
        "Profile workspace identity changed",
    )
    receipt = {
        "stage": str(stage), "boot_id": manifest["boot_id"], "pid": pid,
        "previous_bundle": str(previous), "engine_sha256": manifest["engine_sha256"],
        "app_sha256": manifest["app_sha256"], "checked_only": check_only,
    }
    if check_only:
        print(json.dumps(receipt))
        return
    if (before["active_mode"] == "custom_optimized" and previous == bundle
            and app in mapped_files(pid, app.name)):
        receipt["already_active"] = True
        print(json.dumps(receipt))
        return

    def switch(command, expected_mode):
        unchanged_session()
        output(*control, command)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            unchanged_session()
            state = status()
            require(not state.get("error"), "Native Flutter activation reported an error")
            if state["operation"] == "idle" and state["active_mode"] == expected_mode:
                return state
            time.sleep(0.25)
        raise TimeoutError("Flutter switch timed out; session was left running")

    pending = alias.with_name(f"bundle.live-{os.getpid()}")
    pending.symlink_to(bundle)
    try:
        unchanged_session()
        pending.replace(alias)
    finally:
        pending.unlink(missing_ok=True)
    # Reloading the already active profile mode is a no-op. The packaged UI
    # is the native intermediate; both switches keep the compositor alive.
    if before["active_mode"] == "custom_optimized":
        switch("restore", "official_optimized")
    after = switch("profile", "custom_optimized")
    require(after["generation"] > before["generation"], "Flutter generation did not advance")
    require(app in mapped_files(pid, app.name), "Prepared Dart AOT was not mapped")
    unchanged_session()
    receipt["generation"] = after["generation"]
    receipt["activated_at"] = time.time()
    (stage / f"live-activation-{time.time_ns()}.json").write_text(
        json.dumps(receipt, indent=2) + "\n"
    )
    print(json.dumps(receipt))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", type=Path)
    parser.add_argument("--check", action="store_true", help="Validate without changing the UI")
    args = parser.parse_args()
    with open("/run/denial-aston-live-ui.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        activate(args.stage, args.check)


if __name__ == "__main__":
    main()
