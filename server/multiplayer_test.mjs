// Phase 234 / 228: two-player end-to-end contract test.
//
// Spins up the gateway and the game server in-process, then drives two *Node* clients through
// login → move → place → disconnect → reconnect → verify. These clients reuse the server's own
// framing, so this file proves the server's rules; it does NOT prove the Godot client can speak
// them — that is Pipeline step 10b, which boots the real client under headless Godot. Splitting
// the two is deliberate: an earlier version of this header claimed it launched Godot clients when
// it did no such thing, which is exactly how the transport mismatch survived to review.
// Every assertion is a line in the ledger; if any fails the pipeline gate fails.

import net from 'node:net';
import { makeApp } from '../backend/server.mjs';
import { startGameServer } from './game_server.mjs';
import { Store } from '../backend/store.mjs';
import http from 'node:http';

const GS_PORT = 29876;
const GW_PORT = 28799;

let pass = 0, fail = 0;
function ok(label, cond, detail = '') {
  if (cond) { pass++; console.log(`PASS  ${label}`); }
  else { fail++; console.log(`FAIL  ${label}  ${detail}`); }
}

function encode(msg, payload) {
  const arr = [msg];
  switch (msg) {
    case 1: arr.push(payload.token, payload.client_version); break; // C2S_HELLO
    case 3: arr.push(payload.session_id, payload.last_seq); break; // C2S_RECONNECT
    case 10: arr.push(payload.seq, payload.dt, payload.move_dir.x, payload.move_dir.y, payload.yaw, payload.actions); break; // C2S_INPUT
    case 20: arr.push(payload.req_id, payload.tpl, payload.x, payload.z, payload.yaw, payload.scale, payload.name ?? '', payload.occ ?? -1); break; // C2S_CREATE
    case 21: arr.push(payload.req_id, payload.obj_id); break; // C2S_REMOVE
    case 41: arr.push(payload.t); break; // C2S_PING
    default: arr.push(payload);
  }
  const packed = Buffer.from(JSON.stringify(arr), 'utf8');
  const frame = Buffer.alloc(4 + packed.length);
  frame.writeUInt32BE(packed.length, 0);
  packed.copy(frame, 4);
  return frame;
}

function decodeFrames(buf) {
  const msgs = [];
  let off = 0;
  while (off + 4 <= buf.length) {
    const len = buf.readUInt32BE(off);
    if (off + 4 + len > buf.length) break;
    try {
      const arr = JSON.parse(buf.subarray(off + 4, off + 4 + len).toString('utf8'));
      msgs.push(arr);
    } catch (_) {}
    off += 4 + len;
  }
  return { msgs, rest: buf.subarray(off) };
}

class TestClient {
  constructor(name) { this.name = name; this.sock = null; this.buf = Buffer.alloc(0); this.msgs = []; this.token = ''; this.sessionId = ''; this.playerId = ''; }
  async connect(port) {
    return new Promise((resolve, reject) => {
      this.sock = net.createConnection({ port }, () => resolve());
      this.sock.on('data', d => {
        this.buf = Buffer.concat([this.buf, d]);
        const { msgs, rest } = decodeFrames(this.buf);
        this.msgs.push(...msgs);
        this.buf = rest;
      });
      this.sock.on('error', reject);
      this.sock.on('close', () => {});
    });
  }
  send(msg, payload) { if (this.sock) this.sock.write(encode(msg, payload)); }
  waitFor(msgId, timeoutMs = 5000) {
    const start = Date.now();
    return new Promise(resolve => {
      const check = () => {
        const idx = this.msgs.findIndex(m => m[0] === msgId);
        if (idx >= 0) { const m = this.msgs.splice(idx, 1)[0]; resolve(m); return; }
        if (Date.now() - start > timeoutMs) { resolve(null); return; }
        setTimeout(check, 50);
      };
      check();
    });
  }
  close() { if (this.sock) { this.sock.destroy(); this.sock = null; } }
}

async function registerAndLogin(displayName) {
  const reg = await fetch(`http://127.0.0.1:${GW_PORT}/v1/accounts`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ display_name: displayName, secret: 'test-secret-1' }),
  });
  const regBody = await reg.json();
  const login = await fetch(`http://127.0.0.1:${GW_PORT}/v1/accounts/login`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ display_name: displayName, secret: 'test-secret-1' }),
  });
  const loginBody = await login.json();
  return loginBody.session_token;
}

