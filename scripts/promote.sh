#!/usr/bin/env bash
# Rehearse in the sandbox, then promote:
#
#   bash scripts/promote.sh rehearse/checkout-<version>.yaml
#
# Applies the release to prod only if
#   1. sandbox runs exactly that version,
#   2. the agent's check of THAT rollout passed: the newest HealthCheck created
#      by the TriggeredHealthCheck checkout-rollout after the sandbox's newest
#      ReplicaSet (the rollout) is Completed with result "pass", and
#   3. the sandbox rollout finished.
# No verdict yet, or a NO-GO, and prod is left alone. It runs as the on-call
# engineer, like approve-fix.sh; the agent itself cannot write anywhere.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

release="${1:?usage: promote.sh rehearse/checkout-<version>.yaml}"
version="$(sed -n 's/^ *app.kubernetes.io\/version: "\(.*\)"$/\1/p' "${release}" | head -1)"
[ -n "${version}" ] || { echo "no app.kubernetes.io/version label in ${release}" >&2; exit 2; }

running="$(as_oncall -n sandbox get deploy checkout -o jsonpath='{.spec.template.metadata.labels.app\.kubernetes\.io/version}')"
if [ "${running}" != "${version}" ]; then
  echo "refused: sandbox runs ${running:-nothing}, not ${version}: rehearse it there first" >&2
  exit 4
fi
rollout_at="$(as_oncall -n sandbox get rs -l "app=checkout,app.kubernetes.io/version=${version}" \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.creationTimestamp}')"
verdict="$(as_oncall -n sandbox get healthchecks -l holmesgpt.dev/triggered-by=checkout-rollout -o json \
  | jq -r --arg t "${rollout_at}" '[.items[] | select(.metadata.creationTimestamp >= $t)]
      | sort_by(.metadata.creationTimestamp) | last
      | if . == null then "none" else "\(.metadata.name) \(.status.phase // "Pending") \(.status.result // "none")" end')"
echo "sandbox rollout of ${version} at ${rollout_at}; agent verdict: ${verdict}"
read -r hc phase result _ <<< "${verdict} - - -"
if [ "${hc}" = none ] || [ "${phase}" != Completed ]; then
  echo "refused: no finished verdict on the sandbox rollout of ${version} yet" >&2
  exit 4
fi
if [ "${result}" != pass ]; then
  echo "refused: the agent's verdict on ${version} in sandbox is '${result}' (sandbox/${hc}), not pass" >&2
  exit 4
fi

# Finished means every replica runs the new template and the old ones are
# gone: readyReplicas alone would count the old pod that keeps serving.
if ! progress="$(as_oncall -n sandbox rollout status deploy/checkout --watch=false 2>&1)" \
  || ! grep -q 'successfully rolled out' <<< "${progress}"; then
  echo "refused: the sandbox rollout of ${version} has not finished (${progress})" >&2
  exit 4
fi

echo "promoting ${version} to prod (verdict sandbox/${hc}: pass)"
echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') promoted checkout ${version} to prod on verdict sandbox/${hc}" >> "${OUT}/approvals.log"
as_oncall -n prod apply -f "${release}"
as_oncall -n prod rollout status deploy/checkout --timeout=180s
