#!/usr/bin/env python3
"""Charts, PDF and tables from results/: python3 make_charts.py (needs matplotlib).

Six runs: three setups, each rendering on the Radeon 890M (which drives the
panel) and on the RTX 4060. Writes charts/<a>-vs-<b>-<gpu>.svg for each pair and GPU,
comparison.pdf with every chart and table, and prints the Markdown tables
used in README.md.

"Compositor + shell" is deniald for Denial (the shell runs inside it) and
niri + noctalia for niri. Xwayland, which Denial 0.6.8 starts, is reported on
its own.
"""

import json
import os

import matplotlib

matplotlib.use("pdf")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.backends.backend_pdf import PdfPages  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results")
CHARTS = os.path.join(HERE, "charts")

# key, label, short label, color, compositor + shell processes
SETUPS = {
    "release": ("Denial 0.6.8 (release)", "0.6.8", "#2a78d6", ["deniald"]),
    "new": ("Denial local (dev + fixes, no Xwayland)", "Denial local", "#eb6834", ["deniald"]),
    "niri": ("niri 26.04 + Noctalia 5.6", "niri", "#1baf7a", ["niri", "noctalia"]),
}
GPUS = [("amd", "890M"), ("nvidia", "RTX 4060")]
PHASES = [("idle", "Idle"), ("desktop", "Desktop load"), ("full", "Fullscreen")]
PAIRS = [("release", "niri"), ("niri", "new"), ("release", "new")]
SURFACE, INK, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"


def path(kind, run, phase, ext):
    return os.path.join(RESULTS, f"{kind}-{run}-{phase}.{ext}")


def load(kind, run, phase):
    with open(path(kind, run, phase, "json")) as f:
        return json.load(f)


def package_power(run, phase):
    return float(open(path("power", run, phase, "txt")).read().split()[2])


def board_power(run, phase):
    p = path("nvsmi", run, phase, "txt")
    if not os.path.exists(p):
        return None
    watts = [float(line.split(",")[0]) for line in open(p) if line[:1].isdigit()]
    return sum(watts) / len(watts)


def mem(run, phase, names, keys):
    rows = load("mem", run, phase)
    return sum(rows.get(n, {}).get(k, 0) for n in names for k in keys) / 1024


def proc(run, phase, names, key):
    rows = load("load", run, phase)["processes"]
    return sum(rows.get(n, {}).get(key, 0) for n in names)


METRICS = [
    ("pss", "Memory (PSS)", "MiB", lambda r, p, n: mem(r, p, n, ["pss"]), "{:.0f}"),
    ("gpu_mem", "GPU memory (VRAM + GTT + NVIDIA)", "MiB",
     lambda r, p, n: mem(r, p, n, ["gpu_vram", "gpu_gtt", "gpu_nvidia_fb"]), "{:.0f}"),
    ("cpu", "CPU", "% of one core", lambda r, p, n: proc(r, p, n, "cpu_percent"), "{:.1f}"),
    ("gpu_time", "890M GPU time", "ms per second",
     lambda r, p, n: proc(r, p, n, "gpu_ms_per_s"), "{:.0f}"),
    ("package", "Processor package power", "W", lambda r, p, n: package_power(r, p), "{:.1f}"),
    ("board", "RTX 4060 board power", "W", lambda r, p, n: board_power(r, p), "{:.1f}"),
]


def value(metric, setup, gpu, phase):
    _, _, _, fn, _ = metric
    return fn(f"{setup}-{gpu}", phase, SETUPS[setup][3])


def style_axes(ax, title, unit):
    ax.set_facecolor(SURFACE)
    ax.set_title(f"{title} ({unit})", loc="left", color=INK, fontsize=10, pad=8)
    ax.tick_params(axis="y", colors=MUTED, labelsize=7, length=0)
    ax.tick_params(axis="x", length=0, labelsize=8.5, colors=INK)
    ax.grid(axis="y", color=GRID, linewidth=0.7, zorder=0)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(MUTED)


