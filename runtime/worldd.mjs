/**
 * worldd — the World runtime daemon.
 *
 * The only InsForge-authored process inside a World. It supervises the app the
 * agent writes and exposes the workspace API the control plane (and through it,
 * agents via MCP/CLI) uses to write code into the World:
 *
 *   GET  /v1/health                     liveness + app status
 *   GET  /v1/tree                       list workspace files
 *   GET  /v1/files?path=<p>             read a file
 *   PUT  /v1/files?path=<p>             write a file (body = content)
 *   POST /v1/exec    {"cmd": "..."}     run a command in the workspace (e.g. npm install)
 *   POST /v1/app/start {"cmd": "..."}   (re)start the app process
 *   POST /v1/app/stop                   stop the app process
 *   GET  /v1/logs?lines=N               tail the app's combined output
 *
 * All requests require `Authorization: Bearer $WORKSPACE_TOKEN` — the token is
 * minted per World by the control plane.
 *
 * The app itself binds $PORT and receives the World's env bindings
 * (DATABASE_URL, S3 credentials, ...) passed through from this process's env.
 * worldd has no opinions about what the app is: any language, any framework,
 * any number of files. Branching a World CoW-snapshots $WORKSPACE_DIR and
 * rewrites the env bindings; worldd itself is part of the runtime template,
 * not the workspace.
 */

import http from 'node:http';
import { spawn, exec } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';

const WORKSPACE_DIR = path.resolve(process.env.WORKSPACE_DIR || '/workspace');
const TOKEN = process.env.WORKSPACE_TOKEN;
const CONTROL_PORT = Number(process.env.WORKSPACE_CONTROL_PORT || 7400);
const LOG_LIMIT = 2000;

if (!TOKEN) {
  console.error('worldd: WORKSPACE_TOKEN is required');
  process.exit(1);
}

await fs.mkdir(WORKSPACE_DIR, { recursive: true });

let app = null; // { proc, cmd, startedAt }
const logs = [];

function pushLog(line) {
  logs.push(line);
  if (logs.length > LOG_LIMIT) logs.splice(0, logs.length - LOG_LIMIT);
}

function resolveInWorkspace(p) {
  const abs = path.resolve(WORKSPACE_DIR, p);
  if (abs !== WORKSPACE_DIR && !abs.startsWith(WORKSPACE_DIR + path.sep)) {
    throw Object.assign(new Error('path escapes workspace'), { status: 400 });
  }
  return abs;
}

async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks);
}

function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

function appStatus() {
  return app
    ? { running: true, pid: app.proc.pid, cmd: app.cmd, startedAt: app.startedAt }
    : { running: false };
}

function stopApp() {
  if (!app) return false;
  app.proc.kill('SIGTERM');
  app = null;
  return true;
}

function startApp(cmd) {
  stopApp();
  const proc = spawn(cmd, {
    shell: true,
    cwd: WORKSPACE_DIR,
    env: process.env, // the World's env bindings pass straight through
  });
  const startedAt = new Date().toISOString();
  app = { proc, cmd, startedAt };
  proc.stdout.on('data', (d) => d.toString().split('\n').filter(Boolean).forEach(pushLog));
  proc.stderr.on('data', (d) => d.toString().split('\n').filter(Boolean).forEach(pushLog));
  proc.on('exit', (code) => {
    pushLog(`[worldd] app exited with code ${code}`);
    if (app?.proc === proc) app = null;
  });
  return appStatus();
}

async function listTree(dir, prefix = '') {
  const out = [];
  for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git') continue;
    const rel = path.join(prefix, entry.name);
    if (entry.isDirectory()) out.push(...(await listTree(path.join(dir, entry.name), rel)));
    else out.push(rel);
  }
  return out;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const auth = req.headers.authorization || '';
  if (auth !== `Bearer ${TOKEN}`) return json(res, 401, { error: 'unauthorized' });

  try {
    if (req.method === 'GET' && url.pathname === '/v1/health') {
      return json(res, 200, { status: 'ok', service: 'worldd', app: appStatus() });
    }

    if (req.method === 'GET' && url.pathname === '/v1/tree') {
      return json(res, 200, { files: await listTree(WORKSPACE_DIR) });
    }

    if (url.pathname === '/v1/files') {
      const target = resolveInWorkspace(url.searchParams.get('path') || '');
      if (req.method === 'GET') {
        const content = await fs.readFile(target, 'utf8');
        return json(res, 200, { path: url.searchParams.get('path'), content });
      }
      if (req.method === 'PUT') {
        await fs.mkdir(path.dirname(target), { recursive: true });
        await fs.writeFile(target, await readBody(req));
        return json(res, 200, { written: url.searchParams.get('path') });
      }
    }

    if (req.method === 'POST' && url.pathname === '/v1/exec') {
      const { cmd, timeoutMs } = JSON.parse((await readBody(req)).toString() || '{}');
      if (!cmd) return json(res, 400, { error: 'cmd required' });
      return await new Promise((resolve) => {
        exec(
          cmd,
          { cwd: WORKSPACE_DIR, env: process.env, timeout: timeoutMs || 120000 },
          (error, stdout, stderr) => {
            json(res, 200, { exitCode: error?.code ?? 0, stdout, stderr });
            resolve();
          }
        );
      });
    }

    if (req.method === 'POST' && url.pathname === '/v1/app/start') {
      const { cmd } = JSON.parse((await readBody(req)).toString() || '{}');
      if (!cmd) return json(res, 400, { error: 'cmd required' });
      return json(res, 200, startApp(cmd));
    }

    if (req.method === 'POST' && url.pathname === '/v1/app/stop') {
      return json(res, 200, { stopped: stopApp() });
    }

    if (req.method === 'GET' && url.pathname === '/v1/logs') {
      const lines = Number(url.searchParams.get('lines') || 100);
      return json(res, 200, { logs: logs.slice(-lines) });
    }

    return json(res, 404, { error: 'not found' });
  } catch (error) {
    return json(res, error.status || 500, { error: String(error?.message || error) });
  }
});

server.listen(CONTROL_PORT, () => {
  console.log(`worldd: workspace=${WORKSPACE_DIR} control port=${CONTROL_PORT}`);
});
