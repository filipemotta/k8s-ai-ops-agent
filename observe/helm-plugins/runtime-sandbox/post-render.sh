#!/usr/bin/env bash
# Helm post-renderer: reads the rendered manifests on stdin, writes them back
# on stdout with runtime-patch.yaml applied to every Deployment.
# Needs kubectl (for its built-in Kustomize) in PATH.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cat > "${work}/rendered.yaml"
cp "${here}/runtime-patch.yaml" "${work}/runtime-patch.yaml"
cat > "${work}/kustomization.yaml" <<'KUSTOMIZATION'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- rendered.yaml
patches:
- path: runtime-patch.yaml
  target:
    group: apps
    version: v1
    kind: Deployment
KUSTOMIZATION
kubectl kustomize "${work}"
