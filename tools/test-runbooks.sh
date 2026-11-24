#!/usr/bin/env bash
# Every alert links a runbook that exists, every runbook is a valid Holmes
# skill with the four runbook sections, and the Helm values mount every one.
#   bash tools/test-runbooks.sh              checks the repository
#   bash tools/test-runbooks.sh --self-test  first proves the checks catch a
#                                            broken link, a missing section and
#                                            an unmounted runbook, on copies
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# check <root>: prints one line per problem, exits non-zero if any.
check() {
  local root="$1" problems=0 id url f section
  local rules="${root}/predict/prometheusrule.yaml" values="${root}/observe/holmes-values.yaml"
  local alerts urls
  alerts="$(grep -c '^ *- alert: ' "${rules}")"
  urls="$(grep -c '^ *runbook_url: ' "${rules}")"
  if [ "${alerts}" != "${urls}" ]; then echo "alerts: ${alerts}, runbook_url annotations: ${urls}"; problems=1; fi
  while read -r url; do
    id="$(sed -n 's#.*/runbooks/\([a-z0-9-]*\)/SKILL\.md$#\1#p' <<< "${url}")"
    if [ -z "${id}" ]; then echo "runbook_url not of the form .../runbooks/<id>/SKILL.md: ${url}"; problems=1; continue; fi
    [ -f "${root}/runbooks/${id}/SKILL.md" ] || { echo "runbook_url points to a missing runbook: ${id}"; problems=1; }
  done < <(sed -n 's/^ *runbook_url: *//p' "${rules}")
  id="$(sed -n 's/.*Runbook for this check: \([a-z0-9-]*\)\..*/\1/p' "${root}/rehearse/triggeredhealthcheck.yaml")"
  if [ -z "${id}" ] || [ ! -f "${root}/runbooks/${id}/SKILL.md" ]; then
    echo "the rollout check names no existing runbook (${id:-none})"; problems=1
  fi
  for f in "${root}"/runbooks/*/SKILL.md; do
    id="$(basename "$(dirname "${f}")")"
    [ "$(head -1 "${f}")" = "---" ] || { echo "${id}: no YAML frontmatter"; problems=1; }
    awk 'NR > 1 && /^---$/ { exit } NR > 1' "${f}" | grep -q '^description: ..' || { echo "${id}: no description in the frontmatter"; problems=1; }
    for section in "Goal" "Workflow" "Synthesize Findings" "Recommended Remediation Steps"; do
      grep -qx "## ${section}" "${f}" || { echo "${id}: no '## ${section}' section"; problems=1; }
    done
    if ! grep -q "key: ${id}.SKILL.md$" "${values}" || ! grep -q "path: ${id}/SKILL.md$" "${values}"; then
      echo "${id}: not mounted by observe/holmes-values.yaml"; problems=1
    fi
  done
  return "${problems}"
}

if [ "${1:-}" = --self-test ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' EXIT
  mutate() { # <name> <sed program> <file relative to the repo>
    rm -rf "${work}/r"; mkdir -p "${work}/r"
    cp -R "${REPO_ROOT}/predict" "${REPO_ROOT}/observe" "${REPO_ROOT}/rehearse" "${REPO_ROOT}/runbooks" "${work}/r/"
    sed -i.bak "$2" "${work}/r/$3"
    if check "${work}/r" >/dev/null; then echo "self-test: '$1' was NOT caught" >&2; exit 1; fi
    echo "self-test: '$1' caught"
  }
  mutate "runbook_url to a runbook that does not exist" 's#runbooks/pod-crash-looping/#runbooks/pod-crashloop/#' predict/prometheusrule.yaml
  mutate "an alert without runbook_url" '/runbook_url: .*container-memory/d' predict/prometheusrule.yaml
  mutate "a runbook without its Workflow" 's/^## Workflow$/## Steps/' runbooks/pod-crash-looping/SKILL.md
  mutate "a runbook not mounted into the agent" '/pod-crash-looping.SKILL.md$/d' observe/holmes-values.yaml
  mutate "the rollout check naming an unknown runbook" 's/Runbook for this check: checkout-rollout-verification/Runbook for this check: checkout-verify/' rehearse/triggeredhealthcheck.yaml
fi
check "${REPO_ROOT}"
echo "runbooks: every alert links an existing runbook, every runbook is a mounted skill with the four sections"
