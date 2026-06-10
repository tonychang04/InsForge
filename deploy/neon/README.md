# Neon baseline

`baseline.sql` is the full InsForge schema (and migration-inserted data, including the
`system.migrations` ledger) as produced by the **unmodified** migration ledger, filtered
so it imports into managed Postgres without the `pg_cron` / `http` extensions.

## Import into a Neon database

```bash
# legacy roles referenced by historical GRANTs/policies, and membership so
# default-privilege statements apply
psql "$DATABASE_URL" <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='project_admin') THEN CREATE ROLE project_admin NOLOGIN; END IF;
END $$;
GRANT anon, authenticated, project_admin TO current_user;
SQL

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f deploy/neon/baseline.sql
```

The ledger rows import with the baseline, so `npm run migrate:up` is a no-op afterwards
and future migrations apply normally.

## Regenerate after new migrations

```bash
docker run -d --name insforge-baseline -p 55432:5432 \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=insforge \
  -e JWT_SECRET=baseline -e JWT_EXP=3600 \
  -v "$PWD/deploy/docker-init/db/db-init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro" \
  -v "$PWD/deploy/docker-init/db/jwt.sql:/docker-entrypoint-initdb.d/02-jwt.sql:ro" \
  -v "$PWD/deploy/docker-init/db/postgresql.conf:/etc/postgresql/postgresql.conf:ro" \
  ghcr.io/insforge/postgres:v15.13.4 -c config_file=/etc/postgresql/postgresql.conf

DATABASE_URL=postgresql://postgres:postgres@localhost:55432/insforge \
  npm run migrate:up --workspace=backend

docker exec insforge-baseline pg_dump -U postgres -d insforge --no-owner \
  | python3 deploy/neon/filter-baseline.py > deploy/neon/baseline.sql

docker rm -f insforge-baseline
```

What the filter strips (and why) is documented in `filter-baseline.py`.
