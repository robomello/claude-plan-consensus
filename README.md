# claude-plan-consensus

A Claude Code hook system that enforces multi-LLM consensus review on every implementation plan before it can be approved.

When `plan-agent` writes a plan, a 4-phase pipeline fires automatically:

- **Phase 0** — Haiku 4.5 verifies every file path, symbol, and claim in the plan against the actual codebase
- **Phase 1** — 5 independent reviewers critique the plan (Haiku 4.5 + Sonnet 4.6 + 3 local Ollama models)
- **Phase 2** — same 5 models vote on a consensus document (APPROVE / REVISE / REJECT)
- **Phase 3** — Opus reads the Phase 2 consensus and produces a final synthesis brief for the plan-agent

The main Opus session reads the consensus, incorporates feedback, and adds `<!-- REVIEWED -->` to the plan. A gating hook blocks `ExitPlanMode` until that marker is present — you cannot approve an unreviewed plan.

## Architecture

```
User asks for plan
       ↓
Agent(subagent_type="plan-agent")
       ↓
plan-agent writes ~/.claude/plans/<slug>.md
       ↓
PostToolUse hook fires: review_plan_consensus.sh
  ├─ Phase 0: Haiku grounding (tool-use: Read, Grep, Glob)
  ├─ Phase 1: Haiku (bg) + Sonnet (bg) + model-a, model-b, model-c (sequential)
  ├─ Phase 2: same 5 models vote on consensus
  └─ Phase 3: Opus reads Phase 2 → synthesis brief
       ↓
All phases saved to ~/.claude/reviews/
       ↓
plan-agent reads Opus synthesis + Phase 2 details, revises plan, adds <!-- REVIEWED -->
       ↓
ExitPlanMode PreToolUse: enforce_plan_agent.py
  └─ BLOCKS unless <!-- REVIEWED --> present
       ↓
ExitPlanMode PostToolUse:
  ├─ archive_plan.py  →  plans/archive/YYYY-MM-DD/
  └─ validate_team_section.py  →  warns on stale models
```

## Requirements

| Tool | Purpose |
|------|---------|
| `claude` CLI | Haiku grounding + review (Phase 0, 1, 2) |
| `ollama` | 3 local reviewer models (Phase 1, 2) |
| `jq` | JSON parsing in shell hooks |
| `curl` | Ollama API calls |
| `python3` | Python hooks |

## Installation

```bash
git clone https://github.com/robomello/claude-plan-consensus
cd claude-plan-consensus

# Install to /opt/claude-shared/hooks (shared, may need sudo for mkdir)
bash install.sh

# Or install user-local (no sudo needed)
bash install.sh ~/.claude/hooks/plan-consensus
```

The installer:
1. Copies all hooks to the target directory
2. Copies `plan-agent.md` to `~/.claude/agents/`
3. Creates `~/.claude/plans/` and `~/.claude/reviews/`
4. Generates `settings-fragment-generated.json` with correct absolute paths

Then merge the generated fragment into your `~/.claude/settings.json` — the installer prints the exact Python one-liner to do it.

## Configuration

### Ollama models

The three Ollama reviewers default to the models used on the original server. Override via environment variables:

```bash
export OLLAMA_MODEL_A="llama3.3:70b"
export OLLAMA_MODEL_B="mistral:7b"
export OLLAMA_MODEL_C="deepseek-r1:32b"
```

Or edit `OLLAMA_MODEL_A/B/C` at the top of `hooks/review_plan_consensus.sh`.

### Ollama endpoint

```bash
export OLLAMA_BASE_URL="http://localhost:11434"   # default
export OLLAMA_BASE_URL="http://localhost:11435"   # non-standard port
```

### Timeouts

At the top of `review_plan_consensus.sh`:

```bash
HAIKU_TIMEOUT=180    # seconds — Haiku grounding + review
OLLAMA_TIMEOUT=600   # seconds — per Ollama model call
```

Increase `OLLAMA_TIMEOUT` for large models (70B+).

## How the gating works

`enforce_plan_agent.py` is wired as a `PreToolUse` hook on `ExitPlanMode`. It reads the most recently modified `*.md` in `~/.claude/plans/` and blocks the tool call if `<!-- REVIEWED -->` is not on line 1.

This means: the plan pipeline MUST complete and the plan-agent MUST incorporate feedback before the plan can be presented to the user. There is no bypass.

`enforce_plan_agent.sh` fires on `EnterPlanMode` and plan file writes, warning (but not blocking) if the main session tries to write a plan directly instead of delegating to plan-agent.

## File layout

```
claude-plan-consensus/
├── hooks/
│   ├── review_plan_consensus.sh   ← 3-phase review pipeline
│   ├── enforce_plan_agent.py      ← blocks ExitPlanMode without REVIEWED marker
│   ├── enforce_plan_agent.sh      ← warns against bypassing plan-agent
│   ├── archive_plan.py            ← archives approved plans
│   ├── validate_team_section.py   ← warns on missing/stale Team Structure
│   └── plan_update_hook.py        ← delegates plan saves to background Haiku
├── agents/
│   └── plan-agent.md              ← plan-agent definition (install to ~/.claude/agents/)
├── rules/
│   └── planning-and-agents.md     ← workflow rules (add to CLAUDE.md)
├── settings-fragment.json         ← hook wiring template
└── install.sh                     ← setup script
```

## Plan output format

Every plan produced by `plan-agent` must include these sections (in order):

1. **Context** — why this change is needed
2. **Proposed changes** — files and line numbers
3. **Task breakdown** — tasks with explicit dependencies
4. **Prerequisites** — packages, images, or downloads needed before execution
5. **Verification steps** — how to confirm the work succeeded
6. **Review Notes** — consensus findings incorporated or dismissed (added post-review)
7. **Team Structure** — table of teammates, models, and roles (REQUIRED)

The `<!-- REVIEWED -->` marker goes on line 1, before everything else.

## Review output

Phase output files are saved to `~/.claude/reviews/`:

```
~/.claude/reviews/
  20260429_143022-plan-phase0-grounding.md
  20260429_143022-plan-phase1.md
  20260429_143022-plan-phase2-consensus.md
  20260429_143022-plan-phase3-opus.md
```

The plan-agent receives the Opus synthesis (Phase 3) prepended to the full Phase 2 details.