def comparison_figure(pair, gpu):
    """One page: two setups on one GPU, a chart per metric, two bars per phase."""
    gpu_label = dict(GPUS)[gpu]
    metrics = [m for m in METRICS if gpu == "nvidia" or m[0] != "board"]
    fig, axes = plt.subplots(2, 3, figsize=(11.69, 8.27))
    fig.patch.set_facecolor(SURFACE)
    a, b = (SETUPS[s][1] for s in pair)
    fig.suptitle(f"{a} vs {b}, rendering on the {gpu_label}",
                 x=0.04, ha="left", y=0.965, fontsize=15, color=INK)
    fig.text(0.04, 0.915, "Compositor + shell processes; the power charts are whole-machine. "
             "Same load in both runs. Lower is better.", fontsize=9, color=MUTED)
    width, gap = 0.34, 0.03
    for ax, metric in zip(axes.flat, metrics):
        key, title, unit, _, fmt = metric
        style_axes(ax, title, unit)
        top = 0
        for i, setup in enumerate(pair):
            xs = [j + (i - 0.5) * (width + gap) for j in range(len(PHASES))]
            ys = [value(metric, setup, gpu, phase) for phase, _ in PHASES]
            top = max(top, *ys)
            bars = ax.bar(xs, ys, width, color=SETUPS[setup][2], zorder=2,
                          label=SETUPS[setup][0] if ax is axes.flat[0] else None)
            for bar, y in zip(bars, ys):
                ax.annotate(fmt.format(y), (bar.get_x() + bar.get_width() / 2, y),
                            xytext=(0, 2), textcoords="offset points", ha="center",
                            va="bottom", fontsize=7.5, color=INK)
        ax.set_ylim(0, top * 1.15 if top else 1)
        ax.set_xticks(range(len(PHASES)), [p[1] for p in PHASES])
    for ax in axes.flat[len(metrics):]:
        ax.axis("off")
    fig.legend(loc="upper left", bbox_to_anchor=(0.035, 0.905), ncol=2, frameon=False,
               fontsize=9.5, labelcolor=INK, handlelength=1.2)
    fig.tight_layout(rect=(0.02, 0.02, 0.98, 0.88), h_pad=2.6, w_pad=2.2)
    return fig


def cell(metric, setup, gpu, phase):
    v = value(metric, setup, gpu, phase)
    return "n/m" if v is None else metric[4].format(v)


def table_rows(phase):
    rows = []
    for setup in SETUPS:
        for gpu, gpu_label in GPUS:
            rows.append([f"{SETUPS[setup][1]} on {gpu_label}"]
                        + [cell(m, setup, gpu, phase) for m in METRICS])
    return rows


HEADERS = ["Run", "PSS MiB", "GPU mem MiB", "CPU %", "890M ms/s", "Package W", "4060 W"]


def table_page():
    fig = plt.figure(figsize=(11.69, 8.27))
    fig.patch.set_facecolor(SURFACE)
    fig.text(0.04, 0.95, "All six runs", fontsize=14, color=INK)
    fig.text(0.04, 0.915, "Compositor + shell (Denial: deniald; niri: niri + noctalia). "
             "Package and 4060 power are whole-machine. Fullscreen held 144 fps in every run.",
             fontsize=9, color=MUTED)
    for k, (phase, label) in enumerate(PHASES):
        ax = fig.add_axes((0.04, 0.63 - k * 0.29, 0.92, 0.24))
        ax.axis("off")
        ax.set_title(label, loc="left", fontsize=11, color=INK, pad=2)
        t = ax.table(cellText=table_rows(phase), colLabels=HEADERS, loc="upper left",
                     cellLoc="right", colLoc="right", colWidths=[0.28] + [0.12] * 6)
        t.auto_set_font_size(False)
        t.set_fontsize(8.5)
        t.scale(1, 1.35)
        for (r, c), cell_ in t.get_celld().items():
            cell_.set_edgecolor(GRID)
            cell_.set_linewidth(0.5)
            cell_.set_facecolor(SURFACE)
            cell_.get_text().set_color(INK if r else MUTED)
            if c == 0:
                cell_.get_text().set_horizontalalignment("left")
                cell_._loc = "left"
    return fig


def markdown(phase):
    lines = ["| Run | " + " | ".join(HEADERS[1:]) + " |", "|---|" + "---:|" * 6]
    lines += ["| " + " | ".join(r) + " |" for r in table_rows(phase)]
    return "\n".join(lines)


def breakdown():
    lines = ["| Run | Phase | Process | PSS | anon | file | RSS | VRAM | GTT | NVIDIA |",
             "|---|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for setup, (_, short, _, names) in SETUPS.items():
        for gpu, gpu_label in GPUS:
            for phase, phase_label in PHASES:
                rows = load("mem", f"{setup}-{gpu}", phase)
                for n in names + ["Xwayland"]:
                    if n not in rows:
                        continue
                    r = rows[n]
                    cells = [r.get(k, 0) / 1024 for k in ("pss", "pss_anon", "pss_file", "rss",
                                                           "gpu_vram", "gpu_gtt", "gpu_nvidia_fb")]
                    lines.append(f"| {short} on {gpu_label} | {phase_label} | {n} | "
                                 + " | ".join(f"{c:.0f}" for c in cells) + " |")
    return "\n".join(lines)


os.makedirs(CHARTS, exist_ok=True)
with PdfPages(os.path.join(HERE, "comparison.pdf")) as pdf:
    fig = table_page()
    pdf.savefig(fig, facecolor=SURFACE)
    plt.close(fig)
    for pair in PAIRS:
        for gpu, _ in GPUS:
            fig = comparison_figure(pair, gpu)
            pdf.savefig(fig, facecolor=SURFACE)
            fig.savefig(os.path.join(CHARTS, f"{pair[0]}-vs-{pair[1]}-{gpu}.svg"),
                        facecolor=SURFACE)
            plt.close(fig)
for phase, label in PHASES:
    print(f"### {label}\n\n{markdown(phase)}\n")
print(breakdown())
