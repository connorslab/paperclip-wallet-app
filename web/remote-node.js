'use strict';
// The browser never persists node credentials or resubmits an uncertain send.
(() => {
  let saved = null, records = [], revision = 0, busy = false, loading = false, walletGeneration = -1;
  const hash = value => typeof value === 'string' && /^[0-9a-f]{64}$/i.test(value);
  const integer = value => typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value);
  function satsText(msat) {
    if (!integer(msat)) throw new Error('The node returned an invalid amount.');
    const value = BigInt(msat), whole = value / 1000n, fraction = value % 1000n;
    return whole.toLocaleString() + (fraction ? '.' + String(fraction).padStart(3, '0').replace(/0+$/, '') : '') + ' sats';
  }
  function amount(id, optional = false, zero = false) {
    const text = $(id).value.trim(); if (!text && optional) return null;
    const value = Number(text);
    if (!/^\d+$/.test(text) || !Number.isSafeInteger(value) || value < (zero ? 0 : 1)) throw new Error('Enter a whole-satoshi amount.');
    return value;
  }
  function snapshot() { return {wallet:walletContext(), revision, node:saved?.node_id}; }
  function current(context) { return currentWallet(context.wallet) && context.revision === revision && context.node === saved?.node_id && !!token && !$('wallet').hidden; }
  function changed() { revision++; PaperclipReview.cancel(); }
  for (const id of ['node-connect', 'node-pay']) $(id).addEventListener('input', changed);
  function clear() {
    changed(); saved = null; records = []; busy = false; loading = false;
    $('node-connect').reset(); $('node-pay').reset(); $('node-receive').reset(); $('node-credential').required = true; $('node-credential').placeholder = '';
    $('node-credential').value = ''; $('node-content').hidden = true; $('node-setup').open = true;
    $('node-title').textContent = 'Your Lightning node'; $('node-status').textContent = 'Connect your node to get started.';
    PaperclipReceive.clear('node-request'); $('node-request').textContent = ''; $('node-copy').hidden = true; $('node-payments').replaceChildren();
    $('node-balance').textContent = 'Not checked'; $('node-balance-detail').textContent = '';
    document.querySelectorAll('[data-screen=node] button').forEach(button => { button.disabled = false; });
  }
  function connection(value) {
    if (!['cln', 'lnd'].includes(value.implementation) || !/^(02|03)[a-f0-9]{64}$/i.test(value.node_id || '')) throw new Error('The server returned an invalid node identity.');
    saved = value;
    $('node-kind').value = value.implementation; $('node-kind').dispatchEvent(new Event('change'));
    $('node-endpoint').value = value.endpoint; $('node-pins').value = value.certificate_sha256 || '';
    $('node-tor').checked = value.use_tor === true; $('node-receive-only').checked = value.receive_only === true;
    $('node-credential').value = ''; $('node-credential').required = false; $('node-credential').placeholder = 'Saved securely · enter to replace'; $('node-content').hidden = false; $('node-setup').open = false;
    $('node-open-pay').hidden = saved.receive_only === true;
    $('node-title').textContent = value.alias || (value.implementation === 'cln' ? 'Core Lightning' : 'XBT LND');
  }
  function updateControls() {
    document.querySelectorAll('#node-connect button,#node-pay button,#node-receive button,#node-refresh').forEach(button => { button.disabled = busy || loading; });
  }
  async function act(button, message, operation) {
    if (busy || loading || !token) return;
    busy = true; updateControls(); button.disabled = true; const context = snapshot(); $('node-status').textContent = message;
    try { await operation(context); }
    catch (error) { if (current(context)) $('node-status').textContent = error.message; }
    finally { if (currentWallet(context.wallet)) { busy = false; updateControls(); button.disabled = false; } }
  }
  function showRecord(record) {
    if (!hash(record.payment_hash) || record.node_id !== saved?.node_id || !integer(record.amount_msat) || typeof record.receive !== 'boolean') throw new Error('Invalid saved node payment.');
    const index = records.findIndex(row => row.payment_hash === record.payment_hash && row.receive === record.receive);
    if (index < 0) records.unshift(record); else records[index] = record;
    renderRecords();
  }
  function renderRecords() {
    $('node-payments').replaceChildren();
    const pending = records.filter(row => !row.receive && !['succeeded','failed'].includes(row.state)).length;
    $('node-pending-summary').textContent = pending ? pending + ' payment' + (pending === 1 ? '' : 's') + ' need checking. Open Payment activity before another send.' : '';
    if (!records.length) { $('node-payments').textContent = 'Your node payment requests and sends will appear here.'; return; }
    for (const record of records) {
      const card = document.createElement('div'); card.className = 'node-payment';
      const title = document.createElement('strong'); title.textContent = (record.receive ? 'Receive · ' : 'Send · ') + satsText(record.amount_msat);
      const state = document.createElement('p');
      const names = {succeeded:record.receive ? 'Received' : 'Payment succeeded',failed:'Payment failed',expired:'Request expired',pending:'Pending · check for an update',unknown:'Outcome unknown · check before another send'};
      state.textContent = names[record.state] || names.unknown; card.append(title, state);
      const details = document.createElement('details'), summary = document.createElement('summary'), reference = document.createElement('output');
      summary.textContent = 'Payment reference'; reference.textContent = record.payment_hash; details.append(summary, reference); card.append(details);
      if (!['succeeded', 'failed', 'expired'].includes(record.state)) {
        const check = document.createElement('button'); check.className = 'secondary'; check.textContent = 'Check status';
        check.onclick = () => act(check, 'Checking the saved payment…', async context => {
          const result = await api('remote-node/request', {operation:'status',payment_hash:record.payment_hash,receive:record.receive});
          if (!current(context)) return; showRecord(result); $('node-status').textContent = result.state === 'succeeded' ? (result.receive ? 'Payment received by your node.' : 'Your node confirms the payment succeeded.') : 'Status checked. Pending or unknown payments will not be resent.';
        }); card.append(check);
      }
      if (record.receive && record.invoice) {
        const copy = document.createElement('button'); copy.className = 'secondary'; copy.textContent = 'Copy invoice';
        copy.onclick = () => act(copy, '', async context => { await navigator.clipboard.writeText(record.invoice); if (current(context)) $('node-status').textContent = 'Invoice copied.'; }); card.append(copy);
      }
      $('node-payments').append(card);
    }
  }
  async function load() {
    if (busy || loading || !token) return;
    loading = true; updateControls(); const context = snapshot();
    try {
      const value = await api('remote-node/connection'); if (!current(context)) return;
      if (!value.configured) { $('node-status').textContent = 'Connect CLN or XBT LND to use your channels.'; return; }
      connection(value); records = [];
      for (const record of value.payments || []) showRecord(record);
      renderRecords();
      $('node-status').textContent = 'Saved connection loaded. Refresh to check the node.';
      if (value.offer) { $('node-request').textContent = value.offer; PaperclipReceive.show('node-request', value.offer, 'Receive into your Lightning node'); $('node-copy').hidden = true; }
    } catch (error) { if (current(context)) $('node-status').textContent = error.message; }
    finally { if (currentWallet(context.wallet)) { loading = false; updateControls(); } }
  }
  $('node-kind').onchange = () => { $('node-credential-label').firstChild.textContent = $('node-kind').value === 'cln' ? 'Access rune' : 'Macaroon (hex)'; };
  $('node-connect').onsubmit = event => {
    event.preventDefault(); const button = event.submitter;
    act(button, $('node-tor').checked ? 'Connecting through Tor and verifying your node…' : 'Verifying your node’s secure connection…', async context => {
      const config = {implementation:$('node-kind').value,endpoint:$('node-endpoint').value.trim(),credential:$('node-credential').value.trim(),certificate_sha256:$('node-pins').value.trim(),use_tor:$('node-tor').checked,receive_only:$('node-receive-only').checked};
      let result;
      try { result = await api('remote-node/request', {operation:'connect',connection:config}); }
      finally { config.credential = ''; if (currentWallet(context.wallet)) $('node-credential').value = ''; }
      if (!current(context)) return;
      connection(result); records = []; renderRecords(); revision++;
      $('node-balance').textContent = 'Not checked'; $('node-balance-detail').textContent = '';
      $('node-status').textContent = 'Connection verified and saved. Refresh to load your channel balance.';
    });
  };
  $('node-refresh').onclick = event => act(event.target, 'Checking your node and active channels…', async context => {
    $('node-balance').textContent = 'Checking…'; $('node-balance-detail').textContent = '';
    try {
      const result = await api('remote-node/request', {operation:'refresh'}); if (!current(context)) return;
      if (result.node_id !== saved.node_id || !Number.isSafeInteger(result.balance?.active_channels)) throw new Error('Node identity or channel response changed.');
      const balance = result.balance;
      const sendable = satsText(balance.sendable_msat), receivable = satsText(balance.receivable_msat);
      const local = balance.local_msat == null ? '' : ' · Funds in active channels: ' + satsText(balance.local_msat);
      $('node-title').textContent = result.alias || $('node-title').textContent; $('node-balance').textContent = sendable;
      $('node-balance-detail').textContent = balance.active_channels + ' active channels · Receive capacity: ' + receivable + local + '. Channel reserves are excluded from available-to-send funds.';
      $('node-status').textContent = 'Connected · checked just now';
    } catch (error) { if (current(context)) $('node-balance').textContent = 'Unavailable'; throw error; }
  });
  $('node-pay').onsubmit = event => {
    event.preventDefault(); act(event.submitter, 'Checking the request and preparing your review…', async context => {
      if (!saved || saved.receive_only) throw new Error('This connection is receive only.');
      const destination = $('node-destination').value.trim(), fee = amount('node-fee', false, true), entered = amount('node-amount', true);
      const review = await api('remote-node/request', {operation:'prepare',destination,maximum_fee_sat:fee,amount_sat:entered});
      if (!current(context)) return;
      if (!hash(review.request_id) || !hash(review.payment_hash) || review.node_id !== saved.node_id || review.maximum_fee_sat !== fee || fee > 1000000 || !integer(review.amount_msat) || !integer(review.maximum_total_msat) || BigInt(review.amount_msat) <= 0n || BigInt(review.maximum_total_msat) !== BigInt(review.amount_msat) + BigInt(fee) * 1000n || (entered !== null && BigInt(review.amount_msat) !== BigInt(entered) * 1000n)) throw new Error('Invalid payment review. Nothing was sent.');
      const approved = await PaperclipReview.ask('Pay from ' + $('node-title').textContent + '\n\nRecipient receives: ' + satsText(review.amount_msat) + '\nMaximum routing fee: ' + fee.toLocaleString() + ' sats\nMaximum total: ' + satsText(review.maximum_total_msat) + '\n\nPayment hash: ' + review.payment_hash);
      if (!approved || !current(context)) { if (current(context)) $('node-status').textContent = 'Payment cancelled. Nothing was sent.'; return; }
      $('node-status').textContent = 'Submitting once. Keep this page open while the node responds…';
      try {
        const result = await api('remote-node/request', {operation:'pay',request_id:review.request_id,payment_hash:review.payment_hash,maximum_fee_sat:fee});
        if (!current(context)) return;
        if (result.payment_hash !== review.payment_hash || result.receive !== false || result.amount_msat !== review.amount_msat) throw new Error('Payment response did not match the review.');
        showRecord(result);
        PaperclipNavigation.show('node-activity');
        $('node-status').textContent = result.state === 'succeeded' ? 'Payment succeeded.' : 'Payment recorded. Check its status below before another send.';
        if (result.state === 'succeeded') transactionResult('success','Payment succeeded','Your node confirms this payment completed.',result.payment_hash);
      } catch (_) {
        if (current(context)) {
          showRecord({node_id:saved.node_id,payment_hash:review.payment_hash,amount_msat:review.amount_msat,receive:false,state:'unknown'});
          PaperclipNavigation.show('node-activity');
          $('node-status').textContent = 'The result is uncertain. Check the saved payment below; do not send it again.';
        }
      }
    });
  };
  $('node-request-kind').onchange = () => { $('node-receive-amount').required = $('node-request-kind').value === 'invoice'; };
  $('node-receive').onsubmit = event => {
    event.preventDefault(); act(event.submitter, 'Creating your payment request…', async context => {
      const operation = $('node-request-kind').value;
      const result = await api('remote-node/request', {operation,amount_sat:amount('node-receive-amount',operation === 'offer'),description:$('node-description').value.trim()});
      if (!current(context)) return;
      const text = operation === 'offer' ? result.offer : result.invoice;
      if (typeof text !== 'string' || text.length > 256 * 1024) throw new Error('The node returned an invalid payment request.');
      if (operation === 'invoice') showRecord(result);
      $('node-request').textContent = text; PaperclipReceive.show('node-request', text, 'Receive into your Lightning node'); $('node-copy').hidden = true;
      $('node-status').textContent = operation === 'offer' ? 'Reusable offer ready. Keep your node online to receive payments.' : 'Invoice ready. Share it, then check its status below.';
    });
  };
  $('node-copy').onclick = event => act(event.target, '', async context => { await navigator.clipboard.writeText($('node-request').textContent); if (current(context)) $('node-status').textContent = 'Payment request copied.'; });
  const reloadWallet = $('reload').onclick;
  $('reload').onclick = event => {
    if (!document.querySelector('[data-screen=node]').hidden) { if (saved) $('node-refresh').click(); else load(); }
    else reloadWallet(event);
  };
  window.addEventListener('paperclip:view', event => {
    const generation = globalThis.PaperclipAccounts?.generation ?? 0;
    if (walletGeneration !== generation) { clear(); walletGeneration = generation; }
    const view = event.detail;
    if (view.startsWith('node')) {
      const home = view === 'node';
      $('node-back-lightning').hidden = !home; $('node-back').hidden = home;
      $('node-setup').hidden = !home; $('node-overview').hidden = !home;
      for (const [id, screen] of [['node-send-panel','node-pay'],['node-receive-panel','node-receive'],['node-activity-panel','node-activity']]) {
        $(id).hidden = view !== screen; $(id).classList.toggle('node-page-enter', view === screen);
      }
      if (home || !saved) load();
    }
  });
  new MutationObserver(() => { if ($('wallet').hidden) clear(); }).observe($('wallet'), {attributes:true,attributeFilter:['hidden']});
})();
