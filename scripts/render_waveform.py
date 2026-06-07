#!/usr/bin/env python3
"""Render a digital timing diagram from a VCD file.

Picks out the handful of testbench signals that prove the cache /
pipeline stall protocol works correctly and draws them as a stacked
trace.  Output is a PNG saved under `results/figures/`.

Usage:
    python3 scripts/render_waveform.py \\
        --vcd results/program_A_fib_l1_cache_stall.vcd \\
        --window 50 300 \\
        --out results/figures/program_A_fib_l1_cache_stall.png
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

from cache_lab_common import find_repo

import matplotlib
matplotlib.use("Agg")  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402
import vcdvcd                    # noqa: E402


# (display name, scope-relative signal regex, draw_as: 'bit' | 'bus' | 'pc')
SIGNAL_SELECTORS = [
    ("clk",                r"tb_cache_soc\.clk$",                   "bit"),
    ("cpu_imem_req",       r"u_core\.imem_req$",                    "bit"),
    ("cpu_imem_ready",     r"u_core\.imem_ready$",                  "bit"),
    ("icache_state",       r"u_icache\.state\[1:0\]$",              "bus"),
    ("dcache_state",       r"u_dcache\.state\[2:0\]$",              "bus"),
    ("if_id_valid",        r"u_core\.if_id_valid$",                 "bit"),
    ("imem_stall",         r"debug_imem_stall$",                    "bit"),
    ("dmem_stall",         r"debug_dmem_stall$",                    "bit"),
    ("retire_valid",       r"retire_valid$",                        "bit"),
    ("PC",                 r"u_core\.pc\[31:0\]$",                  "pc"),
]


def collect_signals(vcd):
    """Map each requested label to the actual VCD signal name."""
    matched = []
    for label, pattern, kind in SIGNAL_SELECTORS:
        name = None
        rx = re.compile(pattern)
        for full in vcd.signals:
            if rx.search(full):
                name = full
                break
        if name is None:
            print(f"warn: no signal matched {label!r} ({pattern})")
            continue
        matched.append((label, name, kind))
    return matched


def vcd_value_to_int(s: str | int | None) -> int | None:
    if s is None:
        return None
    if isinstance(s, int):
        return s
    # vcdvcd stores values as bit strings, possibly with 'x'/'z'.
    if any(c in "xzXZ" for c in s):
        return None
    try:
        return int(s, 2)
    except ValueError:
        return None


def render(vcd_path: Path, out_png: Path, win_start: int, win_end: int,
           cycle_ns: int = 10) -> None:
    vcd = vcdvcd.VCDVCD(str(vcd_path), store_tvs=True)
    signals = collect_signals(vcd)

    # The simulation runs at 100 MHz (10 ns period).  VCD timestamps are in
    # the units declared by the file's $timescale (xsim emits 1 ps here), so
    # derive how many VCD ticks make up one clock cycle instead of assuming
    # a 1 ns tick.
    head = vcd_path.read_text(encoding="utf-8", errors="ignore")[:4000]
    m = re.search(r"\$timescale\s+(\d+)\s*([munpf]?s)", head)
    unit_ps = {"s": 1e12, "ms": 1e9, "us": 1e6, "ns": 1e3, "ps": 1.0, "fs": 1e-3}
    tick_ps = (int(m.group(1)) * unit_ps[m.group(2)]) if m else 1.0
    ticks_per_cycle = (cycle_ns * 1000.0) / tick_ps  # 10 ns / 1 ps = 10000

    fig, axes = plt.subplots(
        nrows=len(signals), ncols=1, sharex=True,
        figsize=(11, 0.55 * len(signals) + 1)
    )
    if len(signals) == 1:
        axes = [axes]

    end_time = vcd.endtime
    # Window boundaries in VCD ticks; cycle number = ts / ticks_per_cycle.
    cyc_start_ts = int(win_start * ticks_per_cycle)
    cyc_end_ts   = int(min(end_time, win_end * ticks_per_cycle))

    for ax, (label, sig_name, kind) in zip(axes, signals):
        tvs = vcd[sig_name].tv  # list of (timestamp, value)
        # Build piecewise-constant trace inside the window.
        xs = []
        ys = []
        prev_val_int = 0
        # Seed with the value just before the window starts.
        for ts, val in tvs:
            if ts > cyc_start_ts:
                break
            iv = vcd_value_to_int(val)
            if iv is not None:
                prev_val_int = iv
        cur = prev_val_int
        xs.append(cyc_start_ts / ticks_per_cycle)
        ys.append(cur)
        for ts, val in tvs:
            if ts <= cyc_start_ts:
                continue
            if ts > cyc_end_ts:
                break
            iv = vcd_value_to_int(val)
            if iv is None:
                continue
            # step up at ts
            xs.append(ts / ticks_per_cycle)
            ys.append(cur)
            xs.append(ts / ticks_per_cycle)
            ys.append(iv)
            cur = iv
        # Close out to the right edge.
        xs.append(cyc_end_ts / ticks_per_cycle)
        ys.append(cur)

        if kind == "bit":
            ax.step(xs, ys, where="post", color="#1f77b4")
            ax.set_ylim(-0.4, 1.4)
            ax.set_yticks([0, 1])
        elif kind == "bus":
            ax.step(xs, ys, where="post", color="#d62728")
            ax.set_ylim(min(ys) - 0.5, max(ys) + 0.5 if max(ys) > 0 else 1)
        elif kind == "pc":
            # PC is full-width; just plot the numeric value as a line.
            ax.step(xs, ys, where="post", color="#2ca02c")
            ax.set_ylim(min(ys), max(ys) + 4)
            ax.set_yticks([min(ys), (min(ys) + max(ys))//2, max(ys)])
            ax.set_yticklabels([f"0x{v:08x}" for v in ax.get_yticks()],
                               fontsize=7)

        ax.set_ylabel(label, fontsize=9, rotation=0,
                      labelpad=55, ha="right", va="center")
        ax.grid(True, axis="x", linestyle=":", alpha=0.4)
        ax.tick_params(axis="y", labelsize=7)

    axes[-1].set_xlabel("cycle")
    fig.suptitle(
        f"{vcd_path.name}  —  cycles {win_start}..{win_end} "
        f"(I-Cache miss → IF/ID freeze → fill → resume)",
        fontsize=10
    )
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_png, dpi=130)
    print(f"Wrote {out_png}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, help="Target CPU_Lab2-style repository")
    parser.add_argument("--vcd", type=Path)
    parser.add_argument("--window", nargs=2, type=int, default=[0, 200],
                        metavar=("START", "END"),
                        help="cycle range to render")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    repo = find_repo(args.repo)
    vcd = args.vcd or (repo / "results" / "program_A_fib_l1_cache_stall.vcd")
    out = args.out or (repo / "results" / "figures" / "program_A_fib_l1_cache_stall.png")
    render(vcd, out, args.window[0], args.window[1])


if __name__ == "__main__":
    main()
