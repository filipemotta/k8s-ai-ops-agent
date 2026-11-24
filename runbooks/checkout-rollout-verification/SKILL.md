---
description: Verify a rollout of checkout in the sandbox namespace and answer GO or NO-GO for production
---

## Goal

Decide whether the release of checkout just rolled out in sandbox can go to
production: GO only if the new pods run, are ready and log no errors.

## Workflow

1. List the checkout pods in sandbox with their version label
   (`app.kubernetes.io/version`): which versions run, which are ready.
2. For any pod of the new version that is not Running and Ready, read its logs.
3. Check that the previous version is still serving while the new one fails
   (maxUnavailable 0 keeps it up).

## Synthesize Findings

- Every pod of the new version Running and Ready, no errors: GO.
- Any pod of the new version crashing or not ready: NO-GO, with the crash
  reason from its logs.

## Recommended Remediation Steps

- NO-GO: restore the previous version (needs human approval):
  `kubectl -n sandbox rollout undo deployment/checkout`
- GO: promote with `scripts/promote.sh`, which checks this verdict again.
