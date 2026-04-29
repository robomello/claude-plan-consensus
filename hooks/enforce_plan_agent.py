#!/usr/bin/env python3
"""
PreToolUse hook for ExitPlanMode.
BLOCKS ExitPlanMode unless the plan file contains <!-- REVIEWED --> marker,
which proves plan-agent ran and the consensus review pipeline completed.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    try:
        hook_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, Exception):
        # Fail-open on parse errors (don't break the session)
        return 0

    tool_name = hook_input.get("tool_name", "")
    if tool_name != "ExitPlanMode":
        return 0

    # Find the most recent plan file
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

    if "<!-- REVIEWED -->" in content:
        result = {
            "hookSpecificOutput": {
                "permissionDecision": "allow"
            },
            "systemMessage": f"Plan '{latest_plan.name}' passed enforcement: plan-agent + consensus review confirmed."
        }
        print(json.dumps(result))
        return 0

    # No REVIEWED marker — BLOCK ExitPlanMode
    result = {
        "hookSpecificOutput": {
            "permissionDecision": "deny"
        },
        "systemMessage": (
            f"BLOCKED: Plan '{latest_plan.name}' is missing the '<!-- REVIEWED -->' marker. "
            "This means plan-agent was NOT used or the consensus review pipeline did not complete. "
            "You MUST use plan-agent (subagent_type='plan-agent') to write the plan. "
            "The plan-agent triggers the consensus review, which adds the REVIEWED marker. "
            "Do NOT write plans yourself — spawn plan-agent and let it handle the research, writing, and review cycle."
        )
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
