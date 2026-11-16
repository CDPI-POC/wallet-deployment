#!/usr/bin/env bash
# deploy-inji.sh - runs the Inji external + dependency install scripts in order.
#
# Usage:
#   ./deploy-inji.sh                  run all steps (skips ones already done)
#   ./deploy-inji.sh --list           list steps and their status
#   ./deploy-inji.sh --from keycloak  start from a step (earlier steps are skipped)
#   ./deploy-inji.sh --only kafka     run a single step
#   ./deploy-inji.sh --reset          forget completed steps
#
# Env overrides:
#   REPO_DIR    path to the 'inji' folder   (default: ~/wallet-deployment/deployment/inji)
#   KUBECONFIG_FILE  path passed as $1 to each install.sh (optional)
#   WAIT_TIMEOUT     seconds to wait for pods after each step (default: 600)

set -uo pipefail

REPO_DIR="${REPO_DIR:-$HOME/wallet-deployment/deployment/inji}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
STATE_FILE="$HOME/.inji-deploy.state"
LOG_DIR="$HOME/inji-deploy-logs"
mkdir -p "$LOG_DIR"
touch "$STATE_FILE"

# name | directory (relative to REPO_DIR) | script | namespace to wait on (or -)
STEPS=(
  "postgres|external/postgres|install.sh|postgres"
  "postgres-init|external/postgres|init_db.sh|postgres"
  "keycloak|external/iam|install.sh|keycloak"
  "keycloak-init|external/iam|keycloak_init.sh|keycloak"
  "softhsm|external/hsm/softhsm|install.sh|softhsm"
  "activemq|external/activemq|install.sh|activemq"
  "kafka|external/kafka|install.sh|kafka"
  "msg-gateway|external/msg-gateway|install.sh|msg-gateways"
  "captcha|external/captcha|install.sh|captcha"
  "conf-secrets|inji_dependency/conf-secrets|install.sh|-"
  "config-server|inji_dependency/config-server|install.sh|config-server"
  "artifactory|inji_dependency/artifactory|install.sh|artifactory"
  "keymanager|inji_dependency/keymanager|install.sh|keymanager"
)

log()  { echo -e "\n[$(date +%H:%M:%S)] $*"; }
done_p() { grep -qx "$1" "$STATE_FILE"; }

wait_ns() {
  local ns="$1"
  [[ "$ns" == "-" ]] && return 0
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    log "namespace '$ns' not found, skipping wait (check the script's real namespace)"
    return 0
  fi
  log "waiting up to ${WAIT_TIMEOUT}s for workloads in '$ns'..."
  local end=$((SECONDS + WAIT_TIMEOUT))
  for kind in deployment statefulset; do
    for r in $(kubectl -n "$ns" get "$kind" -o name 2>/dev/null); do
      local left=$((end - SECONDS)); (( left < 5 )) && left=5
      kubectl -n "$ns" rollout status "$r" --timeout="${left}s" || return 1
    done
  done
}

run_step() {
  local name="$1" dir="$2" script="$3" ns="$4"
  local full="$REPO_DIR/$dir"
  local logf="$LOG_DIR/$name.log"

  if [[ ! -f "$full/$script" ]]; then
    log "ERROR: $full/$script not found"; return 1
  fi

  log "=== $name  ($dir/$script) ==="
  chmod +x "$full/$script"
  # stdin stays attached so any prompts in the script still work
  ( cd "$full" && ./"$script" ${KUBECONFIG_FILE:+"$KUBECONFIG_FILE"} ) 2>&1 | tee "$logf"
  local rc=${PIPESTATUS[0]}
  if (( rc != 0 )); then
    log "FAILED: $name (exit $rc). Log: $logf"
    return 1
  fi
  wait_ns "$ns" || { log "FAILED: pods in '$ns' not ready. Log: $logf"; return 1; }
  echo "$name" >> "$STATE_FILE"
  log "OK: $name"
}

list_steps() {
  printf "%-16s %-8s %s\n" STEP STATUS PATH
  for s in "${STEPS[@]}"; do
    IFS='|' read -r n d f ns <<<"$s"
    done_p "$n" && st=done || st=pending
    printf "%-16s %-8s %s/%s\n" "$n" "$st" "$d" "$f"
  done
}

MODE=all; TARGET=""
case "${1:-}" in
  --list)  list_steps; exit 0 ;;
  --reset) : > "$STATE_FILE"; echo "state cleared"; exit 0 ;;
  --from)  MODE=from; TARGET="${2:?step name required}" ;;
  --only)  MODE=only; TARGET="${2:?step name required}" ;;
  "" ) ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac

[[ -d "$REPO_DIR" ]] || { echo "REPO_DIR not found: $REPO_DIR"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v helm    >/dev/null || { echo "helm not found"; exit 1; }
kubectl get nodes >/dev/null 2>&1 || { echo "cannot reach the cluster with kubectl"; exit 1; }

if [[ "$MODE" != all ]]; then
  printf '%s\n' "${STEPS[@]}" | cut -d'|' -f1 | grep -qx "$TARGET" \
    || { echo "unknown step '$TARGET'"; list_steps; exit 1; }
fi

started=0
for s in "${STEPS[@]}"; do
  IFS='|' read -r name dir script ns <<<"$s"

  case "$MODE" in
    only) [[ "$name" == "$TARGET" ]] || continue ;;
    from) [[ "$name" == "$TARGET" ]] && started=1; (( started )) || continue ;;
    all)  if done_p "$name"; then log "skip $name (already done)"; continue; fi ;;
  esac

  run_step "$name" "$dir" "$script" "$ns" || exit 1
done

log "All requested steps finished."
