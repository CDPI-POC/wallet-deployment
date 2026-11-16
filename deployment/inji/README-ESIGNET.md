# eSignet 1.4.0 / mock identity 0.12.0 RKE2 automation

## Scope

This is an *integration controller*, not a full fresh-RKE2 installation bundle. It deploys:

1. `redis` (`bitnami/redis` 17.3.14, `redis` namespace).
2. `softhsm-esignet` and `softhsm-mock-identity-system` (`mosip/softhsm` 12.0.1, `softhsm` namespace).
3. Two fresh-only databases (`mosip_esignet` and `mosip_mockidentitysystem`) using SQL from pinned official tags, **not** the destructive `init_db.sh`/`deploy.sh` commands.
4. `esignet-keycloak-init` (`mosip/keycloak-init` 12.0.1, `esignet` namespace; existing release preserved).
5. `esignet` 1.4.0, `oidc-ui` 1.0.1 (`esignet` namespace).
6. `mock-identity-system` 0.12.0 (`mockid` namespace).
7. `mock-relying-party-service`, `mock-relying-party-ui` 0.12.0 (`esignet` namespace).

**Scope exclusions**: PostgreSQL server, Keycloak server, Config Server, Artifactory, Istio, production HSM, and production credentials. External certificates/ingress, partner onboarding, plugin-specific application JAR/image builds and functional OIDC transactions are NOT automatically handled.

## Verified upstream files

- https://github.com/mosip/esignet/blob/v1.4.0/db_scripts/init_db.sh
- https://github.com/mosip/esignet/tree/v1.4.0/db_scripts/mosip_esignet
- https://github.com/mosip/esignet/blob/v1.4.0/helm/install-all.sh
- https://github.com/mosip/esignet-mock-services/blob/v0.12.0/deploy/install-mock.sh
- https://github.com/mosip/esignet-mock-services/blob/v0.12.0/deploy/prereq.sh

These upstream scripts contain interactive prompts, reinstallation/delete behavior, or direct passwords in Helm values. This controller does not invoke them directly.

## Before deploying

- Configure `KUBECONFIG` for the intended cluster. Verify `kubectl config current-context` and `kubectl get nodes`.
- Install `bash`, `git`, `python3`, `kubectl`, `helm`, `openssl`, `sops` (for encrypted manifests), and DNS/network access to GitHub, Helm repos, and image registries.
- Confirm existing PostgreSQL, Keycloak, `config-server` Deployment, `default/global` ConfigMap, `config-server/config-server-share`, `artifactory/artifactory-share`, admin PostgreSQL Secret, and `postgres/db-common-secrets`.
- Ensure Istio gateways `istio-system/public` and `istio-system/internal` exist or customize Helm values to match your actual gateway names.
- Check the exact eSignet image contains the mock identity plugin implementation and that Config Server resolves its plugin-specific properties. MOSIP `esignet` Helm release does *not* independently install an arbitrary plugin artifact.
- Take a DB backup and verify database strategy. Never run destructive upstream DB scripts against an existing database.
- Ensure `esignet` and `mockid` namespaces, storage classes and certificate policy fit your RKE2 cluster.

## Setup

```bash
cp config/identity.env.example config/identity.env
chmod 600 config/identity.env
nano config/identity.env
export KUBECONFIG="$HOME/.kube/inji-test.yaml"
./deploy-esignet-stack.sh --check
./deploy-esignet-stack.sh --fetch
```

The script performs no cluster mutation in `--check` and no cluster mutation in `--fetch` (only Git operations in its local `sources/` directory).

### Secrets / ConfigMaps

A reviewed SOPS-encrypted Kubernetes YAML file may contain namespace-qualified Secrets and ConfigMaps, including:

- `esignet/esignet-captcha`, with `esignet-captcha-site-key` and `esignet-captcha-secret-key`.
- `esignet/esignet-global`, with `mosip-esignet-host`.
- `esignet/oidc-ui`, with the **real upstream or existing-environment** OIDC UI configuration keys.
- Optional plugin ConfigMap/Secret, with names set via `PLUGIN_CONFIGMAP_NAME` and `PLUGIN_SECRET_NAME`.

Copy `config/resources.example.yaml`, replace ALL placeholders with approved real values, then encrypt it with your SOPS age/KMS config. Do not commit plaintext or the age private key.

```bash
cp config/resources.example.yaml config/resources.yaml
chmod 600 config/resources.yaml
# edit and replace placeholder values with approved credentials/settings
sops --encrypt --in-place config/resources.yaml
# set ENCRYPTED_RESOURCES=/absolute/path/to/config/resources.yaml in config/identity.env
```

