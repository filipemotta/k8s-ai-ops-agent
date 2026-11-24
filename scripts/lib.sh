#!/usr/bin/env bash
# Shared helpers sourced by the lab scripts. Not meant to be run directly.
# shellcheck shell=bash
# The variables below are read by the scripts that source this file.
# shellcheck disable=SC2034

# Decimal point and plain messages whatever the operator's locale.
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/out"
mkdir -p "${OUT}"
export REPO_ROOT OUT
export PATH="${REPO_ROOT}/bin:${PATH}"

CLUSTER_NAME="aiops"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
K8S_VERSION="v1.37.0"
export CLUSTER_NAME KUBE_CONTEXT K8S_VERSION

# --- pinned dependencies --------------------------------------------------------
# HolmesGPT chart from the Robusta Helm repository, checked against the digest
# published in the repository index.
HOLMES_CHART_VERSION="0.47.0"
HOLMES_CHART_URL="https://robusta-charts.storage.googleapis.com/holmes-${HOLMES_CHART_VERSION}.tgz"
HOLMES_CHART_SHA256="02e03ada837d8fef8b57684e77022103a7ab03ad6f74211866b9b6f94eba620a"
KPS_CHART_VERSION="93.9.0"
KPS_CHART_URL="https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-${KPS_CHART_VERSION}/kube-prometheus-stack-${KPS_CHART_VERSION}.tgz"
KPS_CHART_SHA256="b45d041d3f97c645c13dabc5d54af4cb1409644317b81eb2490be20cb2d6e718"
GVISOR_RELEASE="20261116"       # gVisor release-20261116.0
export HOLMES_CHART_VERSION KPS_CHART_VERSION GVISOR_RELEASE

# Names the scripts and the manifests share.
HOLMES_NS="holmes"
HOLMES_RELEASE="holmes"
HOLMES_SA="holmes-holmes-service-account"  # created by the chart
HOLMES_DEPLOY="holmes-holmes"
OPERATOR_DEPLOY="holmes-operator"
export HOLMES_NS HOLMES_RELEASE HOLMES_SA HOLMES_DEPLOY OPERATOR_DEPLOY

# LLM_MODE=fake (default): the scripted OpenAI-compatible stand-in in lab/fake-llm,
# no paid call, deterministic answers. LLM_MODE=bedrock: Amazon Bedrock (see the
# README), never used in CI. Assertions on the stand-in's transcript only run
# in fake mode.
LLM_MODE="${LLM_MODE:-fake}"
export LLM_MODE

# The lab never reads or writes your ~/.kube/config: it has its own.
export KUBECONFIG="${OUT}/kubeconfig"
# Helm and the CLIs never consult your Docker credential helper (it can hang a
# non-interactive shell): empty registry and Docker configs of their own.
HELM_REGISTRY_CONFIG="${OUT}/helm-registry.json"
DOCKER_CONFIG="${OUT}/docker-config"
HELM_CACHE_HOME="${OUT}/helm-cache"
HELM_CONFIG_HOME="${OUT}/helm-config"
HELM_DATA_HOME="${OUT}/helm-data"
# Helm 4 post-renderers are plugins; the lab's own plugin lives in the repo.
HELM_PLUGINS="${REPO_ROOT}/observe/helm-plugins"
mkdir -p "${DOCKER_CONFIG}" "${HELM_CACHE_HOME}" "${HELM_CONFIG_HOME}" "${HELM_DATA_HOME}"
[ -f "${HELM_REGISTRY_CONFIG}" ] || echo '{}' > "${HELM_REGISTRY_CONFIG}"
[ -f "${DOCKER_CONFIG}/config.json" ] || echo '{}' > "${DOCKER_CONFIG}/config.json"
export HELM_REGISTRY_CONFIG DOCKER_CONFIG HELM_CACHE_HOME HELM_CONFIG_HOME HELM_DATA_HOME HELM_PLUGINS

