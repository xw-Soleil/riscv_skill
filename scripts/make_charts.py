#!/usr/bin/env python3
import csv
import json
import math
import re
import argparse
from pathlib import Path

from cache_lab_common import find_repo


def read_csv(path):
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def fnum(value, default=0.0):
    if value in ("", None):
        return default
    return float(value)


def svg_text(x, y, text, size=13, anchor="middle", weight="400", fill="#1f2937"):
    return (
        f'<text x="{x}" y="{y}" font-family="Arial, sans-serif" '
        f'font-size="{size}" text-anchor="{anchor}" font-weight="{weight}" '
        f'fill="{fill}">{text}</text>'
    )


def write_svg(path, width, height, body):
    path.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">\n'
        f'<rect width="100%" height="100%" fill="#ffffff"/>\n'
        + "\n".join(body)
        + "\n</svg>\n",
        encoding="utf-8",
    )


def line_chart(rows, path):
    points = []
    for row in rows:
        m = re.match(r"sweep_blk_(\d+)$", row["run_tag"])
        if row["program"] == "array_seq" and m:
            points.append((int(m.group(1)), int(row["cycles"]), fnum(row["dcache_hit_rate"])))
    points.sort()

    width, height = 720, 420
    x0, y0, w, h = 90, 330, 560, 230
    min_c = min(p[1] for p in points)
    max_c = max(p[1] for p in points)
    body = [
        svg_text(width / 2, 34, "Array Sequential: Block Size vs Cycles and D-Cache Hit Rate", 18, weight="700"),
        f'<line x1="{x0}" y1="{y0}" x2="{x0+w}" y2="{y0}" stroke="#334155" stroke-width="1.5"/>',
        f'<line x1="{x0}" y1="{y0}" x2="{x0}" y2="{y0-h}" stroke="#334155" stroke-width="1.5"/>',
        svg_text(x0 - 52, y0 - h / 2, "cycles", 13, anchor="middle"),
        svg_text(x0 + w / 2, y0 + 58, "L1 block size (bytes)", 13),
    ]
    for i in range(5):
        y = y0 - h * i / 4
        val = round(min_c + (max_c - min_c) * i / 4)
        body.append(f'<line x1="{x0-5}" y1="{y}" x2="{x0+w}" y2="{y}" stroke="#e2e8f0"/>')
        body.append(svg_text(x0 - 12, y + 4, str(val), 11, anchor="end", fill="#475569"))

    def x_of(block):
        idx = [p[0] for p in points].index(block)
        return x0 + idx * (w / (len(points) - 1))

    def y_of(cycles):
        return y0 - (cycles - min_c) / (max_c - min_c) * h

    poly = " ".join(f"{x_of(b)},{y_of(c)}" for b, c, _ in points)
    body.append(f'<polyline points="{poly}" fill="none" stroke="#2563eb" stroke-width="3"/>')
    for b, c, hit in points:
        x, y = x_of(b), y_of(c)
        body.append(f'<circle cx="{x}" cy="{y}" r="5" fill="#2563eb"/>')
        body.append(svg_text(x, y - 13, f"{c} cyc", 11))
        body.append(svg_text(x, y + 24, f"{hit*100:.1f}%", 11, fill="#047857"))
        body.append(svg_text(x, y0 + 24, str(b), 12))
    body.append(svg_text(x0 + w - 4, y0 - h - 10, "green label = D hit rate", 11, anchor="end", fill="#047857"))
    write_svg(path, width, height, body)


