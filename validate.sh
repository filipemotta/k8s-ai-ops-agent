#!/usr/bin/env bash
# Standard static validation for this repository.
# Run it from the root of the repository. It detects which artifact types are
# present and runs the right validator for each.
# Exits non-zero if any validation fails.
set -uo pipefail

FAILURES=0
fail()  { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }
ok()    { echo "  [ok] $1"; }
skip()  { echo "  [skipped] $1 (missing tool: install with 'brew install $2')"; }
run()   { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }

echo "== validate.sh — $(date '+%Y-%m-%d %H:%M') =="

# --- Shell scripts ---
while IFS= read -r s; do
  [ -n "$s" ] || continue
  run "bash -n $s" bash -n "$s"
  if command -v shellcheck >/dev/null; then
    run "shellcheck $s" shellcheck "$s"
  else skip "shellcheck $s" shellcheck; fi
done < <(find . -name '*.sh' -not -path './.terraform/*' -not -path './out/*' -not -path './bin/*' | sort)

# --- Terraform ---
if find . -name '*.tf' -not -path './.terraform/*' | grep -q .; then
  if command -v terraform >/dev/null; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if (cd "$d" \
        && terraform fmt -check >/dev/null \
        && terraform init -backend=false -input=false >/dev/null \
        && terraform validate >/dev/null); then
        ok "terraform fmt+init+validate in $d"
      else fail "terraform in $d"; fi
    done < <(find . -name '*.tf' -not -path './.terraform/*' -exec dirname {} \; | sort -u)
  else skip "terraform" terraform; fi
fi

# --- Kubernetes YAML ---
k8s_files=()
while IFS= read -r f; do k8s_files+=("$f"); done \
  < <(grep -rlE '^(apiVersion|kind):' --include='*.yaml' --include='*.yml' --exclude-dir=out --exclude-dir=bin . 2>/dev/null \
      | grep -v '/helm-plugins/' | sort)  # Helm plugin manifests have an apiVersion but are not Kubernetes objects
if [ "${#k8s_files[@]}" -gt 0 ]; then
  if command -v kubeconform >/dev/null; then
    # -ignore-missing-schemas: third-party CRDs (Karpenter etc.) validate fields against official docs
    run "kubeconform (${#k8s_files[@]} files)" \
      kubeconform -strict -summary -ignore-missing-schemas "${k8s_files[@]}"
  else skip "kubeconform" kubeconform; fi
fi

# --- Helm ---
while IFS= read -r chart; do
  [ -n "$chart" ] || continue
  if command -v helm >/dev/null; then
    run "helm lint $chart" helm lint "$chart"
    run "helm template $chart" helm template "$chart"
  else skip "helm $chart" helm; fi
done < <(find . -name Chart.yaml -exec dirname {} \; | sort)

# --- Repository-specific checks ---
# Python stand-ins and bridge: syntax, then the scripted LLM's own tests.
run "python syntax (lab/, predict/, tools/)" python3 -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' \
  lab/fake-llm/server.py lab/receiver/server.py predict/alert-bridge/bridge.py tools/test-fake-llm.py tools/test-bridge.py tools/llm_usage.py
run "fake LLM scenarios (offline self-test)" python3 tools/test-fake-llm.py
run "alert bridge input checks (offline)" python3 tools/test-bridge.py
run "token usage parser (offline self-test)" python3 tools/llm_usage.py --self-test
# The approval allow-list: the fixes it must accept and the ones it must refuse.
run "approve-fix allow-list accepts a rollout undo" bash scripts/approve-fix.sh --check 'kubectl -n sandbox rollout undo deployment/checkout'
# shellcheck disable=SC2016 # the $(id) must reach the check unexpanded
for bad in 'kubectl delete namespace prod' 'kubectl -n sandbox rollout undo deployment/checkout; kubectl delete ns prod' \
           'kubectl -n sandbox rollout undo deployment/$(id)' 'kubectl -n sandbox scale deployment/checkout --replicas=0'; do
  if bash scripts/approve-fix.sh --check "${bad}" >/dev/null 2>&1; then fail "approve-fix allow-list refuses: ${bad}"; else ok "approve-fix allow-list refuses: ${bad}"; fi
done
run "approve-fix reads markdown, refuses empty or missing suggestions" bash tools/test-approve-fix.sh
# Alert rule: promtool (pinned, checksum-verified into bin/) check + unit tests + mutation.
run "alert rule (promtool check, unit tests, mutation)" bash -c 'bash tools/install-cli.sh promtool >/dev/null && bash tools/test-rules.sh'
# Runbooks: every alert links one that exists, each is a mounted skill with the
# four sections; the self-test first proves the check catches broken links.
run "runbooks (tools/test-runbooks.sh --self-test)" bash tools/test-runbooks.sh --self-test
# The agent never gets a NetworkPolicy to the whole internet: only the egress
# proxy's own policy may name 0.0.0.0/0, and only with the private ranges cut out.
wide="$(grep -rlE 'cidr: *0\.0\.0\.0/0' --include='*.yaml' --exclude-dir=out --exclude-dir=bin . | grep -v '^./observe/egress-proxy.yaml$' || true)"
if [ -n "${wide}" ]; then fail "a NetworkPolicy with cidr 0.0.0.0/0 outside the egress proxy: ${wide}"; else ok "no NetworkPolicy with cidr 0.0.0.0/0 outside the egress proxy"; fi
if grep -A8 'cidr: 0.0.0.0/0' observe/egress-proxy.yaml | grep -q -- '- 10.0.0.0/8' \
  && grep -A8 'cidr: 0.0.0.0/0' observe/egress-proxy.yaml | grep -q -- '- 169.254.0.0/16'; then
  ok "egress proxy: private and link-local ranges excluded"
else fail "egress proxy: 0.0.0.0/0 without the private and link-local exceptions"; fi
if grep -q 'acl allowed_hosts dstdomain -n ' observe/egress-proxy.yaml && grep -q 'http_access deny ip_literal' observe/egress-proxy.yaml; then
  ok "egress proxy: names matched without reverse DNS, IP literals refused"
else fail "egress proxy: dstdomain without -n, or IP literals not refused"; fi
# The chart as the lab installs it: post-renderer, RBAC, Bedrock values.
run "holmes chart rendered with the post-renderer (tools/test-render.sh)" bash tools/test-render.sh

echo "== result: $FAILURES failure(s) =="
[ "$FAILURES" -eq 0 ]
