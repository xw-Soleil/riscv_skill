// Auto-generated cache configuration — see scripts/generate_cache_rtl.py.
// Re-run that script to update; do not edit by hand.
//
// Use this file by adding `\`include "cache_config_generated.vh"\`
// at the top of `tb/tb_cache_soc.v` (or any other consumer) and
// passing `+incdir+rtl` to xvlog.

`ifndef CACHE_CONFIG_GENERATED_VH
`define CACHE_CONFIG_GENERATED_VH

// ---------------------------- L1 ----------------------------
`define CFG_ICACHE_BYTES   8192
`define CFG_DCACHE_BYTES   8192
`define CFG_BLOCK_BYTES    32
`define CFG_ICACHE_WAYS    2
`define CFG_DCACHE_WAYS    2

// ---------------------------- L2 ----------------------------
`define CFG_ENABLE_L2      1
`define CFG_L2_BYTES       65536
`define CFG_L2_WAYS        4
`define CFG_L2_BLOCK_BYTES 64
`define CFG_L2_LATENCY     10

// Replacement policy is currently fixed in RTL (tree-pseudo-LRU); see
// rtl/l1_icache.v, rtl/l1_dcache.v, rtl/l2_cache.v for the
// `plru_victim`/`plru_update` functions if a different policy is
// requested.  This header just records the chosen value as a comment
// for downstream tooling.
// replacement_policy = "tree-pseudo-LRU"

`endif // CACHE_CONFIG_GENERATED_VH
