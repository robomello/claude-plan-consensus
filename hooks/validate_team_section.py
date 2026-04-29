#!/usr/bin/env python3
"""
PostToolUse hook for ExitPlanMode.
Checks that the most recent plan contains a ## Team Structure section
and warns about stale model references. Fail-open: warns but does not block.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    try:
        json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        return 0  # fail-open

    plans_dir = Path.home() / ".claude" / "plans"
    if not plans_dir.exists():
        return 0

    plan_files = sorted(
        plans_dir.glob("*.md"), key=lambda f: f.stat().st_mtime, reverse=True
    )
    if not plan_files:
        return 0

    latest_plan = plan_files[0]

    try:
        content = latest_plan.read_text(encoding="utf-8")
    except Exception:
        return 0  # fail-open

    if "## Team Structure" not in content:
        print(f"WARNING: Plan '{latest_plan.name}' is missing '## Team Structure' section.")
        print("Every non-trivial plan must end with a Team Structure section.")

    # Check for stale model references in Team Structure section
    CURRENT_SONNET = "claude-sonnet-4-6"
    STALE_MODELS = ["claude-sonnet-4-5", "claude-sonnet-4-4", "claude-sonnet-3-5"]

    team_idx = content.find("## Team Structure")
    if team_idx != -1:
        team_section = content[team_idx:]
        for stale in STALE_MODELS:
            if stale in team_section:
                print(f"WARNING: Plan '{latest_plan.name}' references stale model '{stale}' in Team Structure.")
                print(f"Current model should be: {CURRENT_SONNET}")

        if CURRENT_SONNET not in team_section:
            print(f"WARNING: Plan '{latest_plan.name}' does not reference '{CURRENT_SONNET}' in Team Structure.")
            print("Every teammate should use claude-sonnet-4-6 in the Model column.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
