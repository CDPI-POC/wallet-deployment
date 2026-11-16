#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
source "${CONFIG:-$ROOT/config/inji.env}"
: "${EXPECTED_NODE:=inji-test}" "${DB_NAMESPACE:=inji-db}" "${DB_ADMIN_SECRET:=inji-db-admin}" "${DB_HOST:?}" "${DB_PORT:=5432}" "${DB_ADMIN_USER:=postgres}" "${DB_SSLMODE:=prefer}" "${POSTGRES_IMAGE:=postgres:16}" "${TIMEOUT:=900s}" "${MODULES_FILE:=$ROOT/config/modules.tsv}"
log(){ printf '[%s] %s\n' "$(date -Is)" "$*"; }
die(){ log "ERROR: $*" >&2; exit 1; }
trap 'log "FAILED at line $LINENO; no database drop or namespace deletion attempted" >&2' ERR
for c in kubectl helm python3; do command -v "$c" >/dev/null || die "Missing $c"; done
kubectl cluster-info >/dev/null
kubectl get node "$EXPECTED_NODE" >/dev/null || die "Node $EXPECTED_NODE not found. Check kubeconfig"
[[ "$(kubectl get node "$EXPECTED_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]] || die 'Node not Ready'
[[ "${CONFIRM_DEPLOY:-NO}" == YES ]] || die 'Set CONFIRM_DEPLOY=YES in config after review'
[[ -f "$MODULES_FILE" ]] || die "Missing $MODULES_FILE"
mkdir -p "$ROOT/reports"; exec > >(tee -a "$ROOT/reports/deploy-$(date +%Y%m%d-%H%M%S).log") 2>&1
log "Context: $(kubectl config current-context); node: $EXPECTED_NODE"
kubectl get secret "$DB_ADMIN_SECRET" -n "$DB_NAMESPACE" -o jsonpath='{.data.PGPASSWORD}' | grep -q . || die "Secret $DB_NAMESPACE/$DB_ADMIN_SECRET must contain PGPASSWORD"
# SQL is sent through stdin to an ephemeral PostgreSQL client pod. Credentials come from Kubernetes Secret.
psql_run(){
 local db="$1" sql="$2" pod="inji-psql-$RANDOM-$RANDOM" manifest
 manifest=$(mktemp); chmod 600 "$manifest"
 python3 - "$pod" "$DB_NAMESPACE" "$POSTGRES_IMAGE" "$DB_ADMIN_SECRET" "$DB_HOST" "$DB_PORT" "$DB_ADMIN_USER" "$DB_SSLMODE" "$db" > "$manifest" <<'PY'
import json,sys
pod,ns,img,secret,host,port,user,ssl,db=sys.argv[1:]
print(json.dumps({'apiVersion':'v1','kind':'Pod','metadata':{'name':pod,'namespace':ns},'spec':{'restartPolicy':'Never','containers':[{'name':'client','image':img,'command':['sh','-c','sleep 600'],'envFrom':[{'secretRef':{'name':secret}}],'env':[{'name':k,'value':v} for k,v in {'PGHOST':host,'PGPORT':port,'PGUSER':user,'PGSSLMODE':ssl,'PGDATABASE':db}.items()]}]}}))
PY
 kubectl apply -f "$manifest" >/dev/null; rm -f "$manifest"
 local rc=0
 kubectl wait -n "$DB_NAMESPACE" --for=jsonpath='{.status.phase}'=Running "pod/$pod" --timeout=180s >/dev/null || rc=$?
 if ((rc==0)); then kubectl exec -i -n "$DB_NAMESPACE" "$pod" -- psql -X -A -t -v ON_ERROR_STOP=1 -f - <<< "$sql" || rc=$?; fi
 kubectl delete pod "$pod" -n "$DB_NAMESPACE" --ignore-not-found --wait=false >/dev/null || true
 return "$rc"
}
# Quote SQL identifiers and literals safely, including arbitrary passwords; no shell eval.
qsql(){ python3 - "$1" "$2" <<'PY'
import sys
v,kind=sys.argv[1:]
print(('"'+v.replace('"','""')+'"') if kind=='ident' else ("'"+v.replace("'","''")+"'"))
PY
}
# Columns: release namespace chart values db_name db_user password_secret_key migrations_dir mode
# mode: install | existing | disabled. 'existing' validates an installed release without changing it.
while IFS=$'\t' read -r release ns chart values db user passkey migration mode; do
 [[ -z "$release" || "$release" == \#* ]] && continue
 [[ "$release" =~ ^[a-z0-9][a-z0-9-]*$ && "$ns" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Bad release or namespace $release $ns"
 [[ "$mode" == disabled ]] && { log "Disabled: $release"; continue; }
 kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
 if [[ "$db" != - ]]; then
  [[ "$db" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ && "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "Invalid database identifiers for $release"
  # Per-module DB password secret must exist already; never log or store credentials in values.
  [[ "$passkey" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid secret key for $release"
  kubectl get secret "$release-db-auth" -n "$ns" -o jsonpath="{.data.$passkey}" | grep -q . || die "Create secret $ns/$release-db-auth with key $passkey"
  pass=$(kubectl get secret "$release-db-auth" -n "$ns" -o "jsonpath={.data.$passkey}" | base64 -d)
  role=$(qsql "$user" ident); database=$(qsql "$db" ident); password=$(qsql "$pass" literal)
  log "Ensuring DB role $user and database $db"
  # psql \gexec ensures CREATE DATABASE runs outside a transaction and only when absent.
  psql_run postgres "SELECT 'CREATE ROLE $role LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $(qsql "$user" literal)) \\gexec
ALTER ROLE $role PASSWORD $password;
SELECT 'CREATE DATABASE $database OWNER $role' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = $(qsql "$db" literal)) \\gexec
GRANT ALL PRIVILEGES ON DATABASE $database TO $role;"
  unset pass password
  if [[ "$migration" != - ]]; then
   [[ -d "$ROOT/sql/$migration" ]] || die "Missing migrations: sql/$migration"
   shopt -s nullglob; files=("$ROOT/sql/$migration"/*.sql); shopt -u nullglob
   ((${#files[@]})) || die "No SQL files in sql/$migration"
   for file in "${files[@]}"; do
    name=$(basename "$file"); [[ "$name" =~ ^[a-zA-Z0-9_.-]+\.sql$ ]] || die "Invalid migration filename"
    # Do not reapply completed SQL migrations. Serial execution and advisory lock are required for concurrent deploy protection.
    log "Checking migration $release/$name"
    exists=$(psql_run "$db" "CREATE SCHEMA IF NOT EXISTS inji_deploy; CREATE TABLE IF NOT EXISTS inji_deploy.migrations(name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now()); SELECT name FROM inji_deploy.migrations WHERE name=$(qsql "$name" literal);" | grep -Fx "$name" || true)
    if [[ -z "$exists" ]]; then
     sql=$(cat "$file")
     # Transactional migration, records success in same transaction. Migration files must be transaction-compatible.
     psql_run "$db" "BEGIN; SELECT pg_advisory_xact_lock(941027); $sql
INSERT INTO inji_deploy.migrations(name) VALUES ($(qsql "$name" literal)) ON CONFLICT DO NOTHING; COMMIT;"
    fi
   done
  fi
 fi
 if [[ "$mode" == existing ]]; then
  helm status "$release" -n "$ns" >/dev/null || die "Expected existing Helm release $ns/$release"
  log "Preserved existing Helm release $ns/$release"
 elif [[ "$mode" == install ]]; then
  [[ -f "$ROOT/values/$values" ]] || die "Missing values/$values"
  [[ -f "$ROOT/charts/$chart/Chart.yaml" ]] || die "Missing pinned local chart charts/$chart"
  log "Installing/upgrading $ns/$release"
  helm upgrade --install "$release" "$ROOT/charts/$chart" -n "$ns" -f "$ROOT/values/$values" --wait --atomic --timeout "$TIMEOUT" --history-max 10
 else die "Unknown mode $mode"; fi
 kubectl get pods -n "$ns" -o wide
 log "Validated $ns/$release"
done < "$MODULES_FILE"
log 'All selected releases processed. Run issuance, OIDC, signature and verification E2E tests before go-live.'
