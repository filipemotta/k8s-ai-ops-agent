# An AI operations agent inside Kubernetes: the lab

Companion repository for the article on running an AI operations agent in a Kubernetes cluster. An agent like this runs commands a language model picks, after reading data an attacker can write: logs, events, annotations. This lab installs [HolmesGPT](https://github.com/HolmesGPT/holmesgpt) (CNCF Sandbox) as an untrusted tenant and proves, with assertions, each contract the article argues for: it reads a lot and writes nothing, it runs isolated (gVisor, closed egress, no Secrets), it runs on a signal (a `predict_linear` alert, a rollout rehearsed in a sandbox), it follows the team's runbook for each alert, a human applies its suggestions, and the number of model calls per investigation is measured.

| Script | Act | What it proves |
|---|---|---|
| `scripts/00-cluster.sh` | The cluster | kind with gVisor (`runsc`) in the node and a `gvisor` RuntimeClass; a trimmed kube-prometheus-stack (Prometheus, Alertmanager, kube-state-metrics); the lab's stand-ins (fake LLM, webhook receiver, an attacker's collector) |
| `scripts/01-observe.sh` | Observe, isolated | Admission refuses an agent pod that is not sandboxed: as root (Pod Security `restricted`), outside gVisor (a ValidatingAdmissionPolicy), or rendered without the post-renderer. HolmesGPT is installed with `runtimeClassName: gvisor` added by a Helm 4 post-renderer plugin (the chart has no value for it). Inside the pod, gVisor's kernel, uid 10001 and a read-only root filesystem. The chart's ClusterRole uses only `get`, `list` and `watch` and names no Secrets, and an `auth can-i` matrix confirms it. Egress reaches the API server, Prometheus, the LLM and the destination; the attacker's collector, other services and the internet get a dropped SYN. The only way out is an egress proxy (Squid) that tunnels HTTPS to a list of host names: a listed name passes, an unlisted one gets a 403 from the proxy, and going around the proxy is dropped. The agent can resolve only cluster names, through its own CoreDNS that refuses recursion, so it cannot leak data in DNS queries either. The lab also checks what `kubectl get ... --server=<other host>` does, a command the bash allow-list lets through. With `--server` alone, kubectl talks to that server without the in-cluster ServiceAccount token. Over plain HTTP it sent no Authorization header even with `--token=...` (HTTPS was not measured). From the agent, both routes out (the proxy and the direct path) are refused anyway. Then a prompt injection in a workload's logs: the scripted model obeys it and asks for five commands. The deny list blocks one, RBAC refuses another that slipped past the deny list's prefix match, and three need an approval nobody can give in a health check. Nothing reaches the collector |
| `scripts/02-predict.sh` | Predict | promtool unit tests for the `predict_linear` rule, including a mutation they must catch. A container leaks 24 MiB a minute toward a 192 MiB limit. The alert fires while the pod is Ready, with no restarts and at about half of its limit, minutes before the OOMKill; it waits 3 minutes (longer than its 2-minute window), so a container that just started and climbs to its working set does not trigger it. Alertmanager posts to a small bridge that creates one HealthCheck per alert (a re-delivery is a duplicate, not a second investigation). The alert's `runbook_url` names its runbook, and the agent fetches exactly that one (`fetch_skill`), queries Prometheus and sends its verdict, citing the runbook and suggesting a command, to the destination before anything broke |
| `scripts/03-rehearse.sh` | Rehearse in a sandbox | A TriggeredHealthCheck investigates every rollout in namespace `sandbox`. Release 1.5.0 crashes at start while the old pod keeps serving. The agent follows the rollout runbook and answers NO-GO, with the crash reason from the logs and a suggested `rollout undo`, and promotion to `prod` is refused. Meanwhile the classic `KubePodCrashLooping` alert fires on the same pods, and its investigation fetches the crash-loop runbook, not the memory one |
| `scripts/04-act.sh` | Act with approval | The agent cannot apply its own suggestion (RBAC). `approve-fix.sh` checks the suggestion against an allow-list of remediations (no second command, no substitutions), changes nothing without a human's yes, and applies it with the on-call identity. Release 1.5.1 is rehearsed; promoting it before the agent's verdict is refused, and on a GO it reaches `prod` |