# Safety: every kubectl and helm call passes the context explicitly, and the
# lab refuses to run if that context does not point at a local kind API server.
assert_lab_context() {
  local cluster server
  cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${KUBE_CONTEXT}\")].context.cluster}" 2>/dev/null || true)"
  server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${cluster}\")].cluster.server}" 2>/dev/null || true)"
  if [ -z "${cluster}" ] || [[ ! "${server}" =~ ^https://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
    echo "refusing to run: context ${KUBE_CONTEXT} is missing or does not point at a local kind API server (server='${server}')" >&2
    exit 3
  fi
}

k() { kubectl --context "${KUBE_CONTEXT}" "$@"; }
h() { helm --kube-context "${KUBE_CONTEXT}" "$@"; }

# The agent's identity, and the human on call who may apply a fix.
AS_AGENT=(--as "system:serviceaccount:${HOLMES_NS}:${HOLMES_SA}")
AS_ONCALL=(--as oncall@example.com --as-group sre-oncall)
as_agent()  { k "${AS_AGENT[@]}" "$@"; }
as_oncall() { k "${AS_ONCALL[@]}" "$@"; }

ensure_clis() { bash "${REPO_ROOT}/tools/install-cli.sh" kubectl kind helm promtool >/dev/null; }

sha256_of() { local s; s="$(shasum -a 256 "$1" 2>/dev/null || sha256sum "$1")"; printf '%s' "${s%% *}"; }
sha512_of() { local s; s="$(shasum -a 512 "$1" 2>/dev/null || sha512sum "$1")"; printf '%s' "${s%% *}"; }
# fetch <url> <sha256> <dest>: download once into out/, verify, reuse after.
fetch() {
  local url="$1" want="$2" dest="$3"
  if [ ! -f "${dest}" ] || [ "$(sha256_of "${dest}")" != "${want}" ]; then
    curl -sSfL "${url}" -o "${dest}.tmp"
    if [ "$(sha256_of "${dest}.tmp")" != "${want}" ]; then
      echo "checksum mismatch for ${url} (want ${want}, got $(sha256_of "${dest}.tmp"))" >&2
      rm -f "${dest}.tmp"
      exit 1
    fi
    mv "${dest}.tmp" "${dest}"
  fi
}
holmes_chart() { fetch "${HOLMES_CHART_URL}" "${HOLMES_CHART_SHA256}" "${OUT}/holmes-${HOLMES_CHART_VERSION}.tgz"; printf '%s' "${OUT}/holmes-${HOLMES_CHART_VERSION}.tgz"; }
kps_chart() { fetch "${KPS_CHART_URL}" "${KPS_CHART_SHA256}" "${OUT}/kube-prometheus-stack-${KPS_CHART_VERSION}.tgz"; printf '%s' "${OUT}/kube-prometheus-stack-${KPS_CHART_VERSION}.tgz"; }

# holmes_values -> the -f arguments of the agent's Helm release for LLM_MODE
holmes_values() {
  printf '%s\n' -f "${REPO_ROOT}/observe/holmes-values.yaml"
  if [ "${LLM_MODE}" = bedrock ]; then
    printf '%s\n' -f "${REPO_ROOT}/observe/holmes-values-bedrock.yaml"
  else
    printf '%s\n' -f "${REPO_ROOT}/observe/holmes-values-fake.yaml"
  fi
}

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
show() { sed 's/^/      /'; }

# --- assertions: failures are counted, the script exits non-zero at the end ---
PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }

# expect_eq <description> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then pass "$1 (got $3)"; else fail "$1 (expected $2, got $3)"; fi
}
# expect_match <description> <extended regex> <actual>
expect_match() {
  if grep -Eq -- "$2" <<< "$3"; then pass "$1"; else fail "$1 (no match for /$2/ in: $(head -c 600 <<< "$3"))"; fi
}
# expect_no_match <description> <extended regex> <actual>
expect_no_match() {
  if grep -Eq -- "$2" <<< "$3"; then fail "$1 (unexpected /$2/ in: $(grep -E -- "$2" <<< "$3" | head -c 600))"; else pass "$1"; fi
}
# expect_ge <description> <minimum> <actual integer>
expect_ge() {
  if [[ "$3" =~ ^-?[0-9]+$ ]] && [ "$3" -ge "$2" ]; then pass "$1 (got $3, minimum $2)"; else fail "$1 (got $3, minimum $2)"; fi
}
# expect_le <description> <maximum> <actual integer>
expect_le() {
  if [[ "$3" =~ ^-?[0-9]+$ ]] && [ "$3" -le "$2" ]; then pass "$1 (got $3, maximum $2)"; else fail "$1 (got $3, maximum $2)"; fi
}

