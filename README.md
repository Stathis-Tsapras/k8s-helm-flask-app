# Kubernetes Helm Flask App

A learning project deploying an existing Flask application with PostgreSQL on a local kind Kubernetes cluster. The lab demonstrates Helm configuration, Kubernetes Secrets, database backup and restore, and persistence across PostgreSQL pod replacement.

## Current scope

Helm release `flask-app` in namespace `default` manages the Flask Deployment, Flask Service, ConfigMap, application Secret, PostgreSQL Deployment, PostgreSQL Service and PostgreSQL Initialisation ConfigMap. The PersistentVolumeClaim is managed separately. This repository contains its manifest, but does not yet contain the Flask source/Dockerfile.

This is a local lab, not a production deployment. The instructions below assume the existing `devops-lab` kind cluster and the Flask image from the earlier Docker project.

## Tested configuration

| Setting | Value |
| --- | --- |
| Cluster | kind, `devops-lab` |
| Flask image | `flask-app:v2` |
| Flask image pull policy | `Never` |
| Flask replicas | 2 |
| Flask Service port | 8081 |
| Flask target port | 5000 |
| PostgreSQL image | `postgres:16` |
| PostgreSQL host / Service | `postgres` |
| Database / database user | `appdb` / `appuser` |
| Secret / password key | `app-secret` / `DB_PASSWORD` |
| PostgreSQL PVC | `postgres-data`, 1 GiB |
| Data mount | `/var/lib/postgresql/data` |
| StorageClass | `standard`, `rancher.io/local-path` |
| PostgreSQL update strategy | `Recreate` |

## Repository layout

- `flask-app/Chart.yaml`: chart metadata.
- `flask-app/values.yaml`: default configuration, with an empty password value.
- `flask-app/templates/`: Helm-managed Kubernetes resources.
- `flask-app/postgres-pvc.yaml`: separately applied storage claim.
- `flask-app/.helmignore`: files excluded from chart packages.
- `.gitignore`: local backup and temporary files excluded from Git.

## Private password configuration

Create `~/devops-lab-private.yaml` outside the repository:

```yaml
secrets:
  dbPassword: "REPLACE_WITH_YOUR_DATABASE_PASSWORD"
```

Restrict its permissions:

```bash
chmod 600 ~/devops-lab-private.yaml
```

For the existing database, use its current password. Changing this value does not change an existing PostgreSQL user's password. The Secret template uses `required` to reject a missing password. Both applications should use the same credentials.

The password is provided through a Kubernetes Secret, rather than a plain environment value in the Deployment. This avoids committing it to source control; it is not encryption. Helm release records and Kubernetes Secrets still contain sensitive data and require appropriate access controls.

## Validate and update the existing lab

From the repository root:

```bash
kubectl config current-context
kubectl get pods
kubectl get pvc
helm lint ./flask-app -f ~/devops-lab-private.yaml
helm upgrade flask-app ./flask-app -f ~/devops-lab-private.yaml --wait --timeout 2m
```

The expected kind context is `kind-devops-lab`. Use the private values file on each upgrade. `helm template` only generates YAML; `helm upgrade` updates the cluster.

## Installation prerequisites

Before installing into another prepared kind cluster:

1. Build `flask-app:v2` from the original Flask application project. Its source is not included here.
2. Load the image into kind:

   ```bash
   kind load docker-image flask-app:v2 --name devops-lab
   ```

3. Confirm the cluster provides StorageClass `standard`, then apply the PVC:

   ```bash
   kubectl apply -f flask-app/postgres-pvc.yaml
   ```

   With `WaitForFirstConsumer`, the PVC can remain Pending until a pod references it.

4. Create the private values file, then install the chart:

   ```bash
   helm install flask-app ./flask-app -f ~/devops-lab-private.yaml --wait --timeout 2m
   ```

5. On an empty PostgreSQL data directory, the mounted init.sql automcatically creates the users table and inserts Kubernetes User.

   Existing databases are left unchanged.

