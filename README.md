# cache-lab-automation

CPU Lab 2（带缓存系统的 RISC-V 处理器）实验自动化 Skill。

这个目录本身就是可打包的 Skill 包：

- `SKILL.md`：提示词模板 / 工作流说明。
- `scripts/`：实际可执行脚本，包含 Python、Bash、PowerShell、Tcl。

脚本不依赖本仓库的固定相对路径。给别人使用时，只需要把这个目录整体打包过去，然后通过 `--repo` 或环境变量 `CACHE_LAB_REPO` 指向一个同结构的 CPU_Lab2 工程目录。目标工程至少需要包含 `rtl/`、`tb/`、`programs/`。

## 自动化范围

| 功能 | Skill 内脚本 | 说明 |
|---|---|---|
| 参数化缓存配置生成 | `scripts/generate_cache_rtl.py` | 根据容量、块大小、相联度、L2 参数生成 `rtl/cache_config_generated.vh` |
| 测试程序自动生成 | `scripts/generate_matmul.py` | 生成 `matmul_mma/mmb/mmc.S`、`matmul.dmem`、`matmul.expect` |
| 单次仿真 | `scripts/run_sim.sh` / `scripts/run_sim.ps1` | 调用 Vivado XSim，生成 `build/sim/<config>/<program>/results.json` |
| 批量实验和参数扫描 | `scripts/run_experiments.py` | 跑 baseline / sweep，并聚合 JSON、CSV |
| 图表生成 | `scripts/make_charts.py` | 从 CSV 生成 SVG 图表 |
| 综合和 PPA 提取 | `scripts/run_vivado_synth.tcl`、`scripts/extract_synth_ppa.py` | 生成并解析 Vivado utilization / timing / power 报告 |
| 波形渲染（可选） | `scripts/render_waveform.py` | 从 VCD 渲染报告用波形图 |

## 使用方式

方式一：显式指定目标工程。

```bash
python3 cache-lab-automation/scripts/generate_cache_rtl.py \
    --repo /path/to/CPU_Lab2 \
    --enable-l2 --l2-bytes 65536 --l2-ways 4 --l2-block-bytes 64

python3 cache-lab-automation/scripts/generate_matmul.py \
    --repo /path/to/CPU_Lab2 \
    --n 32 --block 8 --seed 20260514

bash cache-lab-automation/scripts/run_sim.sh \
    --repo /path/to/CPU_Lab2 \
    program_A_fib l2
```

方式二：设置环境变量后直接运行。

```bash
export CACHE_LAB_REPO=/path/to/CPU_Lab2
python3 cache-lab-automation/scripts/run_experiments.py --mode baseline --out results/baseline_results
python3 cache-lab-automation/scripts/run_experiments.py --mode sweep --out results/sweep_results
python3 cache-lab-automation/scripts/make_charts.py
```

Vivado 综合：

```bash
vivado -mode batch -nojournal -nolog \
    -source cache-lab-automation/scripts/run_vivado_synth.tcl \
    -tclargs --repo /path/to/CPU_Lab2

python3 cache-lab-automation/scripts/extract_synth_ppa.py --repo /path/to/CPU_Lab2
```

## 可移植性说明

- Skill 脚本默认从当前工作目录向上寻找 `rtl/`、`tb/`、`programs/`，找不到时才要求传 `--repo`。
- `run_sim.sh` 使用 Skill 自带的 `assemble.py`，因此目标工程不强制要求有自己的 `scripts/assemble.py`。
- Vivado、Python 运行环境，以及波形渲染所需的 `matplotlib` / `vcdvcd` 等依赖仍需由使用者本机提供。
- 根目录 `scripts/` 是本仓库自己的工程入口；`skills/cache-lab-automation/scripts/` 是可打包 Skill 的执行入口。
