#!/usr/bin/env bash
# Act 4: act with approval. The agent suggested "rollout undo" for the broken
# release in sandbox. It cannot apply it; a human reads the suggestion, the
# script checks it against a short allow-list, and the human applies it with
# their own identity. Then the fixed release 1.5.1 is rehearsed and promoted:
# not before the agent's verdict, and only on a GO.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

sk() { k -n sandbox "$@"; }
version_in() { k -n "$1" get deploy checkout -o jsonpath='{.spec.template.metadata.labels.app\.kubernetes\.io/version}'; }
triggered_hcs() { sk get healthchecks -l holmesgpt.dev/triggered-by=checkout-rollout --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}'; }
hc="$(cat "${OUT}/rehearse-nogo-hc.txt")"
fix="$(hc_field sandbox "${hc}" '{.status.rationale}' | suggested_fix)"
note "the agent's suggestion (sandbox/${hc}): ${fix:-<none>}"
: > "${OUT}/approvals.log"
# What the runbook prescribes for a NO-GO (runbooks/checkout-rollout-verification).
RUNBOOK_FIX="kubectl -n sandbox rollout undo deployment/checkout"
if [ -n "${fix}" ]; then
  pass "the agent's verdict carries a suggestion (SUGGESTED_FIX)"
else
  # Fail closed: an empty suggestion is never turned into a command.
  fail "the agent's verdict carries a suggestion (SUGGESTED_FIX): none or unparseable"
fi
approvable=no
if [ -n "${fix}" ] && bash "${REPO_ROOT}/scripts/approve-fix.sh" --check "${fix}" >/dev/null 2>&1; then approvable=yes; fi

step "the agent cannot apply a fix itself"
# Always a concrete write, never the parsed suggestion: an empty or odd
# suggestion must not turn this test into "kubectl <nothing>".
refused "as the agent: ${RUNBOOK_FIX}" 'cannot (patch|get) resource "(deployments|replicasets)"' \
  as_agent -n sandbox rollout undo deployment/checkout

step "a suggestion is never run as written: allow-list of remediations"
if [ "${LLM_MODE}" = fake ]; then
  expect_match "allowed: ${fix}" '^allowed: namespace=sandbox action=rollout undo deployment=checkout$' \
    "$(bash "${REPO_ROOT}/scripts/approve-fix.sh" --check "${fix}")"
else
  note "[n/a]  the real model suggested: ${fix:-<none>}; allow-list says: $( { bash "${REPO_ROOT}/scripts/approve-fix.sh" --check "${fix}" 2>&1 || true; } | head -1)"
fi
refused "refused: an empty suggestion" 'not an approvable remediation' \
  bash "${REPO_ROOT}/scripts/approve-fix.sh" --check ''
refused "refused: kubectl delete namespace prod" 'not an approvable remediation' \
  bash "${REPO_ROOT}/scripts/approve-fix.sh" --check 'kubectl delete namespace prod'
refused "refused: a valid fix with a second command appended" 'not an approvable remediation' \
  bash "${REPO_ROOT}/scripts/approve-fix.sh" --check 'kubectl -n sandbox rollout undo deployment/checkout; kubectl delete ns prod'
# shellcheck disable=SC2016 # the $(id) must reach the check unexpanded
refused "refused: a valid fix with a command substitution" 'not an approvable remediation' \
  bash "${REPO_ROOT}/scripts/approve-fix.sh" --check 'kubectl -n sandbox rollout undo deployment/$(id)'

step "without a human's yes, nothing changes"
if [ "${approvable}" = yes ]; then
  refused "approve-fix.sh with no approval (no APPROVE=yes, no terminal)" 'not approved' \
    bash "${REPO_ROOT}/scripts/approve-fix.sh" "sandbox/${hc}" < /dev/null
else
  refused "approve-fix.sh on a suggestion that is missing or not approvable: refused, nothing run" 'refused' \
    bash "${REPO_ROOT}/scripts/approve-fix.sh" "sandbox/${hc}" < /dev/null
fi
expect_eq "sandbox still on the broken release" "1.5.0" "$(version_in sandbox)"

step "the on-call engineer approves: rollout undo, with their identity"
if [ "${approvable}" = yes ]; then
  APPROVE=yes bash "${REPO_ROOT}/scripts/approve-fix.sh" "sandbox/${hc}" | show
else
  # The agent's suggestion is not approvable: the engineer applies the
  # runbook's remediation with their own command, through the same allow-list.
  note "the agent's suggestion is not approvable; the on-call engineer runs the runbook's remediation"
  APPROVE=yes bash "${REPO_ROOT}/scripts/approve-fix.sh" --human "${RUNBOOK_FIX}" | show
