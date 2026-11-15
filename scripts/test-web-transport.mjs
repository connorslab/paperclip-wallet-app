import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source = readFileSync(new URL('../web/transport.js', import.meta.url), 'utf8');
function client(fetch) {
  const ctx = vm.createContext({fetch, AbortController, setTimeout, clearTimeout});
  vm.runInContext(source, ctx);
  return vm.runInContext('PaperclipTransport', ctx);
}
function response(status, value = {}) { return {status, ok: status === 200, json: async () => value, body: {cancel: async () => {}}}; }
for (const path of ['wallet/identity', 'bitcoin/tip', 'lightning/sends/test-hash']) {
  let calls = 0;
  const c = client(async () => response(++calls === 1 ? 503 : 200, {ready: true}));
  assert.equal((await c.request(path, {token: 'fixture'})).ready, true);
  assert.equal(calls, 2);
}
for (const [path, method, body] of [['lightning/pay','POST',{}], ['lightning/offers','POST',{}], ['lightning/offers','DELETE'], ['wallet/addresses/next','POST',{}], ['wallet/mnemonic','GET'], ['unknown','GET']]) {
  let calls = 0;
  const c = client(async () => { calls++; return response(503); });
  await assert.rejects(c.request(path, {method, body, token: 'fixture'}));
  assert.equal(calls, 1, path);
}
for (const status of [401,403,404,500]) {
  let calls = 0;
  const c = client(async () => { calls++; return response(status); });
  await assert.rejects(c.request('wallet/identity', {token: 'fixture'}));
  assert.equal(calls, 1);
}
let calls = 0;
await assert.rejects(client(async () => { calls++; throw new TypeError('TLS or network failure'); }).request('wallet/identity', {token: 'fixture'}));
assert.equal(calls, 1, 'Browser cannot distinguish TLS failures, so fetch rejections must not retry');
const blocked = client(async (_path, {signal}) => new Promise((_resolve,reject) => {
  if (signal.aborted) reject(new Error('aborted'));
  signal.addEventListener('abort', () => reject(new Error('aborted')), {once:true});
}));
const cancel = new AbortController();
const pending = blocked.request('wallet/identity', {token:'fixture', signal:cancel.signal});
cancel.abort();
await assert.rejects(pending, error => error.kind === 'cancelled');
await assert.rejects(blocked.request('wallet/identity', {token:'fixture', timeoutMs:5}), error => error.kind === 'timeout');
let retryCount = 0;
const unavailable = client(async () => { retryCount++; return response(503); });
await assert.rejects(unavailable.request('wallet/identity', {token:'fixture'}));
assert.equal(retryCount, 2, 'Retry is bounded');
console.log('PASS: bounded observation retries, no mutation/auth/TLS replay, distinct cancellation and deadline');
