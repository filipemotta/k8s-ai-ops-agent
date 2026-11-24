---
description: A pod's container keeps crashing and restarting (alert KubePodCrashLooping, CrashLoopBackOff); find the crash reason and whether a rollout caused it
---

## Goal

Find why a container is in CrashLoopBackOff, whether a recent rollout
introduced it, and whether the previous version is still serving.

## Workflow

1. Get the pod's status, restart count and last termination reason and exit code.
2. Read the logs of the crashed container (`kubectl logs --previous` when the
   current one has not started).
3. Find the owning Deployment and compare the crashing pod's template
   (image, env, version label) with the previous ReplicaSet.
4. Check whether an older ReplicaSet still has ready pods serving traffic.

## Synthesize Findings

- Exit at start with a configuration error in the logs (a missing variable, a
  bad flag): the new template is broken; the rollout caused it.
- `OOMKilled`: memory, not code. Use the runbook container-memory-will-hit-limit.
- Crashes on a template that has not changed: a dependency or the node.

## Recommended Remediation Steps

- If a rollout caused it, roll back (needs human approval):
  `kubectl -n <namespace> rollout undo deployment/<name>`
- Fix the configuration in the manifest, then rehearse the release in sandbox again.
