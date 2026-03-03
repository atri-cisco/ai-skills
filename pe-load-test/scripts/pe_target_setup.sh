#!/usr/bin/env bash
set -euo pipefail

NS="sigpolicy"
KCTX=""
POD=""
LOCAL_BINARY=""
DEST_BINARY="/opt/policy_engine/bin/policy_engine"
TMP_BINARY="/tmp/policy_engine.new"
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"
RESTART_CMD="svc -du /service/policy_engine"
READY_PATTERN="processes transaction"
READY_MODE="http"
READY_TIMEOUT_SEC=900
LOG_FILE="/var/log/policy_engine/current"
DISABLE_DEBUG=true
INTERFACE="eth0"

usage() {
  cat <<USAGE
Usage:
  pe_target_setup.sh --pod <target-pod> --binary <local-binary-path> [options]

Required:
  --pod <name>                 Target PE pod name
  --binary <path>              Local PE binary to deploy

Options:
  --namespace <ns>             Kubernetes namespace (default: sigpolicy)
  --context <ctx>              Kubernetes context
  --dest-binary <path>         Destination binary path in pod (default: /opt/policy_engine/bin/policy_engine)
  --tmp-binary <path>          Temp binary path in pod (default: /tmp/policy_engine.new)
  --backup-suffix <suffix>     Backup suffix for old binary (default: timestamp)
  --restart-cmd <cmd>          Restart command in pod (default: svc -du /service/policy_engine)
  --ready-pattern <pattern>    Log pattern to detect readiness (default: processes transaction)
  --ready-mode <http|log>      Readiness check mode (default: http)
  --ready-timeout-sec <secs>   Readiness timeout (default: 900)
  --log-file <path>            Policy Engine log file (default: /var/log/policy_engine/current)
  --disable-debug <true|false> Disable verbose logging after startup (default: true)
  --interface <name>           Pod interface used for local PATCH endpoint (default: eth0)
  --help                       Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pod) POD="$2"; shift 2 ;;
    --binary) LOCAL_BINARY="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --context) KCTX="$2"; shift 2 ;;
    --dest-binary) DEST_BINARY="$2"; shift 2 ;;
    --tmp-binary) TMP_BINARY="$2"; shift 2 ;;
    --backup-suffix) BACKUP_SUFFIX="$2"; shift 2 ;;
    --restart-cmd) RESTART_CMD="$2"; shift 2 ;;
    --ready-pattern) READY_PATTERN="$2"; shift 2 ;;
    --ready-mode) READY_MODE="$2"; shift 2 ;;
    --ready-timeout-sec) READY_TIMEOUT_SEC="$2"; shift 2 ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
    --disable-debug) DISABLE_DEBUG="$2"; shift 2 ;;
    --interface) INTERFACE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$POD" || -z "$LOCAL_BINARY" ]]; then
  echo "--pod and --binary are required" >&2
  usage
  exit 1
fi

if [[ ! -f "$LOCAL_BINARY" ]]; then
  echo "Binary not found: $LOCAL_BINARY" >&2
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

log "Copying binary to pod tmp path: $TMP_BINARY"
k cp "$LOCAL_BINARY" "$POD:$TMP_BINARY"

log "Backing up current binary and swapping in new binary"
k exec "$POD" -- sh -lc "set -eu; NEW='${DEST_BINARY}.new.${BACKUP_SUFFIX}'; cp '$DEST_BINARY' '${DEST_BINARY}.${BACKUP_SUFFIX}'; cp '$TMP_BINARY' '\$NEW'; chmod 755 '\$NEW'; mv -f '\$NEW' '$DEST_BINARY'"

log "Restarting Policy Engine using: $RESTART_CMD"
k exec "$POD" -- sh -lc "$RESTART_CMD"

resolve_target_ip() {
  k exec "$POD" -- sh -lc "ip -4 -o addr show dev '$INTERFACE' | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1 | head -n1"
}

TARGET_IP=""
if [[ "$READY_MODE" == "http" || "$DISABLE_DEBUG" == "true" ]]; then
  log "Resolving pod IP from interface: $INTERFACE"
  TARGET_IP="$(resolve_target_ip)"
  if [[ -z "$TARGET_IP" ]]; then
    echo "Failed to determine target IP from interface $INTERFACE" >&2
    exit 1
  fi
fi

if [[ "$READY_MODE" == "http" ]]; then
  log "Waiting for HTTP readiness on $TARGET_IP/status (timeout=${READY_TIMEOUT_SEC}s)"
else
  log "Waiting for readiness pattern '$READY_PATTERN' in $LOG_FILE (timeout=${READY_TIMEOUT_SEC}s)"
fi
start_ts=$(date +%s)
while true; do
  if [[ "$READY_MODE" == "http" ]]; then
    if k exec "$POD" -- sh -lc "set -e; code=\$(curl -ksS --max-time 5 -o /dev/null -w '%{http_code}' 'https://${TARGET_IP}/status' || true); if [ \"\$code\" = \"200\" ]; then exit 0; fi; code=\$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' 'http://${TARGET_IP}/status' || true); [ \"\$code\" = \"200\" ]" >/dev/null 2>&1; then
      log "HTTP readiness detected"
      break
    fi
  else
    if k exec "$POD" -- sh -lc "tail -n 500 '$LOG_FILE' | grep -q -- '$READY_PATTERN'" >/dev/null 2>&1; then
      log "Readiness pattern detected"
      break
    fi
  fi

  now_ts=$(date +%s)
  elapsed=$((now_ts - start_ts))
  if (( elapsed > READY_TIMEOUT_SEC )); then
    log "Timed out waiting for readiness after ${READY_TIMEOUT_SEC}s"
    log "Last 60 log lines:"
    k exec "$POD" -- sh -lc "tail -n 60 '$LOG_FILE'" || true
    exit 1
  fi
  sleep 10
done

if [[ "$DISABLE_DEBUG" == "true" ]]; then
  log "Disabling verbose logging via PATCH on https://$TARGET_IP/.service/logs/global/config?verbose=false"
  HTTP_CODE=$(k exec "$POD" -- sh -lc "curl -ksS -o /dev/null -w '%{http_code}' -X PATCH 'https://$TARGET_IP/.service/logs/global/config?verbose=false'")
  log "PATCH response HTTP code: $HTTP_CODE"
fi

log "Target setup complete"
log "Backup binary path: ${DEST_BINARY}.${BACKUP_SUFFIX}"
