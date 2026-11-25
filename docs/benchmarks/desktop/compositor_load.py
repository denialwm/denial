#!/usr/bin/env python3
"""CPU and GPU use of every process over a window, for comparing compositors
under the same desktop load.

Usage: compositor_load.py [SECONDS] [--json FILE]

Prints, per process name: CPU (percent of one core, user + kernel) and GPU
time (ms of engine time per second, from DRM fdinfo, summed over engines and
devices). Also the AMD GPU's average busy percent and power when the card
exposes them. Run it as the logged-in user; processes of other users are
skipped. Compare the compositor's own rows (deniald, Hyprland,
kwin_wayland, ...) and the totals across sessions with the same windows,
video and game open.
"""

import glob
import json
import os
import re
import sys
import time

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] != "--json" else 30.0
HZ = os.sysconf("SC_CLK_TCK")


def name(pid):
    try:
        comm = open(f"/proc/{pid}/comm").read().strip()
        cmd = open(f"/proc/{pid}/cmdline").read().split("\0")
    except OSError:
        return None
    # Chromium's children share a comm and may rewrite their command line
    # into one string: the --type argument tells them apart.
    kind = re.search(r"--type=([\w-]+)", " ".join(cmd))
    if kind or comm.startswith("chrom"):
        return f"{comm}:{kind.group(1) if kind else 'browser'}"
    exe = os.path.basename(cmd[0]) if cmd and cmd[0] else comm
    if exe.lower().endswith(".exe"):
        return exe
    return comm


def cpu(pid):
    try:
        fields = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
        return int(fields[11]) + int(fields[12])
    except OSError:
        return None


def gpu(pid):
    # One DRM client can be open through several descriptors: count it once.
    clients = {}
    for fdinfo in glob.glob(f"/proc/{pid}/fdinfo/*"):
        try:
            text = open(fdinfo).read()
        except OSError:
            continue
        client = re.search(r"drm-client-id:\s*(\d+)", text)
        if not client:
            continue
        device = re.search(r"drm-pdev:\s*(\S+)", text)
        key = (device.group(1) if device else "?", client.group(1))
        clients[key] = sum(
            int(ns) for ns in re.findall(r"drm-engine-[\w-]+:\s*(\d+) ns", text)
        )
    return clients


def card():
    for device in glob.glob("/sys/class/drm/card*/device"):
        if os.path.exists(f"{device}/gpu_busy_percent"):
            power = glob.glob(f"{device}/hwmon/hwmon*/power1_average") + glob.glob(
                f"{device}/hwmon/hwmon*/power1_input"
            )
            return f"{device}/gpu_busy_percent", power[0] if power else None
    return None, None


def snapshot():
    state = {}
    for path in glob.glob("/proc/[0-9]*"):
        pid = int(path[6:])
        try:
            if os.stat(path).st_uid != os.getuid():
                continue
        except OSError:
            continue
        label = name(pid)
        ticks = cpu(pid)
        if label is None or ticks is None:
            continue
        state[pid] = (label, ticks, gpu(pid))
    return state


busy_path, power_path = card()
before = snapshot()
start = time.monotonic()
busy, power = [], []
while time.monotonic() - start < SECONDS:
    if busy_path:
        busy.append(int(open(busy_path).read()))
    if power_path:
        power.append(int(open(power_path).read()) / 1e6)
    time.sleep(0.25)
elapsed = time.monotonic() - start
after = snapshot()

rows = {}
for pid, (label, ticks, clients) in after.items():
    if pid not in before:
        continue
    _, ticks0, clients0 = before[pid]
    row = rows.setdefault(label, [0.0, 0.0])
    row[0] += (ticks - ticks0) / HZ / elapsed * 100
    row[1] += (
        sum(ns - clients0.get(key, ns) for key, ns in clients.items()) / 1e6 / elapsed
    )

summary = f"window {elapsed:.0f} s"
if busy:
    summary += f", GPU busy {sum(busy) / len(busy):.0f}%"
if power:
    summary += f", GPU power {sum(power) / len(power):.0f} W"
print(summary)
print(f"{'process':32s} {'CPU % core':>10s} {'GPU ms/s':>9s}")
shown = sorted(rows.items(), key=lambda item: -(item[1][0] + item[1][1] / 10))
for label, (c, g) in shown:
    if c >= 0.2 or g >= 0.5:
        print(f"{label:32s} {c:10.1f} {g:9.1f}")
print(f"{'all of the user':32s} {sum(r[0] for r in rows.values()):10.1f} "
      f"{sum(r[1] for r in rows.values()):9.1f}")

if "--json" in sys.argv:
    with open(sys.argv[sys.argv.index("--json") + 1], "w") as out:
        json.dump({
            "seconds": elapsed,
            "gpu_busy_percent": sum(busy) / len(busy) if busy else None,
            "gpu_power_w": sum(power) / len(power) if power else None,
            "processes": {k: {"cpu_percent": v[0], "gpu_ms_per_s": v[1]} for k, v in rows.items()},
        }, out, indent=1, sort_keys=True)
