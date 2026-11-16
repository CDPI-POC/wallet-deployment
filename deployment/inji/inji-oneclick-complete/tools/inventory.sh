#!/usr/bin/env bash
set -Eeuo pipefail

REPORT_DIR="$(cd "$(dirname "$0")/.." && pwd)/reports"
mkdir -p "$REPORT_DIR"

REPORT="$REPORT_DIR/cluster-inventory-$(date +%Y%m%d-%H%M%S).txt"

{
  echo "===== Kubernetes Cluster ====="
  kubectl config current-context
  kubectl get nodes -o wide

  echo
  echo "===== Namespaces ====="
  kubectl get namespaces

  echo
  echo "===== Helm Releases ====="
  helm list -A

  echo
  echo "===== Inji and Infrastructure Pods ====="
  kubectl get pods -A | grep -Ei \
    'inji|certify|verify|mimoto|datashare|postgres|redis|esignet' || true

  echo
  echo "===== PostgreSQL Services ====="
  kubectl get svc -n postgres

  echo
  echo "===== Existing Inji Secrets (Names Only) ====="
  for ns in inji-certify inji-verify mimoto injiweb; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
      kubectl get secrets -n "$ns" \
        -o custom-columns=NAME:.metadata.name,TYPE:.type
    fi
  done

} | tee "$REPORT"

echo
echo "Inventory saved to: $REPORT"
