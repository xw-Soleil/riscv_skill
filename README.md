# cache-lab-automation Skill

这是一个面向 CPU Lab 2 缓存实验的可打包 Agent Skill。它不是单纯的脚本目录，而是给 Codex/Claude Code 这类代码智能体使用的一套工作单元：`SKILL.md` 提供触发条件、实验流程和操作护栏，`assets/` 提供可复制的 starter 工程资源，`scripts/` 提供需要确定性执行的自动化工具。

## 这个 Skill 解决什么问题

当使用者只有一个空文件夹时，agent 可以用本 Skill 初始化出一个 CPU_Lab2-style 工程，包含：

- `rtl/`：缓存 CPU、L1 I/D Cache、L2 Cache、主存、仲裁器和性能计数器 starter RTL。
- `tb/`：统一 XSim testbench。
- `programs/`：基础程序、数组局部性程序、矩阵乘法程序及对应 `.dmem` / `.expect`。
- `scripts/`：工程入口脚本，用于汇编、仿真、参数扫描、结果整理、波形渲染和综合。

当使用者已经有同结构工程时，agent 也可以把本 Skill 当作外部自动化包，通过 `--repo` 或 `CACHE_LAB_REPO` 指向目标工程，不需要把 Skill 和工程强行放在同一个仓库里。

## 包结构

```text
cache-lab-automation/
├── SKILL.md                  # agent 读取的触发条件、工作流和护栏
├── README.md                 # 给人看的 Skill 使用说明
├── assets/
│   └── starter-project/      # 空目录初始化用的 rtl/tb/programs
└── scripts/                  # agent 调用的确定性执行工具
```

`assets/starter-project/` 是这个 Skill 能“放在空文件夹就开始做”的关键；它不是运行产物，而是 Skill 自带的 starter 资源。

## Agent 应该怎样使用它

当用户说“从零开始做 CPU Lab 2 缓存实验”“帮我生成可跑的缓存实验工程”“用这个 skill 复现/扫描缓存实验”时，agent 应先读取 `SKILL.md`，然后按工作区状态选择路径：

1. 空目录或缺少 `rtl/ tb/ programs/`：先调用初始化入口，把 starter 工程复制到当前目录。
2. 已有 CPU_Lab2-style 工程：直接把该工程作为 target repository 操作。
3. 需要批量实验或参数探索：先保证 baseline 可跑，再进行 L1/L2 或 sweep。
4. 需要定位失败：优先看仿真结果、`cpu_ready` / `mem_ready` 握手、cache state、stall/flush 信号，不要盲目提高 `MAX_CYCLES`。

最小空目录启动只需要：

```bash
python3 cache-lab-automation/scripts/init_project.py .
bash scripts/run_sim.sh program_A_fib l1
```


如果你已经 `cd` 进这个 Skill 仓库根目录，也可以直接运行：

```bash
python3 scripts/init_project.py .
```

如果 Skill 放在 `skills/cache-lab-automation/`，初始化入口相应改为：

```bash
python3 skills/cache-lab-automation/scripts/init_project.py .
```

后续实验由 agent 根据用户目标选择合适脚本；README 不重复展开每个脚本的完整参数，具体流程以 `SKILL.md` 为准。

## 适合交给 agent 的请求示例

- “使用这个 skill 在当前空目录初始化 CPU Lab2 缓存工程，并跑一个最小 L1 仿真检查。”
- “用 cache-lab-automation 对已有工程跑 baseline 和 sweep，整理 CSV/图表结果。”
- “program_A_fib 的 L2 仿真失败了，按 skill 的 guardrails 帮我定位是握手、状态机还是 expect 问题。”
- “把 L1 容量、块大小和相联度做参数探索，并总结哪个配置对矩阵程序更有利。”

这些请求的重点是让 agent 负责任务编排和判断，而不是让使用者手动记住所有命令。

## 设计边界

- 本 Skill 自带 starter RTL/testbench/programs，但 Vivado/XSim、Python 运行环境仍由本机提供。
- `init_project.py` 默认不覆盖已有文件；需要强制刷新 starter 时才使用 `--force`。
- 矩阵程序默认不要打开 VCD，波形文件会非常大。
- 计算 speedup 前先跑无缓存 baseline，避免 L1/L2 结果缺少参考周期数。
- 如果目标课程要求、目录命名或 testbench 接口不同，agent 应把本 Skill 当作 starter 和自动化参考，而不是不可修改的黑盒。

## 复用说明

这个仓库本身可以只包含 Skill 包。别人 clone 后即使仓库根目录没有 `rtl/`、`tb/`、`programs/`，也不代表不能复现；这些 starter 文件位于 `assets/starter-project/`，需要由 agent 或使用者先运行初始化入口复制出来。初始化完成后，当前工作目录才成为真正的 CPU_Lab2 工程目录。
