#!/usr/bin/env python3
"""
UserPromptSubmit hook.
Detects user intent to update/save/finalize a plan and suggests delegating
to a background Haiku agent to keep the main Opus context clean.
"""

import json
import re
import sys

UPDATE_PATTERNS = [
    r"\bupdate\s+(the\s+)?plan\b",
    r"\bsave\s+(the\s+)?plan\b",
    r"\bmark\s+(the\s+)?plan\s+(as\s+)?(done|complete|finished)\b",
    r"\bplan\s+(is\s+)?(done|complete|finished)\b",
    r"\bclose\s+(the\s+)?plan\b",
    r"\bmark\s+task\s*\d+\s+(as\s+)?(done|complete)\b",
    r"\bplan\s+update\b",
    r"\bfinalize\s+(the\s+)?plan\b",
]

CREATION_PATTERNS = [
    r"\b(create|write|make|design|draft)\s+(a\s+|the\s+)?plan\b",
    r"\bplan\s+for\s+",
    r"\bnew\s+plan\b",
]

DELEGATION_MSG = """[PLAN-UPDATE HOOK] The user wants to update/save a plan file. To keep Opus context clean, delegate this to a background haiku agent:

Spawn a background agent with model="haiku" and this prompt:

You are a plan-update agent. Your job:

1. Find the active plan file:
   - Run: ls -lt ~/.claude/plans/*.md | head -5
   - The plan is the most recently modified file (by mtime)
   - If the user mentioned a specific plan name, use that instead

2. Understand what was completed:
   - Run: git log --oneline -20
   - Run: git diff --stat HEAD~5..HEAD
   - Read the plan file to see which tasks exist

3. Update the plan file:
   - Mark completed tasks with [x] based on git history
   - Add or update an '## Execution Status' section with current date
   - Add completion timestamps
   - Keep the plan structure intact — only update checkboxes and status

4. Update MEMORY.md if it exists:
   - Find it: ls ~/.claude/projects/*/memory/MEMORY.md 2>/dev/null | head -1
   - If the plan is listed under '## Plans', update its description/status
   - If the plan is NOT listed, add a one-line entry

5. Print a brief summary of what you changed.

IMPORTANT: If the user is asking you to CREATE, REDESIGN, or WRITE a new plan (not update/save an existing one), IGNORE this hook message and proceed normally with plan-agent."""


def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        return 0

    prompt = hook_input.get("prompt", "")
    if not prompt:
        return 0

    prompt_lower = prompt.lower().strip()

    for pattern in CREATION_PATTERNS:
        if re.search(pattern, prompt_lower):
            return 0

    for pattern in UPDATE_PATTERNS:
        if re.search(pattern, prompt_lower):
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": DELEGATION_MSG
                }
            }))
            return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
