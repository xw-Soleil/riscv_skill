---
name: cache-lab-automation
description: Automate CPU Lab 2 cache experiments for a CPU_Lab2-style repository: parameterized cache RTL config generation, matrix test-program generation, Vivado XSim runs, JSON/CSV/SVG result extraction, parameter sweeps, waveform rendering, and Vivado PPA synthesis.
---

# Cache Lab Automation

Use this skill for the CPU Lab 2 cached RISC-V processor experiment. The skill package is self-contained at `skills/cache-lab-automation/`: `SKILL.md` is the workflow/prompt template, and `scripts/` contains the executable Python/Bash/PowerShell/Tcl scripts.

The scripts operate on a target CPU_Lab2-style repository, not on the skill folder itself. A target repository must contain at least `rtl/`, `tb/`, and `programs/`. Pass it explicitly with `--repo /path/to/CPU_Lab2`, set `CACHE_LAB_REPO=/path/to/CPU_Lab2`, or run the scripts from inside the target repository so they can find it by walking parent directories.

## Capabilities

1. Parameterized cache RTL/config generation: `scripts/generate_cache_rtl.py`
2. Matrix test-program generation: `scripts/generate_matmul.py`
3. Simulation automation and data extraction: `scripts/run_sim.sh`, `scripts/run_sim.ps1`, `scripts/run_experiments.py`
4. Parameter exploration workflow: `scripts/run_experiments.py --mode sweep`, then `scripts/make_charts.py`
5. Optional waveform rendering and synthesis PPA extraction: `scripts/render_waveform.py`, `scripts/run_vivado_synth.tcl`, `scripts/extract_synth_ppa.py`

## Quick Start

From anywhere:

```sh
export CACHE_LAB_REPO=/path/to/CPU_Lab2
python3 /path/to/cache-lab-automation/scripts/generate_cache_rtl.py --enable-l2
python3 /path/to/cache-lab-automation/scripts/generate_matmul.py --n 32 --block 8 --seed 20260514
bash /path/to/cache-lab-automation/scripts/run_sim.sh program_A_fib l2
python3 /path/to/cache-lab-automation/scripts/run_experiments.py --mode baseline --out results/baseline_results
python3 /path/to/cache-lab-automation/scripts/run_experiments.py --mode sweep --out results/sweep_results
python3 /path/to/cache-lab-automation/scripts/make_charts.py
```

Equivalent explicit form:

```sh
python3 /path/to/cache-lab-automation/scripts/run_experiments.py \
    --repo /path/to/CPU_Lab2 \
    --mode sweep \
    --out results/sweep_results
```

Vivado synthesis:

```sh
vivado -mode batch -nojournal -nolog \
    -source /path/to/cache-lab-automation/scripts/run_vivado_synth.tcl \
    -tclargs --repo /path/to/CPU_Lab2
python3 /path/to/cache-lab-automation/scripts/extract_synth_ppa.py --repo /path/to/CPU_Lab2
```

## Outputs

- `rtl/cache_config_generated.vh`: generated `CFG_*` cache configuration header
- `programs/matmul.dmem`, `programs/matmul.expect`, `programs/matmul_mm{a,b,c}.S`: generated matrix workload files
- `build/sim/<config>/<program>/results.json`: one structured result per simulation
- `results/baseline_results.{json,csv}` and `results/sweep_results.{json,csv}`: aggregated experiment tables
- `results/*.svg`: report charts generated from CSV files
- `results/synth/<config>/`: Vivado utilization/timing/power reports

## Guardrails

- Do not enable VCD by default for matrix programs; traces are too large.
- Run no-cache baselines before L1/L2 when computing speedup so `BASELINE_CYCLES` is available.
- If a simulation hangs, inspect `cpu_ready`/`mem_ready` handshakes before increasing `MAX_CYCLES`.
- The bundled scripts are portable, but the target repository must keep the expected lab structure and RTL/testbench filenames.
