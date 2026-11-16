'use strict';
// Receive-only Bridge flow. No browser route pays, retries funding, or stores credentials.
(() => {
  const direction = 'toBLAKE2b';
  let rows = [], invoices = [], nodeId = null, selected = null, page = 0, view = '', epoch = 0, generation = -1, busy = false, historyReady = false;
  let health = null, healthStarted = 0, healthPending = false;
  const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
  const node = value => typeof value === 'string' && /^(02|03)[a-f0-9]{64}$/.test(value);
  const msat = value => typeof value === 'string' && /^[1-9][0-9]{0,15}$/.test(value) && BigInt(value) <= 9007199254740991n;
  const whole = value => Number.isSafeInteger(value) && value > 0;
  const context = () => ({wallet:walletContext(),epoch});
  const current = value => value.epoch === epoch && currentWallet(value.wallet) && !!token && !$('wallet').hidden && !PaperclipAccounts.selectedId;
  const active = () => !!token && !$('wallet').hidden && !PaperclipAccounts.selectedId;
  const visible = () => active() && !document.hidden && (view === 'lightning' || view === 'node' || ['bridge','bridge-detail','bridge-activity'].includes(view));
  function sats(value, currency) {
    const amount = BigInt(value), fraction = amount % 1000n;
    return (amount / 1000n).toLocaleString() + (fraction ? '.' + String(fraction).padStart(3,'0').replace(/0+$/,'') : '') + ' ' + currency + ' sats';
  }
  function validate(row) {
    if (!row || row.direction !== direction || !hash(row.hash) || !(node(row.receive_node_id) || (row.receive_node_id === null && row.verified_settlement === false)) || !msat(row.target_msat) || !msat(row.funding_msat) ||
        !whole(row.pay_sat) || BigInt(row.pay_sat) !== (BigInt(row.funding_msat) + 999n) / 1000n || !whole(row.expires_at) || !whole(row.created) ||
        !Number.isFinite(row.rate) || row.rate <= 0 || !Number.isFinite(row.spread) || row.spread < 0 || typeof row.verified_settlement !== 'boolean' ||
        ![row.target_invoice,row.hold_invoice].every(text => typeof text === 'string' && /^lnbc[0-9a-z]+$/.test(text) && text.length <= 2000)) {
      throw new Error('This saved Bridge request could not be verified. Do not pay its invoice.');
    }
    return row;
  }
  function badge() {
    const age = health ? Date.now() - health.at : Infinity;
    const valid = health && age >= 0 && age < 90000;
    const state = valid && health.open === true ? 'live' : valid && health.open === false ? 'paused' : !health && healthPending ? 'checking' : 'unknown';
    const text = {live:'Live',paused:'Paused',checking:'Checking…',unknown:'Status unknown'}[state];
    for (const element of document.querySelectorAll('[data-bridge-health]:not([data-bridge-health="toSHA256"])')) {
      element.textContent = 'Bridge · ' + text; element.dataset.state = state;
      element.title = 'BTC → XBT availability. This does not confirm a payment.';
    }
  }
  async function availability() {
    if (!visible() || healthPending || (Date.now() >= healthStarted && Date.now() - healthStarted < 30000)) return;
    healthPending = true; healthStarted = Date.now(); const saved = context(); badge();
    try {
      const result = await api('bridge/info?direction=' + direction);
      if (current(saved)) health = {at:Date.now(),open:result.direction === direction && typeof result.open === 'boolean' ? result.open : null};
    } catch (_) { if (current(saved)) health = {at:Date.now(),open:null}; }
    finally { if (current(saved)) { healthPending = false; badge(); } }
  }
  function controls() {
    document.querySelectorAll('#bridge-create input,#bridge-create button,#bridge-continue,#bridge-existing,#bridge-reload,#bridge-check').forEach(element => { element.disabled = busy; });
    $('bridge-create').hidden = !nodeId || !historyReady || network !== 'bitcoin';
    $('bridge-connect').hidden = !!nodeId;
    $('bridge-resume').hidden = !invoices.length;
  }
  function clear() {
    epoch++; busy = false; historyReady = false; rows = []; invoices = []; nodeId = null; selected = null; page = 0;
    health = null; healthStarted = 0; healthPending = false;
    $('bridge-create').reset(); $('bridge-status').textContent = ''; $('bridge-node').textContent = '';
    $('bridge-records').replaceChildren(); $('bridge-existing').replaceChildren(); clearShare();
    for (const id of ['bridge-target','bridge-funding','bridge-recipient','bridge-reference','bridge-rate','bridge-result-state','bridge-deadline']) $(id).textContent = '';
    controls(); badge();
  }
  function clearShare() { PaperclipReceive.clear('bridge-invoice'); $('bridge-invoice').textContent = ''; $('bridge-share').hidden = true; }
  function expired(row) { return !row || Date.now() >= (row.expires_at - 5) * 1000; }
  function resultText(row) {
    if (row.verified_settlement) return 'Received · verified by your node';
    if (row.bridge_settled === true) return 'Bridge settled · node receipt still needs verification';
    if (expired(row)) return 'Invoice expired · check status if it was paid';
    if (['funded','paying','paid','settled'].includes(row.state)) return 'Payment in progress · waiting for your node';
    if (['failed','lost'].includes(row.state)) return 'Needs attention · check this request before paying again';
    return 'Waiting for payment';
  }
  function detail() {
    if (!selected) { $('bridge-result-title').textContent = 'Choose a saved request in Activity'; $('bridge-show').hidden = true; $('bridge-check').hidden = true; clearShare(); return; }
    const row = selected;
    $('bridge-result-title').textContent = row.verified_settlement ? 'XBT received' : 'Your conversion';
    $('bridge-target').textContent = sats(row.target_msat,'XBT'); $('bridge-funding').textContent = sats(row.funding_msat,'BTC');
    $('bridge-result-state').textContent = resultText(row);
    $('bridge-deadline').textContent = expired(row) ? 'This invoice is no longer available to pay.' : 'Pay by ' + new Date(row.expires_at * 1000).toLocaleString();
    $('bridge-recipient').textContent = row.receive_node_id; $('bridge-reference').textContent = row.hash;
    $('bridge-rate').textContent = 'Quoted rate: ' + row.rate.toLocaleString() + ' · spread: ' + (row.spread * 100).toLocaleString() + '%';
    const payable = node(row.receive_node_id) && !expired(row) && !row.verified_settlement && ['quoted','offered'].includes(row.state);
    $('bridge-show').hidden = !payable; $('bridge-check').hidden = row.verified_settlement;
    if (!payable) clearShare();
  }
  function history() {
    const count = Math.max(1,Math.ceil(rows.length / 10)); page = Math.min(page,count - 1);
    $('bridge-records').replaceChildren();
    for (const row of rows.slice(page * 10,page * 10 + 10)) {
      const button = document.createElement('button'); button.className = 'menu-row secondary';
      const label = document.createElement('span'), title = document.createElement('strong'), info = document.createElement('small');
      title.textContent = sats(row.target_msat,'XBT'); info.textContent = resultText(row);
      label.append(title,info); const arrow = document.createElement('span'); arrow.textContent = '›'; arrow.setAttribute('aria-hidden','true'); button.append(label,arrow);
      button.onclick = () => { selected = row; clearShare(); PaperclipNavigation.show('bridge-detail'); }; $('bridge-records').append(button);
    }
    if (!rows.length) $('bridge-records').textContent = 'Your saved Bridge receive requests will appear here.';
    $('bridge-paging').hidden = count === 1; $('bridge-prev').disabled = page === 0; $('bridge-next').disabled = page + 1 >= count;
    $('bridge-page').textContent = 'Page ' + (page + 1) + ' of ' + count;
  }
  function remember(row) {
    validate(row); const index = rows.findIndex(item => item.hash === row.hash);
    if (index < 0) rows.unshift(row); else rows[index] = row;
    selected = row; history(); detail();
  }
  async function act(message, action) {
    if (busy || !active()) return;
    busy = true; controls(); const saved = context(); $('bridge-status').textContent = message;
    try { await action(saved); }
    catch (error) { if (current(saved)) $('bridge-status').textContent = error.message; }
    finally { if (current(saved)) { busy = false; controls(); } }
  }
  async function load(saved) {
    historyReady = false;
    const results = await Promise.allSettled([api('bridge/quotes'),api('remote-node/connection')]);
    if (!current(saved)) return;
    const [quotes,connection] = results;
    if (quotes.status === 'fulfilled') {
      if (!Array.isArray(quotes.value.quotes) || quotes.value.quotes.length > 1000) throw new Error('Bridge history unavailable. Check again before creating another request.');
      // Unbound older requests can be checked, but cannot expose a payable
      // invoice until the original receiving node is identified.
      rows = quotes.value.quotes.filter(row => row.direction === direction).map(validate); historyReady = true; history();
      if (selected) { selected = rows.find(row => row.hash === selected.hash) || null; detail(); }
    }
    if (connection.status === 'fulfilled') {
      const value = connection.value; nodeId = value.configured && node(value.node_id) ? value.node_id : null;
      invoices = (Array.isArray(value.payments) ? value.payments : []).filter(row => row.node_id === nodeId && row.receive === true && row.state === 'pending' && hash(row.payment_hash) && msat(row.amount_msat) && typeof row.invoice === 'string');
      $('bridge-existing').replaceChildren();
      for (const row of invoices) { const option = document.createElement('option'); option.value = row.payment_hash; option.textContent = sats(row.amount_msat,'XBT') + ' · ' + row.payment_hash.slice(0,8); $('bridge-existing').append(option); }
    } else { nodeId = null; invoices = []; }
    $('bridge-node').textContent = network !== 'bitcoin' ? 'Bridge receive is available on XBT mainnet.' : nodeId ? 'Receive into your saved Lightning node.' : 'Connect CLN or XBT LND to continue.';
    controls();
    if (quotes.status === 'rejected') throw new Error('Bridge history unavailable. Refresh before creating another request.');
    $('bridge-status').textContent = '';
  }
  async function quote(saved, invoice) {
    const result = await api('bridge/quotes',{direction,invoice:invoice.invoice});
    if (!current(saved)) return;
    validate(result);
    if (result.hash !== invoice.payment_hash || result.receive_node_id !== invoice.node_id || result.target_msat !== invoice.amount_msat || result.target_invoice !== invoice.invoice) throw new Error('The conversion differs from your node request. Do not pay it.');
    remember(result); clearShare();
    if (['bridge','bridge-detail','bridge-activity'].includes(view)) PaperclipNavigation.show('bridge-detail');
    $('bridge-status').textContent = 'Review both amounts, then share the BTC invoice.';
  }
  $('bridge-create').onsubmit = event => {
    event.preventDefault(); void act('Creating a receive request on your node…',async saved => {
      const text = $('bridge-amount').value.trim(), amount = Number(text);
      if (!historyReady || !nodeId || network !== 'bitcoin' || !/^[1-9][0-9]*$/.test(text) || !whole(amount) || amount > 9007199254740) throw new Error('Enter a whole-satoshi XBT amount.');
      const expectedNode = nodeId;
      let info;
      try { info = await api('bridge/info?direction=' + direction); }
      catch (_) { if (current(saved)) { health = {at:Date.now(),open:null}; badge(); } throw new Error('Bridge availability could not be verified. No node invoice was created.'); }
      if (!current(saved)) return;
      health = {at:Date.now(),open:info.direction === direction && typeof info.open === 'boolean' ? info.open : null}; badge();
      if (health.open !== true) throw new Error(health.open === false ? 'The Bridge is paused. Check again later.' : 'Bridge availability could not be verified. No node invoice was created.');
      const invoice = await api('remote-node/request',{operation:'invoice',amount_sat:amount,description:'Paperclip Bridge receive'});
      if (!current(saved)) return;
      if (invoice.node_id !== expectedNode || !hash(invoice.payment_hash) || invoice.amount_msat !== (BigInt(amount) * 1000n).toString() || invoice.receive !== true) throw new Error('The node returned another receive request. Do not pay it.');
      $('bridge-status').textContent = 'Preparing your conversion. You have not sent a payment.';
      try { await quote(saved,invoice); }
      catch (error) { throw new Error(error.message + ' Refresh Activity, or continue this saved node invoice. Do not create a replacement if someone may have paid it.'); }
    });
  };
  $('bridge-continue').onclick = () => void act('Checking the saved receive request…',async saved => {
    const invoice = invoices.find(row => row.payment_hash === $('bridge-existing').value);
    if (!invoice) throw new Error('Choose a saved node invoice.'); await quote(saved,invoice);
  });
  $('bridge-check').onclick = () => void act('Checking your node and the saved Bridge request…',async saved => {
    const prior = selected; if (!prior) return;
    const result = await api('bridge/check',{direction,hash:prior.hash});
    if (!current(saved)) return;
    validate(result);
    if (result.hash !== prior.hash || (prior.receive_node_id !== null && result.receive_node_id !== prior.receive_node_id) || result.target_invoice !== prior.target_invoice || result.hold_invoice !== prior.hold_invoice) throw new Error('Status returned another request. Check your saved history.');
    if (selected?.hash !== prior.hash) return;
    remember(result);
    $('bridge-status').textContent = result.verified_settlement ? 'Payment received and verified by your node.' : result.node_checked === false ? 'Your node could not verify receipt. Reconnect the original node and check again.' : 'Your node has not received this payment yet. Check this request again shortly.';
  });
  $('bridge-show').onclick = () => {
    if (!selected || !node(selected.receive_node_id) || expired(selected) || selected.verified_settlement || !['quoted','offered'].includes(selected.state)) return;
    $('bridge-share').hidden = false; $('bridge-invoice').textContent = selected.hold_invoice;
    PaperclipReceive.show('bridge-invoice',selected.hold_invoice,'Pay with a BTC Lightning wallet',{hint:'Pay this invoice once. Your node receives the quoted XBT amount.'});
  };
  $('bridge-reload').onclick = () => void act('Loading saved requests…',load);
  $('bridge-prev').onclick = () => { page--; history(); }; $('bridge-next').onclick = () => { page++; history(); };
  window.addEventListener('paperclip:view', event => {
    const next = globalThis.PaperclipAccounts?.generation ?? 0;
    if (generation !== next) { clear(); generation = next; }
    view = event.detail;
    if (!['bridge','bridge-detail','bridge-activity'].includes(view)) clearShare();
    $('bridge-home').hidden = view !== 'bridge'; $('bridge-detail').hidden = view !== 'bridge-detail'; $('bridge-activity').hidden = view !== 'bridge-activity';
    $('bridge-back').hidden = view === 'bridge'; $('bridge-back-lightning').hidden = view !== 'bridge';
    if (view === 'bridge-detail') detail();
    if (view === 'bridge' || view === 'bridge-activity') void act('Loading saved requests…',load);
    void availability();
  });
  new MutationObserver(() => { if ($('wallet').hidden) clear(); }).observe($('wallet'),{attributes:true,attributeFilter:['hidden']});
  document.addEventListener('visibilitychange',() => { if (!document.hidden) { badge(); detail(); void availability(); } });
  setInterval(() => { if (visible()) { badge(); void availability(); if (view === 'bridge-detail') detail(); } },1000);
})();
