// Backend contract tests. Each assertion targets one invariant Part 7 asks for, so a future
// change that quietly weakens server authority, save durability or UGC screening turns red.
// Run: node backend/test.mjs   (exit code 0 = all pass)
import { makeApp } from './server.mjs';
import { Store } from './store.mjs';
import { mkdtempSync, rmSync, readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

let pass = 0, fail = 0;
function ok(name, cond, detail = '') {
  if (cond) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}${detail ? '  <- ' + detail : ''}`); }
}

const dir = mkdtempSync(join(tmpdir(), 'sow-backend-'));
const store = new Store(dir);
// Generous cap on the shared instance so assertion order never depends on the quota;
// the limit itself is proven separately below on its own instance.
const { server } = makeApp({ store, log: () => {}, rateMax: 1000 });
await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

async function call(method, path, { token, body } = {}) {
  const res = await fetch(base + path, {
    method,
    headers: { 'content-type': 'application/json',
      ...(token ? { authorization: 'Bearer ' + token } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch { /* empty body */ }
  return { status: res.status, json };
}
const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');

// --- Phase 47: accounts, tokens, expiry, rotation ---
let r = await call('POST', '/v1/accounts', { body: { display_name: '测试玩家', secret: 'hunter2hunter2' } });
ok('注册返回 201 与三段凭据', r.status === 201 && !!r.json.player_id && !!r.json.session_token
  && !!r.json.refresh_token, JSON.stringify(r.json));
const pid = r.json.player_id; let tok = r.json.session_token; let ref = r.json.refresh_token;
ok('注册赠送由服务器记账', r.json.balance === 1000, String(r.json.balance));

r = await call('POST', '/v1/accounts/login', { body: { display_name: '测试玩家', secret: 'wrong-secret' } });
ok('错误口令被拒 401', r.status === 401);

r = await call('POST', '/v1/accounts/login', { body: { display_name: '测试玩家', secret: 'hunter2hunter2' } });
ok('正确口令登录 200', r.status === 200 && !!r.json.session_token);

r = await call('GET', '/v1/me');
ok('无 token 访问受保护路由 401', r.status === 401);

r = await call('GET', '/v1/me', { token: tok });
ok('带 token 访问 200 且昵称正确', r.status === 200 && r.json.display_name === '测试玩家');

r = await call('POST', '/v1/session/refresh', { body: { refresh_token: ref } });
ok('refresh 换发新会话', r.status === 200 && !!r.json.session_token);
const ref2 = r.json.refresh_token; tok = r.json.session_token;
r = await call('POST', '/v1/session/refresh', { body: { refresh_token: ref } });
ok('旧 refresh token 已失效（单次使用轮换）', r.status === 401);
r = await call('POST', '/v1/session/refresh', { body: { refresh_token: ref2 } });
ok('新 refresh token 可用', r.status === 200);
tok = r.json.session_token;

// --- Phase 48: server-authoritative, versioned, self-healing saves ---
r = await call('PUT', '/v1/save', { token: tok, body: { save_version: 2,
  payload: { buildings: 3 }, balance: 999999 } });
ok('客户端夹带 balance 字段被拒', r.status === 400, JSON.stringify(r.json));

r = await call('PUT', '/v1/save', { token: tok, body: { save_version: 99, payload: {} } });
ok('高于服务器支持的存档版本被拒', r.status === 400);
r = await call('PUT', '/v1/save', { token: tok, body: { save_version: 0, payload: {} } });
ok('低于迁移下限的存档版本被拒', r.status === 409);

r = await call('PUT', '/v1/save', { token: tok, body: { save_version: 2, payload: { v: 'gen1' } } });
ok('写入存档 200', r.status === 200);
r = await call('PUT', '/v1/save', { token: tok, body: { save_version: 2, payload: { v: 'gen2' } } });
ok('两次写入后存在两代存档', r.json.generations.length === 2,
  JSON.stringify(r.json.generations));
r = await call('GET', '/v1/save', { token: tok });
ok('读回最新存档', r.json.recovered === false && r.json.payload.v === 'gen2');

// Corrupt generation 1 on disk; the server must detect, roll back and say so.
const curPath = store.savePath(pid, 1);
const tampered = JSON.parse(readFileSync(curPath, 'utf8'));
tampered.payload.v = 'CORRUPT';
writeFileSync(curPath, JSON.stringify(tampered));
r = await call('GET', '/v1/save', { token: tok });
ok('校验和检出损坏存档', r.json.recovered === true && /checksum/.test(r.json.reason ?? ''),
  JSON.stringify(r.json));
ok('损坏后自动回退到上一代', r.json.payload?.v === 'gen1', JSON.stringify(r.json.payload));

r = await call('POST', '/v1/save/rollback', { token: tok });
ok('显式回退接口可用', r.status === 200 && !!r.json.payload);

// --- Phase 58: append-only ledger, server-computed balance ---
r = await call('POST', '/v1/ledger/tx', { token: tok, body: { type: 'PURCHASE', amount: 300,
  ref: 'flat', idempotency_key: 'k1' } });
ok('购买记账后余额由服务器算出 700', r.json.balance === 700, String(r.json.balance));
r = await call('POST', '/v1/ledger/tx', { token: tok, body: { type: 'PURCHASE', amount: 300,
  idempotency_key: 'k1' } });
ok('幂等键重复提交不二次扣款', r.json.duplicate === true && r.json.balance === 700);
r = await call('POST', '/v1/ledger/tx', { token: tok, body: { type: 'PURCHASE', amount: 99999 } });
ok('余额不足被拒 409', r.status === 409);
r = await call('POST', '/v1/ledger/tx', { token: tok, body: { type: 'PURCHASE', amount: NaN } });
ok('非有限金额被拒', r.status === 400);
r = await call('POST', '/v1/ledger/tx', { token: tok, body: { type: 'WAT', amount: 5 } });
ok('未知交易类型被拒', r.status === 400);
r = await call('GET', '/v1/ledger', { token: tok });
const fold = r.json.transactions.reduce((a, t) => a + t.amount, 0);
ok('账本可审计：逐笔累加等于报告余额', fold === r.json.balance, `${fold} vs ${r.json.balance}`);
ok('账本含注册赠送与一笔消费共 2 条', r.json.transactions.length === 2,
  String(r.json.transactions.length));

// --- Phase 52/53: upload is not publish ---
const pkg = (files, manifest = {}) => ({ manifest: { title: 't', type: 'Building',
  version: 1, triangles: 1000, actors: 2, ...manifest }, files });
r = await call('POST', '/v1/ugc/packages', { token: tok, body: pkg([
  { path: 'building.gd', content: b64('func _ready(): pass') }]) });
ok('含可执行脚本的包被拒', r.status === 422 && /可执行/.test(JSON.stringify(r.json.problems)));
r = await call('POST', '/v1/ugc/packages', { token: tok, body: pkg([
  { path: '../../etc/passwd', content: b64('x') }]) });
ok('路径穿越被拒', r.status === 422 && /路径不安全/.test(JSON.stringify(r.json.problems)));
r = await call('POST', '/v1/ugc/packages', { token: tok, body: pkg(
  [{ path: 'a.json', content: b64('{}') }], { title: '' }) });
ok('manifest 缺字段被拒', r.status === 422 && /title/.test(JSON.stringify(r.json.problems)));
r = await call('POST', '/v1/ugc/packages', { token: tok, body: pkg(
  [{ path: 'a.json', content: b64('{}') }], { triangles: 9e9 }) });
ok('超性能预算被拒', r.status === 422 && /triangles/.test(JSON.stringify(r.json.problems)));
r = await call('POST', '/v1/ugc/packages', { token: tok, body: pkg(
  [{ path: 'a.json', content: b64('{}') }], { dependencies: ['c_nope'] }) });
ok('依赖不存在被拒', r.status === 422 && /依赖不存在/.test(JSON.stringify(r.json.problems)));
r = await call('POST', '/v1/ugc/packages', { token: tok, body: pkg([
  { path: 'a.json', content: b64('{"ok":1}') }]) });
ok('合规包发布 201', r.status === 201 && r.json.status === 'published',
  JSON.stringify(r.json.problems));
const cid = r.json.content_id;
r = await call('POST', '/v1/ugc/install', { token: tok, body: { content_id: cid } });
ok('安装计数递增', r.json.downloads === 1);

// --- Phase 150 / 171: version chain and rollback ---
r = await call('POST', '/v1/ugc/versions', { token: tok, body: pkg(
  [{ path: 'a.json', content: b64('{"v":2}') }], { content_id: cid, version: 2 }) });
ok('新版本发布 201', r.status === 201 && r.json.version === 2, JSON.stringify(r.json.errors ?? ''));
r = await call('POST', '/v1/ugc/versions', { token: tok, body: pkg(
  [{ path: 'a.json', content: b64('x') }], { content_id: cid, version: 2 }) });
ok('版本号不前进被拒', r.status === 422, String(r.status));
// The hole this closes: a version endpoint that skipped the scanner would let a player get a
// .gd published as "v2 of an approved package".
r = await call('POST', '/v1/ugc/versions', { token: tok, body: pkg(
  [{ path: 'evil.gd', content: b64('func _ready(): pass') }], { content_id: cid, version: 3 }) });
ok('新版本同样必须过安全检查', r.status === 422 && /可执行/.test(String(r.json.error)),
  String(r.status));
r = await call('GET', `/v1/ugc/versions?content_id=${cid}`);
ok('版本链含两个版本且 live=2',
  r.json.versions?.length === 2 && r.json.live === 2,
  JSON.stringify(r.json.versions?.map(v => v.version)));
ok('版本列表只给路径不给字节',
  (r.json.versions ?? []).every(v => Array.isArray(v.files) && !('contents' in v)));
r = await call('POST', '/v1/ugc/rollback', { token: tok, body: { content_id: cid, version: 1 } });
ok('回滚到 v1', r.status === 200 && r.json.version === 1, String(r.status));
const back = JSON.parse(readFileSync(store.ugcPath(cid), 'utf8'));
ok('回滚恢复的是真实内容而非仅元数据',
  Buffer.from(back.contents[0].content, 'base64').toString() === '{"ok":1}',
  Buffer.from(back.contents[0].content, 'base64').toString());
ok('被替换的版本仍在链上（回滚可再回滚）',
  (back.versions ?? []).some(v => v.version === 2),
  JSON.stringify((back.versions ?? []).map(v => v.version)));
r = await call('POST', '/v1/ugc/rollback', { token: tok, body: { content_id: cid, version: 77 } });
ok('回滚到不存在的版本 404', r.status === 404, String(r.status));
r = await call('POST', '/v1/ugc/rollback', { token: tok, body: { content_id: cid, version: 1 } });
ok('回滚到当前版本被拒（不是空操作）', r.status === 409, String(r.status));
const other = await call('POST', '/v1/accounts',
  { body: { display_name: '另一个玩家', secret: 'another-secret-1' } });
r = await call('POST', '/v1/ugc/rollback',
  { token: other.json.session_token, body: { content_id: cid, version: 2 } });
ok('非作者不能回滚', r.status === 403, String(r.status));
r = await call('POST', '/v1/ugc/versions', { token: other.json.session_token, body: pkg(
  [{ path: 'a.json', content: b64('{}') }], { content_id: cid, version: 5 }) });
ok('非作者不能发布新版本', r.status === 403, String(r.status));

// Phase 55: pure download order would freeze a fresh creator out. Give an old package a
// huge count and check a brand-new one still outranks it under trending.
const oldRec = JSON.parse(readFileSync(store.ugcPath(cid), 'utf8'));
oldRec.created_at = new Date(Date.now() - 90 * 864e5).toISOString();
oldRec.downloads = 5000;
writeFileSync(store.ugcPath(cid), JSON.stringify(oldRec));
const nf = readdirSync(join(dir, 'ugc'));
ok('UGC 注册表落盘', nf.length >= 1);

const fresh = await call('POST', '/v1/ugc/packages', { token: tok, body: pkg(
  [{ path: 'b.json', content: b64('{}') }], { title: '新作' }) });
for (let i = 0; i < 20; i++)
  await call('POST', '/v1/ugc/install', { token: tok, body: { content_id: fresh.json.content_id } });
r = await call('GET', '/v1/ugc/browse?sort=trending');
const order = r.json.items.map(i => i.content_id);
ok('trending 让 20 次安装的新作品排在 90 天前 5000 次安装的旧作品之前',
  order[0] === fresh.json.content_id, JSON.stringify(order));
r = await call('GET', '/v1/ugc/browse?sort=top');
ok('top 排序仍按下载量（两种口径并存）',
  r.json.items[0].content_id === cid);

// Kept before the rate-limit probe: once the window is exhausted every route answers 429.
r = await call('GET', '/v1/nope', { token: tok });
ok('未知路由 404', r.status === 404);

// --- Phase 79: rate limit, on its own instance so a exhausted window cannot poison the
// assertions above or below ---
const rl = makeApp({ store: new Store(mkdtempSync(join(tmpdir(), 'sow-rl-'))),
  log: () => {}, rateMax: 5 });
const rlServer = rl.server;
await new Promise(res => rlServer.listen(0, '127.0.0.1', res));
const rlBase = `http://127.0.0.1:${rlServer.address().port}`;
const reg = await fetch(rlBase + '/v1/accounts', { method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ display_name: '限流', secret: 'hunter2hunter2' }) }).then(x => x.json());
let got429 = 0, allowed = 0;
for (let i = 0; i < 12; i++) {
  const x = await fetch(rlBase + '/v1/me', { headers: { authorization: 'Bearer ' + reg.session_token } });
  if (x.status === 429) got429++; else allowed++;
}
ok('超过窗口配额后返回 429', got429 > 0, `allowed=${allowed} limited=${got429}`);
ok('限流前仍有正常放行', allowed >= 5, String(allowed));
rlServer.close();

server.close();
rmSync(dir, { recursive: true, force: true });
console.log('-----');
console.log(`backend: ${pass}/${pass + fail} PASS`);
process.exit(fail ? 1 : 0);
