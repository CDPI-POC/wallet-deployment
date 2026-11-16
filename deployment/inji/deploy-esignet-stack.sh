#!/usr/bin/env bash
# MOSIP eSignet v1.4.0 + mock services v0.12.0 deployment controller.
# Requires pre-existing PostgreSQL, Keycloak, Config Server, Artifactory, global ConfigMap and Istio.
set -Eeuo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/config/identity.env}"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE; copy config/identity.env.example" >&2; exit 2; }
# shellcheck disable=SC1090
source "$ENV_FILE"
MODE="${1:---check}"
case "$MODE" in --check|--fetch|--render|--deploy|--status|--db-init) ;; *) echo 'Usage: ./deploy-esignet-stack.sh [--check|--fetch|--render|--db-init|--deploy|--status]' >&2; exit 2;; esac
LOG_DIR="$ROOT/logs"; mkdir -p "$LOG_DIR"; chmod 700 "$LOG_DIR"
LOG_FILE="$LOG_DIR/identity-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG_FILE") 2>&1
say(){ printf '[%s] %s\n' "$(date -Is)" "$*"; }
die(){ say "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null || die "Missing $1"; }
require_file(){ [[ -s "$1" ]] || die "Missing or empty file: $1"; }
helm_status(){ helm status "$1" -n "$2" -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null || echo absent; }
ns(){ kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }
check_context(){
  for c in kubectl helm python3 git openssl; do need "$c"; done
  kubectl cluster-info >/dev/null || die 'Kubernetes inaccessible'
  local c; c="$(kubectl config current-context)"
  [[ -n "${EXPECTED_CONTEXT:-}" && "$c" == "$EXPECTED_CONTEXT" ]] || die "Set EXPECTED_CONTEXT to current Kubernetes context ($c)"
  [[ "${ALLOW_DB_INIT:-NO}" == YES || "${ALLOW_DB_INIT:-NO}" == NO ]] || die 'ALLOW_DB_INIT must be YES or NO'
  [[ "${ALLOW_EXISTING_UPGRADES:-NO}" == YES || "${ALLOW_EXISTING_UPGRADES:-NO}" == NO ]] || die 'ALLOW_EXISTING_UPGRADES must be YES or NO'
  kubectl get namespace postgres keycloak config-server artifactory >/dev/null || die 'Foundation namespaces are missing'
  kubectl get deployment config-server -n config-server >/dev/null || die 'Missing config-server Deployment'
  kubectl get cm global -n default >/dev/null || die 'Missing default/global ConfigMap'
  [[ -n "${ESIGNET_HOST:-}" && -n "${MOCK_RP_HOST:-}" ]] || die 'Set ESIGNET_HOST and MOCK_RP_HOST'
  [[ "${PLUGIN_MODE:-mock}" == mock ]] || die 'Only mock identity plugin mode is supported by this package; other plugins need audited overrides/images'
  say "Cluster context verified: $c"
}
repo_setup(){ helm repo add mosip https://mosip.github.io/mosip-helm --force-update >/dev/null; helm repo add bitnami https://charts.bitnami.com/bitnami --force-update >/dev/null; helm repo update mosip bitnami >/dev/null; }
ensure_sources(){
  mkdir -p "$ROOT/sources"
  local repo tag folder
  for item in 'esignet v1.4.0' 'esignet-mock-services v0.12.0'; do
    read -r repo tag <<< "$item"; folder="$ROOT/sources/$repo"
    if [[ ! -d "$folder/.git" ]]; then
      [[ ! -e "$folder" ]] || die "Refusing non-git source directory: $folder"
      git clone --quiet --no-checkout "https://github.com/mosip/$repo.git" "$folder"
    fi
    git -C "$folder" fetch --quiet --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    git -C "$folder" checkout --quiet --detach "refs/tags/$tag"
    say "Pinned sources: mosip/$repo $tag ($(git -C "$folder" rev-parse --short HEAD))"
  done
}
# Copy only selected object into another namespace. Never delete/overwrite destination by default.
copy_resource(){
  local kind="$1" name="$2" src="$3" dst="$4" dest="${5:-$2}"
  kubectl get "$kind" "$name" -n "$src" >/dev/null || die "Missing $src/$kind/$name"
  if kubectl get "$kind" "$dest" -n "$dst" >/dev/null 2>&1; then say "Preserving $dst/$kind/$dest"; return; fi
  say "Copying $src/$kind/$name -> $dst/$kind/$dest"
  kubectl get "$kind" "$name" -n "$src" -o json | python3 -c '
import json,sys
x=json.load(sys.stdin)
keep={"apiVersion":x["apiVersion"],"kind":x["kind"],"metadata":{"name":sys.argv[1],"namespace":sys.argv[2]}}
for k in ("data","binaryData","stringData","type","immutable"):
 if k in x: keep[k]=x[k]
print(json.dumps(keep))
' "$dest" "$dst" | kubectl create -f - >/dev/null
}
assert_secret_key(){ local ns="$1" secret="$2" key="$3"; kubectl get secret "$secret" -n "$ns" -o json | python3 -c 'import json,sys; x=json.load(sys.stdin); sys.exit(0 if sys.argv[1] in x.get("data",{}) else 1)' "$key" || die "Missing $ns/$secret key $key"; }
create_empty_secret(){
  local ns="$1" name="$2" key="$3"
  if kubectl get secret "$name" -n "$ns" >/dev/null 2>&1; then say "Preserving existing $ns/$name"; return; fi
  kubectl -n "$ns" create secret generic "$name" "--from-literal=$key=" >/dev/null
  say "Created upstream-compatible placeholder $ns/$name; replace with real keys before production testing"
}
# Patch references, not decoded credential values. Config Server Helm management can later overwrite these fields.
config_server_override(){
  local secret_ns="$1" secret_name="$2" key="$3" prefix="$4"
  kubectl -n config-server set env deployment/config-server --from="secret/$secret_name" --keys="$key" --prefix="$prefix" >/dev/null
  say "Config Server references $secret_ns/$secret_name:$key (Secret value never logged)"
}
apply_config_server_overrides(){
  [[ "${MANAGE_CONFIG_SERVER_OVERRIDES:-NO}" == YES ]] || { say 'Config Server override patching disabled; existing configuration must resolve all eSignet properties'; return; }
  # Ensure Config Server has referenced secrets in its own namespace.
  copy_resource secret redis redis config-server
  copy_resource secret esignet-captcha esignet config-server
  copy_resource secret esignet-misp-onboarder-key esignet config-server
  copy_resource secret softhsm-esignet softhsm config-server
  kubectl -n config-server set env deployment/config-server "SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_MOSIP_ESIGNET_HOST=$ESIGNET_HOST" >/dev/null
  if kubectl get secret keycloak-client-secrets -n config-server >/dev/null 2>&1; then
    config_server_override config-server keycloak-client-secrets mosip_pms_client_secret SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_
    config_server_override config-server keycloak-client-secrets mpartner_default_auth_secret SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_
  fi
  config_server_override config-server redis redis-password SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_
  config_server_override config-server esignet-captcha esignet-captcha-site-key SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_
  config_server_override config-server esignet-captcha esignet-captcha-secret-key SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_
  config_server_override config-server esignet-misp-onboarder-key mosip-esignet-misp-key SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_
  config_server_override config-server softhsm-esignet security-pin SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_SOFTHSM_ESIGNET_
  kubectl rollout status deployment/config-server -n config-server --timeout="${WAIT_TIMEOUT:-360s}" >/dev/null
}
# Chart release is never modified if deployed, unless operator separately opts into upgrades.
install_release(){
  local release="$1" nsname="$2" chart="$3" version="$4" values="$5" status
  require_file "$values"
  status="$(helm_status "$release" "$nsname")"
  if [[ "$status" == deployed && "${ALLOW_EXISTING_UPGRADES:-NO}" != YES ]]; then say "Preserving deployed Helm release $nsname/$release"; return; fi
  [[ "$status" == absent || "$status" == deployed ]] || die "Helm release $nsname/$release status '$status'; manual inspection required"
  say "Helm deploying $nsname/$release chart=$chart version=$version"
  local -a public_overrides=()
  case "$release" in
    esignet|oidc-ui)
      public_overrides+=(--set-string "istio.hosts[0]=$ESIGNET_HOST")
      if [[ "$release" == esignet ]]; then
        if [[ -n "${PLUGIN_CONFIGMAP_NAME:-}" ]]; then
          public_overrides+=(--set-string "extraEnvVarsCM[4]=$PLUGIN_CONFIGMAP_NAME")
        fi
        if [[ -n "${PLUGIN_SECRET_NAME:-}" ]]; then
          public_overrides+=(--set-string "extraEnvVarsSecret[0]=$PLUGIN_SECRET_NAME")
        fi
      fi;;
    mock-relying-party-service)
      public_overrides+=(--set-string "mock_relying_party_service.ESIGNET_SERVICE_URL=http://esignet.esignet/v1/esignet")
      public_overrides+=(--set-string "mock_relying_party_service.ESIGNET_AUD_URL=https://$ESIGNET_HOST/v1/esignet/oauth/v2/token");;
    mock-relying-party-ui)
      public_overrides+=(--set-string "mock_relying_party_ui.mock_relying_party_ui_service_host=$MOCK_RP_HOST")
      public_overrides+=(--set-string "mock_relying_party_ui.MOCK_RELYING_PARTY_SERVICE_INTERNAL_URL=http://mock-relying-party-service.esignet")
      public_overrides+=(--set-string "mock_relying_party_ui.ESIGNET_UI_BASE_URL=https://$ESIGNET_HOST")
      public_overrides+=(--set-string "mock_relying_party_ui.MOCK_RELYING_PARTY_SERVER_URL=https://$MOCK_RP_HOST/mock-relying-party-service")
      public_overrides+=(--set-string "mock_relying_party_ui.REDIRECT_URI=https://$MOCK_RP_HOST/userprofile")
      public_overrides+=(--set-string "mock_relying_party_ui.REDIRECT_URI_REGISTRATION=https://$MOCK_RP_HOST/registration")
      public_overrides+=(--set-string "mock_relying_party_ui.SIGN_IN_BUTTON_PLUGIN_URL=https://$ESIGNET_HOST/plugins/sign-in-button-plugin.js")
      public_overrides+=(--set-string "istio.hosts[0]=$MOCK_RP_HOST");;
  esac
  helm upgrade --install "$release" "$chart" -n "$nsname" --create-namespace --version "$version" -f "$values" \
    "${public_overrides[@]}" --wait --timeout "${HELM_TIMEOUT:-15m}" --history-max 10 >/dev/null
  [[ "$(helm_status "$release" "$nsname")" == deployed ]] || die "$nsname/$release is not deployed"
}
# Do not use upstream destructive db_scripts/mosip_esignet/deploy.sh or init_db.sh on existing databases.
PG_POD=''
cleanup(){ if [[ -n "$PG_POD" ]]; then kubectl delete pod "$PG_POD" -n postgres --ignore-not-found --wait=false >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT
start_psql(){
  [[ -z "$PG_POD" ]] || return
  assert_secret_key postgres "${PG_ADMIN_SECRET:-postgres-postgresql}" "${PG_ADMIN_SECRET_KEY:-postgres-password}"
  assert_secret_key postgres "${DB_COMMON_SECRET:-db-common-secrets}" "${DB_COMMON_KEY:-db-dbuser-password}"
  PG_POD="esignet-db-bootstrap-$(openssl rand -hex 4)"
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $PG_POD
  namespace: postgres
spec:
  restartPolicy: Never
  containers:
  - name: psql
    image: ${PG_CLIENT_IMAGE:-postgres:16}
    command: ["sleep","3600"]
    env:
    - name: PGHOST
      value: "${PG_HOST:-postgres-postgresql.postgres.svc.cluster.local}"
    - name: PGPORT
      value: "${PG_PORT:-5432}"
    - name: PGUSER
      value: "${PG_ADMIN_USER:-postgres}"
    - name: PGPASSWORD
      valueFrom:
        secretKeyRef:
          name: ${PG_ADMIN_SECRET:-postgres-postgresql}
          key: ${PG_ADMIN_SECRET_KEY:-postgres-password}
    - name: DBUSERPASSWORD
      valueFrom:
        secretKeyRef:
          name: ${DB_COMMON_SECRET:-db-common-secrets}
          key: ${DB_COMMON_KEY:-db-dbuser-password}
YAML
  kubectl wait -n postgres --for=jsonpath='{.status.phase}'=Running "pod/$PG_POD" --timeout=240s >/dev/null
}
psql_admin(){ kubectl exec -i -n postgres "$PG_POD" -c psql -- psql -X -v ON_ERROR_STOP=1 "$@"; }
bootstrap_db(){
  local db="$1" role="$2" schema="$3" relpath="$4" marker="identity_stack_bootstrap" existing
  [[ "${ALLOW_DB_INIT:-NO}" == YES ]] || die "Database initialization disabled. Set ALLOW_DB_INIT=YES only after a backup"
  [[ "$db" =~ ^[a-z_]+$ && "$role" =~ ^[a-z_]+$ && "$schema" =~ ^[a-z_]+$ ]] || die 'Invalid database identifier'
  start_psql
  existing="$(psql_admin -d postgres -Atc "SELECT count(*) FROM pg_database WHERE datname='$db'")"
  if [[ "$existing" == 1 ]]; then
    # Existing DB never modified. Require explicit acknowledgement when no local init marker exists.
    local has_marker
    has_marker="$(psql_admin -d "$db" -Atc "SELECT CASE WHEN to_regclass('public.identity_stack_bootstrap') IS NULL THEN 0 ELSE 1 END")"
    if [[ "$has_marker" == 1 ]]; then
      local completed
      completed="$(psql_admin -d "$db" -Atc "SELECT count(*) FROM public.identity_stack_bootstrap WHERE module='$db'")"
      if [[ "$completed" == 1 ]]; then say "Preserving previously initialized $db"; return; fi
    fi
    [[ "${ALLOW_EXISTING_DATABASES:-NO}" == YES ]] || die "Database $db exists without completion marker. Preserve and audit it; set ALLOW_EXISTING_DATABASES=YES only for VERIFIED pre-existing DBs"
    say "Preserving externally initialized $db by explicit approval; SQL not re-run"
    return
  fi
  local role_exists
  role_exists="$(psql_admin -d postgres -Atc "SELECT count(*) FROM pg_roles WHERE rolname='$role'")"
  [[ "$role_exists" == 0 ]] || die "Role $role exists, but $db absent; validate credentials manually"
  say "Creating fresh PostgreSQL database $db and role $role; no DROP/TRUNCATE against existing DB"
  kubectl exec -i -n postgres "$PG_POD" -c psql -- bash -s -- "$db" "$role" "$schema" <<'INNER'
set -Eeuo pipefail
db="$1"; role="$2"; schema="$3"
psql -X -v ON_ERROR_STOP=1 -d postgres -v db="$db" -v role="$role" <<'SQL'
\getenv rolepassword DBUSERPASSWORD
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'rolepassword') \gexec
SELECT format('CREATE DATABASE %I OWNER postgres ENCODING ''UTF8''', :'db') \gexec
SQL
psql -X -v ON_ERROR_STOP=1 -d "$db" -v schema="$schema" <<'SQL'
SELECT format('CREATE SCHEMA %I', :'schema') \gexec
SQL
psql -X -v ON_ERROR_STOP=1 -d postgres -v db="$db" -v schema="$schema" <<'SQL'
SELECT format('ALTER DATABASE %I SET search_path TO %I,pg_catalog,public', :'db', :'schema') \gexec
SQL
INNER
  local src="$ROOT/sources/$relpath"
  [[ -f "$src/ddl.sql" && -f "$src/dml.sql" && -f "$src/grants.sql" ]] || die "Upstream SQL missing at $src"
  kubectl exec -n postgres "$PG_POD" -c psql -- mkdir -p "/work/$db"
  kubectl cp "$src/." "postgres/$PG_POD:/work/$db/" -c psql >/dev/null
  kubectl exec -i -n postgres "$PG_POD" -c psql -- bash -s -- "$db" <<'INNER'
set -Eeuo pipefail
cd "/work/$1"
psql -X -v ON_ERROR_STOP=1 -d "$1" -f ddl.sql >/dev/null
psql -X -v ON_ERROR_STOP=1 -d "$1" -f dml.sql >/dev/null
psql -X -v ON_ERROR_STOP=1 -d "$1" -f grants.sql >/dev/null
psql -X -v ON_ERROR_STOP=1 -d "$1" -v module="$1" <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS public.identity_stack_bootstrap (module text primary key, initialized_at timestamptz NOT NULL DEFAULT now());
INSERT INTO public.identity_stack_bootstrap(module) VALUES(:'module') ON CONFLICT DO NOTHING;
SQL
INNER
  say "Fresh database $db initialized using upstream pinned DDL/DML/grants"
}
prepare_namespaces(){
  for n in redis softhsm esignet mockid; do ns "$n"; done
  for n in redis softhsm esignet mockid; do kubectl label ns "$n" istio-injection=enabled --overwrite >/dev/null; done
}
prepare_global(){
  copy_resource configmap global default esignet
  copy_resource configmap global default config-server
  copy_resource configmap artifactory-share artifactory esignet
  copy_resource configmap config-server-share config-server esignet
}
prepare_redis(){
  install_release redis redis bitnami/redis 17.3.14 "$ROOT/values/redis.yaml"
  copy_resource secret redis redis config-server
  copy_resource secret redis redis mockid
  if kubectl get cm redis-config -n redis >/dev/null 2>&1; then copy_resource configmap redis-config redis mockid; fi
}
prepare_hsm(){
  install_release softhsm-esignet softhsm mosip/softhsm 12.0.1 "$ROOT/values/softhsm-esignet.yaml"
  install_release softhsm-mock-identity-system softhsm mosip/softhsm 12.0.1 "$ROOT/values/softhsm-mock-identity-system.yaml"
  copy_resource secret softhsm-esignet softhsm config-server
  copy_resource configmap softhsm-esignet-share softhsm esignet
  copy_resource secret softhsm-mock-identity-system softhsm mockid
  copy_resource configmap softhsm-mock-identity-system-share softhsm mockid
}
prepare_db(){
  copy_resource secret "${PG_ADMIN_SECRET:-postgres-postgresql}" postgres esignet
  copy_resource secret "${PG_ADMIN_SECRET:-postgres-postgresql}" postgres mockid
  copy_resource secret "${DB_COMMON_SECRET:-db-common-secrets}" postgres esignet
  copy_resource secret "${DB_COMMON_SECRET:-db-common-secrets}" postgres mockid
  bootstrap_db mosip_esignet esignetuser esignet esignet/db_scripts/mosip_esignet
  bootstrap_db mosip_mockidentitysystem mockidsystemuser mockidentitysystem esignet-mock-services/db_scripts/mosip_mockidentitysystem
  # The upstream mock identity Helm chart expects this configmap name / keys.
  if ! kubectl get cm mockid-postgres-config -n mockid >/dev/null 2>&1; then
    kubectl -n mockid create cm mockid-postgres-config \
      --from-literal=database-host="${PG_HOST:-postgres-postgresql.postgres.svc.cluster.local}" \
      --from-literal=database-port="${PG_PORT:-5432}" \
      --from-literal=database-name=mosip_mockidentitysystem \
      --from-literal=database-username=mockidsystemuser \
      --from-literal=database-schema=mockidentitysystem >/dev/null
  fi
  cleanup; PG_POD=''
}
prepare_captcha(){
  # Credentials may be supplied in a pre-created Secret or injected from an encrypted secret manifest.
  if ! kubectl get secret esignet-captcha -n esignet >/dev/null 2>&1; then
    [[ -n "${ENCRYPTED_RESOURCES:-}" ]] || die 'Missing esignet/esignet-captcha; provide an encrypted resources bundle'
    die 'Encrypted resource bundle did not create esignet/esignet-captcha'
  fi
  assert_secret_key esignet esignet-captcha esignet-captcha-site-key
  assert_secret_key esignet esignet-captcha esignet-captcha-secret-key
  create_empty_secret esignet esignet-misp-onboarder-key mosip-esignet-misp-key
}
decrypt_resources(){
  [[ -z "${ENCRYPTED_RESOURCES:-}" ]] && return
  need sops
  require_file "$ENCRYPTED_RESOURCES"
  say 'Applying SOPS encrypted Kubernetes resources; plaintext kept in pipe only'
  sops --decrypt "$ENCRYPTED_RESOURCES" | kubectl apply -f - >/dev/null
}
prepare_keycloak(){
  copy_resource configmap keycloak-host keycloak esignet
  copy_resource configmap keycloak-env-vars keycloak esignet
  copy_resource secret keycloak keycloak esignet
  if [[ "$(helm_status esignet-keycloak-init esignet)" == deployed && "${ALLOW_EXISTING_UPGRADES:-NO}" != YES ]]; then
    say 'Preserving existing esignet-keycloak-init'
    if kubectl get secret keycloak-client-secrets -n keycloak >/dev/null 2>&1; then
      copy_resource secret keycloak-client-secrets keycloak config-server
      copy_resource secret keycloak-client-secrets keycloak esignet
    fi
    return
  fi
  require_file "$ROOT/values/esignet-keycloak-init.yaml"
  if [[ "${RUN_KEYCLOAK_INIT:-NO}" == YES ]]; then
    # Operator must supply correct, approved clientSecrets values via an encrypted values file.
    if [[ -n "${KEYCLOAK_INIT_PRIVATE_VALUES_SOPS:-}" ]]; then
      need sops
      require_file "$KEYCLOAK_INIT_PRIVATE_VALUES_SOPS"
      sops --decrypt "$KEYCLOAK_INIT_PRIVATE_VALUES_SOPS" >/dev/null || die 'Cannot decrypt Keycloak client Secret values'
      helm upgrade --install esignet-keycloak-init mosip/keycloak-init -n esignet --version 12.0.1 \
        -f "$ROOT/values/esignet-keycloak-init.yaml" -f <(sops --decrypt "$KEYCLOAK_INIT_PRIVATE_VALUES_SOPS") \
        --wait --wait-for-jobs --timeout "${HELM_TIMEOUT:-15m}" --history-max 10 >/dev/null
    else
      [[ -n "${KEYCLOAK_INIT_PRIVATE_VALUES:-}" ]] || die 'Set KEYCLOAK_INIT_PRIVATE_VALUES_SOPS or KEYCLOAK_INIT_PRIVATE_VALUES for new Keycloak init'
      require_file "$KEYCLOAK_INIT_PRIVATE_VALUES"
      helm upgrade --install esignet-keycloak-init mosip/keycloak-init -n esignet --version 12.0.1 \
        -f "$ROOT/values/esignet-keycloak-init.yaml" -f "$KEYCLOAK_INIT_PRIVATE_VALUES" \
        --wait --wait-for-jobs --timeout "${HELM_TIMEOUT:-15m}" --history-max 10 >/dev/null
    fi
  else
    die 'eSignet Keycloak init is absent. Set RUN_KEYCLOAK_INIT=YES and KEYCLOAK_INIT_PRIVATE_VALUES'
  fi
  if kubectl get secret keycloak-client-secrets -n keycloak >/dev/null 2>&1; then
    copy_resource secret keycloak-client-secrets keycloak config-server
    copy_resource secret keycloak-client-secrets keycloak esignet
  fi
}
prepare_identity_config(){
  copy_resource configmap esignet-global esignet mockid
  copy_resource configmap softhsm-esignet-share softhsm esignet
  copy_resource configmap artifactory-share artifactory esignet
  copy_resource configmap config-server-share config-server esignet
  copy_resource configmap global default esignet
  kubectl get cm oidc-ui -n esignet >/dev/null || die "Missing esignet/oidc-ui ConfigMap; supply via encrypted resources bundle"
  # Leave existing custom plugin ConfigMaps and Secrets untouched; Helm override references them.
  if [[ "${PLUGIN_CONFIGMAP_NAME:-}" != '' ]]; then kubectl get cm "$PLUGIN_CONFIGMAP_NAME" -n esignet >/dev/null || die 'Missing plugin ConfigMap'; fi
  if [[ "${PLUGIN_SECRET_NAME:-}" != '' ]]; then kubectl get secret "$PLUGIN_SECRET_NAME" -n esignet >/dev/null || die 'Missing plugin Secret'; fi
}
precheck(){
  check_context
  for o in 'configmap global default' 'configmap artifactory-share artifactory' 'configmap config-server-share config-server' 'secret keycloak keycloak' 'configmap keycloak-host keycloak'; do
    read -r kind name n <<< "$o"; kubectl get "$kind" "$name" -n "$n" >/dev/null || die "Missing prerequisite $n/$kind/$name"
  done
  kubectl get secret "${PG_ADMIN_SECRET:-postgres-postgresql}" -n postgres >/dev/null || die 'PostgreSQL admin Secret missing'
  kubectl get secret "${DB_COMMON_SECRET:-db-common-secrets}" -n postgres >/dev/null || die 'PostgreSQL app Secret missing'
  say 'Foundation resources verified; eSignet plugin configuration requires appropriate deployment values' 
}
validate(){
  local rel n st
  for spec in 'redis redis' 'softhsm-esignet softhsm' 'softhsm-mock-identity-system softhsm' 'esignet-keycloak-init esignet' 'esignet esignet' 'oidc-ui esignet' 'mock-identity-system mockid' 'mock-relying-party-service esignet' 'mock-relying-party-ui esignet'; do
    read -r rel n <<< "$spec"; st="$(helm_status "$rel" "$n")"; say "$n/$rel => $st"
  done
  kubectl get deploy,pods -n esignet || true
  kubectl get deploy,pods -n mockid || true
  kubectl get pods -n redis || true
}
render(){
  repo_setup
  mkdir -p "$ROOT/rendered"
  for spec in 'redis redis bitnami/redis 17.3.14' 'softhsm-esignet softhsm mosip/softhsm 12.0.1' 'softhsm-mock-identity-system softhsm mosip/softhsm 12.0.1' 'esignet esignet mosip/esignet 1.4.0' 'oidc-ui esignet mosip/oidc-ui 1.0.1' 'mock-identity-system mockid mosip/mock-identity-system 0.12.0' 'mock-relying-party-service esignet mosip/mock-relying-party-service 0.12.0' 'mock-relying-party-ui esignet mosip/mock-relying-party-ui 0.12.0'; do
    read -r rel namespace chart version <<< "$spec"
    require_file "$ROOT/values/$rel.yaml"
    helm template "$rel" "$chart" --version "$version" -n "$namespace" -f "$ROOT/values/$rel.yaml" > "$ROOT/rendered/$rel.yaml"
    say "Rendered $rel"
  done
}
main(){
  case "$MODE" in
    --status) check_context; validate;;
    --fetch) need git; ensure_sources;;
    --check) precheck; say 'No resources modified';;
    --render) precheck; render;;
    --db-init)
      precheck; [[ "${ALLOW_DB_INIT:-NO}" == YES ]] || die 'ALLOW_DB_INIT=YES required'
      ensure_sources; prepare_namespaces; prepare_db;;
    --deploy)
      precheck; repo_setup; ensure_sources; prepare_namespaces
      decrypt_resources
      prepare_redis
      prepare_global
      prepare_hsm
      prepare_captcha
      if [[ "${ALLOW_DB_INIT:-NO}" == YES ]]; then prepare_db
      else
        say 'DB initialization disabled: existing database state must be validated before deployment'
        copy_resource secret "${PG_ADMIN_SECRET:-postgres-postgresql}" postgres esignet
        copy_resource secret "${DB_COMMON_SECRET:-db-common-secrets}" postgres esignet
        copy_resource secret "${DB_COMMON_SECRET:-db-common-secrets}" postgres mockid
      fi
      prepare_keycloak
      apply_config_server_overrides
      # Create esignet-global if not already provided by encrypted configuration.
      # It should be a reviewed environment-specific ConfigMap (not derived blindly).
      kubectl get cm esignet-global -n esignet >/dev/null || die 'Missing esignet/esignet-global ConfigMap: supply via ENCRYPTED_RESOURCES'
      prepare_identity_config
      install_release esignet esignet mosip/esignet 1.4.0 "$ROOT/values/esignet.yaml"
      install_release oidc-ui esignet mosip/oidc-ui 1.0.1 "$ROOT/values/oidc-ui.yaml"
          install_release mock-identity-system mockid mosip/mock-identity-system 0.12.0 "$ROOT/values/mock-identity-system.yaml"
      create_empty_secret esignet mock-relying-party-private-key-jwk client-private-key
      create_empty_secret esignet jwe-userinfo-service-secrets jwe-userinfo-private-key
      install_release mock-relying-party-service esignet mosip/mock-relying-party-service 0.12.0 "$ROOT/values/mock-relying-party-service.yaml"
      install_release mock-relying-party-ui esignet mosip/mock-relying-party-ui 0.12.0 "$ROOT/values/mock-relying-party-ui.yaml"
      validate;;
  esac
}
trap 'say "Deployment failed at line $LINENO; see $LOG_FILE" >&2' ERR
main
