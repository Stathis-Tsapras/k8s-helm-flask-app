# Kubernetes Helm Flask App

A learning project deploying an existing Flask application with PostgreSQL on a local kind Kubernetes cluster. The lab demonstrates Helm configuration, Kubernetes Secrets, database backup and restore, and persistence across PostgreSQL pod replacement.

## Current scope

Helm release `flask-app` in namespace `default` manages the Flask Deployment, Flask Service, ConfigMap, application Secret, PostgreSQL Deployment, and PostgreSQL Service. The PersistentVolumeClaim is managed separately. This repository contains its manifest, but does not yet contain the Flask source/Dockerfile.

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

5. Initialise the application table or restore a backup. The PostgreSQL image initialises the database and user on an empty data directory; the chart does not automatically create the `users` table.

Existing resources created outside Helm need explicit ownership migration before installation/upgrade. This migration was completed for the lab's PostgreSQL Deployment. Do not delete the working database to resolve ownership errors.

## Initialise a fresh application database

For an empty `appdb` only, open psql:

```bash
kubectl exec -it deployment/postgres -- psql -U appuser -d appdb
```

Then run:

```sql
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL
);
INSERT INTO users (name) VALUES ('Kubernetes User');
SELECT id, name FROM users;
```

Exit with `\q`. Do not repeat initialisation on a restored database.

## Access the application

```bash
kubectl port-forward service/flask-app 9090:8081
```

Keep the terminal running, then open `http://localhost:9090` on the machine running port-forward (Ubuntu in this lab).

The lab page displayed `1 - Kubernetes User`. Local port 9090 forwards to Service port 8081; the Service targets Flask port 5000. If the local port is occupied, change only the left-hand port number and use that port in the browser.

## Backup and restore

Save a SQL backup outside the repository:

```bash
kubectl exec deployment/postgres -- pg_dump -U appuser -d appdb > ~/appdb-backup.sql
```

Check the command succeeded and inspect the backup before changing storage. `>` writes output to a local file; do not overwrite a valid backup with a dump of an empty database.

Restore into a fresh database:

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

## Remaining work

- Add reproducible database initialisation or migrations.
- Review probes, resource requests/limits, and database security before considering broader use.
