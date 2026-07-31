#!/usr/bin/env python3
"""Generate dependency-free SVG charts for the consolidated experiment report.

The values below are transcribed from the branch reports and accepted summary
artifacts named in each chart function. Keeping the data beside the rendering
code makes every figure reviewable without requiring plotting dependencies.
"""

from __future__ import annotations

import html
from pathlib import Path


OUT = Path(__file__).resolve().parent / "charts"
FONT = "Inter,Segoe UI,Arial,sans-serif"
COLORS = {
    "blue": "#2563EB",
    "sky": "#38BDF8",
    "green": "#10B981",
    "amber": "#F59E0B",
    "red": "#EF4444",
    "purple": "#8B5CF6",
    "slate": "#475569",
    "ink": "#0F172A",
    "muted": "#64748B",
    "grid": "#CBD5E1",
    "panel": "#F8FAFC",
}


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def text(x: float, y: float, value: object, size: int = 16, *,
         fill: str | None = None, anchor: str = "start",
         weight: int = 400, rotate: float | None = None) -> str:
    transform = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" '
        f'font-size="{size}" font-weight="{weight}" fill="{fill or COLORS["ink"]}" '
        f'text-anchor="{anchor}"{transform}>{esc(value)}</text>'
    )


def rect(x: float, y: float, w: float, h: float, fill: str, *,
         rx: float = 0, stroke: str | None = None, opacity: float = 1) -> str:
    border = f' stroke="{stroke}"' if stroke else ""
    return (
        f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
        f'fill="{fill}" rx="{rx:.1f}" opacity="{opacity:.3f}"{border}/>'
    )


def line(x1: float, y1: float, x2: float, y2: float, *,
         stroke: str | None = None, width: float = 1,
         dash: str | None = None) -> str:
    dashed = f' stroke-dasharray="{dash}"' if dash else ""
    return (
        f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
        f'stroke="{stroke or COLORS["grid"]}" stroke-width="{width:.1f}"{dashed}/>'
    )


def circle(cx: float, cy: float, r: float, fill: str, *, stroke: str = "white") -> str:
    return (
        f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{fill}" '
        f'stroke="{stroke}" stroke-width="2"/>'
    )


def svg_document(width: int, height: int, body: list[str], title_value: str) -> str:
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-label="{esc(title_value)}">',
        f'<title>{esc(title_value)}</title>',
        rect(0, 0, width, height, "white"),
        *body,
        "</svg>",
        "",
    ])


def write_svg(name: str, width: int, height: int, body: list[str], title_value: str) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / name).write_text(svg_document(width, height, body, title_value), encoding="utf-8")


def chart_a01() -> None:
    # Source: A01 G1-R5, G2-R7, and G3-R5 final comparison tables.
    groups = ["G1: 1 pod / 1 task", "G2: 2 pods / 1 task", "G3: 2 concurrent tasks"]
    methods = [
        ("task-ID", [1.0, 1.0, 1.0], COLORS["blue"]),
        ("Kubernetes-node", [1.0, 1.0, 1.0], COLORS["green"]),
        ("10-minute window", [1.0, 1.0, 0.667], COLORS["amber"]),
    ]
    width, height = 1080, 620
    left, right, top, bottom = 105, 40, 125, 120
    plot_w, plot_h = width - left - right, height - top - bottom
    body = [
        text(40, 42, "A01 attribution accuracy by scenario", 26, weight=700),
        text(40, 70, "Five repetitions per scenario; F1 score", 15, fill=COLORS["muted"]),
        text(width - 40, 94,
             "Only the concurrent G3 case separates task-ID from time-window matching.",
             13, fill=COLORS["red"], anchor="end", weight=600),
    ]
    for tick in [0, 0.25, 0.5, 0.75, 1.0]:
        y = top + plot_h * (1 - tick)
        body.extend([line(left, y, left + plot_w, y), text(left - 12, y + 5, f"{tick:.2f}", 13,
                                                            fill=COLORS["muted"], anchor="end")])
    body.extend([line(left, top, left, top + plot_h, stroke=COLORS["slate"], width=1.5),
                 line(left, top + plot_h, left + plot_w, top + plot_h, stroke=COLORS["slate"], width=1.5)])
    group_w = plot_w / len(groups)
    bar_w = 58
    gap = 12
    for gi, group in enumerate(groups):
        center = left + group_w * (gi + 0.5)
        start = center - (3 * bar_w + 2 * gap) / 2
        for mi, (_, values, color) in enumerate(methods):
            value = values[gi]
            h = value * plot_h
            x = start + mi * (bar_w + gap)
            y = top + plot_h - h
            body.extend([rect(x, y, bar_w, h, color, rx=5),
                         text(x + bar_w / 2, y - 8, f"{value:.3f}", 13, anchor="middle", weight=600)])
        body.append(text(center, top + plot_h + 32, group, 14, anchor="middle", weight=600))
    lx = left + 35
    for name, _, color in methods:
        body.extend([rect(lx, height - 54, 22, 12, color, rx=2),
                     text(lx + 30, height - 43, name, 13)])
        lx += 255
    write_svg("a01-attribution-f1.svg", width, height, body, "A01 attribution accuracy by scenario")


