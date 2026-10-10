import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

const base = process.env.CORE_URL ?? 'http://localhost:4000';
async function api(path, body, token, expected = 200, method = 'POST') {
  const response = await fetch(base + path, {method, headers: {
    'Content-Type': 'application/json', ...(token ? {Authorization: `Bearer ${token}`} : {}),
  }, ...(method === 'GET' ? {} : {body: JSON.stringify(body)})});
  assert.equal(response.status, expected, `unexpected status at ${path}`);
  return {body: await response.json(), headers: response.headers};
}

const device = randomUUID();
const guest = (await api('/api/v1/auth/guest', {device_id: device, command_id: randomUUID()})).body.data;
const token = guest.access_token;
const event = {event_id: randomUUID(), event_name: 'connection_state', schema_version: 1,
  occurred_at: new Date().toISOString(), app_version: '0.1.0', session_id: randomUUID(), properties: {state: 'offline'}};
const batch = {batch_id: randomUUID(), events: [event]};
for (let i = 0; i < 2; i++) {
  const result = (await api('/api/v1/analytics/batches', batch, token)).body.data;
  assert.deepEqual(result.accepted_ids, [event.event_id]);
  assert.deepEqual(result.rejected, []);
}
const invalid = {...event, event_id: randomUUID(), properties: {state: 'offline', clue_text: 'privacy-canary'}};
const partial = (await api('/api/v1/analytics/batches', {batch_id: randomUUID(), events: [event, invalid]}, token)).body.data;
assert.deepEqual(partial.accepted_ids, [event.event_id]);
assert.equal(partial.rejected[0].code, 'INVALID_ARGUMENT');
assert(!JSON.stringify(partial).includes('privacy-canary'));

assert.equal((await api('/api/v1/me/erase', {command_id: randomUUID(), confirmation: 'ERASE_ACCOUNT'}, token)).body.data.erased, true);
await api('/api/v1/me', undefined, token, 401, 'GET');
await api('/api/v1/auth/refresh', {refresh_token: guest.refresh_token, device_id: device, refresh_request_id: randomUUID()}, undefined, 401);

const wrongCode = randomUUID();
for (let i = 0; i < 5; i++) {
  await api('/api/v1/auth/recover', {recovery_code: wrongCode, device_id: randomUUID(), recovery_request_id: randomUUID()}, undefined, 401);
}
const limited = await api('/api/v1/auth/recover', {recovery_code: wrongCode, device_id: randomUUID(), recovery_request_id: randomUUID()}, undefined, 429);
assert(limited.body.error.retry_after_ms > 0 && limited.body.error.retry_after_ms <= 60000);
assert(limited.headers.get('retry-after'));
console.log('PASS: HTTP analytics acknowledgement/deduplication/privacy rejection, erasure and credential revocation, authentication failure budgets and Retry-After.');
