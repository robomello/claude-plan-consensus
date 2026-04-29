#!/bin/bash
# Multi-LLM Consensus Plan Review Pipeline (4-phase) — Local Edition
# Phase 0: Haiku 4.5 grounding pass (verify plan claims vs actual codebase)
# Phase 1: Haiku 4.5 + Sonnet 4.6 (bg, parallel) + 3 local Ollama (sequential) = 5 reviewers
# Phase 2: 5-way consensus vote (same models)
# Phase 3: Opus reads Phase 2 consensus → final synthesis → plan-agent
# Output: Opus synthesis + Phase 2 details for plan-agent to consume
#
# Triggered: PostToolUse on Write of plan files, or ExitPlanMode
#
# Requirements:
#   - claude CLI (Haiku, Sonnet, Opus access)
#   - ollama running at $OLLAMA_BASE_URL (default: http://localhost:11434)
#   - jq, curl
#
# Configuration:
#   OLLAMA_BASE_URL   Ollama endpoint (default: http://localhost:11434)
#   OLLAMA_MODEL_A/B/C  Override local model IDs via env (optional)

set -euo pipefail

# --- Unset nested Claude env vars ---
unset CLAUDECODE CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true

# --- Config ---
REVIEWS_DIR="$HOME/.claude/reviews"
OLLAMA_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
HAIKU_TIMEOUT=180
SONNET_TIMEOUT=300
OPUS_TIMEOUT=300
OLLAMA_TIMEOUT=600
MIN_REVIEW_BYTES=200
MIN_VALID_REVIEWS=2

# Local models (run sequentially — single GPU, no VRAM contention)
# Override via environment variables
OLLAMA_MODEL_A="${OLLAMA_MODEL_A:-qwen3-coder-next:q4_K_M}"
OLLAMA_MODEL_B="${OLLAMA_MODEL_B:-glm-4.7-flash:bf16}"
OLLAMA_MODEL_C="${OLLAMA_MODEL_C:-qwen3.6:35b-iq4xs}"

declare -A OLLAMA_MODELS=(
    ["model-a"]="$OLLAMA_MODEL_A"
    ["model-b"]="$OLLAMA_MODEL_B"
    ["model-c"]="$OLLAMA_MODEL_C"
)
OLLAMA_MODEL_ORDER=("model-a" "model-b" "model-c")

# --- Read PostToolUse stdin JSON ---
INPUT_JSON=$(cat)

# ExitPlanMode provides filePath in tool_response; Write/Edit provides in tool_input
FILE_PATH=$(echo "$INPUT_JSON" | jq -r '.tool_response.filePath // .tool_input.file_path // empty')

# Only fire for plan files (plan-mode named files in plans/ dirs, or legacy PLAN.md)
BASENAME=$(basename "$FILE_PATH" 2>/dev/null)
if [[ "$FILE_PATH" != *"/plans/"*".md" ]] && [[ "$BASENAME" != "PLAN.md" ]]; then
    exit 0
fi

if [[ ! -f "$FILE_PATH" ]]; then
    echo "WARNING: Plan file not found at $FILE_PATH, skipping review"
    exit 0
fi

# Skip if already reviewed (prevents infinite loop on re-write)
if head -1 "$FILE_PATH" | grep -q '<!-- REVIEWED -->'; then
    exit 0
fi

PLAN_CONTENT=$(cat "$FILE_PATH")
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
mkdir -p "$REVIEWS_DIR"

echo ""
echo "======================================================"
echo "PLAN REVIEW PIPELINE: $(basename "$(dirname "$FILE_PATH")")/$(basename "$FILE_PATH")"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================================"

# --- Temp files ---
GROUNDING_OUT=$(mktemp)
HAIKU_REVIEW_OUT=$(mktemp)
SONNET_REVIEW_OUT=$(mktemp)
COMBINED_REVIEWS=$(mktemp)
HAIKU_CONS_OUT=$(mktemp)
SONNET_CONS_OUT=$(mktemp)
PHASE2_DOC=$(mktemp)
OPUS_FINAL_OUT=$(mktemp)
FINAL_DOC=$(mktemp)