def heatmap(rows, path):
    blocks = [16, 32, 64]
    ways = [1, 2, 4]
    data = {}
    for row in rows:
        m = re.match(r"sweep_grid_b(\d+)_w(\d+)$", row["run_tag"])
        if row["program"] == "matmul_mmc" and m:
            data[(int(m.group(1)), int(m.group(2)))] = fnum(row["dcache_hit_rate"])

    width, height = 560, 430
    x0, y0, cell = 150, 100, 95
    vals = list(data.values())
    vmin, vmax = min(vals), max(vals)
    body = [svg_text(width / 2, 34, "MMC D-Cache Hit Rate Heatmap", 18, weight="700")]
    body.append(svg_text(x0 + cell * 1.5, 78, "Associativity", 13, weight="700"))
    body.append(svg_text(60, y0 + cell * 1.6, "Block size", 13, weight="700"))
    for j, way in enumerate(ways):
        body.append(svg_text(x0 + j * cell + cell / 2, y0 - 16, f"{way}-way", 12))
    for i, block in enumerate(blocks):
        body.append(svg_text(x0 - 18, y0 + i * cell + cell / 2 + 5, f"{block}B", 12, anchor="end"))
        for j, way in enumerate(ways):
            val = data[(block, way)]
            t = (val - vmin) / (vmax - vmin) if vmax > vmin else 0.5
            r = round(230 - 130 * t)
            g = round(244 - 70 * t)
            b = round(255 - 160 * t)
            color = f"rgb({r},{g},{b})"
            x, y = x0 + j * cell, y0 + i * cell
            body.append(f'<rect x="{x}" y="{y}" width="{cell}" height="{cell}" fill="{color}" stroke="#ffffff" stroke-width="2"/>')
            body.append(svg_text(x + cell / 2, y + cell / 2 - 4, f"{val*100:.2f}%", 14, weight="700"))
            body.append(svg_text(x + cell / 2, y + cell / 2 + 17, f"{data[(block, way)]:.4f}", 11, fill="#475569"))
    write_svg(path, width, height, body)


def locality_bars(baseline_rows, path):
    selected = ["program_A_fib", "array_seq", "array_rand"]
    labels = {
        "program_A_fib": "Fibonacci",
        "array_seq": "Sequential",
        "array_rand": "Random",
    }
    rows = [r for r in baseline_rows if r["config"] == "l1" and r["program"] in selected]
    rows.sort(key=lambda r: selected.index(r["program"]))

    width, height = 650, 390
    x0, y0, w, h = 80, 310, 500, 220
    body = [svg_text(width / 2, 34, "Locality Programs: L1 D-Cache Hit Rate", 18, weight="700")]
    body.append(f'<line x1="{x0}" y1="{y0}" x2="{x0+w}" y2="{y0}" stroke="#334155" stroke-width="1.5"/>')
    body.append(f'<line x1="{x0}" y1="{y0}" x2="{x0}" y2="{y0-h}" stroke="#334155" stroke-width="1.5"/>')
    for i in range(5):
        y = y0 - h * i / 4
        body.append(f'<line x1="{x0-5}" y1="{y}" x2="{x0+w}" y2="{y}" stroke="#e2e8f0"/>')
        body.append(svg_text(x0 - 12, y + 4, f"{i*25}%", 11, anchor="end", fill="#475569"))
    bar_w = 90
    gap = 70
    for i, row in enumerate(rows):
        rate = fnum(row["dcache_hit_rate"])
        bh = rate * h
        x = x0 + 65 + i * (bar_w + gap)
        y = y0 - bh
        body.append(f'<rect x="{x}" y="{y}" width="{bar_w}" height="{bh}" fill="#0f766e"/>')
        body.append(svg_text(x + bar_w / 2, y - 10, f"{rate*100:.1f}%", 12, weight="700"))
        body.append(svg_text(x + bar_w / 2, y0 + 24, labels[row["program"]], 12))
        body.append(svg_text(x + bar_w / 2, y0 + 43, f'{row["dcache_hits"]}/{int(row["dcache_hits"])+int(row["dcache_misses"])}', 11, fill="#475569"))
    write_svg(path, width, height, body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, help="Target CPU_Lab2-style repository")
    parser.add_argument("--results", type=Path, help="Results directory; defaults to <repo>/results")
    args = parser.parse_args()
    repo = find_repo(args.repo)
    results = args.results or (repo / "results")

    sweep = read_csv(results / "sweep_results.csv")
    baseline = read_csv(results / "baseline_results.csv")
    line_chart(sweep, results / "block_size_array_seq.svg")
    heatmap(sweep, results / "mmc_block_way_heatmap.svg")
    locality_bars(baseline, results / "locality_dcache_hit_rates.svg")
    print(f"Wrote SVG charts to {results}")


if __name__ == "__main__":
    main()
