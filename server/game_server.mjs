// Phase 172 / 173: the authoritative game server.
//
// This process is the only thing in the system allowed to decide where a player is, how much
// money they have, whether a building exists, or what an NPC is doing. Clients predict their
// own movement for responsiveness and send inputs; this server simulates, reconciles, and
// streams back the truth. Anything a client claims without the server's signature is fiction.
//
// It reuses the existing backend store for persistence (accounts, saves, ledger, UGC) so there
// is one source of truth for "what the player owns" rather than two databases that will drift.
// The gateway (server.mjs) handles auth and hands off a session token; this server trusts that
// token and nothing else.

import { createServer } from 'node:net';
import { randomBytes, createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { Store } from '../backend/store.mjs';

const sha = (s) => createHash('sha256').update(s).digest('hex');

const TICK_HZ = 30;
const TICK_MS = 1000 / TICK_HZ;
const GRACE_SEC = 30;                // keep a disconnected player's state for this long
const INTEREST_RADIUS_CHUNKS = 1;    // chunk grid: subscribe to own + 8 neighbours
const CHUNK_SIZE = 250;              // metres — must match GameGlobals.CHUNK_SIZE
const MAX_MOVE_PER_TICK = 14.0;      // m/tick ≈ 420 m/s at 30 Hz; above this is rejected
const PROTOCOL_VERSION = 1;

// Prices live here because this is the process that takes the money; a client showing a different
// number would be displaying an opinion, not a fact (Phase 196). Units are cents, the same unit the
// ledger uses. An id missing from this table is charged DEFAULT_BUILD_COST rather than nothing, so
// forgetting an entry makes a building wrongly *expensive* — which review rule R9 turns into a
// build failure before it can become a silent pricing bug.
const DEFAULT_BUILD_COST = 100;
const SALVAGE_RATE = 0.25;
const BUILD_COST = {
  office_tower: 900, plinth_tower: 700, mall: 600, xiaoqu: 500, factory: 450,
  villas: 400, lilong: 350, walkup: 300, shopfront: 250, parking: 200,
  site: 150, park: 120,
  plane_tree: 20, street_lamp: 25, ad_board: 30, stop_sign: 20, bench: 15,
  curb_car: 15, litter_bin: 10, bollard: 10, barrier: 10,
};

function costOf(tpl) {
  const c = BUILD_COST[tpl];
  return Number.isFinite(c) ? c : DEFAULT_BUILD_COST;
}

// Message ids mirror src/net/SyncProtocol.gd exactly. If you add one here, add it there too;
// if they disagree, two players will silently talk past each other.
const Msg = {
  C2S_HELLO: 1, S2C_WELCOME: 2, C2S_RECONNECT: 3, S2C_SNAPSHOT: 4,
  C2S_INPUT: 10, S2C_ENTITY_DELTA: 11, S2C_TIME: 12, S2C_SELF_STATE: 13,
  C2S_CREATE: 20, C2S_REMOVE: 21, S2C_CREATE_ACK: 22, S2C_REMOVE_ACK: 23,
  S2C_CREATION_STREAM: 24,
  S2C_ECON_EVENT: 30,
  S2C_KICK: 40, C2S_PING: 41, S2C_PONG: 42,
};

const Channel = { RELIABLE: 0, UNRELIABLE: 1 };
const CHANNEL_OF = {
  [Msg.C2S_HELLO]: Channel.RELIABLE, [Msg.S2C_WELCOME]: Channel.RELIABLE,
  [Msg.C2S_RECONNECT]: Channel.RELIABLE, [Msg.S2C_SNAPSHOT]: Channel.RELIABLE,
  [Msg.C2S_INPUT]: Channel.UNRELIABLE, [Msg.S2C_ENTITY_DELTA]: Channel.UNRELIABLE,
  [Msg.S2C_TIME]: Channel.UNRELIABLE, [Msg.S2C_SELF_STATE]: Channel.UNRELIABLE,
  [Msg.C2S_CREATE]: Channel.RELIABLE, [Msg.C2S_REMOVE]: Channel.RELIABLE,
  [Msg.S2C_CREATE_ACK]: Channel.RELIABLE, [Msg.S2C_REMOVE_ACK]: Channel.RELIABLE,
  [Msg.S2C_CREATION_STREAM]: Channel.RELIABLE,
  [Msg.S2C_ECON_EVENT]: Channel.RELIABLE,
  [Msg.S2C_KICK]: Channel.RELIABLE, [Msg.C2S_PING]: Channel.RELIABLE, [Msg.S2C_PONG]: Channel.RELIABLE,
};

function encode(msg, payload) {
  const arr = [msg];
  switch (msg) {
    case Msg.S2C_WELCOME:
      arr.push(payload.player_id, payload.session_id, payload.snapshot); break;
    case Msg.S2C_SNAPSHOT:
      arr.push(payload); break;
    case Msg.S2C_ENTITY_DELTA:
      arr.push(payload.entities); break;
    case Msg.S2C_TIME:
      arr.push(payload.hour, payload.day, payload.weather, payload.wet); break;
    case Msg.S2C_SELF_STATE:
      arr.push(payload.seq, payload.x, payload.z, payload.yaw); break;
    case Msg.S2C_CREATE_ACK:
      arr.push(payload.req_id, !!payload.ok, payload.obj_id ?? 0, payload.reason ?? ''); break;
    case Msg.S2C_REMOVE_ACK:
      arr.push(payload.req_id, !!payload.ok, payload.reason ?? ''); break;
    case Msg.S2C_CREATION_STREAM:
      arr.push(payload.obj); break;
    case Msg.S2C_ECON_EVENT:
      arr.push(payload); break;
    case Msg.S2C_KICK:
      arr.push(payload.reason ?? ''); break;
    case Msg.S2C_PONG:
      arr.push(payload.t); break;
    default:
      arr.push(payload);
  }
  return Buffer.from(JSON.stringify(arr), 'utf8');
}

function decode(buf) {
  try {
    const arr = JSON.parse(buf.toString('utf8'));
    if (!Array.isArray(arr) || arr.length < 1) return { msg: -1, payload: {} };
    const [msg, ...rest] = arr;
    const p = {};
    switch (msg) {
      case Msg.C2S_HELLO:
        p.token = String(rest[0] ?? ''); p.client_version = Number(rest[1] ?? 0);
        p.spawn_x = Number(rest[2] ?? 1150); p.spawn_z = Number(rest[3] ?? 300); break;
      case Msg.C2S_RECONNECT:
        p.session_id = String(rest[0] ?? ''); p.last_seq = Number(rest[1] ?? 0); break;
      case Msg.C2S_INPUT:
        p.seq = Number(rest[0] ?? 0); p.dt = Number(rest[1] ?? 0);
        p.move_dir = { x: Number(rest[2] ?? 0), y: Number(rest[3] ?? 0) };;
        p.yaw = Number(rest[4] ?? 0); p.actions = Number(rest[5] ?? 0); break;
      case Msg.C2S_CREATE:
        p.req_id = String(rest[0] ?? ''); p.tpl = String(rest[1] ?? '');
        p.x = Number(rest[2] ?? 0); p.z = Number(rest[3] ?? 0);
        p.yaw = Number(rest[4] ?? 0); p.scale = Number(rest[5] ?? 1);
        p.name = String(rest[6] ?? ''); p.occ = Number(rest[7] ?? -1); break;
      case Msg.C2S_REMOVE:
        p.req_id = String(rest[0] ?? ''); p.obj_id = Number(rest[1] ?? 0); break;
      case Msg.C2S_PING:
        p.t = Number(rest[0] ?? 0); break;
      default:
        p.raw = rest;
    }
    return { msg, payload: p };
  } catch (e) {
    return { msg: -1, payload: {}, error: e };
  }
}

function chunkOf(x, z) {
  return { cx: Math.floor(x / CHUNK_SIZE), cz: Math.floor(z / CHUNK_SIZE) };
}

function chunkKey(cx, cz) { return `${cx},${cz}`; }

function nearbyChunks(cx, cz, r = INTEREST_RADIUS_CHUNKS) {
  const out = [];
  for (let dx = -r; dx <= r; dx++)
    for (let dz = -r; dz <= r; dz++)
      out.push(chunkKey(cx + dx, cz + dz));
  return out;
}

// A minimal creation validator that mirrors the client's Validation.check just enough to stop
// a malicious client from placing buildings in the river or on top of each other. It does NOT
// duplicate the full zone/budget logic — those live on the client for UX and here we only
// refuse things that would corrupt shared state.
function validateCreation(obj, world) {
  if (!obj || typeof obj !== 'object') return 'invalid object';
  if (!Number.isFinite(obj.x) || !Number.isFinite(obj.z)) return 'non-finite position';
  if (Math.abs(obj.x) > 6000 || Math.abs(obj.z) > 6000) return 'off map';
  // Water check uses the same Huangpu centreline the generator does. Cheap distance test;
  // the client already refused most bad placements, this catches the ones that lied.
  const hw = 190; // Huangpu half-width near origin
  if (Math.abs(obj.x) < hw + 30 && obj.z > -3000 && obj.z < 4000) return 'water';
  for (const o of world.creations.values()) {
    const dx = o.x - obj.x, dz = o.z - obj.z;
    if (dx * dx + dz * dz < 4) return 'overlap';
  }
  return null;
}

export function startGameServer(opts = {}) {
  const port = opts.port ?? 9876;
  const store = opts.store ?? new Store(opts.data ?? 'backend/data');
  const sessions = new Map();     // session_id -> {player_id, peer, lastSeen, graceTimer}
  const peers = new Map();         // socket -> {session_id?, buffer}
  const players = new Map();       // player_id -> {pos:{x,z}, yaw, vel, anim, seq, lastInput}
  const world = {
    hour: 9.0, day: 1, weather: 0, wet: 0.0,
    creations: new Map(),          // obj_id -> {id, tpl, x, z, yaw, scale, owner, name?, occ?}
    nextObjId: 1,
  };

  // Load persisted creations into the authoritative world so a restart does not wipe the city.
  const saveRoot = store.root;
  try {
    const shared = path.join(saveRoot, 'world_creations.json');
    if (fs.existsSync(shared)) {
      const arr = JSON.parse(fs.readFileSync(shared, 'utf8'));
      for (const o of arr) {
        const id = Number(o.id ?? world.nextObjId++);
        world.creations.set(id, { ...o, id });
        if (id >= world.nextObjId) world.nextObjId = id + 1;
      }
    }
  } catch (_) { /* first run */ }

  function persistCreations() {
    try {
      const arr = [...world.creations.values()];
      fs.writeFileSync(path.join(store.root, 'world_creations.json'), JSON.stringify(arr));
    } catch (_) {}
  }

  function buildSnapshot(forPlayerId) {
    return {
      protocol: PROTOCOL_VERSION,
      hour: world.hour, day: world.day, weather: world.weather, wet: world.wet,
      players: [...players.entries()].map(([pid, p]) => ({
        id: pid, x: p.pos.x, z: p.pos.z, yaw: p.yaw,
      })).filter(p => p.id !== forPlayerId),
      creations: [...world.creations.values()],
    };
  }

  function send(peer, msg, payload) {
    if (!peer || peer.destroyed) return;
    try {
      const packed = encode(msg, payload);
      const frame = Buffer.alloc(4 + packed.length);
      frame.writeUInt32BE(packed.length, 0);
      packed.copy(frame, 4);
      peer.write(frame);
    } catch (_) {}
  }

  function broadcastToInterested(msg, payload, filter) {
    for (const [sid, sess] of sessions) {
      if (filter && !filter(sess)) continue;
      send(sess.peer, msg, payload);
    }
  }

  function handleHello(peer, p) {
    const account = store.getSession(sha(p.token));
    if (!account || !account.player_id) {
      // The reason has to be visible on the server side too: a client that is kicked with no
      // log line is indistinguishable from a client that never connected.
      console.log(`[gs] kick: no session for token (len=${(p.token || '').length})`);
      send(peer, Msg.S2C_KICK, { reason: 'invalid session' });
      peer.end();
      return;
    }
    if (p.client_version !== PROTOCOL_VERSION) {
      console.log(`[gs] kick: protocol ${p.client_version} != ${PROTOCOL_VERSION}`);
      send(peer, Msg.S2C_KICK, { reason: `protocol ${p.client_version} != ${PROTOCOL_VERSION}` });
      peer.end();
      return;
    }
    const sessionId = 's_' + randomBytes(8).toString('hex');
    sessions.set(sessionId, {
      player_id: account.player_id, peer, lastSeen: Date.now(), graceTimer: null,
    });
    peers.set(peer, { session_id: sessionId, buffer: Buffer.alloc(0) });
    // If this player was already in the world (reconnect-without-C2S_RECONNECT), restore them.
    if (!players.has(account.player_id)) {
      // The client's reported spawn is a seed, not an instruction: it has to be a finite point
      // inside the map, and everything after this instant is integrated server-side from inputs.
      const sx = Number.isFinite(p.spawn_x) ? Math.max(-6000, Math.min(6000, p.spawn_x)) : 1150;
      const sz = Number.isFinite(p.spawn_z) ? Math.max(-6000, Math.min(6000, p.spawn_z)) : 300;
      players.set(account.player_id, {
        pos: { x: sx, z: sz }, yaw: 0, vel: { x: 0, z: 0 }, anim: 0, seq: 0, lastInput: null,
      });
    }
    send(peer, Msg.S2C_WELCOME, {
      player_id: account.player_id, session_id: sessionId,
      snapshot: buildSnapshot(account.player_id),
    });
  }

  function handleReconnect(peer, p) {
    const sess = sessions.get(p.session_id);
    if (!sess) {
      send(peer, Msg.S2C_KICK, { reason: 'unknown session' });
      peer.end();
      return;
    }
    if (sess.graceTimer) { clearTimeout(sess.graceTimer); sess.graceTimer = null; }
    sess.peer = peer;
    sess.lastSeen = Date.now();
    peers.set(peer, { session_id: p.session_id, buffer: Buffer.alloc(0) });
    send(peer, Msg.S2C_SNAPSHOT, buildSnapshot(sess.player_id));
  }

  function handleInput(sess, p) {
    const pl = players.get(sess.player_id);
    if (!pl) return;
    // Reject inputs that imply impossible speed. A real anti-cheat would also check
    // acceleration and terrain, but this stops the trivial "teleport across the map" cheat.
    const dt = Math.max(0.001, Math.min(0.2, Number(p.dt) || 0.033));
    const mx = Number(p.move_dir?.x) || 0;
    const mz = Number(p.move_dir?.y) || 0;
    const len = Math.hypot(mx, mz);
    const step = len * dt * 6.0; // 6 m/s walk cap
    if (step > MAX_MOVE_PER_TICK) {
      // Clamp rather than kick: a lag spike can produce a large dt legitimately.
      const scale = MAX_MOVE_PER_TICK / Math.max(step, 1e-6);
      p.move_dir = { x: mx * scale, y: mz * scale };
    }
    pl.pos.x += (Number(p.move_dir?.x) || 0) * dt * 6.0;
    pl.pos.z += (Number(p.move_dir?.y) || 0) * dt * 6.0;
    pl.yaw = Number(p.yaw) || 0;
    pl.seq = Math.max(pl.seq, Number(p.seq) || 0);
    pl.lastInput = p;
    sess.lastSeen = Date.now();
  }

  function handleCreate(sess, p) {
    // Idempotency first: the ledger key is the request id, so a replayed packet cannot buy the
    // same building twice. Checked before anything else so a duplicate costs nothing and creates
    // nothing.
    const key = p.req_id ? `build:${p.req_id}` : null;
    if (key && store.findTx(sess.player_id, key)) {
      send(sess.peer, Msg.S2C_CREATE_ACK, { req_id: p.req_id, ok: false, reason: 'duplicate request' });
      return;
    }
    const cost = costOf(p.tpl);
    const bal = store.balance(sess.player_id);
    if (bal < cost) {
      send(sess.peer, Msg.S2C_CREATE_ACK, {
        req_id: p.req_id, ok: false, reason: `insufficient funds: have ${bal}, need ${cost}`,
      });
      return;
    }
    const obj = {
      id: world.nextObjId++, tpl: p.tpl, x: p.x, z: p.z,
      yaw: p.yaw, scale: p.scale, owner: sess.player_id,
    };
    if (p.name) obj.name = p.name;
    if (Number(p.occ) >= 0) obj.occ = Number(p.occ);
    const err = validateCreation(obj, world);
    if (err) {
      send(sess.peer, Msg.S2C_CREATE_ACK, { req_id: p.req_id, ok: false, reason: err });
      return;
    }
    world.creations.set(obj.id, obj);
    persistCreations();
    // Charged only after every geometric check passed: a placement the world refused must not
    // also take money. The ledger is the fact — the balance is whatever folding it produces.
    if (key) {
      store.tx(sess.player_id, {
        type: 'UGC_BUILD', amount: -cost, ref: `obj:${obj.id}`, idempotency_key: key,
      });
    }
    const after = store.balance(sess.player_id);
    send(sess.peer, Msg.S2C_CREATE_ACK, { req_id: p.req_id, ok: true, obj_id: obj.id });
    // Stream to every other connected player. Interest management would filter this by chunk;
    // for the two-player slice, broadcast is correct and simple.
    broadcastToInterested(Msg.S2C_CREATION_STREAM, { obj }, s => s.player_id !== sess.player_id);
    // The economic consequence is announced to everyone, payer included, and the number in it
    // came from the ledger rather than from anything a client asserted.
    broadcastToInterested(Msg.S2C_ECON_EVENT, {
      kind: 'build', player_id: sess.player_id, obj_id: obj.id, tpl: obj.tpl,
      delta: -cost, balance: after,
    });
  }

  function handleRemove(sess, p) {
    const obj = world.creations.get(Number(p.obj_id));
    if (!obj) {
      send(sess.peer, Msg.S2C_REMOVE_ACK, { req_id: p.req_id, ok: false, reason: 'not found' });
      return;
    }
    if (obj.owner !== sess.player_id) {
      send(sess.peer, Msg.S2C_REMOVE_ACK, { req_id: p.req_id, ok: false, reason: 'not owner' });
      return;
    }
    world.creations.delete(obj.id);
    persistCreations();
    const rkey = p.req_id ? `demolish:${p.req_id}` : null;
    let credit = 0;
    if (rkey && !store.findTx(sess.player_id, rkey)) {
      // Demolition returns salvage instead of nothing, so removal is auditable too: the ledger
      // explains every cent of the balance either way.
      credit = Math.floor(costOf(obj.tpl) * SALVAGE_RATE);
      store.tx(sess.player_id, {
        type: 'UGC_DEMOLISH', amount: credit, ref: `obj:${obj.id}`, idempotency_key: rkey,
      });
    }
    send(sess.peer, Msg.S2C_REMOVE_ACK, { req_id: p.req_id, ok: true });
    broadcastToInterested(Msg.S2C_CREATION_STREAM, { obj: { ...obj, removed: true } },
      s => s.player_id !== sess.player_id);
    broadcastToInterested(Msg.S2C_ECON_EVENT, {
      kind: 'demolish', player_id: sess.player_id, obj_id: obj.id, tpl: obj.tpl,
      delta: credit, balance: store.balance(sess.player_id),
    });
  }

  function tick() {
    // Advance the shared clock slowly so two clients see the same time of day.
    world.hour += (1 / TICK_HZ) / 480 * 24; // 480 s per in-game day
    if (world.hour >= 24) { world.hour -= 24; world.day += 1; }

    // Build per-player entity deltas scoped to their interest area.
    for (const [sid, sess] of sessions) {
      if (!sess.peer || sess.peer.destroyed) continue;
      const me = players.get(sess.player_id);
      if (!me) continue;
      const myChunk = chunkOf(me.pos.x, me.pos.z);
      const visible = nearbyChunks(myChunk.cx, myChunk.cz);
      const entities = [];
      for (const [pid, pl] of players) {
        if (pid === sess.player_id) continue;
        const pc = chunkOf(pl.pos.x, pl.pos.z);
        if (!visible.includes(chunkKey(pc.cx, pc.cz))) continue;
        entities.push({ id: pid, kind: 'player', x: pl.pos.x, z: pl.pos.z, yaw: pl.yaw });
      }
      // NPCs and vehicles would be added here with the same interest filter. For the
      // two-player slice, only remote players are replicated; the spec's LOD tiers become
      // relevant once the server actually simulates thousands of agents.
      // Sent even when empty. Suppressing the empty list is the classic way to make a peer
      // immortal: the last player walks out of interest range, no message arrives, and the
      // client keeps rendering an avatar for someone the server no longer replicates.
      send(sess.peer, Msg.S2C_ENTITY_DELTA, { entities });
      // Self-state travels separately from the entity list: the entity list is empty for a lone
      // player, but reconciliation must still run or the client's own position is unfalsifiable.
      send(sess.peer, Msg.S2C_SELF_STATE, { seq: me.seq, x: me.pos.x, z: me.pos.z, yaw: me.yaw });
      send(sess.peer, Msg.S2C_TIME, {
        hour: world.hour, day: world.day, weather: world.weather, wet: world.wet,
      });
    }

    // Grace-period eviction: a disconnected player stays in the world briefly so a reconnect
    // restores them; after GRACE_SEC they are removed and their slot freed.
    const now = Date.now();
    for (const [sid, sess] of sessions) {
      if (sess.peer && !sess.peer.destroyed) continue;
      if (!sess.graceTimer) {
        sess.graceTimer = setTimeout(() => {
          sessions.delete(sid);
          players.delete(sess.player_id);
        }, GRACE_SEC * 1000);
      }
    }
  }

  const server = createServer((socket) => {
    peers.set(socket, { session_id: null, buffer: Buffer.alloc(0) });
    socket.on('data', (chunk) => {
      const meta = peers.get(socket);
      if (!meta) return;
      meta.buffer = Buffer.concat([meta.buffer, chunk]);
      // Framing: each message is prefixed with a 4-byte big-endian length. This is the simplest
      // framing that survives TCP coalescing and splitting without requiring a handshake.
      while (meta.buffer.length >= 4) {
        const len = meta.buffer.readUInt32BE(0);
        if (len > 1_000_000) { socket.destroy(); return; } // sanity cap
        if (meta.buffer.length < 4 + len) break;
        const frame = meta.buffer.subarray(4, 4 + len);
        meta.buffer = meta.buffer.subarray(4 + len);
        const { msg, payload, error } = decode(frame);
        if (error) { console.error('[gs] decode error', error); continue; }
        const sess = meta.session_id ? sessions.get(meta.session_id) : null;
        switch (msg) {
          case Msg.C2S_HELLO:   handleHello(socket, payload); break;
          case Msg.C2S_RECONNECT: handleReconnect(socket, payload); break;
          case Msg.C2S_INPUT:   if (sess) handleInput(sess, payload); break;
          case Msg.C2S_CREATE:  if (sess) handleCreate(sess, payload); break;
          case Msg.C2S_REMOVE:  if (sess) handleRemove(sess, payload); break;
          case Msg.C2S_PING:    if (sess) send(sess.peer, Msg.S2C_PONG, { t: payload.t }); break;
          default: /* ignore unknown for forward compat */ break;
        }
      }
    });
    socket.on('close', () => {
      const meta = peers.get(socket);
      if (meta?.session_id) {
        const sess = sessions.get(meta.session_id);
        if (sess) { sess.peer = null; sess.lastSeen = Date.now(); }
      }
      peers.delete(socket);
    });
    socket.on('error', () => socket.destroy());
  });

  const tickInterval = setInterval(tick, TICK_MS);
  server.listen(port, () => console.log(`[game_server] listening on :${port}`));

  return {
    server,
    stop: () => { clearInterval(tickInterval); server.close(); },
    getState: () => ({ players: players.size, sessions: sessions.size, creations: world.creations.size }),
  };
}

// Allow running directly: node server/game_server.mjs
if (process.argv[1]?.endsWith('game_server.mjs')) {
  startGameServer({
    port: Number(process.env.GS_PORT) || 9876,
    // Same root as the gateway: the game server resolves session tokens against the account
    // store, so pointing it at a different directory means every handshake is kicked.
    data: process.env.GS_DATA || 'backend/data',
  });
  // Self-exit for the pipeline: a backgrounded child survives `kill` under Git Bash on Windows,
  // and a stray server holding the port fails the next run for the wrong reason.
  const t = Number(process.env.GS_EXIT_AFTER) || 0;
  if (t > 0) setTimeout(() => process.exit(0), t).unref();
}
