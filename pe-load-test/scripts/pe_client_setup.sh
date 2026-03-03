#!/usr/bin/env bash
set -euo pipefail

NS="sigpolicy"
KCTX=""
CLIENT_POD=""
TARGET_POD=""
TARGET_IP=""
TARGET_INTERFACE="eth0"
TARGETS_LOCAL=""
TARGETS_REMOTE="/tmp/vegeta_targets_prod_samples.jsonl"
FROM_HOST="http://127.0.0.1:8080"
INSTALL_VEGETA=true
VEGETA_VERSION="12.5.1"

usage() {
  cat <<USAGE
Usage:
  pe_client_setup.sh --client-pod <pod> --targets-local <path> [options]

Required:
  --client-pod <name>          Pod that runs vegeta
  --targets-local <path>       Local path to vegeta targets jsonl file

Target host options (provide one):
  --target-ip <ip>             IP to inject into targets as https://<ip>
  --target-pod <name>          Resolve target IP from this pod's eth0 (or --target-interface)

Options:
  --namespace <ns>             Kubernetes namespace (default: sigpolicy)
  --context <ctx>              Kubernetes context
  --target-interface <name>    Interface used to resolve target pod IP (default: eth0)
  --targets-remote <path>      Remote targets file path on client pod (default: /tmp/vegeta_targets_prod_samples.jsonl)
  --from-host <host>           Host string to replace in targets (default: http://127.0.0.1:8080)
  --install-vegeta <true|false>Install vegeta if missing on client pod (default: true)
  --vegeta-version <version>   Vegeta version for install (default: 12.5.1)
  --help                       Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-pod) CLIENT_POD="$2"; shift 2 ;;
    --target-pod) TARGET_POD="$2"; shift 2 ;;
    --target-ip) TARGET_IP="$2"; shift 2 ;;
    --targets-local) TARGETS_LOCAL="$2"; shift 2 ;;
    --targets-remote) TARGETS_REMOTE="$2"; shift 2 ;;
    --from-host) FROM_HOST="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --context) KCTX="$2"; shift 2 ;;
    --target-interface) TARGET_INTERFACE="$2"; shift 2 ;;
    --install-vegeta) INSTALL_VEGETA="$2"; shift 2 ;;
    --vegeta-version) VEGETA_VERSION="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$CLIENT_POD" || -z "$TARGETS_LOCAL" ]]; then
  echo "--client-pod and --targets-local are required" >&2
  usage
  exit 1
fi

if [[ ! -f "$TARGETS_LOCAL" ]]; then
  echo "Targets file not found: $TARGETS_LOCAL" >&2
  exit 1
fi

if [[ -z "$TARGET_IP" && -z "$TARGET_POD" ]]; then
  echo "Provide either --target-ip or --target-pod" >&2
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

if [[ -z "$TARGET_IP" ]]; then
  log "Resolving target IP from pod '$TARGET_POD' interface '$TARGET_INTERFACE'"
  TARGET_IP=$(k exec "$TARGET_POD" -- sh -lc "ip -4 -o addr show dev '$TARGET_INTERFACE' | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1 | head -n1")
  if [[ -z "$TARGET_IP" ]]; then
    echo "Failed to resolve target IP" >&2
    exit 1
  fi
fi
TO_HOST="https://${TARGET_IP}"

if [[ "$INSTALL_VEGETA" == "true" ]]; then
  log "Ensuring vegeta is installed on client pod '$CLIENT_POD'"
  k exec "$CLIENT_POD" -- sh -lc "
    set -eu
    if ! command -v vegeta >/dev/null 2>&1; then
      cd /tmp
      URL='https://github.com/tsenart/vegeta/releases/download/cli%2Fv${VEGETA_VERSION}/vegeta-${VEGETA_VERSION}-linux-amd64.tar.gz'
      if command -v wget >/dev/null 2>&1; then
        wget -q -O vegeta.tar.gz \"\$URL\"
      elif command -v curl >/dev/null 2>&1; then
        curl -fsSL \"\$URL\" -o vegeta.tar.gz
      else
        echo 'Need wget or curl in client pod to install vegeta' >&2
        exit 1
      fi
      tar xfz vegeta.tar.gz
      mv vegeta /usr/bin/vegeta
      chmod 755 /usr/bin/vegeta
    fi
    vegeta -version
  "
fi

log "Copying targets file to client pod: $TARGETS_REMOTE"
k cp "$TARGETS_LOCAL" "$CLIENT_POD:$TARGETS_REMOTE"

log "Rewriting host in targets: $FROM_HOST -> $TO_HOST"
k exec "$CLIENT_POD" -- sh -lc "sed -i 's#${FROM_HOST}#${TO_HOST}#g' '$TARGETS_REMOTE'"

log "First line of updated targets file"
k exec "$CLIENT_POD" -- sh -lc "head -n 1 '$TARGETS_REMOTE'"

log "Client setup complete"
log "Client pod: $CLIENT_POD"
log "Target host in file: $TO_HOST"
log "Targets file: $TARGETS_REMOTE"
