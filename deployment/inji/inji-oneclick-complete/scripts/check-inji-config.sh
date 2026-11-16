#!/usr/bin/env bash
set -Eeuo pipefail
NS="${NS_CERTIFY:-inji-certify}"
SERVICE="${INJI_CONFIG_SERVER_NAME:-inji-config-server}"
BRANCH="${INJI_CONFIG_BRANCH:-Injitest_autodeploy}"
URL="http://${SERVICE}.${NS}.svc.cluster.local/config/certify/mock-identity/${BRANCH}"
# Use a temporary curl pod to test from within Kubernetes; don't print full config (may contain secrets).
POD="inji-config-check-$$"
trap 'kubectl delete pod "$POD" -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
kubectl run "$POD" -n "$NS" --image=curlimages/curl:8.11.1 --restart=Never \
  --command -- sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do curl -fsS "$1" -o /tmp/response && grep -q "mosip.certify.integration.scan-base-package" /tmp/response && exit 0; sleep 5; done; exit 1' sh "$URL" >/dev/null
kubectl wait -n "$NS" --for=jsonpath='{.status.phase}'=Succeeded pod/"$POD" --timeout=150s >/dev/null || {
  echo "Config endpoint missing expected property or unreachable: $URL" >&2
  kubectl logs -n "$NS" "$POD" --tail=30 >&2 || true
  exit 1
}
echo "PASS: Config endpoint contains integration scan property: $URL"
