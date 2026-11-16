#!/bin/bash
set -euo pipefail

SOURCE="inji-certify"
NAMESPACES=("inji-verify" "mimoto" "injiweb")

CONFIGMAPS=(
  "inji-stack-config"
  "config-server-share"
  "softhsm-certify-share"
)

for ns in "${NAMESPACES[@]}"; do
  echo "Processing namespace: $ns"

  kubectl get namespace "$ns" >/dev/null

  for cm in "${CONFIGMAPS[@]}"; do
    if kubectl get configmap "$cm" -n "$ns" >/dev/null 2>&1; then
      echo "Preserving existing ConfigMap $ns/$cm"
      continue
    fi

    kubectl get configmap "$cm" -n "$SOURCE" -o json |
      python3 -c '
import json,sys
obj=json.load(sys.stdin)
obj["metadata"]={
    "name":obj["metadata"]["name"],
    "namespace":sys.argv[1]
}
obj.pop("status",None)
print(json.dumps(obj))
' "$ns" | kubectl create -f -

    echo "Created ConfigMap $ns/$cm"
  done
done
