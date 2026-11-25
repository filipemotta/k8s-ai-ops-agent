#!/usr/bin/env bash
# Runs the whole lab from nothing, in the order of the article, and always
# tears it down at the end (also on failure or Ctrl-C), unless KEEP=1.
# Exits non-zero if any assertion of any step fails.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${DIR}/../out"
mkdir -p "${OUT}"
: > "${OUT}/assertions.txt"
: > "${OUT}/timings.txt"
: > "${OUT}/cost.txt"

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then
    echo "KEEP=1: the cluster is still running; remove it with: bash scripts/teardown.sh"
  else
    printf '\n######## teardown ########\n'
    bash "${DIR}/teardown.sh" || echo "teardown reported leftovers: check the output above"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

start="$(date +%s)"
failed=()
for s in 00-cluster 01-observe 02-predict 03-rehearse 04-act; do
  printf '\n######## %s ########\n' "${s}"
  t0="$(date +%s)"
  if ! bash "${DIR}/${s}.sh" 2>&1 | tee "${OUT}/step-${s}.log"; then
    failed+=("${s}")
    # A step that stopped half way never wrote its result: count what it
    # printed, plus one failure for the part that did not run.
    if ! grep -q "^${s} " "${OUT}/assertions.txt"; then
      echo "${s} $(grep -c '^ *\[PASS\]' "${OUT}/step-${s}.log") $(( $(grep -c '^ *\[FAIL\]' "${OUT}/step-${s}.log") + 1 ))" >> "${OUT}/assertions.txt"
      echo "    step ${s} stopped before its end"
    fi
    # Every later step needs the cluster from step 0 and the agent from step 1.
    case "${s}" in 00-cluster|01-observe) break ;; esac
  fi
  echo "step ${s}: $(( $(date +%s) - t0 ))s" | tee -a "${OUT}/timings.txt"
done

# With a real model, the token usage of every call, per check (the cluster is
# still up here; the teardown runs on exit).
if [ "${LLM_MODE:-fake}" = bedrock ]; then
  printf '\n######## model usage (cost evidence) ########\n'
  bash "${DIR}/../tools/collect-llm-usage.sh" || failed+=("collect-llm-usage")
fi

# The tool calls of the agent that failed (scripted model only), also when every
# step passed: the scripted model retries a failed pod list, and a retry must not
# hide the error. The injection scenario fails some on purpose.
if [ "${LLM_MODE:-fake}" = fake ]; then
  printf '\n######## failed tool calls seen by the scripted model ########\n'
  bash -c 'source "$1/lib.sh"; transcript' _ "${DIR}" 2>/dev/null |
    jq -r '[.[] | .scenario as $s | .tool_results_seen[] | select(test("tool_call_metadata=[^\n]*(Error:|fail:|Tool execution failed)")) | "  [\($s)] " + (gsub("\\s+"; " ") | .[0:600])] | unique | if length == 0 then "  none" else .[] end' ||
    echo "  transcript not available"
fi

printf '\n######## summary ########\n'
awk '{ p += $2; f += $3; printf "  %-14s %3d passed, %d failed\n", $1, $2, $3 }
     END { printf "  %-14s %3d passed, %d failed\n", "total", p, f }' "${OUT}/assertions.txt"
if [ -s "${OUT}/cost.txt" ]; then
  echo "LLM calls and prompt size per investigation (estimate):"
  sed 's/^/  /' "${OUT}/cost.txt"
fi
echo "duration: $(( $(date +%s) - start ))s (teardown not included)"
if [ "${#failed[@]}" -eq 0 ]; then
  echo "all steps passed"
else
  echo "failed steps: ${failed[*]}"
  exit 1
fi
