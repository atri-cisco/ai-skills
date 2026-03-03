---
name: policy-engine-two-pod-loadtest
description: Use when you need to swap a Policy Engine binary in one pod and drive reproducible vegeta load from another pod, with configurable namespace/context/RPS/duration and reusable setup-run-collect steps.
---

# PE Two-Pod Load Test

## When to use
- You want to benchmark a modified `policy_engine` binary in a live Kubernetes pod.
- You use one pod as PE target and a second pod as vegeta client.
- You need repeatable load tests (500/750/1000 RPS etc.) with minimal manual drift.

## Inputs to collect first
- Kubernetes context (optional): example `arn:aws:eks:us-west-2:...`
- Namespace: default `sigpolicy`
- Target pod: PE pod where binary is swapped
- Client pod: pod where vegeta runs
- Local PE binary path: built binary on your machine (`scripts/build.sh` outputs `bin/policy_engine`)
- Local targets file path: usually `test/benchmarks/vegeta_targets_prod_samples.jsonl`
- Load params: `rate`, `duration`, `connections`, `workers`, `max-workers` (if supported by vegeta version), `keepalive`

## Workflow
1. Set up target pod (swap binary, restart PE, wait readiness, disable verbose logs).
2. Set up client pod (install vegeta if needed, copy targets file, rewrite host to target pod IP).
3. Run vegeta with periodic live report and saved artifacts.
4. Collect results and run local profiling scripts.
5. Optionally restore the original PE binary.

Note:
- Some PE pods bind service listeners on pod IP (eth0) rather than `127.0.0.1`.
- For profiling/metrics collection, prefer `kubectl exec ... curl https://<pod-ip>:<port>/...` over `kubectl port-forward` to localhost.

## Scripts in this skill
- `scripts/pe_target_setup.sh`
  - Swaps `/opt/policy_engine/bin/policy_engine` with a local binary.
  - Saves backup as `/opt/policy_engine/bin/policy_engine.<timestamp-or-suffix>`.
  - Restarts PE with `svc -du /service/policy_engine`.
  - Waits for readiness using HTTP probe by default (`https://<pod-eth0-ip>/status`, fallback `http://...`).
  - Supports log-based readiness when needed via `--ready-mode log --ready-pattern "<pattern>"`.
  - Disables debug logs via PATCH on target pod IP (`eth0` by default).
  - Important: after every binary swap/restart, confirm debug stays off (`verbose=false`) before load.

- `scripts/pe_client_setup.sh`
  - Ensures vegeta exists on client pod (downloads v12.5.1 by default).
  - Copies local targets file to client pod (default `/tmp/vegeta_targets_prod_samples.jsonl`).
  - Replaces `http://127.0.0.1:8080` with `https://<target-ip>`.

- `scripts/pe_run_vegeta.sh`
  - Runs vegeta attack on client pod.
  - Defaults: `rate=1000`, `duration=20m`, `connections=30`, `workers=100`, `max-workers=1000`, `keepalive=true`.
  - Automatically detects whether installed vegeta supports `-max-workers`; if unsupported (e.g. older v12 clients), runs without it and logs an INFO message.
  - Streams live report every `10s` and saves:
    - `results.bin`
    - `errors.log`
    - `live-report.txt`
    - `report.txt`
    - `hist.txt`

- `scripts/pe_restore_binary.sh`
  - Restores target binary from backup path and restarts PE.

## Quick start
Run from this skill directory:

```bash
cd /Users/ratri/.codex/skills/policy-engine-two-pod-loadtest
```

1) Target setup
```bash
./scripts/pe_target_setup.sh \
  --context "arn:aws:eks:us-west-2:720988369884:cluster/sse-muon-stage-usw-2-2-0" \
  --namespace sigpolicy \
  --pod policy-engine-prod-brain-555d4bbd8-44297 \
  --binary /Users/ratri/dev/cloudsec-atlantis-policy-engine/bin/policy_engine
```

2) Client setup
```bash
./scripts/pe_client_setup.sh \
  --context "arn:aws:eks:us-west-2:720988369884:cluster/sse-muon-stage-usw-2-2-0" \
  --namespace sigpolicy \
  --client-pod policy-engine-prod-brain-555d4bbd8-kxg2n \
  --target-pod policy-engine-prod-brain-555d4bbd8-44297 \
  --targets-local /Users/ratri/dev/cloudsec-atlantis-policy-engine/test/benchmarks/vegeta_targets_prod_samples.jsonl
```

3) Run load
```bash
./scripts/pe_run_vegeta.sh \
  --context "arn:aws:eks:us-west-2:720988369884:cluster/sse-muon-stage-usw-2-2-0" \
  --namespace sigpolicy \
  --client-pod policy-engine-prod-brain-555d4bbd8-kxg2n \
  --rate 1000 \
  --duration 20m \
  --connections 30 \
  --workers 100 \
  --keepalive true \
  --max-workers 1000
```

4) Optional: copy run artifacts to local disk
```bash
./scripts/pe_run_vegeta.sh \
  --context "arn:aws:eks:us-west-2:720988369884:cluster/sse-muon-stage-usw-2-2-0" \
  --namespace sigpolicy \
  --client-pod policy-engine-prod-brain-555d4bbd8-kxg2n \
  --rate 1000 \
  --duration 20m \
  --local-copy-dir /tmp/pe-vegeta-runs
```

5) Optional: restore original binary
```bash
./scripts/pe_restore_binary.sh \
  --context "arn:aws:eks:us-west-2:720988369884:cluster/sse-muon-stage-usw-2-2-0" \
  --namespace sigpolicy \
  --pod policy-engine-prod-brain-555d4bbd8-44297 \
  --backup-binary /opt/policy_engine/bin/policy_engine.<backup-suffix>
```

## Parameter guidance
- `--connections`: keep at least `20-30` for 1000 RPS tests; tune upward only if upstream can absorb it.
- `--workers`/`--max-workers`: start with defaults; raise if you observe client-side saturation.
- `--max-workers`: only effective when vegeta binary supports the flag; script auto-falls back otherwise.
- `--ready-timeout-sec`: increase to `1200+` if PE startup regularly exceeds 15 minutes.

## Safety checks
- Do not run binary swaps on production pods unless explicitly intended.
- Always keep the backup path from target setup output.
- Confirm test target host rewrite before load (`head -n 1` output from client setup).
- If results look inconsistent, verify both pods did not rotate/restart mid-run.
- If scripts fail with auth errors, refresh credentials first:
  - `sl login`
  - `sl aws session generate --account-id $EKS_STAGE_MUON --role-name sigpolicy --profile muon`
