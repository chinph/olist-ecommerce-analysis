"""One chart style for every figure in the project: recessive axes, thin marks, fixed colour roles."""
from __future__ import annotations

import matplotlib as mpl
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap

from pathlib import Path

FIGURES = Path(__file__).resolve().parents[1] / "reports" / "figures"
FIGURES.mkdir(parents=True, exist_ok=True)

INK, INK_2, MUTED = "#0b0b0b", "#52514e", "#898781"
GRID, AXIS, SURFACE = "#e1e0d9", "#c3c2b7", "#fcfcfb"
# Categorical slots, always used in this order (never cycled past 3 on scatter/maps).
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
HIGHLIGHT, CONTEXT = SERIES[0], "#c3c2b7"
SEQ = LinearSegmentedColormap.from_list("seq_blue", ["#cde2fb", "#86b6ef", "#2a78d6", "#184f95", "#0d366b"])
DIV = LinearSegmentedColormap.from_list("div", ["#2a78d6", "#f0efec", "#e34948"])


def apply_style() -> None:
    mpl.rcParams.update({
        "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
        "font.family": ["Segoe UI", "DejaVu Sans", "sans-serif"], "font.size": 10,
        "text.color": INK, "axes.labelcolor": INK_2, "xtick.color": MUTED, "ytick.color": MUTED,
        "axes.edgecolor": AXIS, "axes.linewidth": 0.8, "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
        "axes.titlesize": 12, "axes.titleweight": "bold", "axes.titlelocation": "left", "axes.titlepad": 12,
        "axes.prop_cycle": mpl.cycler(color=SERIES), "lines.linewidth": 2, "lines.markersize": 7,
        "legend.frameon": False, "figure.dpi": 110, "savefig.dpi": 160, "savefig.bbox": "tight",
    })


def titles(ax, title: str, takeaway: str) -> None:
    """Bold title plus a grey one-line takeaway - every chart states what the reader should see."""
    ax.set_title(title, pad=24)
    ax.text(0, 1.015, takeaway, transform=ax.transAxes, color=INK_2, fontsize=9.5, va="bottom")


def label_points(ax, xs, ys, labels, fontsize=8.5, color=INK_2, offset=(4, 3), offsets=None) -> None:
    """Direct labels; `offsets` overrides the default nudge (in points) for crowded labels."""
    offsets = offsets or {}
    for x, y, s in zip(xs, ys, labels):
        dx, dy = offsets.get(s, offset)
        ax.annotate(s, (x, y), xytext=(dx, dy), textcoords="offset points", fontsize=fontsize, color=color,
                    ha="right" if dx < 0 else "left", va="center" if abs(dy) < 6 else ("bottom" if dy > 0 else "top"),
                    arrowprops=dict(arrowstyle="-", color=AXIS, linewidth=0.6) if s in offsets else None)


def save(fig, name: str) -> None:
    fig.savefig(FIGURES / f"{name}.png")