## How the lab stands in for the LLM and for Slack

No paid model is called, in CI or by default. `lab/fake-llm/server.py` is an OpenAI-compatible endpoint that HolmesGPT uses through its openai-compatible provider (LiteLLM). Holmes, its tools, its RBAC, its sandbox and its network policy are all real; only the model's choices are scripted, selected by a tag in the question (`[lab:rollout]`, ignored by a real model). The script reads the tool results Holmes sends back, so the verdicts come from the cluster's real state: the rollout script, for example, lists the pods, reads the logs of a crashing one and answers NO-GO only if something crashes. The injection script is the worst case: it does whatever the logs tell it to do. `GET /lab/transcript` records every request, so the tests can assert which tool calls Holmes refused and how large each prompt was.

The destination is `lab/receiver/server.py`, a webhook receiver that stores what it gets. HolmesGPT's `webhook` destination posts the same verdict its `slack` destination would format for a channel.

## Runbooks

`runbooks/<id>/SKILL.md` holds one runbook per alert, in the four sections of a HolmesGPT runbook (Goal, Workflow, Synthesize Findings, Recommended Remediation Steps). Since HolmesGPT 0.26 runbooks are loaded as *skills*: a `SKILL.md` with a `description` in its frontmatter, read with the `fetch_skill` tool. The `custom_runbook_catalogs` and `catalog.json` of older versions are gone (see "Migrating from Runbooks" in HolmesGPT's `docs/reference/skills.md`). The lab mounts them from a ConfigMap through the chart's `customSkillPaths`.

Each alert's `runbook_url` points at its file, so the engineer who gets paged and the agent read the same procedure. In a health check, HolmesGPT does not put its skill catalog in the prompt, so the question has to say which runbook applies. The alert bridge takes the id from `runbook_url`, and the rollout check names it in its query. `tools/test-runbooks.sh` checks that every alert links a runbook that exists and is mounted, and the lab checks that each investigation fetched its own runbook and no other.

## Requirements

Docker (Docker Desktop on macOS, or Docker Engine on Linux) with about 3 GiB of memory free, plus `curl`, `jq`, `bash` and `python3`. Everything else is pinned and checked against a published SHA-256, either downloaded by `tools/install-cli.sh` into `./bin` or fetched by the scripts into `./out`:

- kubectl v1.37.2, kind v0.33.0, Helm v4.3.2, promtool from Prometheus 3.16.0
- Node image `kindest/node:v1.37.0` (pinned by digest, the default of kind v0.33.0); kindnet enforces NetworkPolicy
- gVisor release-20261116.0 (SHA-512 checked), installed into the kind node
- HolmesGPT chart `holmes` 0.47.0 (images `robustadev/holmes:0.47.0` and `robustadev/holmes-operator:0.47.0`, operator CRDs `holmesgpt.dev/v1alpha1`, alpha)
- kube-prometheus-stack 93.9.0 (Prometheus Operator v0.95.2, Prometheus v3.16.0)
- Egress proxy `ubuntu/squid:6.6-24.04_beta` and the agent's resolver `registry.k8s.io/coredns/coredns:v1.14.6` (both pinned by digest)
- `python:3.13-alpine` (pinned by digest) for the stand-ins and the demo workloads

Tested on macOS (Apple silicon, Docker Desktop with 5 CPUs and 8 GiB). `.github/workflows/lab.yml` runs the same lab on Linux amd64 in GitHub Actions.

## Run

```bash
bash scripts/test-all.sh
```

It creates the cluster, runs the five steps in order, prints a summary of the assertions and the model calls per investigation, and deletes the cluster at the end, also when a step fails or you press Ctrl-C. To keep the cluster, run `KEEP=1 bash scripts/test-all.sh` and remove it later with `bash scripts/teardown.sh`. The steps can also be run one by one, in order. Every run's evidence is in `out/`: the transcripts of the model calls, the tool results of the injection, the approvals log and the timings.

The lab never reads or writes your `~/.kube/config`. It has its own kubeconfig in `out/`, and every script refuses to run unless its context points at a kind API server on 127.0.0.1. To let another tool see the lab and nothing else (a read-only Kubernetes MCP server, for example), set `MCP_KUBECONFIG=/path/to/file`: step 0 writes the lab's kubeconfig there (kind context only, mode 600), and the teardown replaces it with an offline placeholder that has no credentials.

## Optional: real Slack and Amazon Bedrock

These modes call external services and are not used in CI. The agent never gets a route to the internet: in either mode `01-observe.sh` adds one host name to the egress proxy's allowlist (`observe/egress-allowlist.txt`), `slack.com` for Slack and `bedrock-runtime.us-east-1.amazonaws.com` for Bedrock, and the agent reaches it through the proxy (`HTTPS_PROXY`; the Slack SDK, botocore, LiteLLM and kubectl all honor it). On AWS, a VPC endpoint for Bedrock keeps even that traffic off the internet.

**Slack.** Create a Slack app with a bot token (`xoxb-...`) that can post to your channel (scope `chat:write`), invite the bot to the channel, and give the lab the token and the channel. Prefer a file to an environment variable for the token:

```bash
SLACK_TOKEN_FILE=~/secrets/slack-bot-token SLACK_CHANNEL='#k8s-ai-agent' bash scripts/test-all.sh
```

(`SLACK_TOKEN=xoxb-...` works too.) `01-observe.sh` writes the token to a 0600 temporary file, creates the Secret `holmes/holmes-slack` from it (`--from-file`; the token never appears on a command line or in the output) and deletes the file. The chart reads it as `SLACK_TOKEN`. The scripts then add `{"type": "slack", "config": {"channel": "<SLACK_CHANNEL>"}}` next to the webhook destination when they apply `observe/healthcheck-injection.yaml` and `rehearse/triggeredhealthcheck.yaml`, and in the alert bridge's `DESTINATIONS`. The files in the repository are not changed. `slack.com` joins the egress proxy's allowlist for that run only.

HolmesGPT 0.47 sends a check's verdict to its destinations only when the check fails. A GO is recorded in the HealthCheck's status, which is what `scripts/promote.sh` reads.

**Amazon Bedrock.** `observe/holmes-values-bedrock.yaml` points HolmesGPT at Claude Opus 5.5 through the US cross-Region inference profile `us.anthropic.claude-opus-5-5` in `us-east-1`. Your account needs access to that model. Run:

```bash
eval "$(aws sts get-session-token --duration-seconds 3600 --output text \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' |
  awk '{print "export AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3}')"
LLM_MODE=bedrock bash scripts/test-all.sh
```

A real model decides for itself, so with `LLM_MODE=bedrock` the assertions that depend on the scripted model's transcript are skipped and reported as `[n/a]`. The isolation assertions (admission, gVisor, RBAC, egress) still run. Each investigation is several model calls with prompts of several thousand tokens each (the scripted run prints the measured sizes): check the Bedrock pricing for your model before you run it. On EKS, use IRSA or EKS Pod Identity instead of static keys.

In this mode the agent logs the token usage of every model call (`LOG_LLM_USAGE_RESPONSE`, JSON logs; the usage object only, no prompt), and before the teardown `test-all.sh` runs `tools/collect-llm-usage.sh`. It writes `out/llm-usage.jsonl` (one line per call: time, check, model, input, output and cache tokens) and `out/llm-usage-by-check.txt` (sums per check), plus `out/healthcheck-notifications.json` (where each verdict was delivered, Slack included). Multiply by the price per token of your model to get the cost of each investigation. Calls made while two checks were running are marked as shared between them.

Both at once:

```bash
LLM_MODE=bedrock SLACK_TOKEN_FILE=~/secrets/slack-bot-token SLACK_CHANNEL='#k8s-ai-agent' bash scripts/test-all.sh
```

## Limits

- The HolmesGPT operator and its CRDs are alpha (`holmesgpt.dev/v1alpha1`), and `TriggeredHealthCheck` only supports Deployment rollouts. The operator detects a rollout by comparing pod templates it keeps in memory, so a rollout that happens while it restarts is not checked.
- The bash toolset's deny list matches command prefixes. `kubectl get --all-namespaces secrets` is not caught by `deny: [kubectl get secret]`. The lab shows it running and RBAC refusing it: the deny list reduces noise, RBAC is the boundary.
- The chart's ClusterRole can read every ConfigMap and every pod's logs in the cluster. Anything sensitive there goes to the model, and from the model to the destination.
- Under gVisor, cAdvisor's per-container memory series of the sandboxed pods read 0; the pod-level series (`container=""`) carries the usage. Rules on container-level series do not see sandboxed workloads.
- The alert bridge (`predict/alert-bridge/bridge.py`) is lab code, about 200 lines: Alertmanager's bearer token, the alerts it knows, Kubernetes-name labels, the runbook id from `runbook_url`, one HealthCheck per alert fingerprint, and permission to create HealthChecks in one namespace and nothing else.
- The `runbook_url` annotations point at `github.com/filipemotta/k8s-ai-ops-agent`, the expected name of this repository; the lab only uses the `runbooks/<id>/` part.
- The approval in `approve-fix.sh` is a terminal prompt standing in for an approval workflow (a Slack button, a ticket, a pull request). The on-call identity is impersonated in the lab.

## Residual risks

What the controls in this lab do not stop, so nobody reads more into them:

- **Allowed names are still exits.** The proxy allows host names, not tenants. It never matches an IP literal or a reverse DNS name, and it cannot reach private or cluster addresses itself. With `slack.com` allowed, an injected command that reaches the proxy could post to an attacker's own Slack workspace if it had a token for it. The bash toolset's allow-list keeps `curl` out, and `kubectl` only talks Kubernetes API paths, but the boundary is the list of names: keep it to the APIs the agent needs, and prefer private endpoints (a Bedrock VPC endpoint) where they exist.
- **`kubectl --server` is allowed by the bash toolset.** Holmes' deny list matches prefixes, and `kubectl get pods --server=...` starts with an allowed one. kubectl does not send the in-cluster ServiceAccount token to an overridden `--server` (the lab measures this over plain HTTP): to send it, the model would need the token's value on the command line, and reading it needs `cat` (not on the `core` allow-list) or `$(...)` (always blocked). The proxy and the NetworkPolicy are what keep any such request inside the cluster. An allowed name that echoed request headers back would be an exit.
- **The alert text reaches the model.** The bridge drops every annotation except the summary, puts the summary between explicit untrusted-data delimiters and truncates it. Delimiters help a model tell data from instructions; they do not guarantee it. The labels it copies are checked against Kubernetes naming rules.
- **The operator uses the cluster DNS.** Only the Holmes pod, which runs the commands a model picks, is restricted to the agent resolver. The operator never runs model-chosen commands.
- **The proxy decides on the name the client sends.** Squid refuses a CONNECT on the requested host name before any lookup. It does not inspect TLS, so it cannot see the SNI or the content of an allowed tunnel.

## Cleanup

`bash scripts/teardown.sh` deletes the kind cluster and the lab's kubeconfig, and checks that nothing is left. `./bin` and `./out` are plain directories you can delete.

## License

MIT