def chart_e01() -> None:
    # Source: E01 report, section 4, medians in seconds.
    labels = ["existing / warm / small / light", "existing / cold / large / light",
              "new / cold / small / light", "new / cold / large / heavy"]
    series = [
        ("Node", [0.0, 0.0, 70.248, 72.971], COLORS["purple"]),
        ("Image", [0.0, 106.251, 13.052, 106.720], COLORS["blue"]),
        ("Pod", [0.113, 106.374, 13.775, 106.890], COLORS["sky"]),
        ("App", [0.885, 0.594, 0.623, 3.192], COLORS["green"]),
        ("E2E", [1.827, 107.411, 102.995, 201.228], COLORS["amber"]),
    ]
    width, height = 1180, 660
    left, right, top, bottom = 90, 35, 120, 165
    plot_w, plot_h = width - left - right, height - top - bottom
    max_v = 220.0
    body = [
        text(40, 42, "E01 four-layer baseline medians", 26, weight=700),
        text(40, 70, "Seconds; 5 runs per cell", 15, fill=COLORS["muted"]),
        text(width - 40, 70, "Layer intervals overlap — do not stack or add them", 14,
             fill=COLORS["red"], anchor="end", weight=700),
    ]
    for tick in range(0, 221, 50):
        y = top + plot_h * (1 - tick / max_v)
        body.extend([line(left, y, left + plot_w, y),
                     text(left - 10, y + 5, tick, 13, fill=COLORS["muted"], anchor="end")])
    group_w = plot_w / len(labels)
    bar_w, gap = 34, 7
    total_w = len(series) * bar_w + (len(series) - 1) * gap
    for gi, label_value in enumerate(labels):
        center = left + group_w * (gi + 0.5)
        start = center - total_w / 2
        for si, (name, values, color) in enumerate(series):
            value = values[gi]
            h = value / max_v * plot_h
            x = start + si * (bar_w + gap)
            y = top + plot_h - h
            if value > 0:
                body.append(rect(x, y, bar_w, max(h, 1.5), color, rx=3))
            if name == "E2E":
                body.append(text(x + bar_w / 2, y - 7, f"{value:.3f}", 12,
                                 anchor="middle", weight=700))
        body.append(text(center, top + plot_h + 32, label_value, 13, anchor="middle", weight=600,
                         rotate=-12))
    body.extend([line(left, top, left, top + plot_h, stroke=COLORS["slate"], width=1.5),
                 line(left, top + plot_h, left + plot_w, top + plot_h, stroke=COLORS["slate"], width=1.5)])
    lx = 130
    for name, _, color in series:
        body.extend([rect(lx, height - 48, 22, 12, color, rx=2), text(lx + 30, height - 37, name, 13)])
        lx += 180
    write_svg("e01-four-layer-baseline.svg", width, height, body, "E01 four-layer baseline medians")


