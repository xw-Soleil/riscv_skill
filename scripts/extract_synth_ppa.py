#!/usr/bin/env python3
"""Extract a concise PPA summary from the Vivado utilization / timing /
power reports produced by `scripts/run_vivado_synth.tcl`.

Run from the project root after a Vivado batch synthesis:

    python3 scripts/extract_synth_ppa.py

Outputs a Markdown table on stdout and writes a JSON summary to
`results/synth/ppa_summary.json`.
"""
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path

from cache_lab_common import find_repo


CONFIGS = ["l1_only", "l1_l2"]


def parse_utilization(path: Path) -> dict:
    """Pick out the headline resource numbers from report_utilization."""
    out = {
        "luts": None,
        "lut_ram": None,
        "ffs": None,
        "bram_tile": None,
        "bram_36k": None,
        "bram_18k": None,
        "dsp": None,
        "io": None,
    }
    if not path.exists():
        return out
    text = path.read_text(errors="ignore")

    def first_number(pattern: str) -> int | None:
        m = re.search(pattern, text)
        if not m:
            return None
        try:
            return int(m.group(1).replace(",", ""))
        except ValueError:
            return None

    def first_float(pattern: str) -> float | None:
        # Vivado reports the Block RAM Tile count as a fractional value
        # (e.g. 22.5) when an 18 Kb half-tile is in use, so parse as float.
        m = re.search(pattern, text)
        if not m:
            return None
        try:
            return float(m.group(1).replace(",", ""))
        except ValueError:
            return None

    out["luts"]      = first_number(r"\bSlice LUTs\*?\s*\|\s*([\d,]+)")
    if out["luts"] is None:
        out["luts"]  = first_number(r"\bCLB LUTs\*?\s*\|\s*([\d,]+)")
    out["lut_ram"]   = first_number(r"\bLUT as Memory\s*\|\s*([\d,]+)")
    out["ffs"]       = first_number(r"\bSlice Registers\s*\|\s*([\d,]+)")
    if out["ffs"] is None:
        out["ffs"]   = first_number(r"\bCLB Registers\s*\|\s*([\d,]+)")
    out["bram_tile"] = first_float(r"\bBlock RAM Tile\s*\|\s*([\d,]+(?:\.\d+)?)")
    out["bram_36k"]  = first_number(r"\bRAMB36/FIFO\*?\s*\|\s*([\d,]+)")
    out["bram_18k"]  = first_number(r"\bRAMB18\s*\|\s*([\d,]+)")
    out["dsp"]       = first_number(r"\bDSPs\s*\|\s*([\d,]+)")
    out["io"]        = first_number(r"\bBonded IOB\s*\|\s*([\d,]+)")
    return out


def parse_timing(path: Path) -> dict:
    """Pull the worst negative slack and derive Fmax (post-route)."""
    out = {"wns_ns": None, "tns_ns": None, "fmax_mhz": None, "period_ns": None}
    if not path.exists():
        return out
    text = path.read_text(errors="ignore")

    # Vivado reports WNS in the "Design Timing Summary" block.
    m = re.search(r"WNS\(ns\).*?\n[-\s]+\n\s*(-?\d+\.\d+)", text, re.S)
    if m:
        try:
            out["wns_ns"] = float(m.group(1))
        except ValueError:
            pass
    m = re.search(r"TNS\(ns\).*?\n[-\s]+\n\s*\S+\s+(-?\d+\.\d+)", text, re.S)
    if m:
        try:
            out["tns_ns"] = float(m.group(1))
        except ValueError:
            pass
    # Constraint period: pulled from the Clock Summary line.  The format
    # is e.g.:  "clk    {0.000 5.000}      10.000          100.000"
    # so we match the clock line by name and read the third field.
    m = re.search(
        r"^\s*clk\s+\{[^}]*\}\s+([\d.]+)\s+([\d.]+)\s*$",
        text,
        re.M,
    )
    if m:
        try:
            out["period_ns"] = float(m.group(1))
        except ValueError:
            pass
    if out["period_ns"] and out["wns_ns"] is not None:
        achieved_period = out["period_ns"] - out["wns_ns"]
        if achieved_period > 0:
            out["fmax_mhz"] = round(1000.0 / achieved_period, 2)
    return out


def parse_power(path: Path) -> dict:
    out = {"total_w": None, "dynamic_w": None, "static_w": None}
    if not path.exists():
        return out
    text = path.read_text(errors="ignore")
    for key, pat in [
        ("total_w",   r"Total On-Chip Power \(W\)\s*\|\s*([\d.]+)"),
        ("dynamic_w", r"Dynamic \(W\)\s*\|\s*([\d.]+)"),
        ("static_w",  r"Device Static \(W\)\s*\|\s*([\d.]+)"),
    ]:
        m = re.search(pat, text)
        if m:
            try:
                out[key] = float(m.group(1))
            except ValueError:
                pass
    return out


def collect_one(synth_dir: Path, cfg: str) -> dict:
    cdir = synth_dir / cfg
    return {
        "config":      cfg,
        "utilization": parse_utilization(cdir / "utilization.txt"),
        "timing":      parse_timing(cdir / "timing_summary.txt"),
        "power":       parse_power(cdir / "power.txt"),
    }


def fmt(x, suffix=""):
    if x is None:
        return "-"
    if isinstance(x, float):
        return f"{x:.3f}{suffix}"
    return f"{x:,}{suffix}"


def detect_part(synth_dir: Path) -> str:
    for cfg in CONFIGS:
        p = synth_dir / cfg / "utilization.txt"
        if p.exists():
            for line in p.read_text(errors="ignore").splitlines()[:20]:
                if "Device" in line and ":" in line:
                    return line.split(":", 1)[1].strip(" |")
    return "(unknown part)"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, help="Target CPU_Lab2-style repository")
    parser.add_argument("--synth-dir", type=Path, help="Synthesis report directory; defaults to <repo>/results/synth")
    args = parser.parse_args()
    repo = find_repo(args.repo)
    synth_dir = args.synth_dir or (repo / "results" / "synth")

    rows = [collect_one(synth_dir, c) for c in CONFIGS]

    part = detect_part(synth_dir)
    print(f"# Synthesis PPA summary ({part}, 100 MHz target)")
    print()
    print("| Config | LUT | FF | BRAM (Tile) | DSP | WNS (ns) | Fmax (MHz) | Total Power (W) |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for r in rows:
        u = r["utilization"]; t = r["timing"]; p = r["power"]
        print(
            f"| {r['config']} "
            f"| {fmt(u['luts'])} "
            f"| {fmt(u['ffs'])} "
            f"| {fmt(u['bram_tile'])} "
            f"| {fmt(u['dsp'])} "
            f"| {fmt(t['wns_ns'])} "
            f"| {fmt(t['fmax_mhz'])} "
            f"| {fmt(p['total_w'])} |"
        )

    out_json = synth_dir / "ppa_summary.json"
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(rows, indent=2))
    try:
        display = out_json.relative_to(repo)
    except ValueError:
        display = out_json
    print(f"\nSaved JSON summary to: {display}")


if __name__ == "__main__":
    main()
