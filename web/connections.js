'use strict';
// Connection checks are read-only. They never switch a funded wallet's backend.
let connectionCheck = null;
async function checkConnections() {
  connectionCheck?.abort();
  const controller = new AbortController();
  connectionCheck = controller;
  const session = token;
  $('connections-cancel').hidden = false;
  const targets = [
    ['connection-wallet', 'wallet/identity', () => 'Wallet service reachable'],
    ['connection-node', 'bitcoin/tip', result => Number.isSafeInteger(result?.tip_height) ? 'Node responding · block ' + result.tip_height.toLocaleString() : 'Node response unavailable'],
    ['connection-asp', 'wallet/next-round', () => 'Ark server reachable']
  ];
  try {
    await Promise.all(targets.map(async ([id, path, describe]) => {
      $(id).textContent = 'Checking…';
      try {
        const result = await api(path, undefined, 'GET', controller.signal);
        if (token === session && token && connectionCheck === controller) $(id).textContent = describe(result);
      } catch (error) {
        if (token === session && token && connectionCheck === controller) {
          $(id).textContent = error.kind === 'cancelled' ? 'Check cancelled. Retry when ready.'
            : error.kind === 'timeout' ? 'Timed out. Check this service and retry.'
            : error.message || 'Connection unavailable. Retry when ready.';
        }
      }
    }));
  } finally {
    if (connectionCheck === controller) {
      connectionCheck = null;
      $('connections-cancel').hidden = true;
    }
  }
}
$('connections-check').onclick = event => run(event.target, checkConnections);
$('connections-cancel').onclick = () => connectionCheck?.abort();
$('settings-lock').onclick = () => $('lock').click();
new MutationObserver(() => {
  if (!$('wallet').hidden) return;
  connectionCheck?.abort();
  for (const id of ['connection-wallet', 'connection-node', 'connection-asp']) $(id).textContent = 'Not checked';
}).observe($('wallet'), {attributes: true, attributeFilter: ['hidden']});