def chart_e03() -> None:
    # Source: E03 report section 5.1, mean pull-total seconds per cold cell.
    sizes = [100, 500, 1024]
    panels = {
        "Existing node": {
            "c1": [19.623, 100.388, 211.965],
            "c2": [20.046, 104.159, 224.682],
            "c4": [24.441, 133.018, 296.746],
        },
        "New node": {
            "c1": [19.632, 101.259, 209.729],
            "c2": [19.976, 102.942, 221.326],
            "c4": [24.791, 129.912, 273.617],
        },
    }
    colors = {"c1": COLORS["blue"], "c2": COLORS["green"], "c4": COLORS["red"]}
    width, height = 1180, 700
    body = [
        text(40, 42, "E03 cold image pull: size and concurrency", 26, weight=700),
        text(40, 70, "Mean pull-total seconds per Pod; one run per cell", 15, fill=COLORS["muted"]),
    ]
    panel_y, panel_h, panel_w, gap = 115, 405, 500, 90
    for pi, (panel_name, series) in enumerate(panels.items()):
        x0 = 75 + pi * (panel_w + gap)
        y0 = panel_y
        body.extend([rect(x0 - 22, y0 - 35, panel_w + 44, panel_h + 75, COLORS["panel"], rx=12,
                          stroke=COLORS["grid"]),
                     text(x0, y0 - 10, panel_name, 18, weight=700)])
        max_y = 320.0
        for tick in range(0, 321, 80):
            y = y0 + panel_h * (1 - tick / max_y)
            body.extend([line(x0, y, x0 + panel_w, y),
                         text(x0 - 10, y + 5, tick, 12, fill=COLORS["muted"], anchor="end")])
        x_positions = [x0 + 30 + (panel_w - 60) * i / 2 for i in range(3)]
        for sx, size in zip(x_positions, sizes):
            body.append(text(sx, y0 + panel_h + 27, size, 13, anchor="middle"))
        for name, values in series.items():
            pts = []
            for sx, value in zip(x_positions, values):
                sy = y0 + panel_h * (1 - value / max_y)
                pts.append((sx, sy))
            for (ax, ay), (bx, by) in zip(pts, pts[1:]):
                body.append(line(ax, ay, bx, by, stroke=colors[name], width=3))
            label_offset = {"c1": 20, "c2": -10, "c4": -20}[name]
            for (sx, sy), value in zip(pts, values):
                body.extend([circle(sx, sy, 6, colors[name]),
                             text(sx, sy + label_offset, f"{value:.1f}", 11,
                                  anchor="middle", weight=600)])
        body.append(text(x0 + panel_w / 2, y0 + panel_h + 52, "Image size (MiB)", 13,
                         fill=COLORS["muted"], anchor="middle"))
    lx = 355
    for name in ["c1", "c2", "c4"]:
        body.extend([line(lx, height - 49, lx + 30, height - 49, stroke=colors[name], width=4),
                     circle(lx + 15, height - 49, 5, colors[name]),
                     text(lx + 40, height - 44, f"requested concurrency {name[1:]}", 13)])
        lx += 235
    body.append(text(40, 682,
                     "Descriptive c1 slopes: existing 0.208 s/MiB (R²=0.9998), new 0.206 s/MiB (R²=1.0000).",
                     13, fill=COLORS["muted"]))
    write_svg("e03-image-pull.svg", width, height, body, "E03 cold image pull by size and concurrency")