## Initialise a fresh application database

The chart mounts postgres-init at /docker-entrypoint-initdb.d.

PostgreSQL runs its init.sql only when the data directory is empty.

Updating the script does not apply schema changes to an  existing database; those require migrations.

Verification command:
kubectl exec deployment/postgres -- psql -U appuser -d appdb -c 'SELECT id,name FROM users;'

## Fresh database test

The test pod uses temporary `emptyDir` storage and the chart's
initialisation ConfigMap. It does not use the main database PVC
or receive traffic from the PostgreSQL Service.

Run after deploying the chart:

```bash
kubectl apply -f tests/postgres-init-test.yaml
kubectl logs postgres-init-test
```

Once PostgreSQL is ready, verify:

```bash
kubectl exec postgres-init-test -- psql -U appuser -d appdb -c 'SELECT id, name FROM users;'
```

Expected result: `1 | Kubernetes User`.

Clean up:

```bash
kubectl delete pod postgres-init-test
```

Deleting this test pod removes its temporary database. Each new
test pod starts with empty storage.

## Access the application

```bash
kubectl port-forward service/flask-app 9090:8081
```

Keep the terminal running, then open `http://localhost:9090` on the machine running port-forward (Ubuntu in this lab).

The lab page displayed `1 - Kubernetes User`. Local port 9090 forwards to Service port 8081; the Service targets Flask port 5000. If the local port is occupied, change only the left-hand port number and use that port in the browser.

## Health checks and resource settings

The Flask application provides two health endpoints:

- `/health` returns `OK` when Flask responds. The liveness probe checks this endpoint.
- `/ready` returns `Ready` when Flask can connect to PostgreSQL and execute `SELECT 1`. It returns HTTP 503 if the database check fails. The readiness probe checks this endpoint.

Both probes use container port 5000. Readiness runs every 5 seconds; liveness runs every 10 seconds. Both have a 3-second timeout and a failure threshold of 3.

Each Flask container has these resource settings:

| Resource | Request | Limit |
| --- | --- | --- |
| CPU | 100m | 500m |
| Memory | 128Mi | 256Mi |

These are initial lab settings, not values established through load testing.

## Verified database outage test

Record the Flask Pod names and restart counts:

```bash
kubectl get pods -n default
```

Temporarily stop PostgreSQL:

```bash
kubectl scale deployment postgres --replicas=0 -n default
kubectl get pods -n default -w
```

Both Flask Pods became `0/1 Ready` while remaining `Running`. During a roughly 60-second outage, their restart counts stayed unchanged.

Press Ctrl+C to stop watching, then restore PostgreSQL:

```bash
kubectl scale deployment postgres --replicas=1 -n default
kubectl rollout status deployment/postgres -n default --timeout=2m
kubectl get pods -n default
```

Both Flask Pods returned to `1/1 Ready`. This verified that readiness detected the database outage while liveness kept Flask running. The PostgreSQL PVC remained in place throughout.

## Backup and restore

Save a SQL backup outside the repository:

```bash
kubectl exec deployment/postgres -- pg_dump -U appuser -d appdb > ~/appdb-backup.sql
```

Check the command succeeded and inspect the backup before changing storage. `>` writes output to a local file; do not overwrite a valid backup with a dump of an empty database.

Restore into an empty database without the initialisation-created `users` table. The chart's normal first-start initialisation already creates that table, so restoring the full dump into an automatically initialised database can cause conflicts.

```bash
kubectl exec -i deployment/postgres -- psql -U appuser -d appdb -v ON_ERROR_STOP=1 < ~/appdb-backup.sql
```

`-i` passes the file contents to psql. Restore once, then verify:

```bash
kubectl exec deployment/postgres -- psql -U appuser -d appdb -c 'SELECT id, name FROM users;'
```

## Verified persistence test

The lab backed up the database, attached the PVC, restored the data, and replaced the PostgreSQL pod:

