// SOW Backend - zero-dependency Node service holding the invariants Part 7 asks for.
//
// Scope decision: this implements the parts of Phase 46-84 that are *falsifiable on one
// laptop* - server-authoritative accounts, durable saves with corruption recovery, an
// append-only economy ledger, and a UGC pipeline that refuses unsafe packages. It is
// deliberately NOT a microservice cluster: there is no player traffic to shard, and
// inventing Kubernetes manifests for a prototype would be scaffolding posing as progress.
// The swap points to Postgres/S3 are marked in store.js rather than hidden.
//
// Run:  node backend/server.mjs [--port 8788] [--data backend/data]
import { createServer } from 'node:http';
import { createHash, randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { Store } from './store.mjs';

const SAVE_CURRENT = 2;          // newest save schema the server accepts
const SAVE_MIN_MIGRATABLE = 1;   // anything below this is refused, not guessed at
const SESSION_TTL_MS = 1000 * 60 * 30;
const REFRESH_TTL_MS = 1000 * 60 * 60 * 24 * 30;
const RATE_WINDOW_MS = 10_000;
const RATE_MAX = 60;             // per player (or IP) per window
const TRENDING_GRAVITY = 1.5;    // time-decay exponent for the trending ranking
const UGC_MAX_FILE = 2 * 1024 * 1024;
const UGC_MAX_TOTAL = 8 * 1024 * 1024;
// Anything a player could hand to another player and have executed. Godot ships no way to
// sandbox a .gd from a download, so code in packages is refused outright (Phase 52).
const UGC_DENY_EXT = ['.gd', '.gdc', '.cs', '.dll', '.so', '.dylib', '.exe', '.bat',
  '.cmd', '.ps1', '.sh', '.py', '.js', '.mjs', '.tscn', '.tres', '.godot'];
const UGC_ALLOW_EXT = ['.json', '.txt', '.md', '.png', '.svg', '.wav', '.ogg'];
// How many past versions a package keeps. Each version carries its own file contents so that
// rollback restores bytes rather than metadata, so the chain has to be bounded.
const UGC_KEEP_VERSIONS = 10;

const sha = (s) => createHash('sha256').update(s).digest('hex');

// Every check a package must pass, shared by first publication and by every later version.
// A separate version endpoint that re-implemented none of these would let a player slip a .gd
// through by publishing it as v2 of an already-approved package.
function packageProblems(m, files, store) {
  const problems = [];
  if (!m || typeof m !== 'object') problems.push('缺少 manifest');
  else for (const k of ['title', 'type', 'version'])
    if (m[k] === undefined || m[k] === null || m[k] === '') problems.push(`manifest.${k} 必填`);
  if (!files.length) problems.push('包内无文件');
  if (files.length > 200) problems.push('文件数超过 200');
  let total = 0;
  for (const f of files) {
    const p = String(f?.path ?? '');
    const dot = p.toLowerCase().lastIndexOf('.');
    const ext = dot < 0 ? '' : p.slice(dot);
    const size = Buffer.byteLength(String(f?.content ?? ''), 'base64');
    total += size;
    if (p.includes('..') || p.startsWith('/') || /^[a-zA-Z]:/.test(p))
      problems.push(`路径不安全：${p}`);
    if (UGC_DENY_EXT.includes(ext)) problems.push(`禁止的可执行/场景类型：${p}`);
    else if (!UGC_ALLOW_EXT.includes(ext)) problems.push(`未知文件类型：${p || '(空)'}`);
    if (size > UGC_MAX_FILE) problems.push(`单文件超过 2 MiB：${p}`);
  }
  if (total > UGC_MAX_TOTAL) problems.push('包体总量超过 8 MiB');
  if (m && typeof m === 'object') {
    if (!Number.isFinite(m.triangles) || m.triangles < 0 || m.triangles > 2_000_000)
      problems.push('manifest.triangles 必须存在且不超过 2,000,000');
    if (!Number.isFinite(m.actors) || m.actors > 2000) problems.push('manifest.actors 超过 2000');
    for (const d of m.dependencies ?? [])
      if (!store.ugcByContentId(d)) problems.push(`依赖不存在：${d}`);
  }
  return problems;
}

// Responses never carry file contents: a listing that returned base64 for every version would
// be dominated by payload the client did not ask for.
const publicUgc = (rec) => ({ ...rec,
  files: (rec.contents ?? []).map(f => f.path), contents: undefined,
  versions: (rec.versions ?? []).map(v => ({ version: v.version, created_at: v.created_at,
    declared: v.declared, files: (v.contents ?? []).map(f => f.path) })) });

export function makeApp(opts = {}) {
  const store = opts.store ?? new Store(opts.data ?? 'backend/data');
  const log = opts.log ?? (() => {});
  const rateMax = opts.rateMax ?? RATE_MAX;
  const windows = new Map();

  function limit(key) {
    const now = Date.now();
    let w = windows.get(key);
    if (!w || now - w.t0 > RATE_WINDOW_MS) { w = { t0: now, n: 0 }; windows.set(key, w); }
    w.n += 1;
    return w.n <= rateMax;
  }

  function issueSession(playerId) {
    const token = randomBytes(24).toString('base64url');
    store.putSession(sha(token), { player_id: playerId, expires_at: Date.now() + SESSION_TTL_MS });
    return token;
  }
  function issueRefresh(playerId) {
    const token = randomBytes(32).toString('base64url');
    store.putRefresh(sha(token), { player_id: playerId, expires_at: Date.now() + REFRESH_TTL_MS });
    return token;
  }
  function auth(req) {
    const h = req.headers.authorization || '';
    const t = h.startsWith('Bearer ') ? h.slice(7) : '';
    if (!t) return null;
    const s = store.getSession(sha(t));
    if (!s) return null;
    if (s.expires_at < Date.now()) { store.delSession(sha(t)); return null; }
    return s.player_id;
  }

  const handlers = {
    'POST /v1/accounts': (ctx) => {
      const { display_name, secret } = ctx.body;
      if (!display_name || typeof secret !== 'string' || secret.length < 8)
        return ctx.err(400, 'display_name 与至少 8 位的 secret 必填');
      if (store.accountByName(display_name)) return ctx.err(409, '昵称已存在');
      const salt = randomBytes(16).toString('hex');
      const p = {
        player_id: 'p_' + randomBytes(8).toString('hex'),
        display_name, created_at: new Date().toISOString(),
        last_login: new Date().toISOString(), level: 1,
        salt, hash: scryptSync(secret, salt, 32).toString('hex'),
      };
      store.putAccount(p);
      store.tx(p.player_id, { type: 'GRANT', amount: 1000, ref: 'signup-bonus' });
      return ctx.json(201, {
        player_id: p.player_id, display_name: p.display_name,
        session_token: issueSession(p.player_id), refresh_token: issueRefresh(p.player_id),
        balance: store.balance(p.player_id),
      });
    },

    'POST /v1/accounts/login': (ctx) => {
      const { player_id, display_name, secret } = ctx.body;
      const a = player_id ? store.account(player_id) : store.accountByName(display_name);
      if (!a) return ctx.err(401, '账号不存在');
      const cand = scryptSync(String(secret ?? ''), a.salt, 32);
      const want = Buffer.from(a.hash, 'hex');
      if (cand.length !== want.length || !timingSafeEqual(cand, want)) return ctx.err(401, '口令错误');
      a.last_login = new Date().toISOString();
      store.putAccount(a);
      return ctx.json(200, {
        player_id: a.player_id, session_token: issueSession(a.player_id),
        refresh_token: issueRefresh(a.player_id), balance: store.balance(a.player_id),
      });
    },

    'POST /v1/session/refresh': (ctx) => {
      const t = sha(String(ctx.body.refresh_token ?? ''));
      const r = store.getRefresh(t);
      if (!r || r.expires_at < Date.now()) return ctx.err(401, 'refresh token 无效或已过期');
      store.delRefresh(t);                       // rotation: a refresh token is single-use
      return ctx.json(200, { session_token: issueSession(r.player_id),
        refresh_token: issueRefresh(r.player_id) });
    },

    'GET /v1/me': (ctx) => {
      const a = store.account(ctx.player);
      if (!a) return ctx.err(404, '无此账号');
      return ctx.json(200, { player_id: a.player_id, display_name: a.display_name,
        level: a.level, created_at: a.created_at, last_login: a.last_login,
        balance: store.balance(a.player_id) });
    },

    // Phase 48. Money/level/ownership are never taken from the client: the save envelope
    // keeps them, and any attempt to smuggle them in is rejected before it is written.
    'PUT /v1/save': (ctx) => {
      const b = ctx.body;
      for (const k of ['balance', 'money', 'level'])
        if (k in b) return ctx.err(400, `字段 ${k} 由服务器决定，不接受客户端提交`);
      const v = Number(b.save_version);
      if (!Number.isInteger(v)) return ctx.err(400, 'save_version 必须是整数');
      if (v > SAVE_CURRENT) return ctx.err(400, `save_version ${v} 新于服务器支持的 ${SAVE_CURRENT}`);
      if (v < SAVE_MIN_MIGRATABLE) return ctx.err(409, `存档版本 ${v} 过旧，无迁移路径`);
      const payload = b.payload;
      if (!payload || typeof payload !== 'object') return ctx.err(400, 'payload 必填');
      const rec = store.writeSave(ctx.player, { save_version: SAVE_CURRENT, payload });
      return ctx.json(200, { saved_at: rec.written_at, generations: store.saveGenerations(ctx.player) });
    },

    'GET /v1/save': (ctx) => {
      const r = store.readSave(ctx.player);
      if (!r) return ctx.json(404, { detail: '无存档' });
      if (!r.ok) {
        // Phase 48.3: detect, roll back, restore - and tell the caller it happened.
        const rb = store.rollback(ctx.player);
        return ctx.json(200, { recovered: true, reason: r.reason, restored: !!rb,
          save_version: rb?.save_version ?? null, payload: rb?.payload ?? null });
      }
      return ctx.json(200, { recovered: false, save_version: r.save_version, payload: r.payload });
    },

    'POST /v1/save/rollback': (ctx) => {
      const r = store.rollback(ctx.player);
      if (!r) return ctx.err(409, '没有可回退的前一代存档');
      return ctx.json(200, { save_version: r.save_version, payload: r.payload });
    },

    // Phase 58. Balances are a fold over the ledger, never a mutable field.
    'POST /v1/ledger/tx': (ctx) => {
      const { type, amount, ref, idempotency_key } = ctx.body;
      if (!Number.isFinite(amount) || amount === 0) return ctx.err(400, 'amount 必须是非零有限数');
      if (!['PURCHASE', 'EARN', 'GRANT', 'REFUND', 'PAYOUT'].includes(type))
        return ctx.err(400, 'type 非法');
      const sign = type === 'PURCHASE' || type === 'PAYOUT' ? -1 : 1;
      const delta = sign * Math.abs(Math.trunc(amount));
      const bal = store.balance(ctx.player);
      if (bal + delta < 0) return ctx.err(409, `余额不足：当前 ${bal}，本笔 ${delta}`);
      const dup = idempotency_key && store.findTx(ctx.player, idempotency_key);
      if (dup) return ctx.json(200, { duplicate: true, transaction: dup, balance: bal });
      const t = store.tx(ctx.player, { type, amount: delta, ref: ref ?? null,
        idempotency_key: idempotency_key ?? null });
      return ctx.json(201, { duplicate: false, transaction: t, balance: store.balance(ctx.player) });
    },

    'GET /v1/ledger': (ctx) => ctx.json(200, {
      player_id: ctx.player, balance: store.balance(ctx.player),
      transactions: store.txs(ctx.player) }),

    // Phase 52/53: upload is not publish. A package only becomes listed after every check.
    'POST /v1/ugc/packages': (ctx) => {
      const m = ctx.body.manifest;
      const files = Array.isArray(ctx.body.files) ? ctx.body.files : [];
      const problems = packageProblems(m, files, store);
      const content_id = 'c_' + randomBytes(8).toString('hex');
      const rec = { content_id, creator_id: ctx.player, version: m?.version ?? 1,
        title: m?.title ?? null, type: m?.type ?? null, description: m?.description ?? null,
        dependencies: m?.dependencies ?? [], declared: { triangles: m?.triangles ?? null,
          actors: m?.actors ?? null },
        created_at: new Date().toISOString(), downloads: 0, likes: 0,
        status: problems.length ? 'rejected' : 'published', problems,
        contents: files };
      store.ugcPut(rec, problems.length ? [] : files.map(f => f.path));
      return ctx.json(problems.length ? 422 : 201, rec);
    },

    // Phase 150 / 171: a package is a chain of versions, and rollback has to bring back the
    // bytes rather than only the metadata — which is why each version carries its own file
    // contents and the live record keeps `contents` alongside the historical path list.
    // Publishing a new version means passing manifest.content_id; only the creator may, and the
    // version number must move forward, so a stale client cannot quietly overwrite a newer one.
    'POST /v1/ugc/versions': (ctx) => {
      const m = ctx.body.manifest;
      const files = Array.isArray(ctx.body.files) ? ctx.body.files : [];
      const cid = String(m?.content_id ?? '');
      const prev = store.ugcGet(cid);
      if (!prev) return ctx.json(404, { error: 'not_found', content_id: cid });
      if (prev.creator_id !== ctx.player)
        return ctx.json(403, { error: 'only the creator may publish a new version' });
      if (!Number.isFinite(m?.version) || Number(m.version) <= Number(prev.version))
        return ctx.json(422, { error: `version 必须大于当前值 ${prev.version}` });
      // Same gate as the first publication. Skipping it here would make "v2 of an approved
      // package" the way to get a .gd past the scanner.
      const problems = packageProblems(m, files, store);
      if (problems.length) return ctx.json(422, { error: problems.join('；'), problems });
      const live = { version: prev.version, created_at: prev.updated_at ?? prev.created_at,
        declared: prev.declared, contents: prev.contents ?? [] };
      const versions = [...(prev.versions ?? []), live].slice(-UGC_KEEP_VERSIONS);
      const rec = { ...prev, version: m.version, title: m.title ?? prev.title,
        type: m.type ?? prev.type, description: m.description ?? prev.description,
        declared: { triangles: m.triangles ?? prev.declared?.triangles ?? null,
          actors: m.actors ?? prev.declared?.actors ?? null },
        dependencies: m.dependencies ?? prev.dependencies ?? [],
        updated_at: new Date().toISOString(), status: 'published', problems: [],
        versions, contents: files };
      store.ugcPut(rec, files.map(f => f.path));
      return ctx.json(201, publicUgc(rec));
    },

    'GET /v1/ugc/versions': (ctx) => {
      const r = store.ugcGet(String(ctx.query.get('content_id') ?? ''));
      if (!r) return ctx.json(404, { error: 'not_found' });
      const chain = [...(r.versions ?? []), { version: r.version,
        created_at: r.updated_at ?? r.created_at, declared: r.declared,
        contents: r.contents ?? [] }];
      return ctx.json(200, { content_id: r.content_id, live: r.version, creator: r.creator_id,
        versions: chain.map(v => ({ version: v.version, created_at: v.created_at,
          declared: v.declared, files: (v.contents ?? []).map(f => f.path) }))
          .sort((a, b) => a.version - b.version) });
    },

    'POST /v1/ugc/rollback': (ctx) => {
      const r = store.ugcGet(String(ctx.body.content_id ?? ''));
      if (!r) return ctx.json(404, { error: 'not_found' });
      if (r.creator_id !== ctx.player)
        return ctx.json(403, { error: 'only the creator may roll back' });
      const want = Number(ctx.body.version);
      // Checked before the chain: the live version is not in `versions`, so looking it up
      // first turns "already on this version" into a misleading 404.
      if (Number(r.version) === want) return ctx.json(409, { error: '该版本已经是当前版本' });
      const idx = (r.versions ?? []).findIndex(v => Number(v.version) === want);
      if (idx < 0) return ctx.json(404, { error: `没有版本 ${ctx.body.version} 可回滚` });
      const target = r.versions[idx];
      // The version being displaced goes back into the chain, so a rollback is itself
      // reversible instead of a one-way jump.
      const displaced = { version: r.version, created_at: r.updated_at ?? r.created_at,
        declared: r.declared, contents: r.contents ?? [] };
      const versions = [...r.versions.slice(0, idx), ...r.versions.slice(idx + 1), displaced]
        .slice(-UGC_KEEP_VERSIONS);
      const rec = { ...r, version: target.version, declared: target.declared,
        contents: target.contents ?? [], versions,
        updated_at: new Date().toISOString(), rollback_from: r.version };
      store.ugcPut(rec, (target.contents ?? []).map(f => f.path));
      return ctx.json(200, publicUgc(rec));
    },

    'GET /v1/ugc/browse': (ctx) => {
      const q = (ctx.query.get('q') ?? '').toLowerCase();
      const sort = ctx.query.get('sort') ?? 'trending';
      let list = store.ugcList().filter(r => r.status === 'published');
      if (q) list = list.filter(r => `${r.title} ${r.type} ${r.description ?? ''}`
        .toLowerCase().includes(q));
      const ageH = (rec) => Math.max(1, (Date.now() - Date.parse(rec.created_at)) / 3.6e6);
      // Phase 55 forbids permanent download-count ordering, which freezes new creators out
      // of exposure. The gravity has to be steep enough to actually do that: at 0.7 a
      // 90-day-old package with 5000 installs still beat a fresh one with 20, i.e. the rule
      // was decorative. 1.5 makes age dominate accumulated volume.
      const score = (rec) => sort === 'new' ? Date.parse(rec.created_at)
        : sort === 'top' ? rec.downloads
        : (rec.downloads + rec.likes) / Math.pow(ageH(rec) + 2, TRENDING_GRAVITY);
      return ctx.json(200, { sort, count: list.length,
        items: list.sort((a, b) => score(b) - score(a)).slice(0, 50) });
    },

    'POST /v1/ugc/install': (ctx) => {
      const r = store.ugcGet(String(ctx.body.content_id ?? ''));
      if (!r || r.status !== 'published') return ctx.err(404, '作品不存在或未发布');
      r.downloads += 1; store.ugcPut(r);
      return ctx.json(200, { content_id: r.content_id, downloads: r.downloads, files: r.files });
    },

    'POST /v1/ugc/like': (ctx) => {
      const r = store.ugcGet(String(ctx.body.content_id ?? ''));
      if (!r) return ctx.err(404, '作品不存在');
      r.likes += 1; store.ugcPut(r);
      return ctx.json(200, { content_id: r.content_id, likes: r.likes });
    },
  };

  async function dispatch(req, res, bodyRaw) {
    const url = new URL(req.url, 'http://x');
    const key = `${req.method} ${url.pathname}`;
    const rid = randomBytes(6).toString('hex');
    const ip = req.socket.remoteAddress ?? '?';
    let body = {};
    if (bodyRaw) { try { body = JSON.parse(bodyRaw); } catch { return send(400, { error: 'JSON 解析失败' }); } }
    const ctx = {
      body, query: url.searchParams, player: null,
      json: (code, obj) => send(code, obj),
      err: (code, msg) => send(code, { error: msg, request_id: rid }),
    };
    function send(code, obj) {
      const text = JSON.stringify({ ...obj, request_id: rid });
      res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' });
      res.end(text);
      log({ ts: new Date().toISOString(), service: 'backend', request_id: rid, ip,
        route: key, status: code, player_id: ctx.player ?? null,
        severity: code >= 500 ? 'error' : code >= 400 ? 'warn' : 'info' });
      return code;
    }
    // Rate limit before any work, keyed by identity when present so one player cannot
    // starve another behind a shared NAT address.
    const pre = auth(req);
    if (!limit(pre ?? ip)) return send(429, { error: '请求过于频繁', retry_after_ms:
      RATE_WINDOW_MS });
    const needsAuth = key.startsWith('PUT /v1/save') || key.startsWith('GET /v1/save')
      || key.startsWith('POST /v1/save') || key.startsWith('POST /v1/ledger')
      || key.startsWith('GET /v1/ledger') || key.startsWith('POST /v1/ugc')
      || key === 'GET /v1/me';
    if (needsAuth) {
      if (!pre) return ctx.err(401, '需要有效 session token');
      ctx.player = pre;
    }
    const h = handlers[key];
    if (!h) return ctx.err(404, `未知路由 ${key}`);
    return h(ctx);
  }

  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    try { await dispatch(req, res, Buffer.concat(chunks).toString('utf8')); }
    catch (e) {
      res.writeHead(500, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'internal', detail: String(e?.message ?? e) }));
      log({ ts: new Date().toISOString(), service: 'backend', severity: 'error',
        message: String(e?.stack ?? e) });
    }
  });
  return { server, store };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const argv = process.argv.slice(2);
  const get = (k, d) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d; };
  const port = Number(get('--port', 8788));
  const logFile = get('--log', null);
  // Self-exit timer: the gate scripts run under shells where killing a backgrounded child
  // is unreliable (Git Bash on Windows leaves it running), which silently contaminated later
  // performance measurements with stray processes.
  const exitAfter = Number(get('--exit-after', 0));
  if (exitAfter > 0) setTimeout(() => process.exit(0), exitAfter).unref();
  const { server } = makeApp({ port, data: get('--data', 'backend/data'),
    log: (e) => { if (logFile) appendFileSync(logFile, JSON.stringify(e) + '\n'); } });
  server.listen(port, '127.0.0.1', () => console.log(`[backend] listening on 127.0.0.1:${port}`));
}
