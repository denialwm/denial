#!/usr/bin/env python3
"""Memory of every process of the logged-in user, for comparing compositors
and shells under the same desktop load.

Usage: compositor_memory.py [--json FILE]

Prints, per process name: PSS (shared pages split between the processes
that map them, the fair figure for comparing), its anonymous, file and shmem
parts, RSS, and GPU memory the process holds through DRM (VRAM and GTT from
DRM fdinfo, each client counted once). NVIDIA's driver exposes no DRM
fdinfo: its per-process framebuffer memory comes from `nvidia-smi pmon`.
"""

import glob
import json
import os
import re
import subprocess
import sys

UNITS = {"": 1 / 1024, "KiB": 1, "MiB": 1024, "GiB": 1024 * 1024}


def name(pid):
    try:
        comm = open(f"/proc/{pid}/comm").read().strip()
        cmd = open(f"/proc/{pid}/cmdline").read().split("\0")
    except OSError:
        return None
    kind = re.search(r"--type=([\w-]+)", " ".join(cmd))
    if kind or comm.startswith("chrom"):
        return f"{comm}:{kind.group(1) if kind else 'browser'}"
    return comm


def smaps(pid):
    try:
        text = open(f"/proc/{pid}/smaps_rollup").read()
    except OSError:
        return None
    values = dict(re.findall(r"^(\w+):\s+(\d+) kB", text, re.M))
    get = lambda key: int(values.get(key, 0))
    return {
        "pss": get("Pss"),
        "pss_anon": get("Pss_Anon"),
        "pss_file": get("Pss_File"),
        "pss_shmem": get("Pss_Shmem"),
        "rss": get("Rss"),
        "swap": get("Swap"),
    }


def drm(pid):
    # KiB per memory region, each DRM client once.
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
        regions = {}
        for kind, region, value, unit in re.findall(
            r"drm-(total|memory)-(\w+):\s*(\d+)\s*(KiB|MiB|GiB)?", text
        ):
            regions[region] = int(value) * UNITS[unit or ""]
        clients[(device.group(1) if device else "?", client.group(1))] = regions
    total = {}
    for regions in clients.values():
        for region, kib in regions.items():
            total[region] = total.get(region, 0) + kib
    return total


def nvidia():
    try:
        out = subprocess.run(
            ["nvidia-smi", "pmon", "-c", "1", "-s", "m"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    fb = {}
    for line in out.splitlines():
        fields = line.split()
        if line.startswith("#") or len(fields) < 4 or not fields[1].isdigit():
            continue
        if fields[3].isdigit():
            fb[int(fields[1])] = int(fields[3]) * 1024
    return fb


nvidia_fb = nvidia()
rows = {}
for path in glob.glob("/proc/[0-9]*"):
    pid = int(path[6:])
    try:
        if os.stat(path).st_uid != os.getuid():
            continue
    except OSError:
        continue
    label, memory = name(pid), smaps(pid)
    if label is None or memory is None or memory["rss"] == 0:
        continue
    row = rows.setdefault(label, {"processes": 0})
    row["processes"] += 1
    for key, kib in memory.items():
        row[key] = row.get(key, 0) + kib
    for region, kib in drm(pid).items():
        row[f"gpu_{region}"] = row.get(f"gpu_{region}", 0) + kib
    if pid in nvidia_fb:
        row["gpu_nvidia_fb"] = row.get("gpu_nvidia_fb", 0) + nvidia_fb[pid]

mib = lambda kib: kib / 1024
print(f"{'process':28s} {'PSS':>7s} {'anon':>7s} {'file':>7s} {'shmem':>7s} "
      f"{'RSS':>7s} {'VRAM':>7s} {'GTT':>7s} {'NV fb':>6s}  (MiB)")
for label, row in sorted(rows.items(), key=lambda item: -item[1]["pss"]):
    if row["pss"] < 10 * 1024 and not any(
        k.startswith("gpu_") and v >= 1024 for k, v in row.items()
    ):
        continue
    print(f"{label:28s} {mib(row['pss']):7.1f} {mib(row['pss_anon']):7.1f} "
          f"{mib(row['pss_file']):7.1f} {mib(row['pss_shmem']):7.1f} "
          f"{mib(row['rss']):7.1f} {mib(row.get('gpu_vram', 0)):7.1f} "
          f"{mib(row.get('gpu_gtt', 0)):7.1f} {mib(row.get('gpu_nvidia_fb', 0)):6.0f}")

if "--json" in sys.argv:
    with open(sys.argv[sys.argv.index("--json") + 1], "w") as out:
        json.dump(rows, out, indent=1, sort_keys=True)
