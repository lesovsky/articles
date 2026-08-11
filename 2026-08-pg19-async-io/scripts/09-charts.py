#!/usr/bin/env python3
"""Generate the two charts for the article from the measured results.

Numbers are hard-coded from RESULTS.md (sections 4 and 5) so the charts stay
reproducible without re-parsing the raw CSVs.

Usage:  .venv/bin/python scripts/09-charts.py
Output: charts/*.png  (light and dark variants)
"""

import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, FixedFormatter

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "charts")

# Validated categorical palette (dataviz reference instance).
# Slot order is the CVD-safety mechanism — do not reshuffle.
THEMES = {
    "light": {
        "surface": "#fcfcfb",
        "text": "#0b0b0b",
        "secondary": "#52514e",
        "muted": "#898781",
        "grid": "#e1e0d9",
        "axis": "#c3c2b7",
        "series": ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"],
    },
    "dark": {
        "surface": "#1a1a19",
        "text": "#ffffff",
        "secondary": "#c3c2b7",
        "muted": "#898781",
        "grid": "#2c2c2a",
        "axis": "#383835",
        "series": ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181"],
    },
}

# Slot assignment follows the entity, not the row order, and is identical in
# both charts: sync -> slot 1, worker -> slot 2, io_uring -> slot 3.
SLOT = {"sync": 0, "worker": 1, "io_uring": 2, "fixed3": 3, "fixed8": 4}


def style(ax, t):
    ax.set_facecolor(t["surface"])
    ax.grid(axis="y", color=t["grid"], linewidth=0.8, linestyle="-")
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(t["axis"])
        ax.spines[side].set_linewidth(0.8)
    ax.tick_params(colors=t["muted"], labelsize=10, length=0)
    for lbl in ax.get_xticklabels() + ax.get_yticklabels():
        lbl.set_color(t["muted"])


def line(ax, x, y_ms, color, label, t):
    ax.plot(
        x, [v / 1000 for v in y_ms],
        color=color, linewidth=2, label=label,
        marker="o", markersize=6,
        markeredgecolor=t["surface"], markeredgewidth=1.5, zorder=3,
    )


def finish(fig, ax, t, title, subtitle, name):
    ax.set_title(title, color=t["text"], fontsize=15, fontweight="bold",
                 loc="left", pad=30)
    ax.text(0, 1.045, subtitle, transform=ax.transAxes, color=t["secondary"],
            fontsize=10.5, va="bottom", ha="left")
    leg = ax.legend(frameon=False, fontsize=10.5, labelcolor=t["secondary"],
                    loc="upper left", handlelength=1.6)
    for txt in leg.get_texts():
        txt.set_color(t["secondary"])
    fig.tight_layout()
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    fig.savefig(path, dpi=150, facecolor=t["surface"])
    plt.close(fig)
    print("written:", path)


# ---------------------------------------------------------------- chart 1
# RESULTS.md section 4: bitmap heap scan, sessions 1..16,
# effective_io_concurrency = 16 everywhere. Per iteration the slowest session is
# taken (that is the wall-clock of the whole batch), then the median of three
# iterations. Session 2 published the maximum here while labelling it a median;
# corrected in session 3 against data/results.csv (exp = 2).
SESSIONS = [1, 2, 4, 8, 16]
POOL = [
    ("fixed3", "worker, фиксированный пул 3 (конфигурация 18)", [4201, 8233, 15963, 17079, 19161]),
    ("worker", "worker, адаптивный пул 2–8 (дефолт 19)", [2025, 3857, 7301, 9574, 13359]),
    ("fixed8", "worker, фиксированный пул 8", [1942, 3645, 7227, 9881, 13885]),
    ("io_uring", "io_uring", [1342, 1803, 3379, 6277, 12723]),
    ("sync", "sync (fadvise-префетч)", [1282, 1741, 3320, 5920, 11250]),
]


