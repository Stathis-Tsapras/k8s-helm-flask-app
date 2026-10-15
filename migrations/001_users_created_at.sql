BEGIN;

CREATE TABLE IF NOT EXISTS public.schema_migrations (
   version TEXT PRIMARY KEY,
   applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE public.users
  ADD COLUMN created_at TIMESTAMPTZ;

ALTER TABLE public.users
  ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;

INSERT INTO public.schema_migrations (version)
VALUES ('001_add_users_created_at');


COMMIT;
