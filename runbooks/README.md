# Runbooks

One directory per runbook, `<id>/SKILL.md`: the format HolmesGPT 0.26+ loads as a
skill (YAML frontmatter with a `description`, then Markdown). The body keeps the
four sections of a Holmes runbook: Goal, Workflow, Synthesize Findings,
Recommended Remediation Steps.

Every alert in `predict/prometheusrule.yaml` links its runbook in the
`runbook_url` annotation, and the rollout check in
`rehearse/triggeredhealthcheck.yaml` names its own. The alert bridge passes the
runbook id to the agent, which fetches it with the `fetch_skill` tool. The same
file is what the on-call engineer opens from the alert.

| Runbook | Used by |
|---|---|
| `container-memory-will-hit-limit` | alert `ContainerMemoryWillHitLimit` |
| `pod-crash-looping` | alert `KubePodCrashLooping` |
| `checkout-rollout-verification` | TriggeredHealthCheck `sandbox/checkout-rollout` |

`scripts/01-observe.sh` loads them into the ConfigMap `holmes/holmes-runbooks`,
mounted at `/etc/holmes/runbooks` (`observe/holmes-values.yaml`). After editing a
runbook, re-run that step: Holmes reads skill files from disk on every fetch.
