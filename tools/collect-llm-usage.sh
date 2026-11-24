#!/usr/bin/env bash
# Cost evidence of a real-model run (LLM_MODE=bedrock): the token usage of
# every model call, attributed to the health check it belonged to, from the
# Holmes server's logs (LOG_LLM_USAGE_RESPONSE=true, JSON logs) and the
# HealthChecks' run times. Writes out/llm-usage.jsonl and
# out/llm-usage-by-check.txt; also out/healthcheck-notifications.json (where
# each verdict was delivered). No prompt, no answer, no credential is saved.
# Run it while the cluster is up: scripts/test-all.sh does, before the teardown.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
assert_lab_context

logs="${OUT}/holmes-usage-source.log"
: > "${logs}"
# The previous container's log too, if Holmes restarted during the run.
k -n "${HOLMES_NS}" logs "deploy/${HOLMES_DEPLOY}" -c holmes --previous 2>/dev/null | grep -F 'LLM usage response' >> "${logs}" || true
k -n "${HOLMES_NS}" logs "deploy/${HOLMES_DEPLOY}" -c holmes 2>/dev/null | grep -F 'LLM usage response' >> "${logs}" || true
k get healthchecks -A -o json > "${OUT}/healthchecks.json"
k get healthchecks -A -o json | jq '[.items[] | {check: "\(.metadata.namespace)/\(.metadata.name)",
  result: .status.result, model: .status.modelUsed, duration: .status.duration, notifications: .status.notifications}]' \
  > "${OUT}/healthcheck-notifications.json"
python3 "${REPO_ROOT}/tools/llm_usage.py" "${logs}" "${OUT}/healthchecks.json" "${OUT}"
calls="$(wc -l < "${OUT}/llm-usage.jsonl" | tr -d ' ')"
if [ "${calls}" = 0 ]; then
  echo "no 'LLM usage response' line in the Holmes logs: is LOG_LLM_USAGE_RESPONSE set (LLM_MODE=bedrock)?" >&2
  exit 1
fi
echo "usage of ${calls} model calls in out/llm-usage.jsonl and out/llm-usage-by-check.txt"
