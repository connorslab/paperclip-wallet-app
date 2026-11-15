'use strict';
// Observation requests only. Address generation, signing and mutations never retry.
const PaperclipTransport = (() => {
  const reads = new Set(['wallet', 'wallet/identity', 'wallet/balance', 'wallet/vtxos',
    'wallet/connected', 'wallet/next-round', 'wallet/platform-node', 'onchain/balance',
    'onchain/transactions', 'bitcoin/tip', 'exits/status/all', 'history', 'lightning/receives', 'lightning/offers']);
  function canRetry(path, method) {
    return method === 'GET' && (reads.has(path) || /^lightning\/(sends|receives)\/[^/]+$/.test(path));
  }
  function failure(kind, message) { return Object.assign(new Error(message), {kind}); }
  async function request(path, {body, method = body === undefined ? 'GET' : 'POST', token, signal, timeoutMs = body === undefined ? 10000 : 60000}) {
    const controller = new AbortController();
    let timedOut = false;
    const abort = () => controller.abort();
    if (signal?.aborted) abort();
    signal?.addEventListener('abort', abort, {once: true});
    const timer = setTimeout(() => { timedOut = true; abort(); }, timeoutMs);
    try {
      for (let attempt = 0; attempt < 2; attempt++) {
        if (controller.signal.aborted) throw failure('cancelled', 'Request cancelled.');
        const response = await fetch(path.startsWith('/') ? path : '/api/v1/' + path, {
          signal: controller.signal, method, cache: 'no-store', redirect: 'error',
          headers: {Authorization: 'Bearer ' + token, 'Content-Type': 'application/json'},
          ...(body === undefined ? {} : {body: JSON.stringify(body)})
        });
        if (attempt === 0 && canRetry(path, method) && [502, 503, 504].includes(response.status)) {
          // The same deadline covers both attempts. Browser TLS/network failures
          // are indistinguishable, so a rejected fetch is never automatically retried.
          await response.body?.cancel();
          continue;
        }
        if (!response.ok) {
          if (response.status === 401) throw failure('authentication', 'Access denied. Check the login instructions and the credential provided by your wallet app.');
          if (response.status === 403) throw failure('permission', 'This wallet credential does not permit the requested action.');
          let message = '';
          try { const detail = await response.json(); message = typeof detail.message === 'string' ? detail.message.slice(0, 900) : ''; } catch {}
          throw failure('server', message || 'Wallet request failed (' + response.status + '). Check wallet access and local services.');
        }
        return response.status === 204 ? null : await response.json();
      }
    } catch (error) {
      if (controller.signal.aborted) {
        throw failure(timedOut ? 'timeout' : 'cancelled', timedOut
          ? 'The wallet request timed out. Check connections in Settings.' : 'Request cancelled.');
      }
      throw error;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
    }
  }
  return {request};
})();
