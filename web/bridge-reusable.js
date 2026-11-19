'use strict';
// Management tokens stay in private server storage; no URL or browser persistence.
(() => {
  let rows = [], selected = null, busy = false, ready = false, available = null, epoch = 0, view = '';
  const context = () => ({wallet:walletContext(),epoch});
  const current = c => c.epoch === epoch && currentWallet(c.wallet) && !!token && !$('wallet').hidden && !PaperclipAccounts.selectedId;
  const reference = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
  function validate(row) {
    if (!row || !reference(row.id) || typeof row.revocation_requested !== 'boolean' ||
        (row.binding && (!['toSHA256','toBLAKE2b'].includes(row.binding.direction) || typeof row.binding.revoked !== 'boolean' || !/^lno1[023456789acdefghjklmnpqrstuvwxyz]+$/i.test(row.binding.offer) || row.binding.offer.length > 16384))) throw new Error('Saved offer could not be verified. Keep its management key.');
    return row;
  }
  function controls() { document.querySelectorAll('[data-screen="bridge-reusable"] button,[data-screen="bridge-reusable"] input,[data-screen="bridge-reusable"] textarea,[data-screen="bridge-reusable"] select').forEach(el => { el.disabled = busy || !ready; }); }
  function clearShare() { $('reusable-pay').hidden = true; PaperclipReceive.clear('reusable-offer'); $('reusable-offer').textContent = ''; $('reusable-exported').textContent = ''; $('reusable-private').open = false; }
  function render() {
    clearShare(); $('reusable-home').hidden = !!selected; $('reusable-detail').hidden = !selected;
    $('reusable-records').replaceChildren();
    for (const row of rows.slice().reverse()) {
      const button = document.createElement('button'); button.className = 'menu-row secondary';
      button.textContent = (!row.binding && row.receive_xbt === null ? 'Restore pending' : row.binding?.direction === 'toBLAKE2b' || row.receive_xbt === true ? 'Receive XBT' : 'Receive BTC') + ' · ' + (row.binding?.revoked ? 'Revoked' : row.binding ? 'Reusable offer' : 'Needs status check');
      button.onclick = () => { selected = row; render(); }; $('reusable-records').append(button);
    }
    if (selected) {
      const b = selected.binding, xbt = b ? b.direction === 'toBLAKE2b' : selected.receive_xbt;
      $('reusable-receives').textContent = xbt === null ? 'Not yet verified' : xbt ? 'XBT' : 'Spamcoin (BTC)';
      $('reusable-pays').textContent = xbt === null ? 'Not yet verified' : xbt ? 'Spamcoin (BTC)' : 'XBT';
      $('reusable-state').textContent = b?.revoked ? 'Revoked · in-flight payments can still finish or refund.' : selected.revocation_requested ? 'Revocation not confirmed · sharing disabled.' : !b ? 'Registration not confirmed. Check status or retry this same saved request.' : 'Reusable offer ready. This is not a payment receipt.';
      if (b && !b.revoked && !selected.revocation_requested) PaperclipReceive.show('reusable-offer',b.offer,'Sender pays ' + (xbt ? 'BTC' : 'XBT'),{hint:xbt ? 'Share with a BTC wallet that supports BOLT12.' : 'Pay this XBT offer from Ark or your Lightning node using the normal send screen. Review the requested XBT amount there.'});
      $('reusable-pay').hidden = !b || b.revoked || selected.revocation_requested || xbt;
      $('reusable-retry').hidden = !!b || !selected.destination || selected.revocation_requested;
      $('reusable-revoke').hidden = b?.revoked === true;
    }
    controls();
  }
  async function reload(c) {
    const result = await api('bridge/reusable');
    if (!current(c)) return;
    if (!Array.isArray(result.offers) || result.offers.length > 100) throw new Error('Saved offers could not be loaded.');
    rows = result.offers.map(validate); ready = true;
    if (selected) selected = rows.find(row => row.id === selected.id) || null;
    render();
  }
  async function act(operation) {
    if (busy || !ready || !token) return;
    const c = context(); busy = true; controls(); $('reusable-message').textContent = '';
    try { await operation(c); }
    catch (_) { if (current(c)) $('reusable-message').textContent = 'Request not confirmed. Your saved key and request are preserved. Check status before creating a replacement.'; }
    finally {
      if (current(c)) { try { await reload(c); } catch (_) { ready = false; clearShare(); } busy = false; controls(); }
    }
  }
  async function health() {
    const c = context(); if (view !== 'bridge-reusable' || !current(c) || document.hidden) return;
    try { const result = await api('bridge/reusable/info'); if (current(c)) available = result.available === true ? true : result.available === false ? false : null; }
    catch (_) { if (current(c)) available = null; }
    if (current(c)) { $('reusable-health').textContent = 'Bridge · ' + (available === true ? 'Live' : available === false ? 'Unavailable' : 'Status unknown'); $('reusable-health').dataset.state = available === true ? 'live' : available === false ? 'paused' : 'unknown'; }
  }
  $('reusable-create').onsubmit = event => { event.preventDefault(); void act(async c => {
    if (available !== true) throw new Error('Bridge unavailable');
    const destination = $('reusable-destination').value.trim(), xbt = $('reusable-currency').value === 'XBT';
    if (!/^lno1[023456789acdefghjklmnpqrstuvwxyz]+$/i.test(destination) || destination.length > 16384) throw new Error('Use a BOLT12 offer');
    const confirmed = await PaperclipReview.bridgeOffer({title:'Review reusable bridge offer',action:'Create reusable offer',rows:[['Recipient receives',xbt?'XBT':'Spamcoin (BTC)'],['Sender pays',xbt?'Spamcoin (BTC)':'XBT'],['Receiving offer',destination]],notice:'The receiving wallet must stay reachable. This registers a reusable route; it does not send funds. Each payment uses current conversion rates, fees and limits.'});
    if (!confirmed || !current(c)) return;
    const result = await api('bridge/reusable',{action:'register',destination,receive_xbt:xbt}); if (current(c)) selected = validate(result);
  }); };
  $('reusable-node').onclick = () => void act(async c => {
    const result = await api('remote-node/request',{operation:'offer',description:'Paperclip Bridge'});
    if (current(c)) { $('reusable-destination').value = result.offer; $('reusable-currency').value = 'XBT'; }
  });
  $('reusable-restore').onsubmit = event => { event.preventDefault(); const key = $('reusable-key').value.trim().toLowerCase(); $('reusable-key').value = ''; void act(async c => {
    if (!reference(key) || /^0+$/.test(key)) throw new Error('Invalid key');
    const result = await api('bridge/reusable',{action:'restore',token:key}); if (current(c)) selected = validate(result);
  }); };
  for (const [id,action] of [['reusable-check','lookup'],['reusable-retry','register'],['reusable-revoke','revoke']]) $(id).onclick = () => void act(async c => {
    const row = selected; if (!row) return;
    if (action === 'revoke') {
      const confirmed = await PaperclipReview.bridgeOffer({title:'Stop new payments?',action:'Revoke offer',rows:[['Offer',row.binding?.offer || 'Saved registration']],notice:'In-flight payments can still finish or refund. The receiving wallet’s original offer stays unchanged.'});
      if (!confirmed || !current(c)) return;
      clearShare();
    }
    const result = await api('bridge/reusable',{action,id:row.id}); if (current(c)) selected = validate(result);
  });
  $('reusable-export').onclick = async () => {
    if (busy || !selected || !ready) return;
    const c = context(), id = selected.id; busy = true; controls();
    try { const result = await api('bridge/reusable',{action:'export_key',id}); if (current(c) && selected?.id === id && reference(result.token)) $('reusable-exported').textContent = result.token; }
    catch (_) { if (current(c)) $('reusable-message').textContent = 'Management key could not be loaded.'; }
    finally { if (current(c)) { busy = false; controls(); } }
  };
  window.addEventListener('paperclip:bridge-offer', event => {
    if (view !== 'bridge-reusable' || typeof event.detail !== 'string' || event.detail.length > 16384) return;
    selected = null; $('reusable-destination').value = event.detail; $('reusable-currency').value = 'BTC'; render();
  });
  for (const [id,viewName,field] of [['reusable-pay-node','node-pay','node-destination'],['reusable-pay-ark','transfer','destination']]) $(id).onclick = () => {
    if (busy || !ready || !selected?.binding || selected.binding.revoked || selected.revocation_requested || selected.binding.direction !== 'toSHA256') return;
    const offer = selected.binding.offer;
    PaperclipNavigation.show(viewName);
    $(field).value = offer; $(field).dispatchEvent(new Event('input',{bubbles:true}));
    if (viewName === 'node-pay') $('node-amount').value = '';
    else { $('amount').value = ''; $('ark-max').checked = false; }
  };
  $('reusable-back').onclick = () => { selected = null; render(); };
  function clear() { epoch++; ready = false; busy = false; rows = []; selected = null; available = null; $('reusable-create').reset(); $('reusable-restore').reset(); $('reusable-message').textContent = ''; render(); }
  let generation = -1;
  window.addEventListener('paperclip:view', event => {
    view = event.detail;
    const currentGeneration = walletContext().generation;
    if (generation !== currentGeneration || !token || $('wallet').hidden || PaperclipAccounts.selectedId) { clear(); generation = currentGeneration; }
    if (view === 'bridge-reusable') { const c = context(); void reload(c).catch(() => { if (current(c)) $('reusable-message').textContent = 'Saved offers could not be loaded. Unlock your wallet and try again.'; }); void health(); }
    else { clearShare(); $('reusable-key').value = ''; }
  });
  document.addEventListener('visibilitychange', () => { if (document.hidden) { $('reusable-exported').textContent = ''; $('reusable-key').value = ''; } else void health(); });
  setInterval(() => { if ((!token || $('wallet').hidden || generation !== walletContext().generation) && ready) clear(); },1000);
  setInterval(() => { void health(); },30000);
})();