fi
expect_eq "sandbox back on 1.4.0" "1.4.0" "$(version_in sandbox)"
expect_eq "sandbox ready" "1" "$(sk get deploy checkout -o jsonpath='{.status.readyReplicas}')"
# The 1.5.0 pod takes a few seconds to terminate after the undo.
crashing_pods() { sk get pods -l app=checkout --no-headers 2>/dev/null | grep -cE 'CrashLoopBackOff|Error' || true; }
wait_for 90 "0" crashing_pods || true
expect_eq "no crashing pod left in sandbox" "0" "$(crashing_pods)"
expect_match "the approval is on record" 'approved by oncall@example.com: kubectl -n sandbox rollout undo deployment/checkout' "$(cat "${OUT}/approvals.log")"

step "release 1.5.1 (PAYMENTS_URL restored) is rehearsed in sandbox"
as_oncall -n sandbox apply -f "${REPO_ROOT}/rehearse/checkout-1.5.1.yaml" >/dev/null
t0="${SECONDS}"
sk rollout status deploy/checkout --timeout=180s >/dev/null
expect_eq "sandbox runs 1.5.1, rollout finished" "1.5.1 1" "$(version_in sandbox) $(sk get deploy checkout -o jsonpath='{.status.updatedReplicas}')"
refused "promote before the agent's verdict" 'no finished verdict' \
  bash "${REPO_ROOT}/scripts/promote.sh" "${REPO_ROOT}/rehearse/checkout-1.5.1.yaml"
expect_eq "prod still on 1.4.0" "1.4.0" "$(version_in prod)"

# The rollback was a rollout too; applying 1.5.1 before its check was due
# replaced it, so the next check is the one for 1.5.1.
newest() { triggered_hcs | awk '{ print $NF }'; }
fresh_hc() { [ -n "$(newest)" ] && [ "$(newest)" != "${hc}" ]; }
wait_until 180 fresh_hc || true
go="$(newest)"
wait_hc_done sandbox "${go}" 240 || true
rationale="$(hc_field sandbox "${go}" '{.status.rationale}')"
printf '%s\n' "${rationale}" | show
expect_eq "verdict on 1.5.1" "pass" "$(hc_field sandbox "${go}" '{.status.result}')"
expect_scripted "GO" 'GO for production' "${rationale}"
expect_mentions "the GO verdict cites the rollout runbook" checkout-rollout-verification "${rationale}"
expect_eq "a GO is not sent to the destination (Holmes notifies on failure only)" "0" \
  "$(received | jq --arg c "sandbox/${go}" '[.[] | select(.body.check_name == $c)] | length')"
echo "rehearse go_after_rollout_s=$((SECONDS - t0))" >> "${OUT}/timings.txt"

step "promotion on a GO"
bash "${REPO_ROOT}/scripts/promote.sh" "${REPO_ROOT}/rehearse/checkout-1.5.1.yaml" | show
expect_eq "prod runs 1.5.1" "1.5.1" "$(version_in prod)"
expect_eq "prod ready" "1" "$(k -n prod get deploy checkout -o jsonpath='{.status.readyReplicas}')"
expect_eq "two human decisions on record (the fix, the promotion)" "2" "$(wc -l < "${OUT}/approvals.log" | tr -d ' ')"

step "the agent's footprint"
expect_eq "writes the agent made: none (every change above was the on-call identity)" "" \
  "$(as_agent auth can-i --list 2>/dev/null | awk 'NR > 1 && $NF ~ /(create|update|patch|delete|deletecollection|\*)/' \
      | grep -vE '^(selfsubjectreviews|selfsubjectaccessreviews|selfsubjectrulesreviews)' || true)"
if [ "${LLM_MODE}" = fake ]; then
  t="$(transcript)"
  echo "${t}" > "${OUT}/transcript-all.json"
  note "LLM calls in the whole lab: $(jq 'length' <<< "${t}"), by scenario: $(jq -c 'group_by(.scenario) | map({(.[0].scenario): length}) | add' <<< "${t}")"
  note "prompt size per call (estimate): min $(jq '[.[].prompt_tokens_estimate] | min' <<< "${t}"), max $(jq '[.[].prompt_tokens_estimate] | max' <<< "${t}") tokens"
  echo "rollout-go calls=$(jq '[.[] | select(.scenario == "rollout")] | length - 3' <<< "${t}") (after the NO-GO's 3)" >> "${OUT}/cost.txt"
  echo "lab total calls=$(jq 'length' <<< "${t}") prompt_tokens_estimate=$(jq '[.[].prompt_tokens_estimate] | add' <<< "${t}")" >> "${OUT}/cost.txt"
fi
finish
