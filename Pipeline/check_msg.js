#!/usr/bin/env node
// Part 6 Phase 32: the protocol is only worth having if something enforces it.
// Validates a hand-off message against AI_Agents/schema/agent_message.json plus the rules
// that a JSON Schema cannot express (a "done" must carry reproducible evidence).
const fs = require('fs');
const path = require('path');

const file = process.argv[2];
if (!file) { console.error('用法: check_msg.sh <message.json>'); process.exit(2); }

const root = path.resolve(__dirname, '..');
const schema = JSON.parse(fs.readFileSync(path.join(root, 'AI_Agents/schema/agent_message.json'), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'AI_Agents/manifest.json'), 'utf8'));
const msg = JSON.parse(fs.readFileSync(file, 'utf8'));

const errs = [];
const agents = new Set(['director', ...manifest.roles.map(r => r.name)]);

for (const k of schema.required)
  if (!(k in msg)) errs.push(`缺少必填字段 ${k}`);

if (msg.agent && !agents.has(msg.agent))
  errs.push(`agent "${msg.agent}" 不在 manifest.roles 中`);
for (const [k, list] of Object.entries({ status: schema.properties.status.enum, result: schema.properties.result.enum }))
  if (msg[k] && !list.includes(msg[k])) errs.push(`${k}="${msg[k]}" 非法，允许 ${list.join('|')}`);

const ev = msg.evidence || {};
if (!Array.isArray(ev.files) || ev.files.length === 0) errs.push('evidence.files 不能为空');
if (msg.status === 'done') {
  if (!Array.isArray(ev.commands) || ev.commands.length === 0)
    errs.push('status=done 必须给出至少一条可复现命令 evidence.commands');
  if (!/^\d+\/\d+ (PASS|FAIL)$/.test(ev.assertions || ''))
    errs.push(`status=done 的 evidence.assertions 必须是 "n/m PASS|FAIL"，当前 "${ev.assertions ?? ''}"`);
  if (/^\d+\/\d+ FAIL$/.test(ev.assertions || ''))
    errs.push('status=done 但断言为 FAIL');
  if (ev.assertions) {
    const [a, b] = ev.assertions.split(' ')[0].split('/').map(Number);
    if (a !== b) errs.push(`status=done 但断言 ${a}/${b} 未全通过`);
  }
}
if (msg.result === 'success' && msg.status !== 'done')
  errs.push('result=success 只能配 status=done');

if (errs.length) {
  console.log(`msg: FAIL (${errs.length})`);
  for (const e of errs) console.log(`  - ${e}`);
  process.exit(1);
}
console.log(`msg: PASS  agent=${msg.agent} status=${msg.status} result=${msg.result} ` +
  `assertions=${ev.assertions || 'n/a'}`);
