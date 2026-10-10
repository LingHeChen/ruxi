import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const base = process.env.API_BASE ?? 'http://localhost:4000';
const codeOutput = execFileSync('mix', ['run', '--no-start', 'priv/repo/admin_code.exs', randomUUID(), 'editor', 'reviewer', 'publisher'], {
  cwd: new URL('../services/core/', import.meta.url), encoding: 'utf8', env: {...process.env, PHX_SERVER: 'false'},
});
const loginCode = codeOutput.match(/minutes\):\s*(\S+)/)?.[1];
assert.ok(loginCode, 'CLI code generated');
let token = '';
async function api(method, path, body, expectedError) {
  const response = await fetch(base + path, {method, headers: {'Content-Type': 'application/json',
    ...(token ? {Authorization: 'Bearer ' + token} : {})}, ...(body ? {body: JSON.stringify(body)} : {})});
  const result = await response.json();
  if (expectedError) { assert.equal(result.error?.code, expectedError); return; }
  assert.ok(response.ok, JSON.stringify(result.error));
  return result.data;
}
const login = await api('POST', '/api/v1/admin/auth/exchange', {
  login_code: loginCode, device_id: randomUUID(), login_request_id: randomUUID(),
});
token = login.access_token;
const story = '11111111-1111-4111-8111-111111111111';
const stories = await api('GET', '/api/v1/admin/stories');
assert.ok(stories.items.some(s => s.story_id === story));
const versions = await api('GET', `/api/v1/admin/stories/${story}/versions`);
assert.ok(versions.items.length > 0);
const draft = await api('POST', `/api/v1/admin/stories/${story}/versions`, {
  base_version_id: '11111111-1111-4111-8111-333333333333', command_id: randomUUID(),
});
const version = await api('GET', `/api/v1/admin/versions/${draft.version_id}`);
const validation = await api('POST', `/api/v1/admin/versions/${draft.version_id}/validate`, {revision: 1, command_id: randomUUID()});
const report = await api('GET', `/api/v1/admin/jobs/${validation.job_id}`);
assert.equal(report.valid, true);
assert.deepEqual(report.reachable_endings, ['E1','E2','E3']);
const previewRequest = {revision: 1, command_id: randomUUID()};
let preview = await api('POST', `/api/v1/admin/versions/${draft.version_id}/preview`, previewRequest);
assert.deepEqual(await api('POST', `/api/v1/admin/versions/${draft.version_id}/preview`, previewRequest), preview);
async function step(role, type, payload={}, extra={}) {
  preview = await api('POST', '/api/v1/admin/previews/step', {
    preview_token: preview.preview_token, actor_role: role, type, payload, command_id: randomUUID(), ...extra,
  });
}
const roles = ['investigator','passenger','conductor'];
for (const role of roles) await step(role, 'media_complete', {media_id: 'opening', media_epoch: 1, mode: 'summary'});
for (const role of roles) await step(role, 'media_complete', {media_id: 'role_'+role, media_epoch: 1, mode: 'summary'});
const before = JSON.stringify(preview.views.passenger);
await step('investigator','investigate',{action_id: 'inspect_monitor'});
assert.equal(JSON.stringify(preview.views.passenger), before);
assert.deepEqual(preview.history.at(-1).changed_fields.passenger, []);
await step('investigator','share_clue',{clue_id:'C1'});
await step('passenger','investigate',{action_id:'inspect_phone'});
await step('passenger','offer_item',{item_id:'C2',to_member:preview.views.conductor.self.membership_id},{target_version:1});
await step('conductor','accept_offer',{offer_id:preview.result.offer_id});
await step('conductor','investigate',{action_id:'open_cabinet'});
await step('conductor','share_clue',{clue_id:'C3'});
await step('conductor','request_hint',{hint_level:1});
assert.equal(preview.views.conductor.hints.entries.length,1);
await step('investigator','advance_time',{delta_ms:180000});
for (const role of roles) await step(role,'media_complete',{media_id:'interlude',media_epoch:1,mode:'summary'});
for (const role of roles.slice(0,2)) await step(role,'vote',{round_id:preview.views[role].vote_round.round_id,option_id:'publish'});
await step('investigator','advance_time',{delta_ms:45000});
assert.equal(preview.views.conductor.room.ending_code,'E1');
await api('PUT', `/api/v1/admin/versions/${draft.version_id}`, {revision:1,graph:{...version.graph,title:'末班车的第七位乘客 · 制作预览验证'}});
await api('POST','/api/v1/admin/previews/step', {preview_token:preview.preview_token, actor_role:'investigator', type:'advance_time',payload:{delta_ms:1},command_id:randomUUID()},'REVISION_CONFLICT');
await api('POST','/api/v1/admin/auth/logout',{});
console.log('PASS: controlled admin CLI login, catalog, version draft, compiler, private multi-role preview, transfer, hint, E1, idempotency and revision invalidation. No live rooms or publication modified.');
