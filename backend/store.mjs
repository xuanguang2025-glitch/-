// Filesystem-backed store for the SOW backend.
//
// SWAP POINT (documented rather than abstracted away): every method here is the seam where
// Postgres/S3 would go. It is a directory of JSON + JSONL on purpose - at zero players a
// database adds an operational dependency without adding a single guarantee. The guarantees
// that matter (append-only ledger, save generation rotation, integrity hashes) are all
// implemented here and would carry over unchanged.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync,
  readdirSync, renameSync } from 'node:fs';
import { join } from 'node:path';

const sha = (s) => createHash('sha256').update(s).digest('hex');

function readJson(p, fallback) {
  if (!existsSync(p)) return fallback;
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return fallback; }
}
function writeJsonAtomic(p, obj) {
  const tmp = p + '.tmp';
  writeFileSync(tmp, JSON.stringify(obj));
  renameSync(tmp, p);
}

export class Store {
  constructor(root) {
    this.root = root;
    for (const d of ['', 'accounts', 'sessions', 'refresh', 'saves', 'ledger', 'ugc'])
      mkdirSync(join(root, d), { recursive: true });
  }

  // --- accounts ---
  account(id) { return readJson(join(this.root, 'accounts', `${id}.json`), null); }
  putAccount(a) { writeJsonAtomic(join(this.root, 'accounts', `${a.player_id}.json`), a); }
  accountByName(name) {
    for (const f of readdirSync(join(this.root, 'accounts'))) {
      const a = readJson(join(this.root, 'accounts', f), null);
      if (a && a.display_name === name) return a;
    }
    return null;
  }

  // --- tokens (only hashes are stored; a leaked table cannot be replayed) ---
  putSession(h, v) { writeJsonAtomic(join(this.root, 'sessions', `${h}.json`), v); }
  getSession(h) { return readJson(join(this.root, 'sessions', `${h}.json`), null); }
  delSession(h) { const p = join(this.root, 'sessions', `${h}.json`);
    if (existsSync(p)) writeFileSync(p, 'null'); }
  putRefresh(h, v) { writeJsonAtomic(join(this.root, 'refresh', `${h}.json`), v); }
  getRefresh(h) { const v = readJson(join(this.root, 'refresh', `${h}.json`), null); return v ?? null; }
  delRefresh(h) { const p = join(this.root, 'refresh', `${h}.json`);
    if (existsSync(p)) writeFileSync(p, 'null'); }

  // --- saves: three generations, verified on read (Phase 48.3) ---
  savePath(id, gen) { return join(this.root, 'saves', `${id}.${gen}.json`); }
  writeSave(id, rec) {
    const out = { ...rec, written_at: new Date().toISOString(),
      sha256: sha(JSON.stringify(rec.payload)) };
    for (const [from, to] of [[2, 3], [1, 2]]) {
      if (existsSync(this.savePath(id, from)))
        renameSync(this.savePath(id, from), this.savePath(id, to));
    }
    writeJsonAtomic(this.savePath(id, 1), out);
    return out;
  }
  readSave(id) {
    const p = this.savePath(id, 1);
    if (!existsSync(p)) return null;
    const r = readJson(p, null);
    if (!r) return { ok: false, reason: 'unreadable' };
    if (sha(JSON.stringify(r.payload)) !== r.sha256)
      return { ok: false, reason: 'checksum mismatch' };
    return { ...r, ok: true };
  }
  saveGenerations(id) {
    return [1, 2, 3].filter(g => existsSync(this.savePath(id, g)))
      .map(g => ({ generation: g, written_at: readJson(this.savePath(id, g), {})?.written_at }));
  }
  // Rollback promotes generation 2 over the damaged 1, keeping a copy so it is recoverable.
  rollback(id) {
    const prev = readJson(this.savePath(id, 2), null);
    if (!prev) return null;
    const cur = this.savePath(id, 1);
    if (existsSync(cur)) renameSync(cur, this.savePath(id, 3));
    writeJsonAtomic(cur, prev);
    return prev;
  }

  // --- ledger: append-only, balance is a fold, never a stored field (Phase 58) ---
  ledgerPath(id) { return join(this.root, 'ledger', `${id}.jsonl`); }
  txs(id) {
    if (!existsSync(this.ledgerPath(id))) return [];
    return readFileSync(this.ledgerPath(id), 'utf8').split('\n').filter(Boolean)
      .map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  }
  balance(id) { return this.txs(id).reduce((a, t) => a + t.amount, 0); }
  findTx(id, key) { return this.txs(id).find(t => t.idempotency_key === key) ?? null; }
  tx(id, { type, amount, ref, idempotency_key }) {
    const t = { transaction_id: 't_' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8),
      player_id: id, type, amount, ref: ref ?? null, idempotency_key: idempotency_key ?? null,
      timestamp: new Date().toISOString(), status: 'SUCCESS' };
    appendFileSync(this.ledgerPath(id), JSON.stringify(t) + '\n');
    return t;
  }

  // --- UGC registry ---
  ugcPath(cid) { return join(this.root, 'ugc', `${cid}.json`); }
  ugcPut(rec, files) {
    const out = { ...rec, files: files ?? readJson(this.ugcPath(rec.content_id), {})?.files ?? [] };
    writeJsonAtomic(this.ugcPath(rec.content_id), out);
    return out;
  }
  ugcGet(cid) { return /^[a-zA-Z0-9_]+$/.test(String(cid)) ? readJson(this.ugcPath(cid), null) : null; }
  ugcList() { return readdirSync(join(this.root, 'ugc')).map(f => readJson(join(this.root, 'ugc', f), null)).filter(Boolean); }
  ugcByContentId(cid) { return this.ugcGet(cid); }
}