# refused <description> <regex the error must match> <command...>
# The command must FAIL and its output must say why (Forbidden, denied...).
refused() {
  local desc="$1" why="$2" out rc
  shift 2
  out="$("$@" 2>&1)" && rc=0 || rc=$?
  if [ "${rc}" -ne 0 ] && grep -Eq -- "${why}" <<< "${out}"; then
    pass "${desc}"
    note "  -> ...$(grep -E -- "${why}" <<< "${out}" | head -1 | tail -c 200)"
  elif [ "${rc}" -eq 0 ]; then
    fail "${desc} (the command SUCCEEDED: $(head -c 300 <<< "${out}"))"
  else
    fail "${desc} (failed, but not with /${why}/: $(head -c 400 <<< "${out}"))"
  fi
}
# allowed <description> <command...>: the command must succeed.
allowed() {
  local desc="$1" out
  shift
  if out="$("$@" 2>&1)"; then pass "${desc}"; else fail "${desc} ($(head -c 400 <<< "${out}"))"; fi
}

finish() {
  printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
  printf '%s %s %s\n' "$(basename "$0" .sh)" "${PASSED}" "${FAILED}" >> "${OUT}/assertions.txt"
  [ "${FAILED}" -eq 0 ]
}

# wait_until <seconds> <command...>: re-runs the command every 3s until it
# exits 0. Returns 1 on timeout.
wait_until() {
  local deadline=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    [ "${SECONDS}" -lt "${deadline}" ] || { note "timeout: $*"; return 1; }
    sleep 3
  done
}
# wait_for <seconds> <expected> <command...>: re-runs the command every 3s
# until its output equals <expected>. Returns 1 on timeout.
wait_for() {
  local deadline=$((SECONDS + $1)) expected="$2"; shift 2
  until [ "$("$@" 2>/dev/null)" = "${expected}" ]; do
    [ "${SECONDS}" -lt "${deadline}" ] || { note "timeout (${expected}): $*"; return 1; }
    sleep 3
  done
}

apply_file() {
  note "kubectl apply -f ${1#"${REPO_ROOT}"/}"
  k apply -f "$1" >/dev/null
}

# --- the lab's stand-ins ----------------------------------------------------------
# lab_get <namespace> <deployment> <path>: GET on the stand-in's own port from
# inside its pod (python3 is in the image), so no NetworkPolicy is involved.
lab_get() {
  k -n "$1" exec "deploy/$2" -- python3 -c \
    'import sys, urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080" + sys.argv[1], timeout=10).read().decode())' "$3"
}
# transcript -> every request the fake LLM received, as JSON (lab/fake-llm)
transcript() { lab_get lab-llm fake-llm /lab/transcript; }
# received -> every webhook the receiver got, as JSON (lab/receiver)
received() { lab_get lab-receiver receiver /lab/received; }
# collected -> every request the attacker's collector got, as JSON
collected() { lab_get attacker collector /lab/received; }

# probe <namespace> <deployment> <url> -> "<http code>" or "timeout" or
# "refused" or "error:<reason>" for one DIRECT request from that pod (python3
# is in every image of the lab, curl is not). The probe ignores HTTPS_PROXY:
# it tests what the network lets through, not what the proxy allows. A
# NetworkPolicy deny drops the SYN: the client sees a timeout. The probe only measures reachability and sends
# nothing secret, so it does not verify TLS certificates (the API server's is
# signed by the cluster's own CA).
PROBE_PY='
import socket, ssl, sys, urllib.error, urllib.request
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))
try:
    r = opener.open(sys.argv[1], timeout=5)
    print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except (socket.timeout, TimeoutError):
    print("timeout")
except urllib.error.URLError as e:
    reason = e.reason
    if isinstance(reason, (socket.timeout, TimeoutError)) or "timed out" in str(reason):
        print("timeout")
    elif isinstance(reason, ConnectionRefusedError):
        print("refused")
    else:
        print("error:" + type(reason).__name__)
'
probe() {
  k -n "$1" exec "deploy/$2" -c "${4:-$2}" -- python3 -c "${PROBE_PY}" "$3" 2>/dev/null || echo "exec-failed"
}

# hc_field <namespace> <healthcheck> <jsonpath>
hc_field() { k -n "$1" get healthcheck "$2" -o jsonpath="$3" 2>/dev/null; }
# wait_hc_done <namespace> <healthcheck> <seconds>: until status.phase is
# Completed or Failed.
wait_hc_done() {
  local deadline=$((SECONDS + $3)) phase
  while :; do
    phase="$(hc_field "$1" "$2" '{.status.phase}')"
    case "${phase}" in Completed|Failed) return 0 ;; esac
    [ "${SECONDS}" -lt "${deadline}" ] || { note "timeout waiting for HealthCheck $1/$2 (phase '${phase}')"; return 1; }
    sleep 3
  done
}

