---
description: A container's memory working set is trending to its memory limit (alert ContainerMemoryWillHitLimit, predict_linear); find out how long until an OOMKill and what to do before it happens
---

## Goal

Decide, before the kernel OOM-kills it, whether a container whose memory is
growing toward its limit is leaking, warming a cache, or simply undersized, and
how much time is left.

## Workflow

1. Confirm the alert is still firing: `ALERTS{alertname="ContainerMemoryWillHitLimit"}`
   for the pod and container in the alert.
2. Read the working set as a share of the limit:
   `container_memory_working_set_bytes / kube_pod_container_resource_limits{resource="memory"}`.
3. Read the growth rate and the time left at that rate:
   `(limit - working set) / deriv(container_memory_working_set_bytes[2m])`.
4. Check the pod: Ready, restart count, last termination reason (an earlier
   `OOMKilled` means this has happened before).
5. Read the container's recent logs for what it is accumulating.

## Synthesize Findings

- Straight-line growth with no plateau and no matching rise in traffic: a leak.
  It will be OOM-killed at the time computed in step 3.
- Growth that flattens: a cache or a warm-up. Not urgent if it plateaus under
  the limit.
- Already restarted with `OOMKilled`: the limit is too small or the leak is old.

## Recommended Remediation Steps

- Buy time with a restart (needs human approval):
  `kubectl -n <namespace> rollout restart deployment/<name>`
- Raise the memory limit only if the growth is legitimate.
- Open a bug for the leak with the growth rate and the time to OOM. A restart
  is not a fix.