A deployment run pipes decrypted resources into `kubectl apply` without writing them to a plaintext file. SOPS must be decryptable non-interactively.

For fresh `esignet-keycloak-init`, also prepare an encrypted values file from `config/keycloak-private-values.example.yaml` and set `KEYCLOAK_INIT_PRIVATE_VALUES_SOPS` and `RUN_KEYCLOAK_INIT=YES`. This is the vendor's Keycloak-init chart; Helm release metadata will retain the secret values. Restrict Helm release Secret access accordingly. Keycloak init on an already provisioned realm must be reviewed first.

### Chart override values

Files in `values/` are reviewed environment-specific examples, not substitutes for your working cluster's exported `helm get values`. Redis persistence, SoftHSM key mounts, gateway names, trusted certificates, eSignet plugin properties, OIDC UI environment, Relying Party client IDs, and image repositories must match your actual environment.

The controller preserves existing releases by default, does not regenerate their keys, and refuses to upgrade deployed releases unless `ALLOW_EXISTING_UPGRADES=YES`. It does not copy/overwrite existing destination Secrets/ConfigMaps; compare their content when reconciliation is needed.

### Database init

Fresh DB setup uses the Git-tagged SQL (DDL, DML, grants), executed by a temporary PostgreSQL client pod with password references from Kubernetes Secrets. Existing databases are never modified. If a database exists without this controller's completion marker, the controller stops unless `ALLOW_EXISTING_DATABASES=YES` is explicitly set after verification. For externally installed DBs without markers, set that override only after you check schema, role, credentials, and migration status. If a new run fails partway through DB init, inspect the partial DB and restore/repair it outside this script. It never drops DBs.

**No Helm `postgres-init-esignet` or `postgres-init-mockidentitysystem` release is created** because the controller intentionally performs fresh-only SQL initialization instead of running the vendor chart. Those historical Helm releases are not proof of schema state.

### Execute

```bash
# Configure correct values, secrets, plugin and source connectivity first.
# For *new* databases, change ALLOW_DB_INIT=YES in config/identity.env.
# For *existing* databases, leave ALLOW_DB_INIT=NO and validate them externally.
./deploy-esignet-stack.sh --render
./deploy-esignet-stack.sh --deploy
./deploy-esignet-stack.sh --status
```

`--db-init` is optional to initialize fresh databases without deploying the applications. `--render` renders the base values and is a preliminary check; dynamic domain overrides are injected at `--deploy` time. Run `helm template` with the matching host overrides for an exact final render.

## Config copy mapping

| Object | From | To |
|---|---|---|
| Redis Secret | `redis/redis` | `config-server/redis`, `mockid/redis` |
| eSignet SoftHSM Secret | `softhsm/softhsm-esignet` | `config-server/softhsm-esignet` |
| eSignet SoftHSM share | `softhsm/softhsm-esignet-share` | `esignet/softhsm-esignet-share` |
| Mock SoftHSM Secret+share | `softhsm/...` | `mockid/...` |
| PostgreSQL admin and DB common Secrets | `postgres` | `esignet`, `mockid` |
| Global, config-server, artifactory ConfigMaps | corresponding namespaces | `esignet`, `config-server` |
| Keycloak ConfigMaps/Secret | `keycloak` | `esignet` |
| Keycloak client Secrets (when available) | `keycloak` | `esignet`, `config-server` |
| eSignet global ConfigMap | `esignet` | `mockid` |
| Redis ConfigMap (when available) | `redis` | `mockid` |

The optional `MANAGE_CONFIG_SERVER_OVERRIDES=YES` updates live Config Server Deployment environment references and waits for rollout. It may introduce drift relative to Helm and must be approved if the Deployment is Helm-managed. Secret values are not printed.

## Required postchecks

```bash
helm list -A | grep -E 'redis|softhsm|esignet|oidc|mock-'
kubectl get pods -n esignet
kubectl get pods -n mockid
kubectl get pods -n redis
kubectl -n esignet rollout status deploy/esignet --timeout=300s
kubectl -n mockid rollout status deploy/mock-identity-system --timeout=300s
```

Finally verify authentication against mock-identity, discovery endpoint, OTP/captcha, redirect URI registration, `CLIENT_ID`, Keycloak roles/client-scopes, signing key persistence, Relying Party client onboarding and end-to-end OIDC authorization code flow. Empty mock RP key placeholders are upstream-compatible bootstrap placeholders, **not production credentials**.

## Not tested live

Script shell syntax and YAML parsing were checked offline. The package has **not** been executed against your Rancher/RKE2 cluster, so validate chart values and the linked MOSIP chart repositories on a disposable environment before using it for your current running cluster.
