---
name: cache-lab-automation
description: Bootstrap and automate CPU Lab 2 cache experiments. Use when Codex needs to start from an empty folder by creating a CPU_Lab2-style RTL/testbench/program starter project, or operate on an existing CPU_Lab2-style repository for cache configuration generation, matrix workload generation, Vivado XSim runs, result extraction, parameter sweeps, waveform rendering, or Vivado PPA synthesis.
---

# Cache Lab Automation

Use this skill as an agent workflow for the CPU Lab 2 cached RISC-V processor experiment. The package is self-contained: `assets/starter-project/` contains starter `rtl/`, `tb/`, and `programs/`; `scripts/` contains deterministic execution tools; this `SKILL.md` defines when and how to orchestrate them.

## First Decision

Before running experiments, classify the workspace:

1. **Empty or incomplete folder**: if the target lacks `rtl/`, `tb/`, or `programs/`, initialize it with `scripts/init_project.py` from the Skill package. This copies starter RTL/testbench/programs and project scripts into the target folder without overwriting existing files unless `--force` is explicitly requested.
2. **Existing CPU_Lab2-style repository**: if `rtl/`, `tb/`, and `programs/` already exist, operate on that repository directly. Pass it with `--repo`, set `CACHE_LAB_REPO`, or run from inside the repository.
3. **Ambiguous workspace**: inspect the directory tree first. Do not assume the Skill package directory itself is already the target project unless it has been initialized.

Minimal empty-folder bootstrap:

```sh
python3 cache-lab-automation/scripts/init_project.py .
bash scripts/run_sim.sh program_A_fib l1
```

If already inside the Skill package root, use `python3 scripts/init_project.py .`.

## Agent Workflow

1. **Initialize or locate the target project**. Ensure the target has `rtl/`, `tb/`, `programs/`, and runnable project `scripts/`.
2. **Establish a known-good run**. Prefer `program_A_fib` with `l1` for a quick functional check before broad sweeps.
3. **Generate or update workloads only when needed**. Use matrix generation when the user asks for matrix-size/block experiments or when expected files are missing.
4. **Run baseline before speedup comparisons**. No-cache results provide the reference cycles for L1/L2 speedup.
5. **Run parameter sweeps deliberately**. Sweep cache capacity, block size, associativity, or L2 settings according to the user's question; then aggregate results and charts.
6. **Diagnose failures before increasing limits**. Inspect `results.json`, xsim logs, cache state, `cpu_ready`/`mem_ready`, stall, and flush signals before changing `MAX_CYCLES`.
7. **Summarize in experiment terms**. Report pass/fail, cycles, hit rates, AMAT, speedup, and the cache behavior that explains the result.

## Bundled Tools

Use these tools through the workflow above, not as a flat command list:

- `scripts/init_project.py`: create a CPU_Lab2-style project from the bundled starter assets.
- `scripts/generate_cache_rtl.py`: generate `CFG_*` cache configuration headers for a target project.
- `scripts/generate_matmul.py`: generate matrix workloads and expected results.
- `scripts/run_sim.sh` / `scripts/run_sim.ps1`: run one Vivado XSim simulation.
- `scripts/run_experiments.py`: orchestrate baseline runs and parameter sweeps.
- `scripts/make_charts.py`: render charts from aggregated CSV results.
- `scripts/render_waveform.py`: render selected VCD windows for reports.
- `scripts/run_vivado_synth.tcl` and `scripts/extract_synth_ppa.py`: run Vivado synthesis and extract PPA summaries.

## Guardrails

- Do not enable VCD by default for matrix programs; traces are too large.
- Do not compute speedup without a no-cache baseline.
- Do not mask hangs by raising `MAX_CYCLES` before checking cache/main-memory handshakes.
- Do not overwrite user RTL/program changes during initialization unless the user explicitly asks for `--force`.
- Treat generated CSV/charts as outputs; if results look wrong, debug the simulation source rather than hand-editing tables.
- Vivado/XSim and optional Python plotting dependencies are external prerequisites, not bundled by the Skill.

## Expected Evidence

A successful use of the Skill should leave concrete artifacts in the target project: initialized source directories, `build/sim/<config>/<program>/results.json`, aggregated `results/*.csv`, optional charts, and optional synthesis reports. When asked to demonstrate reuse, show that a blank folder plus this Skill can initialize a project and run at least one passing simulation.
