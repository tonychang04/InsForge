# Agent-Native InsForge (PoC fork)

This fork proves a re-architecture of InsForge: **Neon (managed Postgres) + agent-written
compute + storage**, with no per-project Postgres or PostgREST containers.

The thesis: the PostgREST / anon-key / RLS apparatus existed so apps without a backend
could talk to the database directly. Agents erase that constraint — they write ordinary
backend endpoints in seconds. So the stack collapses to a plain database (Neon), stateless
compute running agent-written code, and object storage.

## What was proven end-to-end

1. **Full InsForge schema on Neon.** A baseline generated from the unmodified migration
   ledger imports cleanly into a Neon database (`deploy/neon/baseline.sql`), including the
   migration ledger itself — `npm run migrate:up` against Neon reports "No migrations to
   run!". Historical migrations were not modified.
2. **Backend boots against Neon** with a single `DATABASE_URL` — no postgres container,
   no postgrest container, no custom image, no docker-init. Auth, secrets, storage
   metadata, and even realtime's LISTEN/NOTIFY work unchanged.
3. **InsForge auth issues JWTs as stateless code over Neon** (user signup/login verified,
   rows confirmed in Neon).
4. **Agent-written compute replaces PostgREST** (`examples/agent-compute/server.mjs`):
   a plain endpoint that verifies the InsForge JWT, owns its schema in plain SQL, and
   enforces authorization in code — no anon role, no RLS, no query-builder SDK.

## Changes in this fork

| Area | Change |
|---|---|
| `backend/src/api/routes/database/records.routes.ts`, `rpc.routes.ts` | Removed — the PostgREST proxy surface |
| `backend/src/services/database/postgrest-proxy.service.ts` | Removed |
| `backend/src/infra/security/token.manager.ts` | Removed the never-expiring PostgREST admin token |
| `backend/src/infra/config/app.config.ts` | Removed `POSTGREST_BASE_URL`; added `DATABASE_URL` support |
| `backend/src/infra/database/database.manager.ts` | Pool + dedicated clients honor `DATABASE_URL` (Neon connection strings, sslmode included) |
| `backend/src/infra/database/migrations/bootstrap/bootstrap-migrations.js` | Creates the legacy `anon`/`authenticated`/`project_admin` roles (NOLOGIN) when no docker-init exists — keeps historical GRANTs/policies valid on managed Postgres |
| `deploy/neon/` | Baseline generator (`filter-baseline.py`), generated `baseline.sql`, and README |
| `examples/agent-compute/` | The agent-written compute service demo |

Historical migrations are untouched. The docker self-host path keeps working.

## Deliberately not done (yet)

- **Schedules** run from the control plane, not pg_cron/http inside the database — the
  in-database schedules engine is absent on Neon (its tables remain; the engine functions
  that require the `http` extension are filtered from the baseline).
- **Realtime** works on Neon but a permanent LISTEN connection prevents scale-to-zero;
  the agent-native tier should move transport to the compute layer.
- **Dashboard table editor** still expects `/api/database/records`; in the agent-native
  model the dashboard reads via direct SQL (the `advance` routes remain).
- **SDK** query-builder is unused here; clients call agent-written endpoints.

## Run it

```bash
# 1. Get a Neon database (instant, claimable): https://neon.new
curl -X POST https://neon.new/api/v1/database -H 'Content-Type: application/json' -d '{"ref":"insforge"}'

# 2. Import the baseline (creates roles, schema, stamps the ledger)
#    see deploy/neon/README.md

# 3. Boot the backend — only a connection string, no containers
DATABASE_URL=postgres://... JWT_SECRET=... ROOT_ADMIN_USERNAME=... ROOT_ADMIN_PASSWORD=... \
  npm run dev --workspace=backend

# 4. Run the agent compute example
DATABASE_URL=postgres://... JWT_SECRET=<same> node examples/agent-compute/server.mjs
```
