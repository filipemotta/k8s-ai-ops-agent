#!/usr/bin/env bash
# Offline tests of how approve-fix.sh reads the agent's suggestion: real
# models write markdown, and sometimes no suggestion at all. Whatever the
# text, the result is one exact command or a refusal, never an empty command.
# (The first real-model run had a test run "kubectl" with an empty suggestion.)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
parse() { printf '%b' "$1" | bash "${REPO_ROOT}/scripts/approve-fix.sh" --parse 2>&1; }
# parses <description> <rationale> <expected command>
parses() {
  local out
  out="$(parse "$2")"
  if [ "${out}" = "$3" ]; then ok "$1"; else bad "$1 (got '${out}')"; fi
}
# refuses <description> <rationale>
refuses() {
  local out rc
  out="$(parse "$2")" && rc=0 || rc=$?
  if [ "${rc}" -eq 2 ] && grep -q '^refused: no SUGGESTED_FIX line with a command' <<< "${out}"; then ok "$1"; else bad "$1 (rc ${rc}: '${out}')"; fi
}

refuses "empty verdict" ""
refuses "verdict with no SUGGESTED_FIX line" "NO-GO. The pods crash.\\nRoll back."
refuses "SUGGESTED_FIX with nothing after it" "NO-GO.\\nSUGGESTED_FIX:"
refuses "SUGGESTED_FIX: none" "GO for production.\\nSUGGESTED_FIX: none"
refuses "markdown around an empty suggestion" "**SUGGESTED_FIX:** \`\`"
parses "the scripted format" "NO-GO.\\nSUGGESTED_FIX: kubectl -n sandbox rollout undo deployment/checkout" \
  "kubectl -n sandbox rollout undo deployment/checkout"
parses "markdown bold and backticks (a real model's habit)" "I used the runbook.\\n**SUGGESTED_FIX:** \`kubectl -n sandbox rollout undo deployment/checkout\`" \
  "kubectl -n sandbox rollout undo deployment/checkout"
parses "lower case and a shell prompt" "suggested_fix: \$ kubectl -n shop rollout restart deployment/leaky  " \
  "kubectl -n shop rollout restart deployment/leaky"
parses "the last SUGGESTED_FIX line wins" "SUGGESTED_FIX: kubectl -n prod delete deployment/checkout\\nSUGGESTED_FIX: kubectl -n sandbox rollout undo deployment/checkout" \
  "kubectl -n sandbox rollout undo deployment/checkout"
# A parsed suggestion still has to pass the allow-list.
fix="$(parse "**SUGGESTED_FIX:** \`kubectl -n sandbox rollout undo deployment/checkout --to-revision=1\`")"
if bash "${REPO_ROOT}/scripts/approve-fix.sh" --check "${fix}" >/dev/null 2>&1; then bad "a suggestion with extra flags is refused by the allow-list"; else ok "a suggestion with extra flags is refused by the allow-list"; fi
if bash "${REPO_ROOT}/scripts/approve-fix.sh" --check "" >/dev/null 2>&1; then bad "an empty command is refused by the allow-list"; else ok "an empty command is refused by the allow-list"; fi
exit "${fails}"
