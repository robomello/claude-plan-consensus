#!/bin/bash
# install.sh — Set up claude-plan-consensus hooks
# Usage: bash install.sh [INSTALL_DIR]
# Default INSTALL_DIR: /opt/claude-shared/hooks  (shared, requires sudo)
# Alternative:         ~/.claude/hooks/plan-consensus  (user-local, no sudo)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-/opt/claude-shared/hooks}"
AGENTS_DIR="$HOME/.claude/agents"
PLANS_DIR="$HOME/.claude/plans"
REVIEWS_DIR="$HOME/.claude/reviews"

echo ""
echo "======================================================"
echo "claude-plan-consensus installer"
echo "======================================================"
echo "  Hook directory : $INSTALL_DIR"
echo "  Agents dir     : $AGENTS_DIR"
echo ""

# --- Dependency checks ---
missing=()
command -v claude  >/dev/null 2>&1 || missing+=("claude CLI")
command -v jq      >/dev/null 2>&1 || missing+=("jq")
command -v curl    >/dev/null 2>&1 || missing+=("curl")
command -v python3 >/dev/null 2>&1 || missing+=("python3")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${missing[@]}"; do echo "  - $dep"; done
    echo ""
    echo "Install them before running this script."
    exit 1
fi
echo "[OK] Dependencies: claude, jq, curl, python3"

# Warn if Ollama is not reachable
OLLAMA_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
if curl -s --max-time 3 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
    echo "[OK] Ollama reachable at $OLLAMA_URL"
else
    echo "[WARN] Ollama not reachable at $OLLAMA_URL"
    echo "       Set OLLAMA_BASE_URL env var if your Ollama runs on a different port."
    echo "       The hooks will still install — Ollama is only needed at review time."
fi

# --- Install hooks ---
echo ""
echo "[1/4] Installing hooks to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
for f in "$SCRIPT_DIR"/hooks/*.sh "$SCRIPT_DIR"/hooks/*.py; do
    [[ -f "$f" ]] || continue
    dest="$INSTALL_DIR/$(basename "$f")"
    cp "$f" "$dest"
    chmod +x "$dest"
    echo "  + $(basename "$f")"
done

# --- Install plan-agent ---
echo ""
echo "[2/4] Installing plan-agent to $AGENTS_DIR ..."
mkdir -p "$AGENTS_DIR"
cp "$SCRIPT_DIR/agents/plan-agent.md" "$AGENTS_DIR/plan-agent.md"
echo "  + plan-agent.md"

# --- Create runtime directories ---
echo ""
echo "[3/4] Creating runtime directories ..."
mkdir -p "$PLANS_DIR" "$REVIEWS_DIR"
echo "  + $PLANS_DIR"
echo "  + $REVIEWS_DIR"

# --- Generate settings fragment ---
echo ""
echo "[4/4] Generating settings fragment ..."
GENERATED_FRAGMENT="$SCRIPT_DIR/settings-fragment-generated.json"
sed "s|__HOOKS_DIR__|$INSTALL_DIR|g" "$SCRIPT_DIR/settings-fragment.json" > "$GENERATED_FRAGMENT"
# Remove the _comment key from the generated file
python3 -c "
import json, sys
d = json.load(open('$GENERATED_FRAGMENT'))
d.pop('_comment', None)
print(json.dumps(d, indent=2))
" > "${GENERATED_FRAGMENT}.tmp" && mv "${GENERATED_FRAGMENT}.tmp" "$GENERATED_FRAGMENT"
echo "  + $GENERATED_FRAGMENT"

echo ""
echo "======================================================"
echo "Installation complete."
echo ""
echo "NEXT STEP: Merge the hook wiring into your Claude Code settings."
echo ""
echo "Option A — automatic merge (requires Python 3.9+):"
echo "  python3 - <<'EOF'"
echo "  import json, pathlib"
echo "  settings_path = pathlib.Path.home() / '.claude' / 'settings.json'"
echo "  settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}"
echo "  fragment = json.load(open('$GENERATED_FRAGMENT'))"
echo "  hooks = settings.setdefault('hooks', {})"
echo "  for event, entries in fragment.get('hooks', {}).items():"
echo "      hooks.setdefault(event, []).extend(entries)"
echo "  settings_path.write_text(json.dumps(settings, indent=2))"
echo "  print('Merged.')"
echo "  EOF"
echo ""
echo "Option B — manual: open $GENERATED_FRAGMENT and copy the"
echo "  hook entries into ~/.claude/settings.json under the 'hooks' key."
echo ""
echo "Optional: add rules/planning-and-agents.md content to your CLAUDE.md"
echo "  to teach Claude the planning workflow."
echo "======================================================"
