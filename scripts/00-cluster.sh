#!/usr/bin/env bash
# Step 0: the cluster the agent will live in.
#   kind v0.33.0, Kubernetes v1.37.0, one node, kindnet (enforces NetworkPolicy)
#   -> gVisor (runsc) in the node + RuntimeClass gvisor
#   -> kube-prometheus-stack 93.9.0, trimmed (Prometheus, Alertmanager, kube-state-metrics)
#   -> the lab's stand-ins: fake LLM, webhook receiver (Slack), attacker's collector
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ensure_clis

step "kind cluster ${CLUSTER_NAME} ($(kind version))"
if grep -qx "${CLUSTER_NAME}" <<< "$(kind get clusters 2>/dev/null)"; then
  note "already exists"
  kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null
else
  kind create cluster --config "${REPO_ROOT}/kind/cluster.yaml" --wait 180s
fi
assert_lab_context
write_mcp_kubeconfig
k get nodes -o wide | show

# install_gvisor <node container>: the gVisor release for the node's
# architecture, checked against its published SHA-512, into /usr/local/bin.
install_gvisor() {
  local node="$1" arch dir base
  arch="$(docker exec "${node}" uname -m)"
  dir="${OUT}/gvisor/${GVISOR_RELEASE}/${arch}"
  base="https://storage.googleapis.com/gvisor/releases/release/${GVISOR_RELEASE}/${arch}"
  if [ ! -x "${dir}/x/runsc" ]; then
    mkdir -p "${dir}/x"
    curl -sSfL "${base}/gvisor.tar.bz2" -o "${dir}/gvisor.tar.bz2"
    curl -sSfL "${base}/gvisor.tar.bz2.sha512" -o "${dir}/gvisor.tar.bz2.sha512"
    if [ "$(awk '{ print $1 }' "${dir}/gvisor.tar.bz2.sha512")" != "$(sha512_of "${dir}/gvisor.tar.bz2")" ]; then
      echo "gVisor ${GVISOR_RELEASE} ${arch}: checksum mismatch" >&2
      exit 1
    fi
    tar -xjf "${dir}/gvisor.tar.bz2" -C "${dir}/x"
  fi
  docker cp "${dir}/x/." "${node}:/usr/local/bin/"
  # The shim reads its options from the file named in the containerd config;
  # an empty [runsc_config] keeps runsc's defaults (platform systrap).
  docker exec "${node}" sh -c 'printf "[runsc_config]\n" > /etc/containerd/runsc.toml'
}

step "gVisor ${GVISOR_RELEASE} on the node"
install_gvisor "${CLUSTER_NAME}-control-plane"
apply_file "${REPO_ROOT}/platform/runtimeclass-gvisor.yaml"

step "kube-prometheus-stack ${KPS_CHART_VERSION} (trimmed)"
# Alertmanager authenticates to the alert bridge with a bearer token, random
# per lab run, mounted from this Secret (platform/kube-prometheus-stack-values.yaml).
k create namespace monitoring --dry-run=client -o yaml | k apply -f - >/dev/null
k -n monitoring create secret generic alert-bridge-token --from-literal=token="$(bridge_token)" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
h upgrade --install kps "$(kps_chart)" -n monitoring --create-namespace \
  -f "${REPO_ROOT}/platform/kube-prometheus-stack-values.yaml" --wait --timeout 10m >/dev/null
k -n monitoring rollout status statefulset/prometheus-kps-prometheus --timeout=300s >/dev/null
k -n monitoring rollout status statefulset/alertmanager-kps-alertmanager --timeout=300s >/dev/null
k -n monitoring get pods | show

step "the lab's stand-ins: fake LLM, webhook receiver, attacker's collector, allowed upstream"
apply_file "${REPO_ROOT}/lab/stand-ins.yaml"
k -n lab-llm create configmap fake-llm --from-file="${REPO_ROOT}/lab/fake-llm/server.py" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
for ns in lab-receiver attacker lab-upstream; do
  k -n "${ns}" create configmap receiver --from-file="${REPO_ROOT}/lab/receiver/server.py" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
done
k -n lab-llm rollout status deploy/fake-llm --timeout=300s >/dev/null
k -n lab-receiver rollout status deploy/receiver --timeout=300s >/dev/null
k -n attacker rollout status deploy/collector --timeout=300s >/dev/null
k -n lab-upstream rollout status deploy/allowed-upstream --timeout=300s >/dev/null

step "Checks"
expect_eq "Kubernetes server version" "${K8S_VERSION}" "$(k version -o json | jq -r .serverVersion.gitVersion)"
expect_eq "node Ready" "1" "$(k get nodes --no-headers | awk '$2 == "Ready"' | wc -l | tr -d ' ')"
expect_eq "runsc in the node" "runsc version release-${GVISOR_RELEASE}.0" \
  "$(docker exec "${CLUSTER_NAME}-control-plane" /usr/local/bin/runsc --version | head -1)"
expect_eq "RuntimeClass gvisor -> containerd handler" "runsc" "$(k get runtimeclass gvisor -o jsonpath='{.handler}')"
expect_eq "Prometheus ready" "1" "$(k -n monitoring get statefulset prometheus-kps-prometheus -o jsonpath='{.status.readyReplicas}')"
expect_eq "Alertmanager ready" "1" "$(k -n monitoring get statefulset alertmanager-kps-alertmanager -o jsonpath='{.status.readyReplicas}')"
expect_eq "no Grafana, no node-exporter" "0" "$(k -n monitoring get deploy,ds -o name | grep -cE 'grafana|node-exporter' || true)"
expect_match "fake LLM answers on /v1/models" '"lab-scripted"' "$(lab_get lab-llm fake-llm /v1/models)"
expect_eq "receiver empty" "[]" "$(received)"
expect_eq "collector empty" "[]" "$(collected)"
finish
