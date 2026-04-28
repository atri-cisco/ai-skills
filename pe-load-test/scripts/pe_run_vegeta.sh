#!/usr/bin/env bash
set -euo pipefail

NS="sigpolicy"
KCTX=""
CLIENT_POD=""
TARGET_POD=""
TARGET_INTERFACE="eth0"
TARGETS_REMOTE="/tmp/vegeta_targets_prod_samples.jsonl"
RATE="1000"
DURATION="20m"
FORMAT="json"
INSECURE=true
CONNECTIONS="30"
WORKERS="100"
MAX_WORKERS="1000"
KEEPALIVE="true"
LIVE_EVERY="10s"
REMOTE_OUT_DIR="/tmp/vegeta-run-$(date +%Y%m%d-%H%M%S)"
LOCAL_COPY_DIR=""
ENSURE_DEBUG_OFF=false

usage() {
  cat <<USAGE
Usage:
  pe_run_vegeta.sh --client-pod <pod> [options]

Required:
  --client-pod <name>          Pod that runs vegeta

Options:
  --target-pod <name>          Target PE pod (required when --ensure-debug-off=true)
  --target-interface <name>    Interface used to resolve target pod IP (default: eth0)
  --namespace <ns>             Kubernetes namespace (default: sigpolicy)
  --context <ctx>              Kubernetes context
  --targets-remote <path>      Targets file path on client pod (default: /tmp/vegeta_targets_prod_samples.jsonl)
  --rate <n>                   Attack rate RPS (default: 1000)
  --duration <dur>             Attack duration, e.g. 20m (default: 20m)
  --format <fmt>               Targets format (default: json)
  --insecure <true|false>      Pass -insecure to vegeta (default: true)
  --connections <n>            Vegeta connections (default: 30)
  --workers <n>                Initial workers (default: 100)
  --max-workers <n>            Max workers (default: 1000)
  --keepalive <true|false>     Use persistent connections (default: true)
  --live-every <dur>           Live report interval (default: 10s)
  --remote-out-dir <path>      Output directory on client pod
  --local-copy-dir <path>      Copy output dir from client pod to this local directory
  --ensure-debug-off <true|false>
                               PATCH target pod log config to verbose=false right before load (default: false)
  --help                       Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-pod) CLIENT_POD="$2"; shift 2 ;;
    --target-pod) TARGET_POD="$2"; shift 2 ;;
    --target-interface) TARGET_INTERFACE="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --context) KCTX="$2"; shift 2 ;;
    --targets-remote) TARGETS_REMOTE="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --insecure) INSECURE="$2"; shift 2 ;;
    --connections) CONNECTIONS="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --max-workers) MAX_WORKERS="$2"; shift 2 ;;
    --keepalive) KEEPALIVE="$2"; shift 2 ;;
    --live-every) LIVE_EVERY="$2"; shift 2 ;;
    --remote-out-dir) REMOTE_OUT_DIR="$2"; shift 2 ;;
    --local-copy-dir) LOCAL_COPY_DIR="$2"; shift 2 ;;
    --ensure-debug-off) ENSURE_DEBUG_OFF="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$CLIENT_POD" ]]; then
  echo "--client-pod is required" >&2
  usage
  exit 1
fi

if [[ "$ENSURE_DEBUG_OFF" == "true" && -z "$TARGET_POD" ]]; then
  echo "--target-pod is required when --ensure-debug-off=true" >&2
  exit 1
fi

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

k() {
  if [[ -n "$KCTX" ]]; then
    kubectl --context "$KCTX" -n "$NS" "$@"
  else
    kubectl -n "$NS" "$@"
  fi
}

auth_hint() {
  cat >&2 <<'EOF'
Kubernetes authentication failed for the selected context/namespace.
Refresh session, then retry:
  sl login
  sl aws session generate --account-id $EKS_STAGE_MUON --role-name sigpolicy --profile muon
EOF
}

ensure_kube_auth() {
  if ! k auth can-i get pods >/dev/null 2>&1; then
    auth_hint
    exit 1
  fi
}

ensure_kube_auth

resolve_target_ip() {
  k exec "$TARGET_POD" -- sh -lc "ip -4 -o addr show dev '$TARGET_INTERFACE' | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1 | head -n1"
}

