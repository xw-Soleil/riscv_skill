#!/usr/bin/env python3
"""Batch driver for portable CPU Lab 2 cache experiments."""
from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import shutil
import subprocess
from pathlib import Path

from cache_lab_common import find_repo


SCRIPT_DIR = Path(__file__).resolve().parent


BASE_PROGRAMS = [
    "program_A_fib",
    "program_B_calls",
    "program_C_vowels",
    "array_seq",
    "array_rand",
    "matmul_mma",
    "matmul_mmb",
    "matmul_mmc",
]


def pick_runner() -> list[str]:
    """Return argv prefix for the bundled single-run simulator."""
    if platform.system() == "Windows":
        ps = SCRIPT_DIR / "run_sim.ps1"
        for exe in ("pwsh", "powershell"):
            if shutil.which(exe):
                return [exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ps)]
        raise RuntimeError(
            "Neither pwsh nor powershell.exe is on PATH; install PowerShell 7 or use Windows PowerShell 5."
        )
    return ["bash", str(SCRIPT_DIR / "run_sim.sh")]


def run_one(repo: Path, runner: list[str], program, config, defines, skip_existing=False, baseline_cycles=None):
    result_path = repo / "build" / "sim" / config / program / "results.json"
    if skip_existing and result_path.exists():
        return load_result(repo, program, config, defines, result_path)

    cmd = [*runner, "--repo", str(repo), program, config, *defines]
    env = os.environ.copy()
    env["CACHE_LAB_REPO"] = str(repo)
    if baseline_cycles:
        env["BASELINE_CYCLES"] = str(baseline_cycles)
    subprocess.run(cmd, cwd=repo, check=True, env=env)
    return load_result(repo, program, config, defines, result_path)


def load_result(repo: Path, program, config, defines, path):
    data = json.loads(path.read_text(encoding="utf-8"))
    data["program"] = program
    data["run_tag"] = config
    data["defines"] = " ".join(defines)
    data["result_path"] = str(path.relative_to(repo))
    add_derived_metrics(data)
    return data


def add_derived_metrics(row):
    ih = int(row.get("icache_hits", 0))
    im = int(row.get("icache_misses", 0))
    dh = int(row.get("dcache_hits", 0))
    dm = int(row.get("dcache_misses", 0))
    l2h = int(row.get("l2_hits", 0))
    l2m = int(row.get("l2_misses", 0))
    row["icache_hit_rate"] = ih / (ih + im) if ih + im else ""
    row["dcache_hit_rate"] = dh / (dh + dm) if dh + dm else ""
    row["l2_hit_rate"] = l2h / (l2h + l2m) if l2h + l2m else ""


def run_baselines(repo: Path, runner: list[str], skip_existing):
    """Run no-cache first, then L1/L2 with matching baseline cycle counts."""
    rows = []
    nocache_cycles = {}
    for program in BASE_PROGRAMS:
        row = run_one(repo, runner, program, "nocache", [], skip_existing=skip_existing)
        nocache_cycles[program] = int(row["cycles"])
        rows.append(row)
    for cfg in ["l1", "l2"]:
        for program in BASE_PROGRAMS:
            rows.append(
                run_one(
                    repo,
                    runner,
                    program,
                    cfg,
                    [],
                    skip_existing=skip_existing,
                    baseline_cycles=nocache_cycles.get(program),
                )
            )
    return rows


def run_sweeps(repo: Path, runner: list[str], skip_existing):
    rows = []

    for size in [4096, 8192, 16384]:
        defs = [
            f"CFG_ICACHE_BYTES={size}",
            f"CFG_DCACHE_BYTES={size}",
            "CFG_BLOCK_BYTES=32",
            "CFG_ICACHE_WAYS=2",
            "CFG_DCACHE_WAYS=2",
        ]
        for program in ["matmul_mmc", "array_seq"]:
            rows.append(run_one(repo, runner, program, f"sweep_cap_{size//1024}k", defs, skip_existing))

    for block in [16, 32, 64]:
        defs = [
            "CFG_ICACHE_BYTES=8192",
            "CFG_DCACHE_BYTES=8192",
            f"CFG_BLOCK_BYTES={block}",
            "CFG_ICACHE_WAYS=2",
            "CFG_DCACHE_WAYS=2",
        ]
        for program in ["matmul_mmc", "array_seq"]:
            rows.append(run_one(repo, runner, program, f"sweep_blk_{block}", defs, skip_existing))

    for ways in [1, 2, 4]:
        defs = [
            "CFG_ICACHE_BYTES=8192",
            "CFG_DCACHE_BYTES=8192",
            "CFG_BLOCK_BYTES=32",
            f"CFG_ICACHE_WAYS={ways}",
            f"CFG_DCACHE_WAYS={ways}",
        ]
        for program in ["matmul_mmc", "array_seq"]:
            rows.append(run_one(repo, runner, program, f"sweep_way_{ways}", defs, skip_existing))

    for block in [16, 32, 64]:
        for ways in [1, 2, 4]:
            defs = [
                "CFG_ICACHE_BYTES=8192",
                "CFG_DCACHE_BYTES=8192",
                f"CFG_BLOCK_BYTES={block}",
                f"CFG_ICACHE_WAYS={ways}",
                f"CFG_DCACHE_WAYS={ways}",
            ]
            rows.append(run_one(repo, runner, "matmul_mmc", f"sweep_grid_b{block}_w{ways}", defs, skip_existing))

    return rows


def write_outputs(rows, out_prefix):
    out_prefix.parent.mkdir(parents=True, exist_ok=True)
    json_path = out_prefix.with_suffix(".json")
    csv_path = out_prefix.with_suffix(".csv")

    json_path.write_text(json.dumps(rows, indent=2), encoding="utf-8")

    fields = [
        "program", "run_tag", "config", "defines", "cycles", "instr_retired",
        "cpi",
        "icache_hits", "icache_misses", "icache_hit_rate",
        "dcache_hits", "dcache_misses", "dcache_hit_rate",
        "dcache_writes_through",
        "l2_hits", "l2_misses", "l2_hit_rate",
        "imem_accesses", "dmem_accesses", "mem_accesses",
        "amat_d", "amat_i", "baseline_cycles", "speedup",
        "imem_stall_cycles", "dmem_stall_cycles",
        "load_use_stalls", "branch_flushes",
        "pass", "fail", "result_path",
    ]
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {json_path}")
    print(f"Wrote {csv_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, help="Target CPU_Lab2-style repository")
    parser.add_argument("--mode", choices=["baseline", "sweep", "all"], default="all")
    parser.add_argument("--skip-existing", action="store_true")
    parser.add_argument("--out", default="results/experiment_results")
    args = parser.parse_args()

    repo = find_repo(args.repo)
    runner = pick_runner()

    rows = []
    if args.mode in ("baseline", "all"):
        rows.extend(run_baselines(repo, runner, args.skip_existing))
    if args.mode in ("sweep", "all"):
        rows.extend(run_sweeps(repo, runner, args.skip_existing))

    out_prefix = Path(args.out)
    if not out_prefix.is_absolute():
        out_prefix = repo / out_prefix
    write_outputs(rows, out_prefix)


if __name__ == "__main__":
    main()