def chart_e07() -> None:
    # Source: E07 report section "Cell results".
    cells = ["B0", "B1", "B2", "B3", "B4"]
    values = [238.215, 130.624, 106.581, 108.989, 97.460]
    subtitles = ["cold node", "warm node", "cooldown 5s", "ACK Queue + k=1", "parallel Argo"]
    colors = [COLORS["slate"], COLORS["blue"], COLORS["green"], COLORS["amber"], COLORS["purple"]]
    deltas = [-45.17, -18.41, 2.26, -10.58]
    width, height = 1120, 650
    left, right, top, bottom = 90, 35, 110, 130
    plot_w, plot_h = width - left - right, height - top - bottom
    max_y = 260.0
    body = [
        text(40, 42, "E07 cumulative tuning smoke", 26, weight=700),
        text(40, 70, "E2E seconds; fixed order, one run per cell", 15, fill=COLORS["muted"]),
        text(width - 40, 70, "Overall B0→B4: −59.09% (descriptive only)", 14,
             anchor="end", fill=COLORS["red"], weight=700),
    ]
    for tick in [0, 50, 100, 150, 200, 250]:
        y = top + plot_h * (1 - tick / max_y)
        body.extend([line(left, y, left + plot_w, y),
                     text(left - 10, y + 5, tick, 13, fill=COLORS["muted"], anchor="end")])
    group_w = plot_w / len(cells)
    bar_w = 108
    centers = []
    for i, (cell_name, value, subtitle, color) in enumerate(zip(cells, values, subtitles, colors)):
        center = left + group_w * (i + 0.5)
        centers.append(center)
        h = value / max_y * plot_h
        y = top + plot_h - h
        body.extend([rect(center - bar_w / 2, y, bar_w, h, color, rx=7),
                     text(center, y - 10, f"{value:.3f}s", 14, anchor="middle", weight=700),
                     text(center, top + plot_h + 30, cell_name, 16, anchor="middle", weight=700),
                     text(center, top + plot_h + 53, subtitle, 12, anchor="middle", fill=COLORS["muted"])])
    for i, delta in enumerate(deltas):
        mid = (centers[i] + centers[i + 1]) / 2
        sign = "+" if delta > 0 else ""
        body.extend([line(centers[i] + bar_w / 2 + 8, 95, centers[i + 1] - bar_w / 2 - 8, 95,
                          stroke=COLORS["grid"], width=2),
                     text(mid, 91, f"{sign}{delta:.2f}%", 12, anchor="middle",
                          fill=COLORS["red"] if delta > 0 else COLORS["green"], weight=700)])
    body.append(text(40, height - 30,
                     "B2→B3 is not a speedup: it validates whole-Job admission plus an application k-of-n barrier.",
                     13, fill=COLORS["muted"]))
    write_svg("e07-cumulative-e2e.svg", width, height, body, "E07 cumulative tuning smoke E2E")


def chart_e08() -> None:
    # Source: accepted E08 summary.json and report tables.
    modes = ["off", "10%", "100%"]
    trace_rates = [0, 12, 100]
    ingest_p50 = [4.342, 7.337, 194.953]
    ingest_p95 = [95.532, 402.463, 465.005]
    controller_cpu = [0, 0.942, 1.507]
    width, height = 1200, 690
    body = [
        text(40, 42, "E08 collector overhead: accepted low-rate smoke", 26, weight=700),
        text(40, 70, "50 Pods/cell, parallelism=2, fixed order; not a formal overhead study", 15,
             fill=COLORS["muted"]),
    ]
    panel_specs = [
        (55, 125, 330, 390, "Complete trace rate (%)", trace_rates, 100, COLORS["blue"], "{:.0f}%"),
        (435, 125, 330, 390, "Controller mean CPU (mCPU)", controller_cpu, 2.0, COLORS["green"], "{:.3f}"),
    ]
    for x0, y0, pw, ph, title_value, values, max_v, color, fmt in panel_specs:
        body.extend([rect(x0, y0 - 38, pw, ph + 83, COLORS["panel"], rx=12, stroke=COLORS["grid"]),
                     text(x0 + 16, y0 - 10, title_value, 16, weight=700)])
        base_y = y0 + ph
        bw = 62
        for i, (mode, value) in enumerate(zip(modes, values)):
            center = x0 + 65 + i * 95
            h = value / max_v * (ph - 35)
            body.extend([rect(center - bw / 2, base_y - h, bw, max(h, 1.5), color, rx=5,
                              opacity=0.45 + 0.25 * i),
                         text(center, base_y - h - 9, fmt.format(value), 12, anchor="middle", weight=700),
                         text(center, base_y + 25, mode, 13, anchor="middle")])
        body.append(line(x0 + 25, base_y, x0 + pw - 20, base_y, stroke=COLORS["slate"], width=1.5))
    x0, y0, pw, ph = 815, 125, 330, 390
    body.extend([rect(x0, y0 - 38, pw, ph + 83, COLORS["panel"], rx=12, stroke=COLORS["grid"]),
                 text(x0 + 16, y0 - 10, "Observed→MySQL latency (ms)", 16, weight=700)])
    max_v, base_y, group_w, bw = 500.0, y0 + ph, 95, 28
    for i, mode in enumerate(modes):
        center = x0 + 65 + i * group_w
        for offset, value, color in [(-17, ingest_p50[i], COLORS["amber"]), (17, ingest_p95[i], COLORS["red"])]:
            h = value / max_v * (ph - 35)
            body.append(rect(center + offset - bw / 2, base_y - h, bw, max(h, 1.5), color, rx=4))
        body.extend([text(center, base_y + 25, mode, 13, anchor="middle"),
                     text(center, base_y - ingest_p95[i] / max_v * (ph - 35) - 9,
                          f"{ingest_p95[i]:.1f}", 11, anchor="middle", weight=700)])
    body.extend([line(x0 + 25, base_y, x0 + pw - 20, base_y, stroke=COLORS["slate"], width=1.5),
                 rect(x0 + 50, y0 + ph + 45, 18, 10, COLORS["amber"], rx=2),
                 text(x0 + 75, y0 + ph + 55, "p50", 12),
                 rect(x0 + 145, y0 + ph + 45, 18, 10, COLORS["red"], rx=2),
                 text(x0 + 170, y0 + ph + 55, "p95", 12)])
    body.extend([
        text(55, 623, "All three cells had workload startup p50/p95 = 2s; off max was 8s, on max was 2s.",
             13, fill=COLORS["muted"]),
        text(55, 648, "The off cell still retained application SDK → ingester → MySQL events; only controller/node-agent were off.",
             13, fill=COLORS["red"], weight=600),
    ])
    write_svg("e08-collector-overhead.svg", width, height, body, "E08 collector overhead smoke")


