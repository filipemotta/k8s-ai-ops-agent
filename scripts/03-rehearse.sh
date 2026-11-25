#!/usr/bin/env bash
# Act 3: rehearse in a sandbox. checkout 1.4.0 runs in sandbox and prod. A
# TriggeredHealthCheck makes the agent look at every rollout in sandbox.
# Release 1.5.0 lands there first: its pods crash at start, the old pod keeps
# serving (so nothing looks down), the agent's verdict is NO-GO and reaches
# the destination, and the promotion to prod is refused.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

sk() { k -n sandbox "$@"; }
version_in() { k -n "$1" get deploy checkout -o jsonpath='{.spec.template.metadata.labels.app\.kubernetes\.io/version}'; }
# triggered_hcs -> the HealthChecks the rollout trigger created, oldest first
triggered_hcs() { sk get healthchecks -l holmesgpt.dev/triggered-by=checkout-rollout --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}'; }

step "sandbox and prod run checkout 1.4.0; the on-call group may change them, the agent may not"
apply_file "${REPO_ROOT}/rehearse/namespaces.yaml"
apply_file "${REPO_ROOT}/act/oncall-rbac.yaml"
for ns in sandbox prod; do
  as_oncall -n "${ns}" apply -f "${REPO_ROOT}/rehearse/checkout-1.4.0.yaml" >/dev/null
done
for ns in sandbox prod; do k -n "${ns}" rollout status deploy/checkout --timeout=180s >/dev/null; done
refused "the agent cannot roll out a release itself" 'cannot (patch|create) resource "deployments"' \
  as_agent -n sandbox apply -f "${REPO_ROOT}/rehearse/checkout-1.5.0.yaml"

step "every rollout in sandbox is investigated 45s later (TriggeredHealthCheck)"
apply_with_destinations "${REPO_ROOT}/rehearse/triggeredhealthcheck.yaml"
wait_until 60 sh -c "[ -n \"\$(kubectl --context ${KUBE_CONTEXT} -n sandbox get triggeredhealthcheck checkout-rollout -o jsonpath='{.status.conditions}')\" ]" || true
sk get triggeredhealthcheck checkout-rollout -o jsonpath='{.status.conditions}' | jq -c '.[]? | {type, status, reason}' | show
# The operator learns each Deployment's current pod template when it first
# sees it; only a later change is a rollout.
sleep 10
before="$(triggered_hcs)"
expect_eq "no check before the first rollout" "" "${before}"

step "release 1.5.0 lands in sandbox"
as_oncall -n sandbox apply -f "${REPO_ROOT}/rehearse/checkout-1.5.0.yaml" >/dev/null
t0="${SECONDS}"
crashing() { sk get pods -l app=checkout,app.kubernetes.io/version=1.5.0 --no-headers 2>/dev/null | grep -qE 'CrashLoopBackOff|Error'; }
wait_until 120 crashing || true
sk get pods -l app=checkout -L app.kubernetes.io/version | show
expect_eq "1.5.0 pods crash" "yes" "$(crashing && echo yes || echo no)"
expect_eq "the 1.4.0 pod keeps serving (ready replicas)" "1" "$(sk get deploy checkout -o jsonpath='{.status.readyReplicas}')"
expect_eq "prod untouched" "1.4.0" "$(version_in prod)"

step "the agent's verdict on the rollout"
has_triggered_hc() { [ -n "$(triggered_hcs)" ]; }
wait_until 180 has_triggered_hc || true
hc="$(triggered_hcs | awk '{ print $NF }')"
note "HealthCheck sandbox/${hc} created $((SECONDS - t0))s after the rollout"
wait_hc_done sandbox "${hc}" 240 || true
rationale="$(hc_field sandbox "${hc}" '{.status.rationale}')"
printf '%s\n' "${rationale}" | show
expect_eq "verdict" "fail" "$(hc_field sandbox "${hc}" '{.status.result}')"
expect_scripted "NO-GO, with the crash reason from the logs" 'NO-GO.*PAYMENTS_URL is not set' "${rationale}"
expect_mentions "the verdict names the crash reason (PAYMENTS_URL)" PAYMENTS_URL "${rationale}"
expect_scripted "the verdict cites the rollout runbook and its goal" '^Runbook: checkout-rollout-verification \(Decide whether the release of checkout' "${rationale}"
expect_mentions "the verdict names the rollout runbook" checkout-rollout-verification "${rationale}"
expect_scripted "a suggestion for a human" '^SUGGESTED_FIX: kubectl -n sandbox rollout undo deployment/checkout$' "${rationale}"
expect_match "a suggestion line a human can read (SUGGESTED_FIX: <command>)" '.' "$(suggested_fix <<< "${rationale}")"
expect_match "the operator gave the agent the rollout's context" 'triggered automatically by a Kubernetes Deployment rollout' \
  "$(sk get healthcheck "${hc}" -o jsonpath='{.spec.query}')"
