# claude-plan-consensus

> **Make Claude Code argue with itself (and 3 local LLMs) before it ships a plan.**

A hook system that forces a **5-LLM peer review** on every implementation plan Claude Code writes — *before* it's allowed to leave plan mode. The main session **cannot approve an unreviewed plan.** There is no bypass.

![status: works on my machine](https://img.shields.io/badge/status-works_on_my_machine-brightgreen)
![claude-code](https://img.shields.io/badge/claude--code-hooks-blue)
![ollama](https://img.shields.io/badge/ollama-local-orange)
![bypass](https://img.shields.io/badge/bypass-impossible-red)

---

## What it does

When `plan-agent` writes a plan to `~/.claude/plans/<slug>.md`, a **4-phase pipeline** fires automatically:

| Phase | Job | Model(s) |
|------:|-----|----------|
| **0** | Grounding — verify every file path, symbol, and claim against the *actual* codebase | Haiku 4.5 (with Read/Grep/Glob) |
| **1** | 5 independent reviewers critique the plan | Haiku 4.5 + Sonnet 4.6 + 3 local Ollama |
| **2** | Same 5 models vote on a consensus document (APPROVE / REVISE / REJECT) | Haiku 4.5 + Sonnet 4.6 + 3 local Ollama |
| **3** | Final synthesis — actionable brief for the architect | Opus |

The main Opus session reads the consensus, incorporates feedback, and writes `<!-- REVIEWED -->` to line 1 of the plan. A `PreToolUse` hook on `ExitPlanMode` **blocks** the call until that marker is present.

**You cannot escape the review loop.** That's the point.

---

## Why this exists

Plans drift. LLMs hallucinate file paths, propose changes that are already implemented, miss edge cases, over-engineer, or skip prerequisite steps. A single reviewer (even Opus) misses things a panel doesn't.

This repo makes that panel automatic, local-first, and **enforced** — not an opt-in suggestion.

---

## Architecture

```
User asks for a plan
        │
        ▼
Agent(subagent_type="plan-agent")
        │
        ▼
plan-agent writes ~/.claude/plans/<slug>.md
        │
        ▼  (PostToolUse hook)
review_plan_consensus.sh
   ├─ Phase 0:  Haiku grounding   (Read, Grep, Glob — verifies plan claims)
   ├─ Phase 1:  Haiku (bg) ║ Sonnet (bg) ║ model-a → model-b → model-c
   ├─ Phase 2:  same 5 models vote on consensus
   └─ Phase 3:  Opus reads Phase 2 → synthesis brief
        │
        ▼
All phases archived to ~/.claude/reviews/
        │
        ▼
plan-agent reads the synthesis, revises, adds <!-- REVIEWED -->
        │
        ▼  (PreToolUse hook)
ExitPlanMode  ─►  enforce_plan_agent.py
                  └─ BLOCKS unless <!-- REVIEWED --> is on line 1
```

---

## Quick start

```bash
git clone https://github.com/robomello/claude-plan-consensus
cd claude-plan-consensus
bash install.sh ~/.claude/hooks/plan-consensus     # user-local, no sudo
```

Then merge the generated `settings-fragment-generated.json` into `~/.claude/settings.json` — the installer prints a Python one-liner that does it for you.

That's it. Next time `plan-agent` writes a plan, the pipeline fires automatically.

---

## Requirements

| Tool | Why |
|------|-----|
| `claude` CLI | Phase 0/1/2 (Haiku, Sonnet) + Phase 3 (Opus) |
| `ollama` | 3 local reviewer models (Phase 1, 2) |
| `jq` | JSON parsing in shell hooks |
| `curl` | Ollama API |
| `python3` | Python hooks |

---

## Configuration

### Ollama models

Defaults are the models used on the original server. Override via env:

```bash
export OLLAMA_MODEL_A="llama3.3:70b"
export OLLAMA_MODEL_B="mistral:7b"
export OLLAMA_MODEL_C="deepseek-r1:32b"
```

Or edit `OLLAMA_MODEL_A/B/C` at the top of `hooks/review_plan_consensus.sh`.

### Ollama endpoint

```bash
export OLLAMA_BASE_URL="http://localhost:11434"   # default
```

### Timeouts

At the top of `review_plan_consensus.sh`:

```bash
HAIKU_TIMEOUT=180    # seconds — Haiku grounding + review
SONNET_TIMEOUT=300   # seconds — Sonnet review/consensus
OPUS_TIMEOUT=300     # seconds — Opus synthesis
OLLAMA_TIMEOUT=600   # seconds — per Ollama model call (bump for 70B+)
```

---

## How the gating works

`enforce_plan_agent.py` is a `PreToolUse` hook on `ExitPlanMode`. It reads the most recently modified `*.md` in `~/.claude/plans/` and **denies** the tool call if `<!-- REVIEWED -->` is not on line 1.

This means: the consensus pipeline MUST complete and `plan-agent` MUST incorporate feedback before the plan can be presented to the user.

`enforce_plan_agent.sh` fires on `EnterPlanMode` and plan-file writes — it warns (does not block) if the main session tries to write a plan directly instead of delegating to `plan-agent`. The hard block is at `ExitPlanMode`.

---

## File layout

```
claude-plan-consensus/
├── hooks/
│   ├── review_plan_consensus.sh   ← 4-phase consensus pipeline
│   ├── enforce_plan_agent.py      ← BLOCKS ExitPlanMode without REVIEWED marker
│   ├── enforce_plan_agent.sh      ← warns against bypassing plan-agent
│   ├── archive_plan.py            ← archives approved plans by date
│   ├── validate_team_section.py   ← warns on missing/stale Team Structure
│   └── plan_update_hook.py        ← delegates plan saves to background Haiku
├── agents/
│   └── plan-agent.md              ← installs to ~/.claude/agents/
├── rules/
│   └── planning-and-agents.md     ← workflow rules for your CLAUDE.md
├── settings-fragment.json         ← hook wiring template
└── install.sh                     ← setup script
```

---

## Plan format

Every plan produced by `plan-agent` includes these sections, in order:

1. **Context** — why this change is needed
2. **Proposed changes** — files and line numbers
3. **Task breakdown** — tasks with explicit dependencies
4. **Prerequisites** — packages/images/downloads needed *before* execution
5. **Verification steps** — how to confirm success
6. **Review Notes** — consensus findings incorporated or dismissed *(added post-review)*
7. **Team Structure** — table of teammates, models, roles *(REQUIRED)*

The `<!-- REVIEWED -->` marker is line 1, before everything else.

---

## Review output

Phase artifacts land in `~/.claude/reviews/`:

```
~/.claude/reviews/
  20260429_143022-plan-phase0-grounding.md
  20260429_143022-plan-phase1.md
  20260429_143022-plan-phase2-consensus.md
  20260429_143022-plan-phase3-opus.md
```

The plan-agent receives the Opus synthesis prepended to the full Phase 2 details.

---

## FAQ

**Q: Doesn't this slow Claude down?**
Yes — by 2 to 5 minutes per plan, depending on Ollama model size. That's the price of catching a 30-minute mistake before it ships.

**Q: Can I disable a phase?**
Set the matching timeout to `1` and the phase will fail-soft. The pipeline degrades gracefully if reviewers fail or time out (`MIN_VALID_REVIEWS=2` floor).

**Q: What if Ollama is down?**
Phase 1/2 will run with just Haiku + Sonnet. The pipeline still completes; you just lose the local reviewers.

**Q: Can I use different cloud models?**
Edit the `--model` flags in `review_plan_consensus.sh`. Anything the `claude` CLI accepts works.

**Q: Why local Ollama instead of more cloud calls?**
Cost, latency, and diversity of opinion. Local 70B models often catch things cloud models miss because they were trained on different data slices.

---

## License

MIT — do whatever you want, just don't blame me when your plan-agent calls you out.
