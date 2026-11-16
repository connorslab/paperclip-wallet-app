'use strict';
// The node journal owns submission. Browser retries only read saved status.
(() => {
  const direction = 'toSHA256';
  let rows = [], selected = null, nodeId = null, canSend = false, ready = false, busy = false, page = 0, view = '', epoch = 0, approval = 0, generation = -1;
  let health = null, healthStarted = 0, healthPending = false;
  const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
  const node = value => typeof value === 'string' && /^(02|03)[a-f0-9]{64}$/.test(value);
  const msat = value => typeof value === 'string' && /^[1-9][0-9]{0,15}$/.test(value) && BigInt(value) <= 9007199254740991n;
  const whole = value => Number.isSafeInteger(value) && value > 0;
  const active = () => !!token && !$('wallet').hidden && !PaperclipAccounts.selectedId;
  const context = () => ({wallet:walletContext(),epoch,approval});
  const current = saved => active() && saved.epoch === epoch && currentWallet(saved.wallet);
  const reviewCurrent = saved => current(saved) && saved.approval === approval && !document.hidden && view === 'bridge-send-detail';
  const visible = () => active() && !document.hidden && (['lightning','node'].includes(view) || view.startsWith('bridge-send'));
  const expired = row => Date.now() >= (row.expires_at - 5) * 1000;
  function invalidate() { approval++; PaperclipReview.cancel(); }
  function sats(value, currency = 'XBT') {
    const amount = BigInt(value), fraction = amount % 1000n;
    return (amount / 1000n).toLocaleString() + (fraction ? '.' + String(fraction).padStart(3,'0').replace(/0+$/,'') : '') + ' ' + currency + ' sats';
  }
  const arkReady = () => lightningEnabled && lightningDebitLimit;
  const source = () => $('bridge-pay-method').value;
  function validFunding(value) {
    if (value == null) return true;
    if (!['not_submitted','unknown','pending','succeeded','failed','recovery'].includes(value.state)) return false;
    if (value.source === 'ark') return whole(value.maximum_total_sat) && value.maximum_total_sat <= 2100000000000000;
    return (value.source == null || value.source === 'node') && node(value.node_id) && Number.isSafeInteger(value.maximum_fee_sat) && value.maximum_fee_sat >= 0 && value.maximum_fee_sat <= 1000000;
  }
  function validate(row) {
    if (!row || row.direction !== direction || !hash(row.hash) || !msat(row.target_msat) || !msat(row.funding_msat) ||
        !whole(row.pay_sat) || BigInt(row.pay_sat) !== (BigInt(row.funding_msat) + 999n) / 1000n || !whole(row.expires_at) || !whole(row.created) ||
        !Number.isFinite(row.rate) || row.rate <= 0 || !Number.isFinite(row.spread) || row.spread < 0 || typeof row.verified_settlement !== 'boolean' ||
        ![row.target_invoice,row.hold_invoice].every(text => typeof text === 'string' && /^lnbc[0-9a-z]+$/.test(text) && text.length <= 2000) ||
        (!validFunding(row.funding) || (row.funding?.source === 'ark' && row.funding.maximum_total_sat < row.pay_sat))) {
      throw new Error('This conversion could not be verified. Check its saved status before sending.');
    }
    return row;
  }
  function badge() {
    const age = health ? Date.now() - health.at : Infinity;
    const valid = health && age >= 0 && age < 90000;
    const state = valid && health.open === true ? 'live' : valid && health.open === false ? 'paused' : !health && healthPending ? 'checking' : 'unknown';
    for (const element of document.querySelectorAll('[data-bridge-health="toSHA256"]')) {
      element.dataset.state = state; element.textContent = 'Bridge · ' + {live:'Live',paused:'Paused',checking:'Checking…',unknown:'Status unknown'}[state];
      element.title = 'XBT → BTC availability. This does not confirm a payment.';
    }
  }
  async function availability() {
    if (!visible() || healthPending || (Date.now() >= healthStarted && Date.now() - healthStarted < 30000)) return;
    healthStarted = Date.now(); healthPending = true; const saved = context(); badge();
    try { const result = await api('bridge/info?direction=' + direction); if (current(saved)) health = {at:Date.now(),open:result.direction === direction && typeof result.open === 'boolean' ? result.open : null}; }
    catch (_) { if (current(saved)) health = {at:Date.now(),open:null}; }
    finally { if (current(saved)) { healthPending = false; badge(); } }
  }
  function fundable(row) { return row && ready && (canSend || arkReady()) && !row.verified_settlement && ['quoted','offered'].includes(row.state) && !expired(row) && (!row.funding || row.funding.state === 'not_submitted'); }
  function resultText(row) {
    if (row.verified_settlement) return 'BTC payment settled · verified by the Bridge';
    if (row.funding && row.funding.state !== 'not_submitted') {
      if (row.funding.state === 'succeeded') return (row.funding.source === 'ark' ? 'Ark funded' : 'Node funded') + ' · BTC settlement still needs verification';
      if (row.funding.state === 'recovery') return 'Ark funding needs recovery · check wallet recovery before another payment';
      if (row.funding.state === 'failed') return 'Node funding failed · check the conversion before making another payment';
      return 'Funding result pending · check status; do not send again';
    }
    if (expired(row)) return 'Quote expired · check status if it was funded';
    if (!['quoted','offered'].includes(row.state)) return 'Conversion needs a status check before another payment';
    return 'Ready to review · no funding submitted';
  }
  function controls() {
    document.querySelectorAll('#bridge-pay-create input,#bridge-pay-create textarea,#bridge-pay-create button,#bridge-pay-approve input,#bridge-pay-approve select,#bridge-pay-approve button,#bridge-pay-check,#bridge-pay-reload').forEach(element => { element.disabled = busy; });
    $('bridge-pay-create').hidden = !ready || (!canSend && !arkReady()) || network !== 'bitcoin';
    $('bridge-pay-connect').hidden = !!nodeId;
    $('bridge-pay-approve').hidden = !fundable(selected);
    $('bridge-pay-method').querySelector('[value=node]').disabled = !canSend;
    $('bridge-pay-method').querySelector('[value=ark]').disabled = !arkReady();
    $('bridge-pay-fee-label').hidden = source() === 'ark';
    $('bridge-pay-fee').required = source() !== 'ark';
  }
  function detail() {
    if (!selected) { $('bridge-pay-title').textContent = 'Choose a saved conversion in Activity'; $('bridge-pay-approve').hidden = true; $('bridge-pay-check').hidden = true; return; }
    const row = selected;
    $('bridge-pay-title').textContent = row.verified_settlement ? 'BTC payment settled' : 'Your conversion';
    $('bridge-pay-target').textContent = sats(row.target_msat,'BTC'); $('bridge-pay-funding').textContent = sats(row.funding_msat);
    $('bridge-pay-result').textContent = resultText(row); $('bridge-pay-reference').textContent = row.hash;
    $('bridge-pay-deadline').textContent = row.funding && row.funding.state !== 'not_submitted' ? 'This funding request is saved. Closing the page will not send it again.' : expired(row) ? 'This quote is no longer available to fund.' : 'Review and send by ' + new Date(row.expires_at * 1000).toLocaleString();
    $('bridge-pay-rate').textContent = 'Quoted rate: ' + row.rate.toLocaleString() + ' · spread: ' + (row.spread * 100).toLocaleString() + '%';
    $('bridge-pay-source').textContent = row.funding ? row.funding.source === 'ark' ? 'Funded from this Ark wallet · approved maximum: ' + row.funding.maximum_total_sat.toLocaleString() + ' XBT sats' : 'Funding node: ' + row.funding.node_id : '';
    $('bridge-pay-check').hidden = row.verified_settlement; controls();
  }
  function history() {
    const count = Math.max(1,Math.ceil(rows.length / 10)); page = Math.min(page,count - 1); $('bridge-pay-records').replaceChildren();
    for (const row of rows.slice(page * 10,page * 10 + 10)) {
      const button = document.createElement('button'); button.className = 'menu-row secondary';
      const label = document.createElement('span'), title = document.createElement('strong'), info = document.createElement('small');
      title.textContent = sats(row.target_msat,'BTC'); info.textContent = resultText(row); label.append(title,info); button.append(label);
      button.onclick = () => { selected = row; if (row.funding) $('bridge-pay-method').value = row.funding.source === 'ark' ? 'ark' : 'node'; PaperclipNavigation.show('bridge-send-detail'); }; $('bridge-pay-records').append(button);
    }
    if (!rows.length) $('bridge-pay-records').textContent = 'Your saved Bridge payments will appear here.';
    $('bridge-pay-paging').hidden = count === 1; $('bridge-pay-prev').disabled = page === 0; $('bridge-pay-next').disabled = page + 1 >= count;
    $('bridge-pay-page').textContent = 'Page ' + (page + 1) + ' of ' + count;
  }
  function remember(row) {
    validate(row); const index = rows.findIndex(item => item.hash === row.hash); if (index < 0) rows.unshift(row); else rows[index] = row;
    selected = row; history(); detail();
  }
  function clear() {
    epoch++; invalidate(); rows = []; selected = null; nodeId = null; canSend = false; ready = false; busy = false; page = 0;
    health = null; healthStarted = 0; healthPending = false;
    $('bridge-pay-create').reset(); $('bridge-pay-approve').reset(); $('bridge-pay-records').replaceChildren();
    for (const id of ['bridge-pay-target','bridge-pay-funding','bridge-pay-result','bridge-pay-deadline','bridge-pay-reference','bridge-pay-source','bridge-pay-rate','bridge-pay-status','bridge-pay-node']) $(id).textContent = '';
    detail(); controls(); badge();
  }
  async function act(message, action) {
    if (busy || !active()) return;
    busy = true; controls(); const saved = context(); $('bridge-pay-status').textContent = message;
    try { await action(saved); }
    catch (error) { if (current(saved)) $('bridge-pay-status').textContent = error.message; }
    finally { if (current(saved)) { busy = false; controls(); } }
  }
  async function load(saved) {
    ready = false;
    const results = await Promise.allSettled([api('bridge/quotes'),api('remote-node/connection')]); if (!current(saved)) return;
    const [quotes,connection] = results;
    nodeId = connection.status === 'fulfilled' && connection.value.configured && node(connection.value.node_id) ? connection.value.node_id : null;
    canSend = !!nodeId && connection.value?.receive_only !== true;
    $('bridge-pay-method').value = canSend ? 'node' : 'ark';
    $('bridge-pay-node').textContent = network !== 'bitcoin' ? 'Bridge payments are available on XBT mainnet.' : canSend ? 'Choose Ark or your saved Lightning node at review.' : arkReady() ? 'Fund from your Ark balance, or connect a Lightning node.' : 'Enable Ark Lightning on your wallet server or connect a node with send access.';
    if (quotes.status !== 'fulfilled' || !Array.isArray(quotes.value.quotes) || quotes.value.quotes.length > 1000) throw new Error('Bridge history unavailable. Refresh before creating another conversion.');
    rows = quotes.value.quotes.filter(row => row.direction === direction).map(validate); ready = true;
    if (selected) selected = rows.find(row => row.hash === selected.hash) || null;
    history(); detail(); controls(); $('bridge-pay-status').textContent = '';
  }
  $('bridge-pay-create').onsubmit = event => {
    event.preventDefault(); void act('Preparing your conversion. No payment has been sent…',async saved => {
      if (!ready || (!canSend && !arkReady()) || network !== 'bitcoin') throw new Error('Load your saved node and Bridge history first.');
      const invoice = $('bridge-pay-invoice').value.trim().toLowerCase();
      if (!/^lnbc[0-9a-z]+$/.test(invoice) || invoice.length > 2000) throw new Error('Enter a fixed-amount BTC Lightning invoice.');
      const row = await api('bridge/quotes',{direction,invoice}); if (!current(saved)) return;
      validate(row); if (row.target_invoice !== invoice) throw new Error('The conversion changed your recipient invoice. Nothing was sent.');
      remember(row); if (view === 'bridge-send') PaperclipNavigation.show('bridge-send-detail');
      $('bridge-pay-status').textContent = 'Review both currencies before you send.';
    });
  };
  $('bridge-pay-approve').addEventListener('input',invalidate);
  $('bridge-pay-method').addEventListener('change',() => { invalidate(); controls(); });
  $('bridge-pay-approve').onsubmit = event => {
    event.preventDefault(); void act('Preparing the exact funding review…',async saved => {
      const row = selected, method = source(), expectedNode = nodeId, text = $('bridge-pay-fee').value.trim(), fee = Number(text);
      if (!fundable(row) || (method === 'ark' ? !arkReady() : !canSend || !/^(0|[1-9][0-9]*)$/.test(text) || !Number.isSafeInteger(fee) || fee > 1000000)) throw new Error('Choose an available funding source and review a current quote.');
      const prepared = await api(method === 'ark' ? 'bridge/prepare-ark-funding' : 'bridge/prepare-funding',method === 'ark' ? {hash:row.hash} : {hash:row.hash,maximum_fee_sat:fee}); if (!reviewCurrent(saved)) return;
      const returned = validate(prepared.quote), review = prepared.review;
      if (returned.hash !== row.hash || returned.target_invoice !== row.target_invoice || returned.hold_invoice !== row.hold_invoice || returned.target_msat !== row.target_msat || returned.funding_msat !== row.funding_msat || returned.expires_at !== row.expires_at || !fundable(returned) || !hash(review?.request_id) || review.payment_hash !== row.hash) throw new Error('The funding review changed. Nothing was submitted.');
      let breakdown, intent, body, endpoint;
      if (method === 'ark') {
        if (review.funding_amount_sat !== row.pay_sat || !Number.isSafeInteger(review.fees_and_reserves_sat) || review.fees_and_reserves_sat < 0 || !whole(review.maximum_total_sat) || review.maximum_total_sat > 2100000000000000 || BigInt(review.maximum_total_sat) !== BigInt(row.pay_sat) + BigInt(review.fees_and_reserves_sat)) throw new Error('The Ark funding review changed. Nothing was submitted.');
        breakdown = 'Ark funds: ' + row.pay_sat.toLocaleString() + ' XBT sats\nFees and recovery reserves: ' + review.fees_and_reserves_sat.toLocaleString() + ' XBT sats\nMaximum total: ' + review.maximum_total_sat.toLocaleString() + ' XBT sats';
        intent = {source:'ark',maximum_total_sat:review.maximum_total_sat,state:'unknown'};
        body = {hash:row.hash,request_id:review.request_id,maximum_total_sat:review.maximum_total_sat}; endpoint = 'bridge/fund-ark';
      } else {
        if (review.node_id !== expectedNode || review.amount_msat !== row.funding_msat || review.maximum_fee_sat !== fee || !msat(review.maximum_total_msat) || BigInt(review.maximum_total_msat) !== BigInt(row.funding_msat) + BigInt(fee) * 1000n) throw new Error('The funding review changed. Nothing was submitted.');
        breakdown = 'Node funds: ' + sats(row.funding_msat) + '\nMaximum routing fee: ' + fee.toLocaleString() + ' XBT sats\nMaximum total: ' + sats(review.maximum_total_msat) + '\n\nFunding node: ' + expectedNode;
        intent = {node_id:expectedNode,maximum_fee_sat:fee,state:'unknown'};
        body = {hash:row.hash,maximum_fee_sat:fee,request_id:review.request_id}; endpoint = 'bridge/fund';
      }
      const approved = await PaperclipReview.ask('Pay through Paperclip Bridge\n\nRecipient receives: ' + sats(row.target_msat,'BTC') + '\n' + breakdown + '\n\nPayment reference: ' + row.hash);
      if (!approved || !reviewCurrent(saved)) return;
      if (expired(row)) throw new Error('The quote expired while you reviewed it. Nothing was submitted.');
      // Only a server journal check can prove an interrupted preflight did not submit.
      remember({...row,funding:intent}); $('bridge-pay-status').textContent = 'Submitting once. Your conversion is saved for recovery…';
      try {
        const result = await api(endpoint,body); if (!current(saved)) return;
        validate(result);
        if (result.hash !== row.hash || result.hold_invoice !== row.hold_invoice || result.target_invoice !== row.target_invoice || (method === 'ark' ? result.funding?.source !== 'ark' || result.funding.maximum_total_sat !== review.maximum_total_sat : result.funding?.node_id !== expectedNode || result.funding.maximum_fee_sat !== fee)) throw new Error('Funding response differs from the review.');
        remember(result); $('bridge-pay-status').textContent = 'Funding request saved. Check status to verify BTC settlement.';
      } catch (_) { if (current(saved)) $('bridge-pay-status').textContent = 'The result is uncertain. Check this saved conversion; do not send it again.'; }
    });
  };
  $('bridge-pay-check').onclick = () => void act('Checking the original funding and BTC settlement…',async saved => {
    if (!selected) return; const row = selected;
    const result = await api('bridge/check',{direction,hash:row.hash}); if (!current(saved)) return;
    if (result.hash !== row.hash || result.target_invoice !== row.target_invoice || result.hold_invoice !== row.hold_invoice) throw new Error('Status returned another conversion.');
    remember(result); $('bridge-pay-status').textContent = result.verified_settlement ? 'BTC settlement verified.' : result.funding_checked === false && row.funding ? 'Funding could not be checked. Keep this saved conversion and check again.' : 'Status updated. Funding and BTC settlement are checked separately.';
  });
  $('bridge-pay-reload').onclick = () => void act('Loading saved conversions…',load);
  $('bridge-pay-prev').onclick = () => { page--; history(); }; $('bridge-pay-next').onclick = () => { page++; history(); };
  window.addEventListener('paperclip:view',event => {
    const next = globalThis.PaperclipAccounts?.generation ?? 0; if (next !== generation) { clear(); generation = next; }
    if (view !== event.detail) invalidate(); view = event.detail;
    $('bridge-pay-home').hidden = view !== 'bridge-send'; $('bridge-pay-detail').hidden = view !== 'bridge-send-detail'; $('bridge-pay-activity').hidden = view !== 'bridge-send-activity';
    $('bridge-pay-back').hidden = view === 'bridge-send'; $('bridge-pay-lightning').hidden = view !== 'bridge-send';
    if (view === 'bridge-send' || view === 'bridge-send-activity') void act('Loading saved conversions…',load);
    if (view === 'bridge-send-detail') detail(); void availability();
  });
  new MutationObserver(() => { if ($('wallet').hidden) clear(); }).observe($('wallet'),{attributes:true,attributeFilter:['hidden']});
  document.addEventListener('visibilitychange',() => { invalidate(); if (!document.hidden) { badge(); detail(); void availability(); } });
  setInterval(() => { if (visible()) { badge(); void availability(); if (view === 'bridge-send-detail') detail(); } },1000);
})();
