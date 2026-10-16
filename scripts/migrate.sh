#!/usr/bin/env bash
set -euo pipefail

target="${1:-deployment/postgres}"

cd "$(dirname "$0")/.."

kubectl exec "$target" -- \
 psql -U appuser -d appdb -v ON_ERROR_STOP=1 -c \
 "CREATE TABLE IF NOT EXISTS public.schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
 );"

applied=$(kubectl exec "$target" -- \
 psql -U appuser -d appdb -At -v ON_ERROR_STOP=1 -c \
 "SELECT EXISTS (
  SELECT 1 FROM public.schema_migrations
  WHERE version = '001_add_users_created_at'
 );")

if [[ "$applied" == "t" ]]; then
   echo "Migration 001 already applied; skipping."

elif [[ "$applied" == "f" ]]; then
   kubectl exec -i "$target" -- \
    psql -U appuser -d appdb -v ON_ERROR_STOP=1 \
    < migrations/001_users_created_at.sql

else
   echo "Unexpected migration status: $applied" >&2
   exit 1
fi