dest="$(received | jq -c --arg c "sandbox/${hc}" '[.[] | select(.body.check_name == $c)]')"
expect_eq "NO-GO delivered to the destination" "1" "$(jq 'length' <<< "${dest}")"
expect_eq "destination payload: result" "fail" "$(jq -r '.[0].body.result' <<< "${dest}")"
echo "${hc}" > "${OUT}/rehearse-nogo-hc.txt"
echo "rehearse nogo_after_rollout_s=$((SECONDS - t0))" >> "${OUT}/timings.txt"

step "meanwhile, the classic alert: KubePodCrashLooping, with its own runbook"
crash_hc() { k -n "${HOLMES_NS}" get healthchecks -l agents.example.com/alertname=KubePodCrashLooping -o jsonpath='{.items[*].metadata.name}'; }
has_crash_hc() { [ -n "$(crash_hc)" ]; }
wait_until 300 has_crash_hc || true
chc="$(crash_hc | awk '{ print $1 }')"
note "HealthCheck created by the bridge: ${HOLMES_NS}/${chc} ($((SECONDS - t0))s after the rollout)"
wait_hc_done "${HOLMES_NS}" "${chc}" 240 || true
crationale="$(hc_field "${HOLMES_NS}" "${chc}" '{.status.rationale}')"
printf '%s\n' "${crationale}" | show
expect_eq "crash-loop verdict" "fail" "$(hc_field "${HOLMES_NS}" "${chc}" '{.status.result}')"
expect_match "the question names the crash-loop runbook" 'Runbook for this alert: pod-crash-looping\.' "$(hc_field "${HOLMES_NS}" "${chc}" '{.spec.query}')"
expect_scripted "the verdict cites the crash-loop runbook's goal" '^Runbook: pod-crash-looping \(Find why a container is in CrashLoopBackOff' "${crationale}"
expect_scripted "the crash-loop verdict read the pod and its log" 'is in CrashLoopBackOff; last log line: .*PAYMENTS_URL is not set' "${crationale}"
expect_scripted "the crash-loop verdict carries a suggestion" '^SUGGESTED_FIX: kubectl -n sandbox rollout undo deployment/checkout$' "${crationale}"
expect_mentions "the verdict names the crash-loop runbook" pod-crash-looping "${crationale}"
expect_no_match "... and not the memory one" '[Cc]ontainer-memory-will-hit-limit' "${crationale}"
expect_eq "crash-loop verdict delivered to the destination" "1" \
  "$(received | jq --arg c "${HOLMES_NS}/${chc}" '[.[] | select(.body.check_name == $c)] | length')"
if [ "${LLM_MODE}" = fake ]; then
  ct="$(transcript | jq -c '[.[] | select(.scenario == "alert" and (.question | contains("alert KubePodCrashLooping is firing")))] | .[-2:]')"
  echo "${ct}" > "${OUT}/transcript-crashloop.json"
  expect_eq "crash-loop investigation: fetch_skill pod-crash-looping, and no other" '["pod-crash-looping"]' \
    "$(jq -c '[.[].tool_calls[] | select(.name == "fetch_skill") | .arguments.skill_id]' <<< "${ct}")"
  expect_no_match "... the content it got is not the memory runbook" 'OOM-kills it, whether a container whose memory' "$(jq -r '.[1].tool_results_seen[0]' <<< "${ct}")"
  rt="$(transcript | jq -c '[.[] | select(.scenario == "rollout")]')"
  expect_eq "rollout investigation: fetch_skill checkout-rollout-verification, and no other" '["checkout-rollout-verification"]' \
    "$(jq -c '[.[].tool_calls[] | select(.name == "fetch_skill") | .arguments.skill_id]' <<< "${rt}")"
  echo "crashloop-alert calls=$(jq 'length' <<< "${ct}") prompt_tokens_estimate=$(jq '[.[].prompt_tokens_estimate] | add' <<< "${ct}")" >> "${OUT}/cost.txt"
fi

step "promotion to prod is refused"
refused "promote 1.5.0: refused on the agent's NO-GO" "verdict on 1.5.0 in sandbox is 'fail'" bash "${REPO_ROOT}/scripts/promote.sh" "${REPO_ROOT}/rehearse/checkout-1.5.0.yaml"
expect_eq "prod still runs 1.4.0" "1.4.0" "$(version_in prod)"

if [ "${LLM_MODE}" = fake ]; then
  t="$(transcript | jq -c '[.[] | select(.scenario == "rollout")]')"
  echo "${t}" > "${OUT}/transcript-rollout-nogo.json"
  expect_eq "LLM calls for this investigation" "3" "$(jq 'length' <<< "${t}")"
  echo "rollout-nogo calls=$(jq 'length' <<< "${t}") prompt_tokens_estimate=$(jq '[.[].prompt_tokens_estimate] | add' <<< "${t}")" >> "${OUT}/cost.txt"
fi
finish
