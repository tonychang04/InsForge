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

## Target architecture (beyond this PoC)

The PoC keeps InsForge auth as a running service and verifies its JWT in the compute
example. The target goes further — the platform runs **no app-layer services at all**:

- **Everything app-layer is the user's code.** Auth (sessions, JWT, OAuth — their
  choice; the JWT in the example was a convention, not a requirement), API endpoints,
  and the storage protocol are all written by the agent in the project's compute.
  The platform ships hardened **scaffolds** (auth, storage presigning, payments) as
  starting points the user owns, not services it operates.
- **Storage is direct-to-S3.** The platform provisions a bucket prefix and mints
  tightly-scoped credentials (per project and per branch); the user's compute mints
  presigned URLs and defines its own upload protocol. S3 POST policies replace
  in-path enforcement; a CDN serves public objects; metering is async.
- **The platform owns only:** real resources (Neon branch, S3 prefix, compute,
  domains), their credentials, scaffolds, and control-plane ops (branching, merge,
  backups, observability, billing, a project-scoped email API).
- **Code lives in the World.** A World = { CoW code workspace, Neon branch, S3
  prefix, env vars, runtime template }. Agents write through a workspace API
  (read/write/run/tail); cloning a World is sub-second (one Neon API call + one
  CoW snapshot); git is history, not deployment.
- **The cloneability boundary is explicit.** Postgres-maximalism (queues, vector,
  full-text in Neon) extends clone coverage; resources outside Neon+S3+workspace
  attach as explicitly non-branching; apps that outgrow the model eject cleanly
  (their database, their repo, standard resources).

The litmus test for any platform feature: is it a resource, a scaffold, or
control-plane ops? If none, it's just code the agent should write.

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
