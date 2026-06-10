# World runtime

This directory is the future shape of the InsForge OSS repo: in the agent-native
architecture the platform runs **no app-layer services** — no auth service, no
storage service, no PostgREST, no functions product. A project is a **World**:

```
World = { code workspace (CoW), Neon branch, S3 prefix, env bindings, runtime template }
```

Everything in `backend/` is the classic self-host tier, frozen. The agent-native
runtime is just two pieces:

- **`worldd.mjs`** — the workspace daemon. Supervises the app the agent writes and
  exposes the workspace API (read/write files, exec, start/stop app, tail logs),
  authenticated by a per-World token. This is the entire interface agents use to
  put code in production.
- **`Dockerfile`** — the runtime template: a base image that runs `worldd` over a
  mounted workspace volume. Branching a World CoW-snapshots the volume and rewrites
  the env bindings (`DATABASE_URL` → branch's Neon string, S3 creds → branch prefix);
  the app code never knows it's a branch.

The app inside the workspace is arbitrary user/agent code: it binds `$PORT`, reads
its resources from env, and implements its own auth, storage protocol, realtime —
whatever the app needs. The platform's security boundary is the resources
(scoped credentials, isolated Worlds), not the app layer.

## Try it

```bash
WORKSPACE_DIR=/tmp/world WORKSPACE_TOKEN=dev WORKSPACE_CONTROL_PORT=7400 \
DATABASE_URL=postgres://... PORT=7401 node runtime/worldd.mjs

# agent writes an app through the API
curl -X PUT 'localhost:7400/v1/files?path=app.mjs' -H 'Authorization: Bearer dev' --data-binary @app.mjs
curl -X POST localhost:7400/v1/exec -H 'Authorization: Bearer dev' -d '{"cmd":"npm install pg"}'
curl -X POST localhost:7400/v1/app/start -H 'Authorization: Bearer dev' -d '{"cmd":"node app.mjs"}'
curl localhost:7401/        # the app, live against the World's database
```