def chart_e09() -> None:
    # Source: accepted E09 two-A100 pilot summary.json.
    # Each strategy/profile cell contains six batches across two physical A100s.
    profiles = ["1g.10gb", "3g.40gb"]
    static_capacity = [2, 1]
    dynamic_capacity = [7, 2]
    ratios = [3.5, 2.0]
    latency_cells = [
        ("static", "1g.10gb", 6.762, 6.736, 7.045, 7.091, COLORS["blue"]),
        ("dynamic", "1g.10gb", 17.273, 7.543, 38.290, 38.623, COLORS["green"]),
        ("static", "3g.40gb", 6.700, 6.704, 6.838, 6.861, COLORS["blue"]),
        ("dynamic", "3g.40gb", 27.423, 35.886, 40.388, 40.399, COLORS["green"]),
    ]
    width, height = 1240, 720
    body = [
        text(40, 42, "E09 two-A100 MIG/DRA crossover pilot", 26, weight=700),
        text(40, 70,
             "Six batches per strategy/profile across two physical A100s; descriptive pilot",
             15, fill=COLORS["muted"]),
    ]

    # Left panel: exact first-wave capacity published by DRA and confirmed by CUDA.
    x0, y0, pw, ph = 55, 150, 500, 340
    base_y = y0 + ph
    body.extend([
        rect(x0, y0 - 45, pw, ph + 115, COLORS["panel"], rx=12, stroke=COLORS["grid"]),
        text(x0 + 18, y0 - 15, "First-wave CUDA capacity (devices)", 17, weight=700),
    ])
    max_capacity = 8.0
    for tick in [0, 2, 4, 6, 8]:
        y = base_y - tick / max_capacity * ph
        body.extend([
            line(x0 + 55, y, x0 + pw - 25, y),
            text(x0 + 45, y + 5, tick, 12, fill=COLORS["muted"], anchor="end"),
        ])
    centers = [x0 + 165, x0 + 365]
    bar_w, gap = 66, 18
    for center, profile, static_value, dynamic_value, ratio in zip(
            centers, profiles, static_capacity, dynamic_capacity, ratios):
        for offset, value, color in [
                (-bar_w / 2 - gap / 2, static_value, COLORS["blue"]),
                (bar_w / 2 + gap / 2, dynamic_value, COLORS["green"])]:
            h = value / max_capacity * ph
            body.extend([
                rect(center + offset - bar_w / 2, base_y - h, bar_w, h, color, rx=6),
                text(center + offset, base_y - h - 9, value, 14,
                     anchor="middle", weight=700),
            ])
        dynamic_h = dynamic_value / max_capacity * ph
        body.append(text(center + bar_w / 2 + gap / 2, base_y - dynamic_h - 31,
                         f"{ratio:.2f}×", 12, fill=COLORS["green"],
                         anchor="middle", weight=700))
        body.append(text(center, base_y + 31, profile, 14, anchor="middle", weight=700))
    body.extend([
        line(x0 + 55, base_y, x0 + pw - 25, base_y, stroke=COLORS["slate"], width=1.5),
        rect(x0 + 105, base_y + 58, 22, 12, COLORS["blue"], rx=2),
        text(x0 + 135, base_y + 69, "static-balanced", 13),
        rect(x0 + 300, base_y + 58, 22, 12, COLORS["green"], rx=2),
        text(x0 + 330, base_y + 69, "dynamic-homogeneous", 13),
    ])

    # Right panel: mean plus descriptive p50/p95/max for request-to-first-CUDA.
    x0, y0, pw, ph = 610, 150, 575, 340
    base_y = y0 + ph
    body.extend([
        rect(x0, y0 - 45, pw, ph + 115, COLORS["panel"], rx=12, stroke=COLORS["grid"]),
        text(x0 + 18, y0 - 15, "Request → first CUDA (seconds)", 17, weight=700),
    ])
    max_latency = 45.0
    for tick in [0, 10, 20, 30, 40]:
        y = base_y - tick / max_latency * ph
        body.extend([
            line(x0 + 55, y, x0 + pw - 25, y),
            text(x0 + 45, y + 5, tick, 12, fill=COLORS["muted"], anchor="end"),
        ])
    point_centers = [x0 + 100, x0 + 230, x0 + 360, x0 + 490]
    for center, (strategy, profile, mean, p50, p95, maximum, color) in zip(
            point_centers, latency_cells):
        value_y = lambda value: base_y - value / max_latency * ph
        mean_y, p50_y = value_y(mean), value_y(p50)
        p95_y, max_y = value_y(p95), value_y(maximum)
        body.extend([
            line(center, p50_y, center, max_y, stroke=color, width=3),
            circle(center, mean_y, 7, color),
            circle(center, p50_y, 6, "white", stroke=color),
            rect(center - 5, p95_y - 5, 10, 10, COLORS["red"], rx=2),
            line(center - 9, max_y, center + 9, max_y, stroke=COLORS["ink"], width=2),
            text(center, max_y - 10, f"max {maximum:.1f}", 10,
                 anchor="middle", weight=600),
            text(center, mean_y + 20, f"mean {mean:.1f}", 11,
                 fill=color, anchor="middle", weight=700),
            text(center, base_y + 27, strategy, 13, fill=color,
                 anchor="middle", weight=700),
            text(center, base_y + 47, profile, 12, anchor="middle"),
        ])
    body.append(line(x0 + 55, base_y, x0 + pw - 25, base_y,
                     stroke=COLORS["slate"], width=1.5))
    legend_y = base_y + 70
    body.extend([
        circle(x0 + 75, legend_y, 6, COLORS["blue"]),
        text(x0 + 88, legend_y + 5, "mean (strategy color)", 11),
        circle(x0 + 235, legend_y, 6, "white", stroke=COLORS["slate"]),
        text(x0 + 248, legend_y + 5, "p50", 11),
        rect(x0 + 303, legend_y - 5, 10, 10, COLORS["red"], rx=2),
        text(x0 + 320, legend_y + 5, "p95", 11),
        line(x0 + 382, legend_y, x0 + 400, legend_y, stroke=COLORS["ink"], width=2),
        text(x0 + 408, legend_y + 5, "max", 11),
    ])

    body.extend([
        text(55, 645,
             "Mismatch epochs: reshape mean 24.610s; request → first CUDA mean 37.313s.",
             13, fill=COLORS["muted"]),
        text(55, 672,
             "n=6 per cell. p95 is a descriptive order statistic, not a production tail estimate or confidence bound.",
             13, fill=COLORS["red"], weight=600),
    ])
    write_svg("e09-gpu-mig-capacity-latency.svg", width, height, body,
              "E09 two-A100 MIG DRA capacity and latency")


def main() -> None:
    chart_a01()
    chart_e01()
    chart_e03()
    chart_e07()
    chart_e08()
    chart_e09()


if __name__ == "__main__":
    main()
