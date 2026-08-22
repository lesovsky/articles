#!/usr/bin/env python3
"""Графики к статье про pgpro_rp.

Числа зашиты из RESULTS.md, чтобы графики воспроизводились без повторного
разбора сырых CSV.

Запуск:  .venv/bin/python scripts/10-charts.py
Вывод:   charts/*.png (светлый и тёмный варианты)
"""

import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "charts")

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

# Слот закреплён за сущностью и одинаков во всех графиках:
# вес 1 -> слот 1, вес 8 -> слот 2, сосед -> слот 3.
SLOT = {"low": 0, "high": 1, "neighbor": 2}


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


def finish(fig, ax, t, title, subtitle, name, legend=True):
    ax.set_title(title, color=t["text"], fontsize=15, fontweight="bold",
                 loc="left", pad=30)
    ax.text(0, 1.045, subtitle, transform=ax.transAxes, color=t["secondary"],
            fontsize=10.5, va="bottom", ha="left")
    if legend:
        leg = ax.legend(frameon=False, fontsize=10.5, loc="upper left",
                        handlelength=1.6)
        for txt in leg.get_texts():
            txt.set_color(t["secondary"])
    fig.tight_layout()
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    fig.savefig(path, dpi=150, facecolor=t["surface"])
    plt.close(fig)
    print("written:", path)


# ---------------------------------------------------------------- график 1
# RESULTS.md, раздел 10: длинный CPU-запрос (≈12 с под нагрузкой) при конкуренции
# четырёх сеансов с весом 8. Оба веса меряются одновременно (pair_query).
# Медианы трёх прогонов, миллисекунды.
# При интервале 5 с результат неустойчив: в двух прогонах из трёх замедление есть,
# в третьем его нет вовсе (12896 мс) — медиана попадает на прогон с замедлением.
INTERVALS = ["0\n(по умолчанию)", "1 с", "5 с", "60 с"]
LONG_LOW = [12314, 102613, 79748, 11833]
LONG_HIGH = [12958, 10398, 12065, 12099]


def chart_interval(mode):
    t = THEMES[mode]
    fig, ax = plt.subplots(figsize=(9, 5.2), facecolor=t["surface"])
    style(ax, t)

    x = range(len(INTERVALS))
    w = 0.36
    ax.bar([i - w / 2 for i in x], [v / 1000 for v in LONG_LOW], w,
           color=t["series"][SLOT["low"]], label="вес 1", zorder=3)
    ax.bar([i + w / 2 for i in x], [v / 1000 for v in LONG_HIGH], w,
           color=t["series"][SLOT["high"]], label="вес 8", zorder=3)

    for i, (lo, hi) in enumerate(zip(LONG_LOW, LONG_HIGH)):
        ax.text(i - w / 2, lo / 1000 + 2, f"{lo/1000:.0f} с", ha="center",
                color=t["secondary"], fontsize=9.5)
        ax.text(i + w / 2, hi / 1000 + 2, f"{hi/1000:.0f} с", ha="center",
                color=t["secondary"], fontsize=9.5)

    ax.set_xticks(list(x))
    ax.set_xticklabels(INTERVALS)
    ax.set_ylabel("время выполнения, с", color=t["secondary"], fontsize=10.5)
    ax.set_ylim(0, 120)

    finish(fig, ax, t,
           "Чем реже опрос, тем меньше механизм замечает запрос",
           "Запрос ≈12 с, конкуренция — 4 сеанса с весом 8, медиана 3 прогонов",
           f"interval-sensitivity-{mode}.png")


if __name__ == "__main__":
    for mode in ("light", "dark"):
        chart_interval(mode)


# ---------------------------------------------------------------- график 2
# RESULTS.md, раздел 13: сценарий «шумный сосед». Медианы пяти прогонов.
NOISY = [
    ("base", "соседа нет", 71550, 0.296),
    ("flat", "сосед, веса равны", 43847, 0.950),
    ("priority", "сосед придушен", 53509, 0.661),
]


def chart_noisy(mode):
    t = THEMES[mode]
    fig, axes = plt.subplots(1, 2, figsize=(10.5, 4.8), facecolor=t["surface"])
    labels = [row[1] for row in NOISY]
    x = range(len(NOISY))
    # цвет закреплён за конфигурацией: точка отсчёта, без приоритизации, с ней
    colors = [t["muted"], t["series"][SLOT["low"]], t["series"][SLOT["high"]]]

    for ax, key, title, fmt in (
        (axes[0], 2, "Пропускная способность OLTP, тыс. TPS", lambda v: f"{v/1000:.1f}"),
        (axes[1], 3, "Латентность OLTP, p99, мс", lambda v: f"{v:.2f}"),
    ):
        style(ax, t)
        vals = [row[key] for row in NOISY]
        plot_vals = [v / 1000 for v in vals] if key == 2 else vals
        ax.bar(list(x), plot_vals, 0.55, color=colors, zorder=3)
        top = max(plot_vals)
        for i, v in enumerate(plot_vals):
            ax.text(i, v + top * 0.03, fmt(vals[i]), ha="center",
                    color=t["secondary"], fontsize=10)
        ax.set_xticks(list(x))
        ax.set_xticklabels(labels, fontsize=9.5)
        ax.set_ylim(0, top * 1.18)
        ax.set_title(title, color=t["text"], fontsize=12, fontweight="bold",
                     loc="left", pad=12)

    fig.suptitle("Приоритизация возвращает приложению часть отобранного",
                 color=t["text"], fontsize=15, fontweight="bold", x=0.012,
                 ha="left", y=0.985)
    fig.text(0.012, 0.90,
             "pgbench -S, 8 клиентов; сосед — два аналитических сеанса; медиана 5 прогонов",
             color=t["secondary"], fontsize=10.5, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.87))
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"noisy-neighbor-{mode}.png")
    fig.savefig(path, dpi=150, facecolor=t["surface"])
    plt.close(fig)
    print("written:", path)


for mode in ("light", "dark"):
    chart_noisy(mode)