```bash
kubectl rollout restart deployment/postgres
kubectl rollout status deployment/postgres --timeout=120s
kubectl exec deployment/postgres -- psql -U appuser -d appdb -c 'SELECT id, name FROM users;'
```

The query still returned `1 | Kubernetes User`. This verifies persistence across pod replacement. The local-path volume is stored in the kind node; deleting the kind cluster can remove it. A PVC is not a database backup.

## Troubleshooting lessons

- `relation "users" does not exist`: inspect the connected database and schema; create the lab table only in an empty database or restore the appropriate backup.
- `address already in use`: choose an available local port for port-forward.
- `Service does not have a service port`: the right-hand port in port-forward must match the running Service.
- PVC stuck Pending: check pod events and ensure `claimName` exactly matches `postgres-data`.
- Invalid storage quantity: use `1Gi`, with capital G and lowercase i.
- YAML parse errors: keep `repository` and `tag` aligned, with a space after each colon.
- `valueFrom ... may not be specified when value is not empty`: explicitly remove the retained plain `value` when switching an existing environment entry to `secretKeyRef`.
- Exported Deployment conflicts: remove generated metadata such as `resourceVersion` and the generated `status` section from maintained manifests.
-  Readiness returns 503: check database connectivity and configuration. A typo in `.Values.postgres.database` rendered an empty `POSTGRES_DB`. Correcting the template, upgrading Helm, and restarting Flask resolved it. ConfigMap values supplied as environment variables require replacement Pods to take effect.

## PostgreSQL probes and resources

All three PostgreSQL probes run `pg_isready` against localhost port 5432 using the container's database and user environment variables.

- Startup checks every 5 seconds, with a failure threshold of 60.
- Readiness checks every 5 seconds, with a failure threshold of 3.
- Liveness checks every 10 seconds, with a failure threshold of 6.
- Each probe has a 3-second timeout; `pg_isready` has a 2-second timeout.

Startup must succeed before readiness and liveness begin. Readiness failure removes the Pod from normal Service traffic; repeated liveness failure restarts the container.

PostgreSQL requests 100m CPU and 256Mi memory, with limits of 1 CPU and 512Mi memory. These are initial lab settings. Liveness behaviour during recovery and resource sizing need further testing.

The upgrade succeeded, PostgreSQL accepted connections, and the application and Flask health endpoints continued to work.  

## Resource observation

Metrics Server v0.9.0 was installed separately in kube-system. This local kind lab required --kubelet-insecure-tls because the kubelet certificate lacked an IP SAN. This disables kubelet certificate verification and is a testing workaround.

Initial readings were 2m CPU and 26–28Mi memory per Flask Pod, and 10m CPU and 57Mi memory for PostgreSQL.

A sequential curl loop sent 300 requests through port-forward without reporting errors. Flask's highest observed CPU reading was 19m. Memory during the test was not recorded.

This was a small traffic exercise, not a capacity benchmark. Port-forward targeted one Flask Pod. Resource requests and limits were left unchanged.

## Metrics Server setup for kind

The configuration in `infrastructure/metrics-server/kustomization.yaml` references Metrics Server v0.9.0 and adds `--kubelet-insecure-tls` for this local kind lab.

This flag bypasses kubelet certificate verification. It is a testing workaround for the node certificate's missing IP SAN.

From the repository root:

```bash
kubectl apply --dry-run=server -k infrastructure/metrics-server
kubectl apply -k infrastructure/metrics-server
kubectl rollout status deployment/metrics-server -n kube-system --timeout=2m
kubectl top pods -n default
```

`-k` builds the Kustomize configuration from the directory. Fetching the pinned upstream manifest requires network access.

The rollout and metrics readings were verified. Reapplying the configuration left the Deployment unchanged. Metrics Server is managed separately from the Flask Helm release.

## Remaining work

- Add schema migrations for existing databases.
- Test PostgreSQL probe behaviour during failures and recovery.
- Measure resource usage under load and adjust the Flask settings.
- Review database security before considering broader use.
