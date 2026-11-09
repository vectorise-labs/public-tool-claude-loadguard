#!/bin/bash
# loadguard installer: user-level install of the Claude Code plugin, plus the
# initial capacity scan. Safe to re-run (it updates in place).
#
#   curl -fsSL https://raw.githubusercontent.com/vectorise-labs/public-tool-claude-loadguard/main/install.sh | bash
#
# Or by hand inside Claude Code:
#   /plugin marketplace add vectorise-labs/public-tool-claude-loadguard
#   /plugin install loadguard@vectorise-loadguard
set -euo pipefail

REPO="vectorise-labs/public-tool-claude-loadguard"
MARKET="vectorise-loadguard"

[ "$(uname -s)" = Darwin ] || { echo "loadguard targets macOS. On other systems it installs but stays inert." >&2; }
command -v claude >/dev/null || { echo "Claude Code CLI not found. Install it first: https://code.claude.com" >&2; exit 1; }

echo "→ adding marketplace $REPO"
claude plugin marketplace add "$REPO" >/dev/null 2>&1 || claude plugin marketplace update "$MARKET" >/dev/null 2>&1 || true

echo "→ installing loadguard (user scope)"
if ! claude plugin install "loadguard@$MARKET" --scope user -y; then
  echo "  install failed. Inside Claude Code, run: /plugin install loadguard@$MARKET" >&2; exit 1
fi

# Initial capacity scan from the installed copy, so the first session is instant.
root=$(ls -d "$HOME"/.claude/plugins/cache/"$MARKET"/loadguard/*/ 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$root" ] && [ -x "$root/bin/loadguard" ]; then
  echo "→ scanning this machine"
  "$root/bin/loadguard" scan | grep -E '^(model|ncpu|pcores|ecores|mem_gb|heavy_slots)=' | sed 's/^/    /'
  "$root/bin/loadguard" status | sed 's/^/    /'
fi

cat <<'EOF'
✓ loadguard installed. It runs silently in every new Claude Code session:
  - checks CPU, memory pressure, swap and thermals before heavy work, queueing it when the Mac is saturated
  - tells running agents and subagents mid-run when to replan, and when to go back to full speed
  - offers once per episode to clean up dead processes (never kills without asking)
  Tune thresholds in ~/.loadguard/config. Set LOADGUARD_DISABLE=1 to switch it off.
EOF