# prom <promql> -> the query's JSON result, through the API server's service
# proxy (no port-forward, no NetworkPolicy on the way).
prom() {
  k get --raw "/api/v1/namespaces/monitoring/services/http:kps-prometheus:9090/proxy/api/v1/query?query=$(jq -rn --arg q "$1" '$q | @uri')"
}
# prom_value <promql> -> the first sample's value, or "none"
prom_value() { prom "$1" | jq -r '.data.result[0].value[1] // "none"'; }

# Optional: MCP_KUBECONFIG=/path writes a copy of the lab's kubeconfig (the
# kind context only) there, for a read-only Kubernetes MCP server or any other
# tool that should see the lab and nothing else. Unset by default (CI). The
# teardown does not delete the file (a tool reading it may refuse to start
# without it): it puts back an offline placeholder with no credentials. It
# never writes your default kubeconfig.
mcp_path_ok() {
  case "${MCP_KUBECONFIG}" in
    */.kube/config) echo "refusing MCP_KUBECONFIG=${MCP_KUBECONFIG}: never the default kubeconfig" >&2; return 1 ;;
  esac
}
write_mcp_kubeconfig() {
  [ -n "${MCP_KUBECONFIG:-}" ] || return 0
  mcp_path_ok || return 1
  mkdir -p "$(dirname "${MCP_KUBECONFIG}")"
  ( umask 077; kind get kubeconfig --name "${CLUSTER_NAME}" > "${MCP_KUBECONFIG}" )
  chmod 600 "${MCP_KUBECONFIG}"
  note "kubeconfig of the lab (context ${KUBE_CONTEXT} only) also written to ${MCP_KUBECONFIG}"
}
MCP_PLACEHOLDER='apiVersion: v1
kind: Config
clusters:
- name: kind-lab-offline
  cluster:
    server: https://127.0.0.1:1
contexts:
- name: kind-lab-offline
  context:
    cluster: kind-lab-offline
    user: none
current-context: kind-lab-offline
users:
- name: none
  user: {}'
restore_mcp_kubeconfig() {
  [ -n "${MCP_KUBECONFIG:-}" ] || return 0
  mcp_path_ok || return 0
  mkdir -p "$(dirname "${MCP_KUBECONFIG}")"
  ( umask 077; printf '%s\n' "${MCP_PLACEHOLDER}" > "${MCP_KUBECONFIG}" )
  chmod 600 "${MCP_KUBECONFIG}"
}

# dns_query <namespace> <deployment> <server ip> <name> -> the DNS response
# code (NOERROR, NXDOMAIN, SERVFAIL, REFUSED...) with the answer count, or
# "timeout", for one A query sent straight to <server ip>:53 over UDP from
# that pod, whatever its resolv.conf says.
DNS_PY='
import random, socket, struct, sys
server, name = sys.argv[1], sys.argv[2]
qid = random.randint(0, 65535)
q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
q += b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(4)
try:
    s.sendto(q, (server, 53))
    r = s.recv(512)
except (socket.timeout, TimeoutError):
    print("timeout"); sys.exit()
rcode = r[3] & 15
names = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}
print(names.get(rcode, str(rcode)), struct.unpack(">H", r[6:8])[0])
'
dns_query() {
  k -n "$1" exec "deploy/$2" -c "${5:-$2}" -- python3 -c "${DNS_PY}" "$3" "$4" 2>/dev/null || echo "exec-failed"
}
# resolve_in <namespace> <deployment> <name> [container] -> the addresses the
# pod's own resolver (resolv.conf) returns, or "unresolved: <error>"
RESOLVE_PY='
import socket, sys
try:
    print(" ".join(sorted({a[4][0] for a in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)})))
except OSError as e:
    print("unresolved: " + type(e).__name__)
'
resolve_in() {
  k -n "$1" exec "deploy/$2" -c "${4:-$2}" -- python3 -c "${RESOLVE_PY}" "$3" 2>/dev/null || echo "exec-failed"
}

# render_apiserver <manifest> <output>: the manifest with the placeholder
# 192.0.2.10 replaced by the cluster's API server endpoint (a NetworkPolicy can
# only name the API server by IP).
render_apiserver() {
  local ip
  ip="$(k -n default get endpointslices -l kubernetes.io/service-name=kubernetes -o jsonpath='{.items[0].endpoints[0].addresses[0]}')"
  sed "s#192.0.2.10/32#${ip}/32#" "$1" > "$2"
}

# The bearer token Alertmanager sends to the alert bridge: random, generated
# the first time the lab runs, kept in out/ (gitignored), never in the repo.
bridge_token() {
  local f="${OUT}/alert-bridge.token"
  [ -s "${f}" ] || ( umask 077; python3 -c 'import secrets; print(secrets.token_hex(32))' > "${f}" )
  cat "${f}"
}