ensure_debug_off() {
  local target_ip=""
  target_ip="$(resolve_target_ip)"
  if [[ -z "$target_ip" ]]; then
    echo "Failed to resolve target pod IP for $TARGET_POD/$TARGET_INTERFACE" >&2
    exit 1
  fi

  log "Ensuring verbose logging is OFF on target pod '$TARGET_POD' (${target_ip})"
  local patch_code=""
  patch_code="$(k exec "$TARGET_POD" -- sh -lc "curl -ksS -o /dev/null -w '%{http_code}' -X PATCH 'https://${target_ip}/.service/logs/global/config?verbose=false'")"
  if [[ "$patch_code" != "200" ]]; then
    patch_code="$(k exec "$TARGET_POD" -- sh -lc "curl -sS -o /dev/null -w '%{http_code}' -X PATCH 'http://${target_ip}/.service/logs/global/config?verbose=false'")"
  fi
  if [[ "$patch_code" != "200" ]]; then
    echo "Failed to disable verbose logging on target pod (HTTP ${patch_code})" >&2
    exit 1
  fi

  local cfg
  cfg="$(k exec "$TARGET_POD" -- sh -lc "curl -ksS 'https://${target_ip}/.service/logs/global/config' || curl -sS 'http://${target_ip}/.service/logs/global/config'")"
  log "Target log config response: $cfg"
}

if [[ "$ENSURE_DEBUG_OFF" == "true" ]]; then
  ensure_debug_off
fi

cleanup_remote_vegeta() {
  # Best-effort cleanup for interrupted local runs.
  k exec "$CLIENT_POD" -- sh -lc "
    pids=\$(ps -eo pid,args | awk '/vegeta attack|vegeta report/ && !/awk/ && !/pgrep/ {print \$1}')
    if [ -n \"\$pids\" ]; then
      kill \$pids >/dev/null 2>&1 || true
      sleep 1
      kill -9 \$pids >/dev/null 2>&1 || true
    fi
  " >/dev/null 2>&1 || true
}

remote_has_vegeta_processes() {
  k exec "$CLIENT_POD" -- sh -lc "ps -eo pid,args | awk '/vegeta attack|vegeta report/ && !/awk/ && !/pgrep/ {found=1} END {exit(found?0:1)}'" >/dev/null 2>&1
}

RUN_ACTIVE=false
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$RUN_ACTIVE" == "true" ]]; then
    log "Run failed (exit ${rc}). Cleaning up remote vegeta processes."
    cleanup_remote_vegeta
  fi
}

trap 'log "Interrupted. Cleaning up remote vegeta processes."; cleanup_remote_vegeta; exit 130' INT TERM
trap on_exit EXIT

INSECURE_FLAG=""
if [[ "$INSECURE" == "true" ]]; then
  INSECURE_FLAG="-insecure"
fi
KEEPALIVE_FLAG="-keepalive=false"
if [[ "$KEEPALIVE" == "true" ]]; then
  KEEPALIVE_FLAG="-keepalive"
fi

log "Running vegeta attack on client pod '$CLIENT_POD'"
log "Rate=$RATE, Duration=$DURATION, Connections=$CONNECTIONS, Workers=$WORKERS/$MAX_WORKERS"
log "Keepalive=$KEEPALIVE"
log "Output dir in pod: $REMOTE_OUT_DIR"

if ! k exec "$CLIENT_POD" -- sh -lc "test -s '$TARGETS_REMOTE'"; then
  echo "Targets file missing/empty on client pod: $TARGETS_REMOTE" >&2
  exit 1
fi

if k exec "$CLIENT_POD" -- sh -lc "grep -q '127.0.0.1:8080' '$TARGETS_REMOTE'"; then
  echo "Targets file still points to 127.0.0.1:8080; run pe_client_setup.sh first." >&2
  exit 1
fi

if remote_has_vegeta_processes; then
  log "Found existing vegeta processes on client pod. Cleaning up stale processes first."
  cleanup_remote_vegeta
  sleep 1
fi

if remote_has_vegeta_processes; then
  echo "Existing vegeta processes are still running on client pod; aborting to avoid mixed runs." >&2
  exit 1
fi

