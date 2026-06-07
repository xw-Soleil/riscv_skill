#!/usr/bin/env python3
r"""Emit a parameterised cache configuration include for the SoC.

Generates ``rtl/cache_config_generated.vh``, a Verilog \`define-style
header that pins the L1 / L2 / block-size / way / replacement-policy
parameters used by ``riscv_cached_soc.v`` and ``tb_cache_soc.v``.

Usage::

    python3 scripts/generate_cache_rtl.py \
        --icache-bytes 8192 --dcache-bytes 8192 \
        --block-bytes 32 --icache-ways 2 --dcache-ways 2 \
        --enable-l2 --l2-bytes 65536 --l2-ways 4 --l2-block-bytes 64

The same parameters can also be passed to ``scripts/run_sim.sh`` as
``CFG_*`` defines, but this header lets the generated configuration be
checked into Vivado projects (for synthesis runs that don't pass
defines on the command line).

This implements the docx §6.1 "参数化缓存 RTL 生成" Skill capability
without committing to a Jinja2 dependency: the header is emitted purely
from string templates so it works in any Python environment.
"""
from __future__ import annotations

import argparse
import math
from pathlib import Path

from cache_lab_common import find_repo


HEADER = """// Auto-generated cache configuration — see scripts/generate_cache_rtl.py.
// Re-run that script to update; do not edit by hand.
//
// Use this file by adding `\\`include "cache_config_generated.vh"\\`
// at the top of `tb/tb_cache_soc.v` (or any other consumer) and
// passing `+incdir+rtl` to xvlog.

`ifndef CACHE_CONFIG_GENERATED_VH
`define CACHE_CONFIG_GENERATED_VH

// ---------------------------- L1 ----------------------------
`define CFG_ICACHE_BYTES   {icache_bytes}
`define CFG_DCACHE_BYTES   {dcache_bytes}
`define CFG_BLOCK_BYTES    {block_bytes}
`define CFG_ICACHE_WAYS    {icache_ways}
`define CFG_DCACHE_WAYS    {dcache_ways}

// ---------------------------- L2 ----------------------------
{l2_block}

// Replacement policy is currently fixed in RTL (tree-pseudo-LRU); see
// rtl/l1_icache.v, rtl/l1_dcache.v, rtl/l2_cache.v for the
// `plru_victim`/`plru_update` functions if a different policy is
// requested.  This header just records the chosen value as a comment
// for downstream tooling.
// replacement_policy = "{policy}"

`endif // CACHE_CONFIG_GENERATED_VH
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--icache-bytes", type=int, default=8192)
    parser.add_argument("--dcache-bytes", type=int, default=8192)
    parser.add_argument("--block-bytes", type=int, default=32)
    parser.add_argument("--icache-ways", type=int, default=2)
    parser.add_argument("--dcache-ways", type=int, default=2)
    parser.add_argument("--enable-l2", action="store_true")
    parser.add_argument("--l2-bytes", type=int, default=65536)
    parser.add_argument("--l2-ways", type=int, default=4)
    parser.add_argument("--l2-block-bytes", type=int, default=32,
                        help="L2 internal block size in bytes")
    parser.add_argument("--l2-hit-latency", type=int, default=10)
    parser.add_argument("--policy", default="tree-pseudo-LRU")
    parser.add_argument(
        "--repo", type=Path,
        help="Target CPU_Lab2-style repository. Defaults to CACHE_LAB_REPO or cwd parent search.",
    )
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    repo = find_repo(args.repo)
    out = args.out or (repo / "rtl" / "cache_config_generated.vh")

    # Sanity-check the depths: each is a power of two and the sizes are
    # compatible with the chosen block size / ways.
    for name, v in [
        ("icache-bytes", args.icache_bytes),
        ("dcache-bytes", args.dcache_bytes),
        ("block-bytes",  args.block_bytes),
        ("l2-block-bytes", args.l2_block_bytes),
    ]:
        if v & (v - 1):
            raise SystemExit(f"--{name}={v} must be a power of two")
        if v == 0:
            raise SystemExit(f"--{name} must be > 0")

    if args.icache_bytes % (args.block_bytes * args.icache_ways):
        raise SystemExit("L1 I-cache geometry is not aligned (bytes / (block*ways) must be integer)")
    if args.dcache_bytes % (args.block_bytes * args.dcache_ways):
        raise SystemExit("L1 D-cache geometry is not aligned")
    if args.enable_l2:
        if args.l2_bytes % (args.l2_block_bytes * args.l2_ways):
            raise SystemExit("L2 cache geometry is not aligned")
        l2_block = (
            f"`define CFG_ENABLE_L2      1\n"
            f"`define CFG_L2_BYTES       {args.l2_bytes}\n"
            f"`define CFG_L2_WAYS        {args.l2_ways}\n"
            f"`define CFG_L2_BLOCK_BYTES {args.l2_block_bytes}\n"
            f"`define CFG_L2_LATENCY     {args.l2_hit_latency}"
        )
    else:
        l2_block = "// L2 disabled — `define CFG_ENABLE_L2 not set."

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        HEADER.format(
            icache_bytes=args.icache_bytes,
            dcache_bytes=args.dcache_bytes,
            block_bytes=args.block_bytes,
            icache_ways=args.icache_ways,
            dcache_ways=args.dcache_ways,
            l2_block=l2_block,
            policy=args.policy,
        ),
        encoding="utf-8",
    )
    print(f"Wrote {out}")
    print(
        f"L1 I = {args.icache_bytes // 1024} KB / {args.icache_ways}-way, "
        f"L1 D = {args.dcache_bytes // 1024} KB / {args.dcache_ways}-way, "
        f"block = {args.block_bytes} B; "
        f"L2 = {'enabled' if args.enable_l2 else 'disabled'}"
    )


if __name__ == "__main__":
    main()
