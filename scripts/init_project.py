#!/usr/bin/env python3
"""Initialize a CPU_Lab2-style repository from this Skill package."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


SKIP_DIRS = {"__pycache__", ".git"}


def copy_tree(src: Path, dst: Path, *, force: bool, dry_run: bool) -> tuple[int, int]:
    copied = 0
    kept = 0
    for path in sorted(src.rglob("*")):
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        rel = path.relative_to(src)
        out = dst / rel
        if path.is_dir():
            if not dry_run:
                out.mkdir(parents=True, exist_ok=True)
            continue
        if out.exists() and not force:
            kept += 1
            continue
        copied += 1
        if not dry_run:
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, out)
    return copied, kept


def write_text_if_missing(path: Path, text: str, *, force: bool, dry_run: bool) -> str:
    existed = path.exists()
    if existed and not force:
        return "kept"
    if not dry_run:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return "overwritten" if existed else "created"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a CPU_Lab2-style project in an empty directory using the bundled starter files."
    )
    parser.add_argument(
        "target",
        nargs="?",
        default=".",
        help="Target project directory. Defaults to the current directory.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing files in the target project.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be initialized without writing files.",
    )
    args = parser.parse_args()

    skill_root = Path(__file__).resolve().parents[1]
    starter = skill_root / "assets" / "starter-project"
    target = Path(args.target).resolve()

    if not starter.is_dir():
        raise SystemExit(f"missing starter assets: {starter}")

    if not args.dry_run:
        target.mkdir(parents=True, exist_ok=True)

    print(f"Skill package : {skill_root}")
    print(f"Target project: {target}")

    total_copied = 0
    total_kept = 0
    for dirname in ("rtl", "tb", "programs"):
        copied, kept = copy_tree(starter / dirname, target / dirname, force=args.force, dry_run=args.dry_run)
        total_copied += copied
        total_kept += kept
        print(f"{dirname}/: copied {copied}, kept {kept}")

    copied, kept = copy_tree(skill_root / "scripts", target / "scripts", force=args.force, dry_run=args.dry_run)
    total_copied += copied
    total_kept += kept
    print(f"scripts/: copied {copied}, kept {kept}")

    gitignore = """build/
results/*.json
results/*.csv
results/*.svg
results/*.png
*.jou
*.log
*.wdb
*.vcd
*.pb
__pycache__/
"""
    status = write_text_if_missing(target / ".gitignore", gitignore, force=args.force, dry_run=args.dry_run)
    print(f".gitignore: {status}")

    readme = """# CPU_Lab2 Starter Project

This project was initialized from the `cache-lab-automation` Skill.

Quick check:

```sh
bash scripts/run_sim.sh program_A_fib l1
python3 scripts/run_experiments.py --mode baseline --out results/baseline_results
```

Vivado 2022.2 must be available in the shell before running XSim or synthesis.
"""
    status = write_text_if_missing(target / "README.md", readme, force=args.force, dry_run=args.dry_run)
    print(f"README.md: {status}")

    print(f"Done: copied {total_copied} files, kept {total_kept} existing files.")
    print("Next: cd into the target project and run `bash scripts/run_sim.sh program_A_fib l1`.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
