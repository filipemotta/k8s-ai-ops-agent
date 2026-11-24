#!/usr/bin/env bash
# Renders the HolmesGPT chart (pinned, checksum-verified) offline, the way the
# lab installs it, and checks what the article claims about it:
#   - with the post-renderer plugin, both Deployments get runtimeClassName gvisor;
#   - without it, none does (the chart has no value for it);
#   - the chart's ClusterRole only uses get/list/watch and names no secrets;
#   - the Bedrock values render the documented model and keep the security context.
# Needs the network once (chart download into out/); no cluster.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
bash "${REPO_ROOT}/tools/install-cli.sh" kubectl helm >/dev/null
chart="$(holmes_chart)"
fail=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (expected $2, got $3)"; fi; }

with="$(helm template "${HOLMES_RELEASE}" "${chart}" -n "${HOLMES_NS}" -f "${REPO_ROOT}/observe/holmes-values.yaml" -f "${REPO_ROOT}/observe/holmes-values-fake.yaml" --post-renderer runtime-sandbox)"
without="$(helm template "${HOLMES_RELEASE}" "${chart}" -n "${HOLMES_NS}" -f "${REPO_ROOT}/observe/holmes-values.yaml" -f "${REPO_ROOT}/observe/holmes-values-fake.yaml")"
bedrock="$(helm template "${HOLMES_RELEASE}" "${chart}" -n "${HOLMES_NS}" -f "${REPO_ROOT}/observe/holmes-values.yaml" \
  -f "${REPO_ROOT}/observe/holmes-values-bedrock.yaml" --post-renderer runtime-sandbox)"
printf '%s\n' "${with}" > "${OUT}/rendered-holmes.yaml"

# Bedrock mode must not carry the scripted model: Holmes resolves every
# modelList entry at start and crashes on the fake one's missing env vars.
eq "Bedrock render: no lab-fake model entry" "0" "$(grep -c 'lab-fake' <<< "${bedrock}" || true)"
eq "Bedrock render: bedrock-opus model with an STS session token" "1" "$(grep -c 'aws_session_token' <<< "${bedrock}")"
eq "Deployments rendered" "2" "$(grep -c '^kind: Deployment$' <<< "${with}")"
eq "runtimeClassName gvisor with the post-renderer" "2" "$(grep -c 'runtimeClassName: gvisor' <<< "${with}")"
eq "runtimeClassName without the post-renderer" "0" "$(grep -c 'runtimeClassName' <<< "${without}" || true)"
eq "readOnlyRootFilesystem forced by the chart" "true" "$(grep -m1 -o 'readOnlyRootFilesystem: true' <<< "${with}" | awk '{ print $2 }')"
# doc_in <rendered> <kind> <name> / doc <kind> <name>: one document of a rendered output
doc_in() { awk -v k="kind: $2" -v n="  name: $3" 'BEGIN { RS = "\n---\n" } index($0, "\n" k "\n") || index($0, k "\n") == 1 { if (index($0, "\n" n "\n")) print }' <<< "$1"; }
doc() { awk -v k="kind: $1" -v n="  name: $2" 'BEGIN { RS = "\n---\n" } index($0, "\n" k "\n") || index($0, k "\n") == 1 { if (index($0, "\n" n "\n")) print }' <<< "${with}"; }
holmes_deploy="$(doc Deployment holmes-holmes)"
eq "Holmes pod: runAsNonRoot and uid 10001 from the values" "true 10001" \
  "$(grep -m1 -o 'runAsNonRoot: true' <<< "${holmes_deploy}" | awk '{ print $2 }') $(grep -m1 -o 'runAsUser: 10001' <<< "${holmes_deploy}" | awk '{ print $2 }')"
role="$(doc ClusterRole holmes-holmes-cluster-role)"
eq "the Holmes ClusterRole found" "1" "$(grep -c '^kind: ClusterRole$' <<< "${role}")"
eq "ClusterRole verbs" "get list watch" "$(grep -E '^ *- (get|list|watch|create|update|patch|delete|deletecollection|"\*"|\*|escalate|bind|impersonate)$' <<< "${role}" | awk '{ print $2 }' | sort -u | paste -sd' ' -)"
eq "ClusterRole names secrets" "0" "$(grep -cE '^ *- secrets$' <<< "${role}" || true)"
eq "Holmes pod: dnsPolicy None (the agent resolver only)" "1" "$(grep -c 'dnsPolicy: None' <<< "${holmes_deploy}")"
eq "Holmes pod: nameserver 10.96.53.53" "1" "$(grep -c -- '- 10.96.53.53' <<< "${holmes_deploy}")"
eq "Holmes pod: HTTPS_PROXY is the egress proxy" "1" "$(grep -A1 'name: HTTPS_PROXY' <<< "${holmes_deploy}" | grep -c 'egress-proxy.egress-proxy.svc.cluster.local:3128')"
eq "Bedrock values: the proxy variables are kept" "2" "$(grep -cE 'name: (HTTPS_PROXY|NO_PROXY)$' <<< "$(doc_in "${bedrock}" Deployment holmes-holmes)")"
eq "Bedrock: model" "bedrock/us.anthropic.claude-opus-5-5" "$(sed -n 's/^ *model: \(bedrock\/.*\)$/\1/p' <<< "${bedrock}")"
eq "Bedrock: token usage logged per call, in JSON logs" "true true" \
  "$(grep -A1 'name: LOG_LLM_USAGE_RESPONSE' <<< "${bedrock}" | sed -n 's/.*value: "\{0,1\}\([a-z]*\)"\{0,1\}$/\1/p' | head -1) $(grep -A1 'name: ENABLE_JSON_LOGS_FORMAT' <<< "${bedrock}" | sed -n 's/.*value: "\{0,1\}\([a-z]*\)"\{0,1\}$/\1/p' | head -1)"
eq "default mode: no usage logging (scripted model)" "0" "$(grep -c 'name: LOG_LLM_USAGE_RESPONSE' <<< "${with}" || true)"
eq "Bedrock: keys come from the holmes-aws Secret" "1" "$(grep -c 'name: holmes-aws' <<< "${bedrock}")"
eq "Bedrock: still on gVisor" "2" "$(grep -c 'runtimeClassName: gvisor' <<< "${bedrock}")"
if command -v kubeconform >/dev/null; then
  if kubeconform -strict -summary -ignore-missing-schemas "${OUT}/rendered-holmes.yaml" >/dev/null; then ok "kubeconform on the rendered chart"; else bad "kubeconform on the rendered chart"; fi
fi
exit "${fail}"
