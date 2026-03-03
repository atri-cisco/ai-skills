#!/usr/bin/env bash
set -euo pipefail

NS="sigpolicy"
KCTX=""
POD=""
DEST_BINARY="/opt/policy_engine/bin/policy_engine"
BACKUP_BINARY=""
RESTART_CMD="svc -du /service/policy_engine"

usage() {
  cat <<USAGE
Usage:
  pe_restore_binary.sh --pod <target-pod> --backup-binary <path> [options]

Required:
  --pod <name>                 Target pod name
  --backup-binary <path>       Backup binary path in pod (for example /opt/policy_engine/bin/policy_engine.20260225-101530)

Options:
  --namespace <ns>             Kubernetes namespace (default: sigpolicy)
  --context <ctx>              Kubernetes context
  --dest-binary <path>         Destination binary path (default: /opt/policy_engine/bin/policy_engine)
  --restart-cmd <cmd>          Restart command in pod (default: svc -du /service/policy_engine)
  --help                       Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pod) POD="$2"; shift 2 ;;
    --backup-binary) BACKUP_BINARY="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --context) KCTX="$2"; shift 2 ;;
    --dest-binary) DEST_BINARY="$2"; shift 2 ;;
    --restart-cmd) RESTART_CMD="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$POD" || -z "$BACKUP_BINARY" ]]; then
  echo "--pod and --backup-binary are required" >&2
  usage
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

log "Restoring backup binary: $BACKUP_BINARY -> $DEST_BINARY"
k exec "$POD" -- sh -lc "set -eu; cp '$BACKUP_BINARY' '$DEST_BINARY'; chmod 755 '$DEST_BINARY'"

log "Restarting Policy Engine"
k exec "$POD" -- sh -lc "$RESTART_CMD"

log "Restore complete"
