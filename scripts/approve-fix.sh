#!/usr/bin/env bash
# Act with approval: the agent suggests, a human applies.
#
#   bash scripts/approve-fix.sh <namespace>/<healthcheck>
#       Reads the agent's verdict from the HealthCheck status, extracts the
#       line "SUGGESTED_FIX: <command>", checks the command against a short
#       allow-list of remediations, shows it and applies it only if a human
#       approves: APPROVE=yes in the environment, or "yes" typed at the prompt.
#       It runs with the on-call engineer's identity, never the agent's.
#   bash scripts/approve-fix.sh --check '<command>'
#       Only the allow-list check (used by the tests).
#   bash scripts/approve-fix.sh --parse < rationale.txt
#       Only the extraction of the suggestion (used by the tests).
#   bash scripts/approve-fix.sh --human '<command>'
#       The on-call engineer's own command instead of the agent's (when the
#       agent suggested nothing approvable): same allow-list, same approval.
#
# Fails closed: no suggestion, an empty one, "none", or one that does not
# match the allow-list exactly, and nothing runs.
#
# The suggestion is text written by a model that reads attacker-controlled
# data, so it is never evaluated by a shell: it must match one of the
# patterns below exactly, and only the parsed namespace and Deployment name are
# passed to kubectl.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The remediations a human may approve from a suggestion. Anything else is
# refused, whatever the model wrote.
ALLOWED='^kubectl -n ([a-z0-9][a-z0-9-]{0,62}) rollout (undo|restart) deployment/([a-z0-9][a-z0-9-]{0,62})$'

check() {
  if [[ "$1" =~ ${ALLOWED} ]]; then
    echo "allowed: namespace=${BASH_REMATCH[1]} action=rollout ${BASH_REMATCH[2]} deployment=${BASH_REMATCH[3]}"
  else
    echo "refused: not an approvable remediation: $1" >&2
    return 2
  fi
}

case "${1:-}" in
  --check)
    check "${2:-}"
    exit $? ;;
  --parse)
    fix="$(suggested_fix)"
    if [ -z "${fix}" ]; then echo "refused: no SUGGESTED_FIX line with a command in the verdict" >&2; exit 2; fi
    printf '%s\n' "${fix}"
    exit 0 ;;
esac

usage="usage: approve-fix.sh <namespace>/<healthcheck> | --human '<command>' | --check '<command>' | --parse"
ref="${1:?${usage}}"
assert_lab_context
if [ "${ref}" = --human ]; then
  fix="${2:-}"
  ns="human" hc="on-call"
  echo "the on-call engineer's own command (not the agent's)"
else
  ns="${ref%%/*}"
  hc="${ref#*/}"
  rationale="$(as_oncall -n "${ns}" get healthcheck "${hc}" -o jsonpath='{.status.rationale}')"
  result="$(as_oncall -n "${ns}" get healthcheck "${hc}" -o jsonpath='{.status.result}')"
  echo "agent verdict for ${ns}/${hc}: ${result:-none}"
  fix="$(suggested_fix <<< "${rationale}")"
fi
if [ -z "${fix}" ]; then
  echo "refused: no command to approve (the verdict has no usable SUGGESTED_FIX line); nothing was run" >&2
  exit 2
fi
echo "suggested fix: ${fix}"
check "${fix}" >/dev/null
[[ "${fix}" =~ ${ALLOWED} ]]
target_ns="${BASH_REMATCH[1]}" action="${BASH_REMATCH[2]}" deploy="${BASH_REMATCH[3]}"

if [ "${APPROVE:-}" != yes ]; then
  if [ -t 0 ]; then
    read -r -p "Apply it as oncall@example.com? Type yes to approve: " answer
  else
    answer=""
  fi
  if [ "${answer}" != yes ]; then
    echo "not approved: nothing was changed" >&2
    exit 3
  fi
fi

echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') approved by oncall@example.com: ${fix} (from ${ns}/${hc})" >> "${OUT}/approvals.log"
as_oncall -n "${target_ns}" rollout "${action}" "deployment/${deploy}"
# Right after an undo the Deployment can still carry the failed release's
# ProgressDeadlineExceeded condition, which "rollout status" reports as an
# error until the controller catches up: poll instead.
deadline=$((SECONDS + 180))
until as_oncall -n "${target_ns}" rollout status "deployment/${deploy}" --watch=false 2>/dev/null | grep -q 'successfully rolled out'; do
  if [ "${SECONDS}" -ge "${deadline}" ]; then
    echo "the ${action} of ${target_ns}/${deploy} did not finish in 180s" >&2
    exit 1
  fi
  sleep 3
done
echo "deployment ${target_ns}/${deploy}: ${action} finished"