# bridge_post <path> <Authorization header or ""> <json> -> the HTTP status
# on the first line, the body on the second: one POST to the alert bridge from
# inside its own pod.
bridge_post() {
  k -n alert-bridge exec deploy/alert-bridge -- python3 -c '
import sys, urllib.error, urllib.request
headers = {"Content-Type": "application/json"}
if sys.argv[2]:
    headers["Authorization"] = sys.argv[2]
req = urllib.request.Request("http://127.0.0.1:8080" + sys.argv[1], data=sys.argv[3].encode(), headers=headers, method="POST")
try:
    r = urllib.request.urlopen(req, timeout=15)
    print(r.status); print(r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code); print(e.read().decode())' "$1" "$2" "$3"
}

# --- optional real Slack ----------------------------------------------------------
# On when a bot token is given, as SLACK_TOKEN or as a file (SLACK_TOKEN_FILE),
# together with SLACK_CHANNEL ("#k8s-ai-agent"). The token is never printed and
# never passed on a command line.
slack_enabled() { [ -n "${SLACK_TOKEN:-}" ] || [ -n "${SLACK_TOKEN_FILE:-}" ]; }
check_slack_config() {
  slack_enabled || return 0
  if [[ ! "${SLACK_CHANNEL:-}" =~ ^#[a-z0-9][a-z0-9._-]{0,79}$ ]]; then
    echo "Slack mode needs SLACK_CHANNEL, a channel name like #k8s-ai-agent (got '${SLACK_CHANNEL:-}')" >&2
    exit 2
  fi
  if [ -n "${SLACK_TOKEN_FILE:-}" ] && [ ! -r "${SLACK_TOKEN_FILE}" ]; then
    echo "SLACK_TOKEN_FILE=${SLACK_TOKEN_FILE} is not readable" >&2
    exit 2
  fi
}
# write_slack_token <file>: the token, without its trailing newline, into a
# 0600 file (printf is a shell builtin: the value never shows in ps).
write_slack_token() {
  ( umask 077
    if [ -n "${SLACK_TOKEN_FILE:-}" ]; then tr -d '\r\n' < "${SLACK_TOKEN_FILE}" > "$1"
    else printf '%s' "${SLACK_TOKEN}" > "$1"; fi )
  chmod 600 "$1"
}
slack_destination() { jq -cn --arg ch "${SLACK_CHANNEL}" '{type: "slack", config: {channel: $ch}}'; }
# apply_with_destinations <manifest>: applies a HealthCheck or TriggeredHealthCheck;
# in Slack mode with a Slack destination added next to the webhook. The file
# in the repository is not changed.
apply_with_destinations() {
  if slack_enabled; then
    note "kubectl apply -f ${1#"${REPO_ROOT}"/} (+ Slack destination ${SLACK_CHANNEL})"
    k create --dry-run=client -f "$1" -o json \
      | jq --argjson d "$(slack_destination)" '.spec.destinations += [$d]' | k apply -f - >/dev/null
  else
    apply_file "$1"
  fi
}

# suggested_fix: the agent's suggestion, from a rationale on stdin. Takes the
# last line that carries "SUGGESTED_FIX:" (any case), drops markdown (**, `,
# a leading "$ "), trims it. Prints nothing when there is no such line, when
# it is empty, or when it says none: callers must treat empty as "no
# suggestion" and refuse (approve-fix.sh does), never run it.
suggested_fix() {
  grep -i 'SUGGESTED_FIX' | tail -1 | sed -E 's/[*`]//g; s/^.*[Ss][Uu][Gg][Gg][Ee][Ss][Tt][Ee][Dd]_[Ff][Ii][Xx][[:space:]]*:[[:space:]]*//; s/^\$[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -viE '^(none|n/a|-)?$' || true
}

# Assertions on what the agent wrote. The scripted model's wording is exact,
# a real model's is not: expect_scripted checks the exact text only with the
# scripted model (LLM_MODE=fake) and reports [n/a] otherwise; expect_mentions
# checks, in every mode, that a word appears (any case, markdown removed).
expect_scripted() {
  if [ "${LLM_MODE}" = fake ]; then expect_match "$@"; else note "[n/a]  $1 (exact wording of the scripted model)"; fi
}
expect_mentions() {
  if tr -d '*`' <<< "$3" | grep -Fqi -- "$2"; then pass "$1"; else fail "$1 (no '$2' in: $(head -c 400 <<< "$3"))"; fi
}