RUN_ACTIVE=true
k exec "$CLIENT_POD" -- sh -lc "
  set -eu
  mkdir -p '$REMOTE_OUT_DIR'
  if (vegeta attack -help 2>&1 || true) | grep -q -- '-max-workers'; then
    echo 'INFO: vegeta supports -max-workers; using provided value' >&2
    vegeta attack \
      $INSECURE_FLAG \
      $KEEPALIVE_FLAG \
      -format='$FORMAT' \
      -targets='$TARGETS_REMOTE' \
      -rate='$RATE' \
      -duration='$DURATION' \
      -connections='$CONNECTIONS' \
      -workers='$WORKERS' \
      -max-workers='$MAX_WORKERS' \
      2>'$REMOTE_OUT_DIR/errors.log' \
    | tee '$REMOTE_OUT_DIR/results.bin' \
    | vegeta report -every='$LIVE_EVERY' \
    | tee '$REMOTE_OUT_DIR/live-report.txt'
  else
    echo 'INFO: vegeta does not support -max-workers; running without it' >&2
    vegeta attack \
      $INSECURE_FLAG \
      $KEEPALIVE_FLAG \
      -format='$FORMAT' \
      -targets='$TARGETS_REMOTE' \
      -rate='$RATE' \
      -duration='$DURATION' \
      -connections='$CONNECTIONS' \
      -workers='$WORKERS' \
      2>'$REMOTE_OUT_DIR/errors.log' \
    | tee '$REMOTE_OUT_DIR/results.bin' \
    | vegeta report -every='$LIVE_EVERY' \
    | tee '$REMOTE_OUT_DIR/live-report.txt'
  fi

  vegeta report < '$REMOTE_OUT_DIR/results.bin' > '$REMOTE_OUT_DIR/report.txt'
  vegeta report -type='hist[0,2ms,5ms,10ms,25ms,50ms,100ms,250ms,500ms,1s]' \
    < '$REMOTE_OUT_DIR/results.bin' > '$REMOTE_OUT_DIR/hist.txt'
"
RUN_ACTIVE=false

log "Run complete. Key files in pod:"
log "  $REMOTE_OUT_DIR/report.txt"
log "  $REMOTE_OUT_DIR/hist.txt"
log "  $REMOTE_OUT_DIR/errors.log"
log "  $REMOTE_OUT_DIR/live-report.txt"
log "  $REMOTE_OUT_DIR/results.bin"

if [[ -n "$LOCAL_COPY_DIR" ]]; then
  mkdir -p "$LOCAL_COPY_DIR"
  dest="$LOCAL_COPY_DIR/$(basename "$REMOTE_OUT_DIR")"
  log "Copying pod output directory to local: $dest"
  cp_ok=false
  if command -v timeout >/dev/null 2>&1; then
    if [[ -n "$KCTX" ]]; then
      if timeout 120s kubectl --context "$KCTX" -n "$NS" cp "$CLIENT_POD:$REMOTE_OUT_DIR" "$dest"; then
        cp_ok=true
      fi
    else
      if timeout 120s kubectl -n "$NS" cp "$CLIENT_POD:$REMOTE_OUT_DIR" "$dest"; then
        cp_ok=true
      fi
    fi
  elif command -v gtimeout >/dev/null 2>&1; then
    if [[ -n "$KCTX" ]]; then
      if gtimeout 120s kubectl --context "$KCTX" -n "$NS" cp "$CLIENT_POD:$REMOTE_OUT_DIR" "$dest"; then
        cp_ok=true
      fi
    else
      if gtimeout 120s kubectl -n "$NS" cp "$CLIENT_POD:$REMOTE_OUT_DIR" "$dest"; then
        cp_ok=true
      fi
    fi
  else
    if k cp "$CLIENT_POD:$REMOTE_OUT_DIR" "$dest"; then
      cp_ok=true
    fi
  fi

  if [[ "$cp_ok" == "true" ]]; then
    log "Copied run artifacts via kubectl cp"
  else
    log "kubectl cp failed/timed out; falling back to file-by-file copy"
    mkdir -p "$dest"

    # Copy large binary with cp first, then fall back to cat if needed.
    if ! k cp "$CLIENT_POD:$REMOTE_OUT_DIR/results.bin" "$dest/results.bin"; then
      log "Fallback: streaming results.bin via kubectl exec"
      k exec "$CLIENT_POD" -- sh -lc "cat '$REMOTE_OUT_DIR/results.bin'" > "$dest/results.bin" || true
    fi

    for f in report.txt hist.txt errors.log live-report.txt; do
      if k exec "$CLIENT_POD" -- sh -lc "test -f '$REMOTE_OUT_DIR/$f'"; then
        k exec "$CLIENT_POD" -- sh -lc "cat '$REMOTE_OUT_DIR/$f'" > "$dest/$f" || true
      fi
    done
    log "Fallback copy complete (verify files under $dest)"
  fi
fi