# Ollama temp files
declare -A OLLAMA_OUTS
for key in "${OLLAMA_MODEL_ORDER[@]}"; do
    OLLAMA_OUTS[$key]=$(mktemp)
done

trap 'rm -f "$GROUNDING_OUT" "$HAIKU_REVIEW_OUT" "$SONNET_REVIEW_OUT" "$COMBINED_REVIEWS" "$HAIKU_CONS_OUT" "$SONNET_CONS_OUT" "$PHASE2_DOC" "$OPUS_FINAL_OUT" "$FINAL_DOC" ${OLLAMA_OUTS[*]}' EXIT

# --- Helper: Call Ollama ---
call_ollama() {
    local model_id="$1"
    local prompt="$2"
    local system_prompt="${3:-}"
    local out_file="$4"

    local messages
    if [[ -n "$system_prompt" ]]; then
        messages=$(jq -n --arg sys "$system_prompt" --arg usr "$prompt" \
            '[{"role": "system", "content": $sys}, {"role": "user", "content": $usr}]')
    else
        messages=$(jq -n --arg usr "$prompt" \
            '[{"role": "user", "content": $usr}]')
    fi

    local payload
    payload=$(jq -n --arg model "$model_id" --argjson msgs "$messages" \
        '{model: $model, messages: $msgs, stream: false, options: {num_ctx: 16384, num_predict: 4096}}')

    local raw
    raw=$(curl -s --max-time "$OLLAMA_TIMEOUT" -X POST \
        "${OLLAMA_URL}/api/chat" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    local text
    text=$(echo "$raw" | jq -r '.message.content // empty' 2>/dev/null)

    # Strip <think> tags from reasoning models
    if [[ "$text" == *"</think>"* ]]; then
        text="${text#*</think>}"
        text="${text#$'\n'}"
    fi

    [[ -n "$text" ]] && echo "$text" > "$out_file"
}

# ============================================================
# PHASE 0: GROUNDING PASS (Haiku verifies codebase state)
# ============================================================
echo ""
echo "======================================================"
echo "PHASE 0/4: Grounding Pass (Haiku 4.5)"
echo "======================================================"

GROUNDING_SYSTEM='You are a code-state verifier. Use your Read, Grep, and Glob tools to verify every claim the plan below makes about the CURRENT state of the codebase. For every file path, function name, class name, line count, or code reference in the plan, confirm whether it exists in reality at the location claimed.

Output a structured markdown report in this exact format:

## Reality Check

### Files referenced
- `<path>` -- EXISTS (<N> lines) | MISSING | RENAMED to `<new>` | WRONG_PATH (actual: `<real>`)

### Functions / classes / symbols referenced
- `<symbol>` in `<file>` -- EXISTS at line <N> | MISSING | RENAMED to `<new>` | MOVED to `<file>:<line>`

### Plan claims about current state vs reality
- Plan says: "<quote>" -> Reality: "<finding>" [MATCH | MISMATCH | UNVERIFIABLE]

### Already-implemented detection
- Any changes the plan proposes that already appear to be implemented in the current code.

### Notes
- Anything else reviewers should know before critiquing this plan.

Be terse. Use exact file paths. Do NOT review the plan. Do NOT suggest changes. Only report ground truth. If you cannot verify something, say UNVERIFIABLE with a one-line reason. Cap output at 1500 words.'

GROUNDING_PROMPT="Verify the current codebase state against this plan. Use your tools.

---

$PLAN_CONTENT"

echo "[...] Haiku grounding pass (timeout ${HAIKU_TIMEOUT}s)..."
echo "$GROUNDING_PROMPT" | timeout "$HAIKU_TIMEOUT" \
    claude --print --model haiku --system-prompt "$GROUNDING_SYSTEM" \
    > "$GROUNDING_OUT" 2>/dev/null || true

if [[ ! -s "$GROUNDING_OUT" ]]; then
    {
        echo "## Reality Check"
        echo ""
        echo "_Grounding pass failed or timed out. Reviewers should verify claims themselves._"
    } > "$GROUNDING_OUT"
    echo "[WARN] Grounding pass failed -- using placeholder"
else
    echo "[OK] Grounding doc: $(wc -c < "$GROUNDING_OUT") bytes"
fi

GROUNDING_CONTENT=$(cat "$GROUNDING_OUT")
GROUNDING_LEN=${#GROUNDING_CONTENT}
if [[ $GROUNDING_LEN -lt 50 ]]; then
    echo "[WARN] Grounding output suspiciously small (${GROUNDING_LEN} bytes) — may be incomplete"
fi
cp "$GROUNDING_OUT" "$REVIEWS_DIR/${TIMESTAMP}-plan-phase0-grounding.md"
echo "[SAVED] Phase 0: $REVIEWS_DIR/${TIMESTAMP}-plan-phase0-grounding.md"

# ============================================================
# PHASE 1: Independent Reviews
#   Haiku 4.5 (bg) + Sonnet 4.6 (bg) + 3 Ollama (sequential)
# ============================================================
echo ""
echo "======================================================"
echo "PHASE 1/4: Independent Reviews (Haiku + Sonnet + 3 local Ollama = 5 reviewers)"
echo "======================================================"

REVIEW_SYSTEM="You are an expert software architect reviewing an implementation plan. A grounding pass has already verified which parts of the plan match the current codebase state. Cross-reference the plan against the Reality Check — DO NOT duplicate the grounding work, focus on the plan's soundness given what is already verified.

Review for:
1. Feasibility - Can this actually be built as described? Missing steps?
2. Architecture - Are the patterns, file structure, and dependencies sound?
3. Security - Any risks, credential exposure, injection vectors?
4. Edge cases - What could go wrong? What's missing?
5. Complexity - Is it over-engineered? Could it be simpler?
6. Dependencies - Are all prerequisites identified? Any missing?

Rate each finding as CRITICAL, HIGH, or MEDIUM. Be specific and actionable. Be brief."

REVIEW_PROMPT="Review this implementation plan.

# Plan

$PLAN_CONTENT

---

# Reality Check (pre-verified by grounding pass)

$GROUNDING_CONTENT"

# Haiku 4.5 — background
(
    echo "$REVIEW_PROMPT" | timeout "$HAIKU_TIMEOUT" \
        claude --print --model haiku --system-prompt "$REVIEW_SYSTEM" \
        > "$HAIKU_REVIEW_OUT" 2>/dev/null || true
) &
PID_HAIKU_REVIEW=$!

# Sonnet 4.6 — background (parallel with Haiku, no GPU needed)
(
    echo "$REVIEW_PROMPT" | timeout "$SONNET_TIMEOUT" \
        claude --print --model sonnet --system-prompt "$REVIEW_SYSTEM" \
        > "$SONNET_REVIEW_OUT" 2>/dev/null || true
) &
PID_SONNET_REVIEW=$!

# Ollama models — SEQUENTIAL (single GPU, no VRAM contention)
for key in "${OLLAMA_MODEL_ORDER[@]}"; do
    model_id="${OLLAMA_MODELS[$key]}"
    out_file="${OLLAMA_OUTS[$key]}"
    echo "[...] $key (${model_id})..."
    T0=$SECONDS
    call_ollama "$model_id" "$REVIEW_PROMPT" "$REVIEW_SYSTEM" "$out_file"
    ELAPSED=$((SECONDS - T0))
    SIZE=$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')
    if [[ ${SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then
        echo "[OK] $key: ${SIZE}B (${ELAPSED}s)"
    else
        echo "[FAIL] $key: ${SIZE:-0}B (${ELAPSED}s)"
    fi
done

echo "[...] Waiting for Haiku + Sonnet reviews..."
wait $PID_HAIKU_REVIEW 2>/dev/null || true
wait $PID_SONNET_REVIEW 2>/dev/null || true

# Assess Phase 1 results
HAIKU_REVIEW_SIZE=$(wc -c < "$HAIKU_REVIEW_OUT" 2>/dev/null | tr -d ' ')
SONNET_REVIEW_SIZE=$(wc -c < "$SONNET_REVIEW_OUT" 2>/dev/null | tr -d ' ')
VALID_REVIEWS=0

if [[ ${HAIKU_REVIEW_SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then
    VALID_REVIEWS=$((VALID_REVIEWS + 1))
    echo "[OK] Haiku 4.5: ${HAIKU_REVIEW_SIZE}B"
else
    echo "[FAIL] Haiku 4.5: ${HAIKU_REVIEW_SIZE:-0}B (< ${MIN_REVIEW_BYTES}B minimum)"
fi

if [[ ${SONNET_REVIEW_SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then
    VALID_REVIEWS=$((VALID_REVIEWS + 1))
    echo "[OK] Sonnet 4.6: ${SONNET_REVIEW_SIZE}B"
else
    echo "[FAIL] Sonnet 4.6: ${SONNET_REVIEW_SIZE:-0}B (< ${MIN_REVIEW_BYTES}B minimum)"
fi

VALID_OLLAMA=0
for key in "${OLLAMA_MODEL_ORDER[@]}"; do
    out_file="${OLLAMA_OUTS[$key]}"
    size=$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')
    if [[ ${size:-0} -ge $MIN_REVIEW_BYTES ]]; then
        VALID_OLLAMA=$((VALID_OLLAMA + 1))
    fi
done
VALID_REVIEWS=$((VALID_REVIEWS + VALID_OLLAMA))
TOTAL_REVIEWER_COUNT=$((2 + ${#OLLAMA_MODEL_ORDER[@]}))

echo ""
echo "Phase 1 result: $VALID_REVIEWS/$TOTAL_REVIEWER_COUNT sources valid"

# Build combined reviews document
{
    echo "# Reality Check (Phase 0 grounding)"
    echo ""
    echo "$GROUNDING_CONTENT"
    echo ""
    echo "---"
    echo ""
    echo "# Phase 1: Independent Plan Reviews"
    echo ""
    echo "## Haiku 4.5"
    if [[ ${HAIKU_REVIEW_SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then cat "$HAIKU_REVIEW_OUT"; else echo "(insufficient response: ${HAIKU_REVIEW_SIZE:-0}B)"; fi
    echo ""
    echo "---"
    echo ""
    echo "## Sonnet 4.6"
    if [[ ${SONNET_REVIEW_SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then cat "$SONNET_REVIEW_OUT"; else echo "(insufficient response: ${SONNET_REVIEW_SIZE:-0}B)"; fi
    echo ""
    for key in "${OLLAMA_MODEL_ORDER[@]}"; do
        model_id="${OLLAMA_MODELS[$key]}"
        out_file="${OLLAMA_OUTS[$key]}"
        size=$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')
        echo "---"
        echo ""
        echo "## $key — ${model_id} (Local Ollama)"
        if [[ ${size:-0} -ge $MIN_REVIEW_BYTES ]]; then cat "$out_file"; else echo "(insufficient response: ${size:-0}B)"; fi
        echo ""
    done
} > "$COMBINED_REVIEWS"

cp "$COMBINED_REVIEWS" "$REVIEWS_DIR/${TIMESTAMP}-plan-phase1.md"
echo "[SAVED] Phase 1: $REVIEWS_DIR/${TIMESTAMP}-plan-phase1.md"

if [[ $VALID_REVIEWS -lt $MIN_VALID_REVIEWS ]]; then
    echo ""
    echo "WARNING: Only $VALID_REVIEWS valid review source(s) (need >= $MIN_VALID_REVIEWS). Returning Phase 1 only."
    echo ""
    cat "$COMBINED_REVIEWS"
    exit 0
fi

# ============================================================
# PHASE 2: Consensus Vote
#   Haiku 4.5 (bg) + Sonnet 4.6 (bg) + 3 Ollama (sequential) = 5 voters
# ============================================================
echo ""
echo "======================================================"
echo "PHASE 2/4: Consensus Vote (Haiku + Sonnet + 3 Local Ollama = 5 voters)"
echo "======================================================"

CONSENSUS_SYSTEM='You are a consensus analyst reviewing a set of independent LLM plan reviews.
You received: (1) a Reality Check from a grounding pass, and (2) independent reviews from 5 LLMs.

Your task: synthesize these reviews into a consensus document.

Categorize each finding by agreement level:
- UNANIMOUS (5/5): All reviewers flagged this issue
- STRONG MAJORITY (4/5): Near-consensus, high confidence
- MAJORITY (3/5): Most agree
- MINORITY (2/5): Some agreement
- DISPUTED (1/5): Only 1 reviewer found it, but CRITICAL severity — carry forward
- DISMISSED: False positives, misunderstandings, or incorrect claims

For each category, list the findings with:
- The issue (one sentence)
- Which reviewers identified it
- Recommended action

End with a Final Verdict: APPROVE, REVISE, or REJECT with a one-paragraph rationale.

Be concise. Cap output at 1500 words. Use markdown formatting.'

REVIEWS_CONTENT=$(cat "$COMBINED_REVIEWS")

# Haiku consensus — background
(
    cat "$COMBINED_REVIEWS" | timeout "$HAIKU_TIMEOUT" \
        claude --print --model haiku --system-prompt "$CONSENSUS_SYSTEM" \
        > "$HAIKU_CONS_OUT" 2>/dev/null || true
) &
PID_CONS_HAIKU=$!

# Sonnet consensus — background (parallel with Haiku)
(
    cat "$COMBINED_REVIEWS" | timeout "$SONNET_TIMEOUT" \
        claude --print --model sonnet --system-prompt "$CONSENSUS_SYSTEM" \
        > "$SONNET_CONS_OUT" 2>/dev/null || true
) &
PID_CONS_SONNET=$!

# Ollama consensus — SEQUENTIAL (single GPU)
declare -A OLLAMA_CONS_OUTS
for key in "${OLLAMA_MODEL_ORDER[@]}"; do
    OLLAMA_CONS_OUTS[$key]=$(mktemp)
done

for key in "${OLLAMA_MODEL_ORDER[@]}"; do
    model_id="${OLLAMA_MODELS[$key]}"
    out_file="${OLLAMA_CONS_OUTS[$key]}"
    echo "[...] $key consensus..."
    T0=$SECONDS
    call_ollama "$model_id" "$REVIEWS_CONTENT" "$CONSENSUS_SYSTEM" "$out_file"
    ELAPSED=$((SECONDS - T0))
    SIZE=$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')
    if [[ ${SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then
        echo "[OK] $key consensus: ${SIZE}B (${ELAPSED}s)"
    else
        echo "[FAIL] $key consensus: ${SIZE:-0}B (${ELAPSED}s)"
    fi
done

echo "[...] Waiting for Haiku + Sonnet consensus..."
wait $PID_CONS_HAIKU 2>/dev/null || true
wait $PID_CONS_SONNET 2>/dev/null || true

HAIKU_CONS_SIZE=$(wc -c < "$HAIKU_CONS_OUT" 2>/dev/null | tr -d ' ')
SONNET_CONS_SIZE=$(wc -c < "$SONNET_CONS_OUT" 2>/dev/null | tr -d ' ')
VALID_CONS=0
HAIKU_CONS_STATUS="FAIL"
SONNET_CONS_STATUS="FAIL"

if [[ ${HAIKU_CONS_SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then
    VALID_CONS=$((VALID_CONS + 1))
    HAIKU_CONS_STATUS="OK"
    echo "[OK] Haiku 4.5 consensus: ${HAIKU_CONS_SIZE}B"
else
    echo "[FAIL] Haiku 4.5 consensus: ${HAIKU_CONS_SIZE:-0}B"
fi

if [[ ${SONNET_CONS_SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then
    VALID_CONS=$((VALID_CONS + 1))
    SONNET_CONS_STATUS="OK"
    echo "[OK] Sonnet 4.6 consensus: ${SONNET_CONS_SIZE}B"
else
    echo "[FAIL] Sonnet 4.6 consensus: ${SONNET_CONS_SIZE:-0}B"
fi

VALID_OLLAMA_CONS=0
for key in "${OLLAMA_MODEL_ORDER[@]}"; do
    out_file="${OLLAMA_CONS_OUTS[$key]}"
    size=$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')
    if [[ ${size:-0} -ge $MIN_REVIEW_BYTES ]]; then
        VALID_OLLAMA_CONS=$((VALID_OLLAMA_CONS + 1))
    fi
done
VALID_CONS=$((VALID_CONS + VALID_OLLAMA_CONS))
TOTAL_CONS_VOTERS=$((2 + ${#OLLAMA_MODEL_ORDER[@]}))

echo ""
echo "Phase 2 result: $VALID_CONS/$TOTAL_CONS_VOTERS sources valid"

if [[ $VALID_CONS -lt 2 ]]; then
    echo "[FAIL] Fewer than 2 consensus sources valid — outputting Phase 1 instead"
    echo ""
    cat "$COMBINED_REVIEWS"
    for key in "${OLLAMA_MODEL_ORDER[@]}"; do rm -f "${OLLAMA_CONS_OUTS[$key]}"; done
    exit 0
fi

# Build Phase 2 consensus document
{
    echo "# Phase 2: Consensus Analysis (5-way vote)"
    echo ""
    echo "- **Phase 1 sources**: $VALID_REVIEWS/$TOTAL_REVIEWER_COUNT valid"
    echo "- **Phase 2 voters**: $VALID_CONS/$TOTAL_CONS_VOTERS valid (Haiku + Sonnet + ${#OLLAMA_MODEL_ORDER[@]} local)"
    echo "- **Local models**: ${OLLAMA_MODELS[model-a]}, ${OLLAMA_MODELS[model-b]}, ${OLLAMA_MODELS[model-c]}"
    echo "- **Date**: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "---"
    echo ""
    echo "## Haiku 4.5 Consensus"
    echo ""
    if [[ ${HAIKU_CONS_SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then cat "$HAIKU_CONS_OUT"; else echo "(failed/timed out)"; fi
    echo ""
    echo "---"
    echo ""
    echo "## Sonnet 4.6 Consensus"
    echo ""
    if [[ ${SONNET_CONS_SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then cat "$SONNET_CONS_OUT"; else echo "(failed/timed out)"; fi
    echo ""
    for key in "${OLLAMA_MODEL_ORDER[@]}"; do
        model_id="${OLLAMA_MODELS[$key]}"
        out_file="${OLLAMA_CONS_OUTS[$key]}"
        size=$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')
        echo "---"
        echo ""
        echo "## $key — ${model_id} (Local Ollama) Consensus"
        echo ""
        if [[ ${size:-0} -ge $MIN_REVIEW_BYTES ]]; then cat "$out_file"; else echo "(failed/timed out)"; fi
        echo ""
    done
} > "$PHASE2_DOC"

# Cleanup Ollama consensus temps
for key in "${OLLAMA_MODEL_ORDER[@]}"; do rm -f "${OLLAMA_CONS_OUTS[$key]}"; done

cp "$PHASE2_DOC" "$REVIEWS_DIR/${TIMESTAMP}-plan-phase2-consensus.md"
echo "[SAVED] Phase 2: $REVIEWS_DIR/${TIMESTAMP}-plan-phase2-consensus.md"

# ============================================================
# PHASE 3: Opus Synthesis
#   Reads Phase 2 consensus → produces actionable brief for plan-agent
# ============================================================
echo ""
echo "======================================================"
echo "PHASE 3/4: Opus Synthesis (reading Phase 2 consensus)"
echo "======================================================"

OPUS_SYSTEM='You are the final reviewer in a plan review pipeline. Five independent LLMs (Haiku 4.5, Sonnet 4.6, and three local Ollama models) have reviewed an implementation plan and produced a consensus analysis.

Your job: synthesize their consensus into a clear, actionable brief for the architect who will revise the plan.

Structure your output exactly as:

## Opus Synthesis

### Must Address (CRITICAL / HIGH)
For each issue: one sentence describing it, which reviewers flagged it, and a specific recommended fix.

### Should Consider (MEDIUM)
For each issue: one sentence and recommended action. Keep this section short.

### Dismissed
List any reviewer concerns you assess as false positives, duplicates, or noise — with one-line reason for dismissal.

### Final Verdict
APPROVE | REVISE | REJECT

One paragraph rationale. Be direct. Name the top concern if REVISE or REJECT.

Max 600 words total.'

PHASE2_CONTENT=$(cat "$PHASE2_DOC")

echo "[...] Opus synthesis (timeout ${OPUS_TIMEOUT}s)..."
echo "$PHASE2_CONTENT" | timeout "$OPUS_TIMEOUT" \
    claude --print --model opus --system-prompt "$OPUS_SYSTEM" \
    > "$OPUS_FINAL_OUT" 2>/dev/null || true

OPUS_SIZE=$(wc -c < "$OPUS_FINAL_OUT" 2>/dev/null | tr -d ' ')
if [[ ${OPUS_SIZE:-0} -ge $MIN_REVIEW_BYTES ]]; then
    echo "[OK] Opus synthesis: ${OPUS_SIZE}B"
    cp "$OPUS_FINAL_OUT" "$REVIEWS_DIR/${TIMESTAMP}-plan-phase3-opus.md"
    echo "[SAVED] Phase 3: $REVIEWS_DIR/${TIMESTAMP}-plan-phase3-opus.md"
else
    echo "[WARN] Opus synthesis failed or too small (${OPUS_SIZE:-0}B) — using Phase 2 only"
    cat "$PHASE2_DOC" > "$OPUS_FINAL_OUT"
fi

# Build final document: Opus synthesis first, Phase 2 details appended
{
    echo "# Plan Review: Opus Synthesis"
    echo ""
    cat "$OPUS_FINAL_OUT"
    echo ""
    echo "---"
    echo ""
    echo "# Full Phase 2 Details (5-way consensus)"
    echo ""
    cat "$PHASE2_DOC"
} > "$FINAL_DOC"

# ============================================================
# Output to stdout for plan-agent (Opus) to consume
# ============================================================
echo ""
echo "======================================================"
echo "PLAN REVIEW COMPLETE"
echo "  Phase 0: grounding (Haiku)"
echo "  Phase 1: $VALID_REVIEWS/$TOTAL_REVIEWER_COUNT reviewers (Haiku, Sonnet, ${OLLAMA_MODELS[model-a]}, ${OLLAMA_MODELS[model-b]}, ${OLLAMA_MODELS[model-c]})"
echo "  Phase 2: $VALID_CONS/$TOTAL_CONS_VOTERS voters (Haiku: $HAIKU_CONS_STATUS, Sonnet: $SONNET_CONS_STATUS, Local: $VALID_OLLAMA_CONS/${#OLLAMA_MODEL_ORDER[@]})"
echo "  Phase 3: Opus synthesis (${OPUS_SIZE:-0}B)"
echo "  Duration: $SECONDS seconds"
echo "======================================================"
echo ""
echo "--- BEGIN CONSENSUS DOCUMENT ---"
cat "$FINAL_DOC"
echo "--- END CONSENSUS DOCUMENT ---"
