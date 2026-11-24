#!/usr/bin/env bash
# Removes everything the lab created: the kind cluster "aiops" (and with it
# every namespace, CRD, Helm release and the gVisor binaries copied into the
# node) and the lab's kubeconfig. Nothing else on the machine is touched.
# Exits non-zero if the cluster or its node container is still there.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "kind cluster ${CLUSTER_NAME}"
# On a loaded Docker Desktop a node container can take longer to exit than
# docker rm waits; it exits a few seconds later, so try again.
for attempt in 1 2 3; do
  kind delete cluster --name "${CLUSTER_NAME}" && break
  note "kind delete failed (attempt ${attempt}); retrying in 10s"
  sleep 10
done
rm -f "${KUBECONFIG}"
restore_mcp_kubeconfig

step "leftovers"
expect_eq "kind cluster ${CLUSTER_NAME} gone" "" "$(kind get clusters 2>/dev/null | grep -x "${CLUSTER_NAME}" || true)"
if [ -n "${MCP_KUBECONFIG:-}" ]; then
  expect_eq "${MCP_KUBECONFIG}: offline placeholder, no credentials" "kind-lab-offline 0" \
    "$(sed -n 's/^current-context: //p' "${MCP_KUBECONFIG}") $(grep -cE 'client-key-data|client-certificate-data|token:' "${MCP_KUBECONFIG}" || true)"
fi
expect_eq "no node containers left" "0" "$(docker ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" -q | wc -l | tr -d ' ')"
finish
