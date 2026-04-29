#!/bin/bash
# PreToolUse hook for EnterPlanMode AND Write|Edit of plan files.
# Outputs a strong reminder to use plan-agent instead of built-in plan mode.
#
# Triggers:
#   - EnterPlanMode: always warns
#   - Write|Edit: only warns if the target file is a plan file (/plans/ or PLAN.md)
#
# Cannot hard-block because plan-agent itself calls Write/Edit and there's no
# env var to distinguish main session from subagent. Outputs a loud warning instead.

INPUT_JSON=$(cat)

TOOL_NAME=$(echo "$INPUT_JSON" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(echo "$INPUT_JSON" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# For Write|Edit: only warn on plan files
if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
    BASENAME=$(basename "$FILE_PATH" 2>/dev/null)
    if [[ "$FILE_PATH" != *"/plans/"* ]] && [[ "$BASENAME" != "PLAN.md" ]]; then
        exit 0
    fi
fi

echo ""
echo "======================================================"
echo "MANDATORY: Planning goes through plan-agent, not built-in plan mode."
echo ""
echo "If you are the MAIN SESSION (not already inside plan-agent):"
echo "  1. Do NOT proceed with built-in Phase 1-5 plan workflow"
echo "  2. Instead launch: Agent(subagent_type='plan-agent', prompt='<task>')"
echo "  3. Or use the /plan skill"
echo ""
echo "The plan-agent triggers the consensus review pipeline"
echo "(Haiku 4.5 + 3 local Ollama models) that built-in plan mode does NOT."
echo ""
echo "If you ARE the plan-agent subagent, ignore this message and proceed."
echo "======================================================"