def chart_pool(mode):
    t = THEMES[mode]
    fig, ax = plt.subplots(figsize=(9, 5.2), facecolor=t["surface"])
    style(ax, t)
    for key, label, ys in POOL:
        line(ax, SESSIONS, ys, t["series"][SLOT[key]], label, t)

    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_locator(FixedLocator(SESSIONS))
    ax.xaxis.set_major_formatter(FixedFormatter([str(s) for s in SESSIONS]))
    ax.set_xlabel("Параллельных читающих сессий", color=t["muted"], fontsize=10.5)
    ax.set_ylabel("Время, с (меньше — лучше)", color=t["muted"], fontsize=10.5)
    ax.set_ylim(0, 21)

    # selective direct label: the one series that matters, placed clear of the lines
    ax.annotate("фиксированный пул 3 —\nхуже всех на любой конкурентности",
                xy=(15.5, 15.9), color=t["series"][SLOT["fixed3"]], fontsize=10,
                ha="right", va="center", fontweight="bold")

    finish(fig, ax, t,
           "Пул io-воркеров под конкурентной нагрузкой",
           "Bitmap heap scan, каждая сессия читает свой диапазон ≈460 MB, "
           "effective_io_concurrency = 16",
           f"pool-scaling-{mode}.png")


# ---------------------------------------------------------------- chart 2
# RESULTS.md section 5: bitmap heap scan, effective_io_concurrency sweep,
# minimum of 2 iterations.
EIC = [0, 1, 4, 16, 64, 128]
SWEEP = [
    ("sync", "sync (fadvise-префетч)", [12651, 12632, 3165, 1170, 1045, 1016]),
    ("worker", "worker", [12609, 13853, 4560, 2005, 1974, 1962]),
    ("io_uring", "io_uring", [12732, 12684, 3447, 1225, 856, 863]),
]


def chart_eic(mode):
    t = THEMES[mode]
    fig, ax = plt.subplots(figsize=(9, 5.2), facecolor=t["surface"])
    style(ax, t)
    xs = list(range(len(EIC)))
    for key, label, ys in SWEEP:
        line(ax, xs, ys, t["series"][SLOT[key]], label, t)

    ax.set_yscale("log")
    ax.yaxis.set_major_locator(FixedLocator([1, 2, 5, 10, 20]))
    ax.yaxis.set_major_formatter(FixedFormatter(["1", "2", "5", "10", "20"]))
    ax.yaxis.set_minor_locator(FixedLocator([]))
    ax.set_ylim(0.7, 20)
    ax.set_xticks(xs)
    ax.set_xticklabels([str(v) for v in EIC])
    ax.set_xlim(-0.35, len(EIC) - 0.35)
    ax.set_xlabel("effective_io_concurrency", color=t["muted"], fontsize=10.5)
    ax.set_ylabel("Время, с (лог. шкала)", color=t["muted"], fontsize=10.5)

    # the default of 18/19 — a recessive marker, not a series
    ax.axvline(3, color=t["axis"], linewidth=1, zorder=1)
    ax.text(3, 18.5, " дефолт 18/19", color=t["muted"], fontsize=10, va="top")

    ax.annotate("при 0 и 1 выигрыша нет ни у одного метода;\n"
                "worker при 1 даже медленнее, чем при 0 —\n"
                "накладные расходы без отдачи",
                xy=(3.35, 8.5), color=t["secondary"], fontsize=10,
                ha="left", va="center")
    ax.annotate("io_uring", xy=(5, 0.863), xytext=(8, -2), textcoords="offset points",
                color=t["series"][SLOT["io_uring"]], fontsize=10,
                va="center", fontweight="bold")
    ax.annotate("worker", xy=(5, 1.962), xytext=(8, 0), textcoords="offset points",
                color=t["series"][SLOT["worker"]], fontsize=10,
                va="center", fontweight="bold")
    ax.annotate("sync", xy=(5, 1.016), xytext=(8, 8), textcoords="offset points",
                color=t["series"][SLOT["sync"]], fontsize=10,
                va="center", fontweight="bold")

    finish(fig, ax, t,
           "Без глубины очереди асинхронный I/O не даёт ничего",
           "Bitmap heap scan 33 GB, развёртка effective_io_concurrency, "
           "минимум из 2 итераций",
           f"eic-sweep-{mode}.png")


if __name__ == "__main__":
    for mode in ("light", "dark"):
        chart_pool(mode)
        chart_eic(mode)