async function main() {
  const store = new Store('backend/data_test_mp');
  const gw = makeApp({ store, port: GW_PORT });
  gw.server.listen(GW_PORT, '127.0.0.1');
  const gs = startGameServer({ store, port: GS_PORT });

  // Wait for both servers to be accepting connections.
  await new Promise(r => setTimeout(r, 1000));
  // Verify gateway is reachable before proceeding.
  for (let i = 0; i < 10; i++) {
    try { await fetch(`http://127.0.0.1:${GW_PORT}/v1/me`); break; } catch (_) { await new Promise(r => setTimeout(r, 300)); }
  }

  const tokA = await registerAndLogin('玩家A');
  const tokB = await registerAndLogin('玩家B');
  ok('两个账号注册并登录成功', !!tokA && !!tokB, `tokA=${!!tokA} tokB=${!!tokB}`);

  const cA = new TestClient('A');
  const cB = new TestClient('B');
  await cA.connect(GS_PORT);
  await cB.connect(GS_PORT);

  // --- Handshake ---
  cA.send(1, { token: tokA, client_version: 1 });
  cB.send(1, { token: tokB, client_version: 1 });
  const welcA = await cA.waitFor(2);
  const welcB = await cB.waitFor(2);
  ok('A 收到 WELCOME', welcA != null);
  ok('B 收到 WELCOME', welcB != null);
  ok('A 获得 player_id', welcA && String(welcA[1]).length > 0, String(welcA?.[1]));
  ok('B 获得 player_id', welcB && String(welcB[1]).length > 0, String(welcB?.[1]));
  ok('两人 player_id 不同', welcA && welcB && String(welcA[1]) !== String(welcB[1]));

  // --- Movement sync ---
  cA.send(10, { seq: 1, dt: 0.033, move_dir: { x: 1, y: 0 }, yaw: 0, actions: 0 });
  await new Promise(r => setTimeout(r, 200));
  // B should receive an entity delta containing A's position.
  const deltas = cB.msgs.filter(m => m[0] === 11);
  ok('B 收到 A 的移动同步', deltas.length > 0, `deltas=${deltas.length}`);
  if (deltas.length > 0) {
    const ents = deltas[deltas.length - 1][1];
    const aEnt = Array.isArray(ents) ? ents.find(e => e.id === String(welcA[1])) : null;
    ok('B 看到的 A 位置已更新', aEnt && Number(aEnt.x) > 1150, JSON.stringify(aEnt));
  }

  // --- Creation sync ---
  // Self-state is the frame the Godot client reconciles against. Its shape is asserted here
  // because encode() reaches for `default:` on an unrecognised id and pushes the whole payload as
  // one nested object — which every consumer then reads as undefined. A missing case label is
  // invisible unless someone checks the field count, and one already went missing this way.
  const self = await cA.waitFor(13);
  ok('A 收到 SELF_STATE 且为扁平字段', self != null && self.length === 5, JSON.stringify(self));
  ok('SELF_STATE 字段为有限数值',
    self != null && Number.isFinite(Number(self[2])) && Number.isFinite(Number(self[3])),
    JSON.stringify(self));

  cA.send(20, { req_id: 'r1', tpl: 'mall', x: 2000, z: 2000, yaw: 0, scale: 1, name: '', occ: -1 });
  const ackA = await cA.waitFor(22);
  ok('A 收到 CREATE_ACK', ackA != null);
  ok('A 的放置被服务器接受', ackA && ackA[2] === true, JSON.stringify(ackA));
  const streamB = await cB.waitFor(24, 3000);
  ok('B 收到 A 的建筑流式推送', streamB != null, `msgs=${cB.msgs.map(m=>m[0])}`);
  if (streamB) {
    const obj = streamB[1];
    ok('B 收到的建筑 tpl 正确', obj && obj.tpl === 'mall', JSON.stringify(obj));
    ok('B 收到的建筑归属是 A', obj && obj.owner === String(welcA[1]), JSON.stringify(obj));
  }

  // --- Server authority: invalid creation refused ---
  cA.send(20, { req_id: 'r2', tpl: 'mall', x: 0, z: 0, yaw: 0, scale: 1, name: '', occ: -1 }); // Huangpu river
  const ackBad = await cA.waitFor(22);
  ok('河里的建筑被服务器拒绝', ackBad && ackBad[2] === false, JSON.stringify(ackBad));

  // --- Disconnect + reconnect ---
  cA.close();
  await new Promise(r => setTimeout(r, 500));
  // B should still be connected and able to act.
  cB.send(20, { req_id: 'r3', tpl: 'shopfront', x: 3000, z: 3000, yaw: 0, scale: 1, name: '', occ: -1 });
  const ackB = await cB.waitFor(22);
  ok('A 断开后 B 仍能放置', ackB && ackB[2] === true, JSON.stringify(ackB));

  // A reconnects with the same session.
  const cA2 = new TestClient('A2');
  await cA2.connect(GS_PORT);
  cA2.send(3, { session_id: String(welcA[2]), last_seq: 1 }); // C2S_RECONNECT
  const snap = await cA2.waitFor(4, 3000);
  ok('A 重连收到 SNAPSHOT', snap != null);
  if (snap) {
    const creations = snap[1]?.creations ?? [];
    ok('重连快照包含 A 之前放的建筑',
      creations.some(c => c.tpl === 'mall' && c.owner === String(welcA[1])),
      JSON.stringify(creations.map(c => ({ tpl: c.tpl, owner: c.owner }))));
    ok('重连快照包含 B 在 A 离线期间放的建筑',
      creations.some(c => c.tpl === 'shopfront' && c.owner === String(welcB[1])),
      JSON.stringify(creations.map(c => ({ tpl: c.tpl, owner: c.owner }))));
  }

  // --- Ownership enforcement ---
  // B tries to remove A's building — should be refused.
  const aObjId = ackA ? Number(ackA[3]) : 0;
  if (aObjId > 0) {
    cB.send(21, { req_id: 'r4', obj_id: aObjId });
    const rmAck = await cB.waitFor(23, 2000);
    ok('B 不能删除 A 的建筑', rmAck && rmAck[2] === false, JSON.stringify(rmAck));
  }

  // Cleanup
  cA2.close();
  cB.close();
  gs.stop();
  gw.server.close();

  console.log('-----');
  console.log(`multiplayer: ${pass}/${pass + fail} PASS`);
  process.exit(fail ? 1 : 0);
}

main().catch(e => { console.error('FATAL', e); process.exit(1); });
