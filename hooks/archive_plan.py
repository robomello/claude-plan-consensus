#!/usr/bin/env python3
"""
PostToolUse hook for ExitPlanMode.
Saves approved plans to ~/.claude/plans/archive/YYYY-MM-DD/HHMMSS-session-{id}.md
"""

import json
import re
import sys
from datetime import datetime
from pathlib import Path


def sanitize(s: str) -> str:
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", s)
    return s.strip("._-")[:32] or "unknown"


def main() -> int:
    try:
        hook_input = json.loads(sys.stdin.read())
    except json.JSONDecodeError as e:
        print(f"archive_plan.py: invalid JSON: {e}", file=sys.stderr)
        return 1

    session_id = hook_input.get("session_id", "unknown")

    plans_dir = Path.home() / ".claude" / "plans"
    if not plans_dir.exists():
        print("archive_plan.py: No plans directory found", file=sys.stderr)
        return 0

    plan_files = sorted(
        plans_dir.glob("*.md"), key=lambda f: f.stat().st_mtime, reverse=True
    )
    if not plan_files:
        print("archive_plan.py: No plan files found to archive", file=sys.stderr)
        return 0

    plan_file = plan_files[0]

    try:
        plan_content = plan_file.read_text(encoding="utf-8")
    except Exception as e:
        print(f"archive_plan.py: Failed to read plan: {e}", file=sys.stderr)
        return 1

    now = datetime.now()
    date_dir = now.strftime("%Y-%m-%d")
    time_prefix = now.strftime("%H%M%S")

    archive_dir = plans_dir / "archive" / date_dir
    archive_dir.mkdir(parents=True, exist_ok=True)

    safe_session = sanitize(session_id)
    archive_filename = f"{time_prefix}-session-{safe_session}.md"
    archive_path = archive_dir / archive_filename

    try:
        archive_path.write_text(plan_content, encoding="utf-8")
        print(f"archive_plan.py: Archived plan to {archive_path}")
    except Exception as e:
        print(f"archive_plan.py: Failed to write archive: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
