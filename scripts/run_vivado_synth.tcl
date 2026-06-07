# Portable Vivado out-of-context synthesis for a CPU_Lab2-style repository.
# Usage:
#   vivado -mode batch -source run_vivado_synth.tcl -tclargs --repo /path/to/CPU_Lab2

proc looks_like_repo {d} {
    expr {[file isdirectory [file join $d rtl]] &&
          [file isdirectory [file join $d tb]] &&
          [file isdirectory [file join $d programs]]}
}

proc find_repo {} {
    global argv env
    set repo ""
    for {set i 0} {$i < [llength $argv]} {incr i} {
        if {[lindex $argv $i] eq "--repo" && [expr {$i + 1}] < [llength $argv]} {
            set repo [lindex $argv [expr {$i + 1}]]
        }
    }
    if {$repo eq "" && [info exists env(CACHE_LAB_REPO)]} {
        set repo $env(CACHE_LAB_REPO)
    }
    if {$repo ne ""} {
        set repo [file normalize $repo]
        if {![looks_like_repo $repo]} {
            error "$repo does not look like a CPU_Lab2 repo: expected rtl/, tb/, programs/."
        }
        return $repo
    }
    set d [file normalize [pwd]]
    while {1} {
        if {[looks_like_repo $d]} { return $d }
        set parent [file dirname $d]
        if {$parent eq $d} { break }
        set d $parent
    }
    error "Cannot locate CPU_Lab2-style repo. Run from the project root or pass -tclargs --repo /path/to/CPU_Lab2."
}

set root    [find_repo]
set out_top [file join $root results synth]
file mkdir $out_top

set part xc7a200tfbg484-1
set clk_period 10.0

set rtl_files [list \
    [file join $root rtl alu.v] \
    [file join $root rtl regfile.v] \
    [file join $root rtl control_unit.v] \
    [file join $root rtl forward_unit.v] \
    [file join $root rtl hazard_unit.v] \
    [file join $root rtl riscv_core.v] \
    [file join $root rtl perf_counters.v] \
    [file join $root rtl l1_icache.v] \
    [file join $root rtl l1_dcache.v] \
    [file join $root rtl l2_cache.v] \
    [file join $root rtl mem_arbiter.v] \
    [file join $root rtl riscv_cached_soc_synth.v] \
]

proc run_one {root rtl_files part clk_period out_top label enable_l2 \
              icache_kb dcache_kb l2_kb l2_ways l2_block_bytes} {
    puts "================================================================"
    puts "Synthesising config '$label' (ENABLE_L2 = $enable_l2)"
    puts "  L1 I/D = $icache_kb KB / $dcache_kb KB / 32 B / 2-way"
    puts "  L2     = $l2_kb KB / $l2_block_bytes B / $l2_ways-way"
    puts "================================================================"

    set out_dir [file join $out_top $label]
    file mkdir $out_dir

    create_project -in_memory -force -part $part
    foreach f $rtl_files { read_verilog $f }

    set generics [list \
        "ENABLE_L2=$enable_l2" \
        "ICACHE_SIZE_BYTES=[expr {$icache_kb * 1024}]" \
        "DCACHE_SIZE_BYTES=[expr {$dcache_kb * 1024}]" \
        "L2_SIZE_BYTES=[expr {$l2_kb * 1024}]" \
        "L2_WAYS=$l2_ways" \
        "L2_BLOCK_BYTES=$l2_block_bytes" \
    ]

    synth_design -top riscv_cached_soc_synth \
                 -part $part \
                 -mode out_of_context \
                 -generic $generics \
                 -flatten_hierarchy rebuilt

    set clk_obj [get_ports clk]
    create_clock -period $clk_period -name clk $clk_obj

    opt_design
    place_design
    route_design

    report_utilization        -file [file join $out_dir utilization.txt]
    report_utilization -hierarchical \
                              -file [file join $out_dir utilization_hier.txt]
    report_timing_summary     -file [file join $out_dir timing_summary.txt]
    report_timing -delay_type max -max_paths 5 \
                              -file [file join $out_dir timing_top_paths.txt]
    report_clock_utilization  -file [file join $out_dir clock_utilization.txt] -quiet
    report_power              -file [file join $out_dir power.txt]
    report_drc                -file [file join $out_dir drc.txt] -quiet

    write_checkpoint -force [file join $out_dir riscv_cached_soc.dcp]
    close_project
}

run_one $root $rtl_files $part $clk_period $out_top "l1_only" 0  8 8 64 4 64
run_one $root $rtl_files $part $clk_period $out_top "l1_l2"   1  8 8 64 4 64

puts ""
puts "All requested synthesis runs finished. Reports in: $out_top"
