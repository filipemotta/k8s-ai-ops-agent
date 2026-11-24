#!/usr/bin/env bash
# Tests the alert rule offline: extracts the spec of predict/prometheusrule.yaml
# into a plain Prometheus rule file, runs promtool check rules and the unit
# tests in predict/prometheusrule.test.yaml. Then checks that the tests can
# fail: with the horizon of predict_linear cut to 60s the leaking case must no
# longer fire, and with "for" shorter than the window a startup ramp must.
# Needs bin/promtool (bash tools/install-cli.sh promtool) or promtool in PATH.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMTOOL="${REPO_ROOT}/bin/promtool"
[ -x "${PROMTOOL}" ] || PROMTOOL="$(command -v promtool)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The PrometheusRule's spec is the rule file: everything under "spec:",
# one indentation level less.
sed -n '/^spec:/,$p' "${REPO_ROOT}/predict/prometheusrule.yaml" | tail -n +2 | sed 's/^  //' > "${work}/memory-trend.rules.yaml"
cp "${REPO_ROOT}/predict/prometheusrule.test.yaml" "${work}/"

"${PROMTOOL}" check rules "${work}/memory-trend.rules.yaml"
(cd "${work}" && "${PROMTOOL}" test rules prometheusrule.test.yaml)

# Mutation: a 60s horizon only sees 24 MiB ahead, never above the limit.
sed -i.bak 's/\[2m\], 600)/[2m], 60)/' "${work}/memory-trend.rules.yaml"
grep -q '\[2m\], 60)' "${work}/memory-trend.rules.yaml"
if (cd "${work}" && "${PROMTOOL}" test rules prometheusrule.test.yaml >/dev/null 2>&1); then
  echo "mutation survived: the unit tests pass with a 60s horizon" >&2
  exit 1
fi
echo "mutation (60s horizon) caught by the unit tests"

# Mutation: "for" back to 1m (shorter than the 2m window) lets a startup ramp
# fire, the false positive of the first real-model run.
sed -n '/^spec:/,$p' "${REPO_ROOT}/predict/prometheusrule.yaml" | tail -n +2 | sed 's/^  //' > "${work}/memory-trend.rules.yaml"
awk '/alert: ContainerMemoryWillHitLimit/ { a = 1 } a && /^ *for: 3m$/ { sub(/3m/, "1m"); a = 0 } { print }' \
  "${work}/memory-trend.rules.yaml" > "${work}/m.yaml" && mv "${work}/m.yaml" "${work}/memory-trend.rules.yaml"
grep -q 'for: 1m' "${work}/memory-trend.rules.yaml"
if (cd "${work}" && "${PROMTOOL}" test rules prometheusrule.test.yaml >/dev/null 2>&1); then
  echo "mutation survived: the unit tests pass with for: 1m on ContainerMemoryWillHitLimit" >&2
  exit 1
fi
echo "mutation (for: 1m, shorter than the window) caught by the unit tests"
