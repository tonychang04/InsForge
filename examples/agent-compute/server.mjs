/**
 * Agent-written compute service — the agent-native replacement for PostgREST.
 *
 * In the agent-native architecture the client never talks to the database
 * directly: an agent writes ordinary backend endpoints like these, which
 * connect to the project's Neon database with the app's own connection and
 * enforce authorization in code. No PostgREST, no anon role, no RLS.
 *
 * Auth integration: verifies the JWT issued by the InsForge auth service
 * (same JWT_SECRET, HS256). The token's `sub` is the user id.
 *
 * Run:
 *   DATABASE_URL=postgres://... JWT_SECRET=... node examples/agent-compute/server.mjs
 */

import http from 'node:http';
import pg from 'pg';
import jwt from 'jsonwebtoken';

const { Pool } = pg;
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
const JWT_SECRET = process.env.JWT_SECRET;
const PORT = Number(process.env.COMPUTE_PORT || 7391);

// The agent owns its schema: plain SQL, applied idempotently at boot.
await pool.query(`
  CREATE SCHEMA IF NOT EXISTS app;
  CREATE TABLE IF NOT EXISTS app.todos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    done BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
  CREATE INDEX IF NOT EXISTS idx_todos_user ON app.todos(user_id);
`);

function authenticate(req) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return null;
  try {
    return jwt.verify(token, JWT_SECRET, { algorithms: ['HS256'] });
  } catch {
    return null;
  }
}

function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  if (req.url === '/health') return json(res, 200, { status: 'ok', service: 'agent-compute' });

  const claims = authenticate(req);
  if (!claims?.sub) return json(res, 401, { error: 'missing or invalid token' });

  try {
    // Authorization lives in code: every query is scoped to the caller.
    if (req.method === 'GET' && req.url === '/todos') {
      const { rows } = await pool.query(
        'SELECT id, title, done, created_at FROM app.todos WHERE user_id = $1 ORDER BY created_at',
        [claims.sub]
      );
      return json(res, 200, { todos: rows });
    }

    if (req.method === 'POST' && req.url === '/todos') {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const { title } = JSON.parse(Buffer.concat(chunks).toString() || '{}');
      if (!title) return json(res, 400, { error: 'title required' });
      const { rows } = await pool.query(
        'INSERT INTO app.todos (user_id, title) VALUES ($1, $2) RETURNING id, title, done, created_at',
        [claims.sub, title]
      );
      return json(res, 201, { todo: rows[0] });
    }

    return json(res, 404, { error: 'not found' });
  } catch (error) {
    return json(res, 500, { error: String(error?.message || error) });
  }
});

server.listen(PORT, () => {
  console.log(`agent-compute listening on :${PORT}`);
});
