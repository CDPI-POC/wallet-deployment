# Inji deployment orchestrator for existing `inji-test` RKE2 cluster

**Status: safe-by-default deployment framework, NOT a ready-to-run full-stack installer.** Actual Inji chart versions, plugin-specific database schemas, ingress domains, image registries, signing keys, eSignet client registration and end-to-end issuance/verification contracts cannot be inferred from the cluster name. Supply and validate these first. Empty module manifest intentionally does not install any service.

## Prerequisites

- A working kubeconfig pointing at the intended `inji-test` cluster; `kubectl`, `helm`, `python3` and `base64` installed.
- Existing reachable PostgreSQL server, DNS, network policies, persistent storage, and correct PostgreSQL client image.
- DB admin secret `inji-db/inji-db-admin` with key `PGPASSWORD`. For example: `kubectl -n inji-db create secret generic inji-db-admin --from-literal=PGPASSWORD='REPLACE_ME'` (use a secure secret manager instead of shell history for real passwords).
- For each database module, namespace secret `<release>-db-auth` with the key declared in `modules.tsv`. These passwords are read from secrets, not written into Helm values.
- Version-pinned, reviewed local Helm charts under `charts/<chart>/`, matching values under `values/`, and vendor-provided version-specific SQL migrations under `sql/<migration>/`.
- Charts must actually reference their DB auth secrets, expose correct URLs, and include required configuration. This framework does not generate application-specific values automatically.

## Run

```bash
cp config/inji.env.example config/inji.env
# Edit config/inji.env, set CONFIRM_DEPLOY=YES only after review
# Edit config/modules.tsv with real TAB-delimited module entries, in dependency order
# Populate charts/, values/, and sql/ with audited release artifacts
bash -n deploy.sh
./deploy.sh
```

## Modes

- `install`: create DB role/database if specified, apply SQL migrations, Helm upgrade/install and wait.
- `existing`: create DB role/database/migrations if specified, validate existing Helm release but do not modify it.
- `disabled`: skip.
- Use `-` for no DB or no migration. If a component has an existing DB, use `-` for DB and migrations to avoid altering its credentials.

## Important operational limits

- No destructive DROP statements or namespace deletions are issued by the script. SQL migration content itself must be reviewed for destructive operations.
- No automatic PostgreSQL server installation, Redis installation, Keycloak realm/client provisioning, HSM provisioning, chart download, certificate issuance, or issuance/verification tests. These are environment-specific integrations that require verified artifacts and secrets.
- The database bootstrap currently needs PostgreSQL role/database creation privileges and may reset the specified module DB role password on re-run. It will not reset the database itself.
- The SQL migration ledger prevents routine re-runs, but parallel invocations must be prevented externally. Use a maintenance lock or CI concurrency guard. Only transactional SQL migrations are supported; `CREATE INDEX CONCURRENTLY` and other nontransactional statements need separate controlled execution.
- The migration ledger is created with the admin connection. Review `search_path`, schema ownership and permissions for your application.
- `helm --atomic` rolls back Helm changes on failure, **not database migrations**. Take a PostgreSQL backup before applying new migrations.
- For true one-click end-to-end deployment, collect exact module versions, DB schema migration sources, current namespaces/Helm releases, ingress domains, and external integrations, then create the module-specific values and bootstrap jobs.

## Inventory commands

```bash
kubectl config current-context
kubectl get nodes -o wide
helm list -A
kubectl get ns
kubectl get svc -A | grep -Ei 'postgres|redis|keycloak|esignet|inji|softhsm'
kubectl get ingress,gateway,virtualservice -A 2>/dev/null
```

Never paste secrets, private keys or tokens into shared inventory output.
