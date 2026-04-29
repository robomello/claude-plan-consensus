# Planning & Agent Orchestration

## Planning Workflow (STRICT ORDER)

1. **Plan** — plan-agent writes plan to `~/.claude/plans/<slug>.md`
2. **Review** — consensus hook fires automatically (4 LLMs, 2 phases)
3. **Incorporate** — plan-agent reads consensus, revises plan, adds `<!-- REVIEWED -->`
4. **Present** — ExitPlanMode shows plan to user
5. **Prerequisites** — download ALL dependencies BEFORE implementation
6. **Execute** — create agent team, spawn teammates

**Key:** Use `subagent_type="plan-agent"` NOT the built-in `"Plan"` agent.
The built-in plan mode lacks Write/Edit tools and does NOT trigger the consensus hook.

## Team Creation (After Approval)

```
TeamCreate → TaskCreate (for each task) → TaskUpdate (set dependencies)
→ Agent(model="sonnet") for builders → Agent(model="haiku") for reviewers
→ TaskUpdate (assign owners) → Monitor → Shutdown → TeamDelete
```

### Team Sizing

- **Minimum 3** — builder + tester + devil's advocate
- **Required roles**: Devil's Advocate (haiku, code-reviewer), Integration Tester (sonnet)
- **Model rule**: writes files → sonnet, only reads/reviews → haiku
- Main session (Opus) orchestrates only — does NOT implement

### Shared File Conflict Prevention (Task 0 Pattern)

When parallel builders need the same files (router, nav, config):
- **Task 0** (runs first): edits ALL shared files
- **Tasks 1..N** (parallel): create ONLY files in their own directory, NEVER touch shared files

### Exception: Trivial Plans
If ≤3 files AND the fix is obvious — skip plan mode AND team creation. Just implement + code-review.
Single-file <20 line changes need no review either.

## Model Selection

| Model | Use for |
|-------|---------|
| Haiku | Lightweight agents, exploration, reviews |
| Sonnet | Main dev work, all code-writing teammates |
| Opus | Orchestration, architecture, complex debugging |

## Effort Levels

| Level | Use for |
|-------|---------|
| low | Quick lookups, trivial edits |
| medium | Simple routine tasks |
| **high** (default) | Most development work |
| **max** | Architecture, complex debugging, planning |

**high ≠ max.** Max enables extended thinking.
