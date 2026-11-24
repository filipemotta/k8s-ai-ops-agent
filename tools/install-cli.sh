#!/usr/bin/env bash
# Downloads the pinned CLIs used by the lab into ./bin (gitignored), each one
# checked against the SHA-256 published with its release.
# Idempotent: a binary is only downloaded when missing or at another version.
# Usage: bash tools/install-cli.sh [kubectl] [kind] [helm] [promtool]
#        (no argument: all four; validate.sh installs only promtool)
# Supports darwin/linux on arm64/amd64. No sudo, nothing outside ./bin.
# Docker is the only prerequisite (kind runs the cluster in containers).
set -euo pipefail

KUBECTL_VERSION="v1.37.2"   # nodes run v1.37.0
KIND_VERSION="v0.33.0"
HELM_VERSION="v4.3.2"
# promtool, from the Prometheus release, for the alert rule unit tests.
# SHA-256 pinned here (from the release's sha256sums.txt), not fetched.
PROMETHEUS_VERSION="3.16.0"
prometheus_sha256() {
  case "$1" in
    darwin-amd64) echo 998fb3301c1d77452bdfc481f61353e2e4a3b16c97a6b725c2b7beee5464c8c2 ;;
    darwin-arm64) echo f7c71b553316f822bdd860a3ea527ebefb2f8e944e5b7dfd419ae2653cf3ba01 ;;
    linux-amd64)  echo 68727009472a2c02e1ff7f062fd5b3e637285bffc8fc2d340c76fb449d6e0f34 ;;
    linux-arm64)  echo fd8571b8162f4020232d886f17340bcf92e1722985ae3b4c1d096157826c0fbe ;;
  esac
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO_ROOT}/bin"
mkdir -p "${BIN}"

case "$(uname -s)" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux" ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="amd64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

have_version() { # $1 binary, $2 expected substring of the version output, rest: version args
  local out
  [ -x "${BIN}/$1" ] || return 1
  out="$("${BIN}/$1" "${@:3}" 2>/dev/null)" || return 1
  [[ "${out}" == *"$2"* ]]
}
TOOLS=" ${*:-kubectl kind helm promtool} "
wants() { [[ "${TOOLS}" == *" $1 "* ]]; }
sha256_of() { local s; s="$(shasum -a 256 "$1" 2>/dev/null || sha256sum "$1")"; printf '%s' "${s%% *}"; }
# check_sha <file> <expected sha256> <name>
check_sha() {
  local got
  got="$(sha256_of "$1")"
  if [ -z "$2" ] || [ "$2" != "${got}" ]; then
    echo "$3: checksum mismatch (want ${2:-none}, got ${got})" >&2
    exit 1
  fi
}

if ! wants kubectl; then
  :
elif have_version kubectl "${KUBECTL_VERSION}" version --client; then
  echo "kubectl ${KUBECTL_VERSION} already in bin/"
else
  echo "downloading kubectl ${KUBECTL_VERSION} (${OS}/${ARCH})"
  tmp="$(mktemp -d)"
  base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}"
  curl -sSfL "${base}/kubectl" -o "${tmp}/kubectl"
  check_sha "${tmp}/kubectl" "$(curl -sSfL "${base}/kubectl.sha256" | awk '{ print $1 }')" kubectl
  mv "${tmp}/kubectl" "${BIN}/kubectl"
  chmod +x "${BIN}/kubectl"
  rm -rf "${tmp}"
fi

if ! wants kind; then
  :
elif have_version kind "${KIND_VERSION} " version; then
  echo "kind ${KIND_VERSION} already in bin/"
else
  echo "downloading kind ${KIND_VERSION} (${OS}-${ARCH})"
  tmp="$(mktemp -d)"
  base="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}"
  curl -sSfL "${base}/kind-${OS}-${ARCH}" -o "${tmp}/kind"
  check_sha "${tmp}/kind" "$(curl -sSfL "${base}/kind-${OS}-${ARCH}.sha256sum" | awk '{ print $1 }')" kind
  mv "${tmp}/kind" "${BIN}/kind"
  chmod +x "${BIN}/kind"
  rm -rf "${tmp}"
fi

if ! wants helm; then
  :
elif have_version helm "${HELM_VERSION}" version --short; then
  echo "helm ${HELM_VERSION} already in bin/"
else
  echo "downloading helm ${HELM_VERSION} (${OS}-${ARCH})"
  tmp="$(mktemp -d)"
  pkg="helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  curl -sSfL "https://get.helm.sh/${pkg}" -o "${tmp}/${pkg}"
  check_sha "${tmp}/${pkg}" "$(curl -sSfL "https://get.helm.sh/${pkg}.sha256sum" | awk '{ print $1 }')" helm
  tar -xzf "${tmp}/${pkg}" -C "${tmp}" "${OS}-${ARCH}/helm"
  mv "${tmp}/${OS}-${ARCH}/helm" "${BIN}/helm"
  chmod +x "${BIN}/helm"
  rm -rf "${tmp}"
fi

if ! wants promtool; then
  :
elif have_version promtool "version ${PROMETHEUS_VERSION} " --version; then
  echo "promtool ${PROMETHEUS_VERSION} already in bin/"
else
  echo "downloading promtool ${PROMETHEUS_VERSION} (${OS}-${ARCH})"
  tmp="$(mktemp -d)"
  dir="prometheus-${PROMETHEUS_VERSION}.${OS}-${ARCH}"
  curl -sSfL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/${dir}.tar.gz" -o "${tmp}/${dir}.tar.gz"
  check_sha "${tmp}/${dir}.tar.gz" "$(prometheus_sha256 "${OS}-${ARCH}")" promtool
  tar -xzf "${tmp}/${dir}.tar.gz" -C "${tmp}" "${dir}/promtool"
  mv "${tmp}/${dir}/promtool" "${BIN}/promtool"
  chmod +x "${BIN}/promtool"
  rm -rf "${tmp}"
fi

echo "binaries in ${BIN}:"
if wants kubectl; then "${BIN}/kubectl" version --client | sed -n 1p; fi
if wants kind; then "${BIN}/kind" version; fi
if wants helm; then "${BIN}/helm" version --short; fi
if wants promtool; then "${BIN}/promtool" --version | sed -n 1p; fi
