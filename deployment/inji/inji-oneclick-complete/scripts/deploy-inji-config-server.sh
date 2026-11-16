#!/usr/bin/env bash
set -Eeuo pipefail
NS="${NS_CERTIFY:-inji-certify}"
NAME="${INJI_CONFIG_SERVER_NAME:-inji-config-server}"
REPO="${INJI_CONFIG_REPO:-https://github.com/sjkarthik/inji-config.git}"
BRANCH="${INJI_CONFIG_BRANCH:-Injitest_autodeploy}"
IMAGE="${INJI_CONFIG_SERVER_IMAGE:-mosipid/config-server:1.1.2}"
APPLY="${APPLY:-NO}"
OUT="${OUT:-${PWD}/reports/rendered/inji-config-server.yaml}"
mkdir -p "$(dirname "$OUT")"
for bin in kubectl python3; do command -v "$bin" >/dev/null || { echo "Missing $bin" >&2; exit 1; }; done
[[ "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo 'Invalid namespace' >&2; exit 1; }
[[ "$NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo 'Invalid service name' >&2; exit 1; }
export NS NAME REPO BRANCH IMAGE OUT
python3 - <<'PY'
import os, json
n=os.environ
name=n['NAME']; ns=n['NS']; repo=n['REPO']; branch=n['BRANCH']; image=n['IMAGE']
# JSON is a YAML-compatible Kubernetes manifest, separated as independent JSON documents.
objects=[
 {'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':name+'-env','namespace':ns},'data':{
   'SPRING_CLOUD_CONFIG_SERVER_GIT_URI':repo,
   'SPRING_CLOUD_CONFIG_SERVER_GIT_DEFAULT_LABEL':branch,
   'SPRING_CLOUD_CONFIG_SERVER_GIT_SEARCHPATHS':'',
   'SPRING_CLOUD_CONFIG_SERVER_GIT_CLONE_ON_START':'true',
   'SPRING_CLOUD_CONFIG_SERVER_GIT_USERNAME':'',
   'SERVER_PORT':'51000',
   
 }},
 {'apiVersion':'apps/v1','kind':'Deployment','metadata':{'name':name,'namespace':ns},'spec':{
   'replicas':1,'selector':{'matchLabels':{'app':name}},
   'template':{'metadata':{'labels':{'app':name}},'spec':{
     'containers':[{'name':'config-server','image':image,'imagePullPolicy':'IfNotPresent',
       'ports':[{'name':'http','containerPort':51000}],
       'envFrom':[{'configMapRef':{'name':name+'-env'}}],
       'readinessProbe':{'tcpSocket':{'port':51000},'initialDelaySeconds':15,'periodSeconds':10},
       'startupProbe':{'tcpSocket':{'port':51000},'failureThreshold':36,'periodSeconds':10},
       'resources':{'requests':{'cpu':'50m','memory':'384Mi'},'limits':{'cpu':'500m','memory':'1500Mi'}}
     }]
   }}}
 },
 {'apiVersion':'v1','kind':'Service','metadata':{'name':name,'namespace':ns},'spec':{
   'selector':{'app':name},'ports':[{'name':'http','port':80,'targetPort':51000}], 'type':'ClusterIP'
 }}
]
with open(n['OUT'],'w') as f:
 for i,o in enumerate(objects):
  if i: f.write('---\n')
  json.dump(o,f,indent=2);f.write('\n')
print('Rendered:',n['OUT'])
PY
if [[ "$APPLY" != YES ]]; then
  echo 'Render-only mode. Set APPLY=YES to apply after review.'
  exit 0
fi
kubectl get namespace "$NS" >/dev/null
kubectl apply -f "$OUT"

echo "Restarting dedicated Inji Config Server..."
kubectl rollout restart deployment/"$NAME" -n "$NS"

echo "Waiting for Config Server rollout..."
kubectl rollout status deployment/"$NAME" -n "$NS" --timeout=300s

echo "Validating Inji Config Server Git configuration..."

kubectl exec -n "$NS" deployment/"$NAME" -- sh -c '
  curl -fsS --max-time 30     http://127.0.0.1:51000/config/certify/mock-identity/Injitest_autodeploy
' | python3 -c '
import json
import sys

data = json.load(sys.stdin)

key = "mosip.certify.integration.scan-base-package"
expected = "io.mosip.certify.mock.integration"

if data.get("label") != "Injitest_autodeploy":
    sys.exit("ERROR: Incorrect Git label")

for source in data.get("propertySources", []):
    value = source.get("source", {}).get(key)
    if value == expected:
        print("Inji Config Server validation PASSED")
        sys.exit(0)

sys.exit("ERROR: Required configuration property missing or incorrect")
'

printf 'Config Server deployed. Test: http://%s.%s.svc.cluster.local/config/certify/mock-identity/%s\n' "$NAME" "$NS" "$BRANCH"
