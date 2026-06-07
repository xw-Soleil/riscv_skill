#!/usr/bin/env python3
"""Shared helpers for portable CPU Lab 2 automation scripts."""

from __future__ import annotations

import os
from pathlib import Path


def looks_like_repo(path: Path) -> bool:
    return all((path / name).exists() for name in ("rtl", "tb", "programs"))


def find_repo(repo_arg: str | Path | None = None) -> Path:
    """Return the target CPU_Lab2-style repository.

    Resolution order:
    1. explicit --repo argument
    2. CACHE_LAB_REPO environment variable
    3. current working directory or one of its parents
    """
    if repo_arg:
        repo = Path(repo_arg).expanduser().resolve()
    elif os.environ.get("CACHE_LAB_REPO"):
        repo = Path(os.environ["CACHE_LAB_REPO"]).expanduser().resolve()
    else:
        cur = Path.cwd().resolve()
        candidates = [cur, *cur.parents]
        repo = next((p for p in candidates if looks_like_repo(p)), None)
        if repo is None:
            raise SystemExit(
                "Cannot locate a CPU_Lab2-style repo. Run from the project "
                "root or pass --repo /path/to/CPU_Lab2."
            )
    if not looks_like_repo(repo):
        raise SystemExit(
            f"{repo} does not look like a CPU_Lab2 repo: expected rtl/, tb/, programs/."
        )
    return repo
