"""Per-call token usage of the agent, attributed to health checks.

Input: the Holmes server's logs in JSON format (enableJsonLogsFormat, with
LOG_LLM_USAGE_RESPONSE=true, as observe/holmes-values-bedrock.yaml sets) and
`kubectl get healthchecks -A -o json`. Each "LLM usage response" line is one
model call; it is attributed to the HealthCheck whose run (status.startTime ..
status.completionTime) contains the line's timestamp. Only token counts,
timestamps, check names and the model are written: no prompt, no answer.

  python3 tools/llm_usage.py <holmes.log> <healthchecks.json> <out dir>
  python3 tools/llm_usage.py --self-test

Writes <out dir>/llm-usage.jsonl (one line per call) and
<out dir>/llm-usage-by-check.txt (sums per check and in total). Checks that
ran at the same time make a call ambiguous: it is attributed to all of them
and marked so; the total counts it once.
"""

import json
import re
import sys
from datetime import datetime, timedelta, timezone

FIELDS = ("prompt_tokens", "completion_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")


def parse_time(value):
    value = value.replace("Z", "+00:00")
    t = datetime.fromisoformat(value)
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)  # Holmes logs in UTC without an offset


def usage_calls(log_lines):
    for line in log_lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        message = str(entry.get("message", ""))
        if "LLM usage response" not in message:
            continue
        call = {"time": entry.get("asctime")}
        for field in FIELDS:
            found = re.search(rf"\b{field}=(\d+)", message)
            call[field] = int(found.group(1)) if found else None
        yield call


def check_windows(healthchecks):
    for item in healthchecks.get("items", []):
        status = item.get("status") or {}
        if not status.get("startTime"):
            continue
        start = parse_time(status["startTime"])
        end = parse_time(status["completionTime"]) if status.get("completionTime") else start + timedelta(minutes=10)
        yield {"check": f"{item['metadata']['namespace']}/{item['metadata']['name']}",
               "start": start - timedelta(seconds=1), "end": end + timedelta(seconds=1),
               "model": status.get("modelUsed"), "result": status.get("result")}


def attribute(calls, windows):
    for call in calls:
        t = parse_time(call["time"]) if call["time"] else None
        owners = [w for w in windows if t and w["start"] <= t <= w["end"]]
        call["checks"] = [w["check"] for w in owners] or ["unattributed"]
        call["model"] = owners[0]["model"] if owners else None
        call["ambiguous"] = len(owners) > 1
        yield call


def summarize(calls, windows):
    lines, totals = [], dict.fromkeys(FIELDS, 0)
    results = {w["check"]: w["result"] for w in windows}
    for check in sorted({c for call in calls for c in call["checks"]}):
        mine = [c for c in calls if check in c["checks"]]
        sums = {f: sum(c[f] or 0 for c in mine) for f in FIELDS}
        lines.append(f"{check} ({results.get(check, '-')}): {len(mine)} calls, "
                     + ", ".join(f"{f}={sums[f]}" for f in FIELDS)
                     + (" (includes calls shared with a concurrent check)" if any(c["ambiguous"] for c in mine) else ""))
    for call in calls:
        for f in FIELDS:
            totals[f] += call[f] or 0
    lines.append(f"total: {len(calls)} calls, " + ", ".join(f"{f}={totals[f]}" for f in FIELDS))
    return "\n".join(lines) + "\n"


def run(log_lines, healthchecks):
    windows = list(check_windows(healthchecks))
    calls = list(attribute(usage_calls(log_lines), windows))
    return calls, summarize(calls, windows)


def self_test():
    log = [
        '{"asctime": "2026-11-24T12:00:05", "severity": "INFO", "name": "root", "message": "LLM usage response:\\n'
        'completion_tokens=120 prompt_tokens=6400 total_tokens=6520 completion_tokens_details=None '
        'prompt_tokens_details=None cache_creation_input_tokens=0 cache_read_input_tokens=5000\\n"}',
        '{"asctime": "2026-11-24T12:00:09", "severity": "INFO", "name": "root", "message": "LLM usage response:\\n'
        'Usage(completion_tokens=80, prompt_tokens=7100, total_tokens=7180)\\n"}',
        '{"asctime": "2026-11-24T12:05:00", "severity": "INFO", "name": "root", "message": "LLM usage response:\\n'
        'completion_tokens=10 prompt_tokens=100 total_tokens=110\\n"}',
        '{"asctime": "2026-11-24T12:00:06", "severity": "INFO", "name": "root", "message": "Executing bash command: kubectl get pods"}',
        "plain text line, not JSON",
    ]
    hcs = {"items": [
        {"metadata": {"namespace": "holmes", "name": "payments-logs"},
         "status": {"startTime": "2026-11-24T12:00:00Z", "completionTime": "2026-11-24T12:00:10Z",
                    "modelUsed": "bedrock/us.anthropic.claude-opus-5-5", "result": "fail"}},
        {"metadata": {"namespace": "sandbox", "name": "checkout-rollout-x"},
         "status": {"startTime": "2026-11-24T12:00:08Z", "completionTime": "2026-11-24T12:00:20Z", "result": "pass"}},
    ]}
    calls, summary = run(log, hcs)
    failures = []
    if len(calls) != 3:
        failures.append(f"expected 3 calls, got {len(calls)}")
    if calls and (calls[0]["checks"] != ["holmes/payments-logs"] or calls[0]["prompt_tokens"] != 6400
                  or calls[0]["cache_read_input_tokens"] != 5000 or calls[0]["model"] != "bedrock/us.anthropic.claude-opus-5-5"):
        failures.append(f"first call misattributed: {calls[0]}")
    if len(calls) > 1 and not (calls[1]["ambiguous"] and calls[1]["completion_tokens"] == 80):
        failures.append(f"overlapping checks not marked ambiguous: {calls[1]}")
    if len(calls) > 2 and calls[2]["checks"] != ["unattributed"]:
        failures.append(f"call outside every check attributed: {calls[2]}")
    if "total: 3 calls, prompt_tokens=13600, completion_tokens=210" not in summary:
        failures.append("total wrong:\n" + summary)
    if any("kubectl" in json.dumps(c) for c in calls):
        failures.append("a non-usage log line leaked into the output")
    print(summary, end="")
    print("self-test: " + ("ok" if not failures else "FAILED\n" + "\n".join(failures)))
    return 0 if not failures else 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    log_file, hc_file, out_dir = sys.argv[1:4]
    with open(log_file) as f:
        lines = f.readlines()
    with open(hc_file) as f:
        hcs = json.load(f)
    calls, summary = run(lines, hcs)
    with open(f"{out_dir}/llm-usage.jsonl", "w") as f:
        for call in calls:
            f.write(json.dumps(call) + "\n")
    with open(f"{out_dir}/llm-usage-by-check.txt", "w") as f:
        f.write(summary)
    print(summary, end="")
