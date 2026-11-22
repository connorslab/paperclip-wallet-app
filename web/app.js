'use strict';
let token = '';
let network = null;
let uncertainMutation = sessionRead('paperclip.uncertain') === '1';
let submissionJournal = false;
let lightningEnabled = false;
let lightningDebitLimit = false;
let hardwareArkEnabled = false;
let setupPending = false;
let setupDefaultsLoaded = false;
const $ = id => document.getElementById(id);
const status = text => { $('status').textContent = text; };
let walletMutations = 0;
function walletContext() { return {token, generation:globalThis.PaperclipAccounts?.generation ?? 0}; }
function currentWallet(context) { return token===context.token && (globalThis.PaperclipAccounts?.generation ?? 0)===context.generation; }
const runningControls = new Map();
function resetWalletControls() {
  for (const button of runningControls.keys()) button.disabled=false;
  runningControls.clear();
}
async function api(path, body, method, signal) {
  const account = globalThis.PaperclipAccounts?.selectedId || '', generation = globalThis.PaperclipAccounts?.generation ?? 0;
  // Jam has its own wallet authorization. Selecting a public account must not
  // hide that independent wallet or grant access to any hot-wallet operation.
  const separateWallet = ['joinblaket/connection','joinblaket/request','joinblaket/pairings','joinblaket/pairings/revoke'].includes(path);
  const qrRecovery = path==='submissions' && (body===undefined || body?.operation==='hardware/board/commit') || ['submissions/ack','submissions/check'].includes(path);
  if (account && !qrRecovery && !path.startsWith('hardware/') && !path.startsWith('/api/profiles') && !separateWallet) throw new Error('This action belongs to the hot wallet. Switch wallets first.');
  const mutation = (body !== undefined || (method && method !== 'GET')) && !(path === 'hardware/request' && body?.operation === 'refresh');
  if (mutation) { walletMutations++; globalThis.PaperclipAccounts?.busyChanged(); }
  try {
    const result = await PaperclipTransport.request(path, {body, method, token, profile: separateWallet ? '' : globalThis.PaperclipAccounts?.hotProfileId || '', signal, ...(path === 'joinblaket/request' && body?.operation === 'prepare_payment' && body.send?.coinjoin === true ? {timeoutMs:190000} : path === 'submissions' && body !== undefined ? {timeoutMs:190000} : path === 'hardware/request' ? {timeoutMs:150000} : (path.startsWith('remote-node/') || ['bridge/quotes','bridge/prepare-funding','bridge/fund','bridge/prepare-ark-funding','bridge/fund-ark'].includes(path)) ? {timeoutMs:190000} : path === 'bridge/check' ? {timeoutMs:60000} : {})});
    if (generation !== (globalThis.PaperclipAccounts?.generation ?? 0)) throw new Error('Wallet changed. Refresh the selected wallet.');
    return result;
  }
  catch (error) {
    if (error.message.includes('no pending lightning receive')) error.message = 'No received payment matches this invoice in this wallet. An invoice from another wallet belongs in Pay someone, not Received status.';
    if (error.message.toLowerCase().includes('dust') || error.message.includes('funded-HTLC minimum') || error.message.includes('No constructible Lightning input')) error.message = path === 'fees/ark/send' ? 'Ark payment or change is too small after recovery reserves. Check your balance and amount, or refresh eligible inputs. No payment was sent.' : 'Available Ark inputs cannot cover this payment with valid recovery reserves and change. Refresh eligible inputs to consolidate funds, or add Ark funds. Check Sent status before retrying.';
    throw error;
  }
  finally { if (mutation) { walletMutations--; globalThis.PaperclipAccounts?.busyChanged(); } }
}
let updateInFlight = null;
let nextAutomaticUpdate = 0;
async function update() {
  if (globalThis.PaperclipAccounts?.selectedId) return globalThis.PaperclipAccounts.refresh();
  if (updateInFlight && currentWallet(updateInFlight.context)) return updateInFlight.promise;
  const sessionToken = token;
  const promise = updateBalances(sessionToken);
  updateInFlight = {context:walletContext(), promise};
  try { return await promise; }
  finally { if (updateInFlight?.promise === promise) updateInFlight = null; }
}
async function updateBalances(sessionToken) {
  const accountGeneration = globalThis.PaperclipAccounts?.generation ?? 0;
  const results = await Promise.allSettled(['wallet/balance', 'onchain/balance', 'wallet/vtxos', 'exits/status/all', 'bitcoin/tip', 'boards/pending'].map(path => api(path)));
  if (!token || token !== sessionToken || accountGeneration !== (globalThis.PaperclipAccounts?.generation ?? 0)) return;
  const [balance, chain, vtxos, exits, tip, boards] = results.map(result => result.status === 'fulfilled' ? result.value : null);
  $('exits').textContent = JSON.stringify(exits, null, 2);
  const hasArkBalance = Number.isSafeInteger(balance?.spendable_sat) && balance.spendable_sat >= 0;
  const hasChainBalance = Number.isSafeInteger(chain?.confirmed_sat) && chain.confirmed_sat >= 0;
  $('ark-balance').textContent = hasArkBalance ? balance.spendable_sat.toLocaleString() : 'Unavailable';
  $('chain-balance').textContent = hasChainBalance ? chain.confirmed_sat.toLocaleString() : 'Unavailable';
  $('vtxos').textContent = JSON.stringify({balance, onchain: chain, vtxos}, null, 2);
  vtxoSnapshot = {balance: balance || {}, rows: Array.isArray(vtxos) ? vtxos : [], tip: Number.isSafeInteger(tip?.tip_height) ? tip.tip_height : null};
  renderVtxos();
  renderPendingBoards(boards);
  if (!vtxos || !balance) {
    $('vtxo-list').replaceChildren(); $('vtxo-summary').textContent = 'Recovery balances are unavailable. Check connections and try again.';
  }
  const incomplete = results.some(result => result.status === 'rejected') || !hasArkBalance || !hasChainBalance;
  nextAutomaticUpdate = Date.now() + (incomplete ? 120000 : 30000);
  $('wallet-readiness').hidden = !incomplete;
  $('wallet-readiness').textContent = incomplete ? 'Some wallet data is unavailable. Your node may be syncing or busy. Check connections in Settings before sending.' : '';
  return !incomplete;
}
async function run(button, operation) {
  const context=token?walletContext():null, ticket=Symbol();
  runningControls.set(button,ticket);button.disabled = true;
  status('');
  try { await operation(); } catch (error) { if(!context||currentWallet(context))status(error.message); }
  finally { if(runningControls.get(button)===ticket){runningControls.delete(button);button.disabled=false;} }
}
function accessToken(value) {
  // Umbrel supplies a random 32-byte app password, never a wallet seed.
  if (/^[0-9a-f]{64}$/i.test(value)) {
    return btoa(String.fromCharCode(0, ...value.match(/../g).map(hex => parseInt(hex, 16))))
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  return value;
}
async function connectWallet() {
    const session = token;
    const info = await api('wallet/identity');
    if (!session || token !== session) return;
    if (!['bitcoin', 'regtest'].includes(info.network) || info.exit_profile !== 2) throw new Error('Unsupported network or ASP recovery profile.');
    network = info.network;
    submissionJournal = info.submission_journal === 1;
    lightningEnabled = info.lightning_enabled === true;
    lightningDebitLimit = info.lightning_debit_limit === true;
    hardwareArkEnabled = info.hardware_ark_boarding === true && submissionJournal;
    $('ln-controls').disabled = !lightningEnabled;
    $('ln-capability').textContent = lightningEnabled ? 'Ark Lightning available \u00b7 payments depend on channel and Ark pool liquidity.' : 'This ASP has not enabled funded Lightning. Payment controls are unavailable.';
    $('network').textContent = network === 'bitcoin' ? 'XBT MAINNET \u00b7 EXPERIMENTAL' : 'XBT REGTEST';
    await globalThis.PaperclipAccounts?.restore();
    if (!session || token !== session) return;
    $('setup').hidden = true; $('login').hidden = true; $('wallet').hidden = false;
    $('ark-balance').textContent = 'Loading\u2026'; $('chain-balance').textContent = 'Loading\u2026';
    $('submission-warning').hidden = !uncertainMutation;
    if (submissionJournal && !globalThis.PaperclipAccounts?.selectedId) await syncSubmissions();
    if ($('remember-session').checked) sessionWrite('paperclip.session', token);
    status('Signed in. Loading balances\u2026');
    void update().then(complete => { if (token === session) status(complete ? 'Wallet updated.' : 'Signed in. Some wallet data is unavailable.'); }).catch(() => { if (token === session) status('Signed in. Check connections in Settings.'); });
}
async function unlockWallet(value) {
  token = accessToken(value);
  try {
    await globalThis.PaperclipAccounts?.restoreHot();
    uncertainMutation = sessionRead(uncertainKey()) === '1';
    const existing = await api('wallet');
    if (existing.fingerprint !== null && typeof existing.fingerprint !== 'string') throw new Error('Unrecognized wallet status.');
    setupPending = false;
    if (existing.fingerprint === null) {
      if (!$('wallet').hidden) { $('wallet').hidden = true; await Promise.resolve(); }
      $('login').hidden = true;
      $('setup-back-wallets').hidden = !globalThis.PaperclipAccounts?.hotProfileId;
      if (!setupDefaultsLoaded) {
        const defaults = await api('/api/config').catch(() => null);
        if (typeof defaults?.arkServer === 'string') {
          try {
            const url = new URL(defaults.arkServer);
            if (['https:', 'http:'].includes(url.protocol) && !url.username && !url.password) {
              $('setup-asp').value = defaults.arkServer;
            }
          } catch {}
        }
        setupDefaultsLoaded = true;
      }
      const installed = await api('wallet/platform-node').catch(() => ({available: false}));
      $('setup-installed').disabled = !installed.available;
      $('setup-backend').value = installed.available ? 'installed' : 'manual';
      setupBackend();$('setup').hidden = false;
      status('Choose your XBT backend and ASP to create a wallet.');
      return;
    }
    await connectWallet();
  } catch (error) { token = ''; throw error; }
}
$('unlock').addEventListener('submit', event => { event.preventDefault(); run(event.submitter, async () => {
  const value = $('token').value.trim(); $('token').value = '';
  await unlockWallet(value);
}); });
function endpoint(id, protocols) {
  const value = $(id).value.trim();
  const url = new URL(value);
  if (!protocols.includes(url.protocol) || url.username || url.password || url.hash || url.search) {
    throw new Error('Use an HTTP(S) endpoint without embedded credentials, query, or fragment.');
  }
  return value;
}
function setupChainSource() {
  const backend = $('setup-backend').value;
  if (backend === 'installed') return 'platform';
  if (backend === 'electrum') {
    const url = new URL($('setup-electrum').value.trim());
    if (!['ssl:', 'tcp:'].includes(url.protocol) || !url.hostname || !Number(url.port) ||
        url.username || url.password || url.search || url.hash || !['', '/'].includes(url.pathname))
      throw new Error('Enter an Electrum server address such as ssl://host:50002 or tcp://host:50001.');
    const pin = $('setup-electrum-pin').value.trim();
    if (pin && (url.protocol !== 'ssl:' || !/^[a-f0-9]{64}$/i.test(pin)))
      throw new Error('A certificate fingerprint requires TLS and 64 hexadecimal digits.');
    const onion = url.hostname.toLowerCase().replace(/\.$/, '').endsWith('.onion');
    return {electrum: {url: url.href, certificate_sha256: pin || null, use_tor: onion || $('setup-electrum-tor').checked}};
  }
  if (backend !== 'manual') throw new Error('Choose a chain connection.');
  const user = $('setup-user').value, pass = $('setup-password').value;
  if (!user || !pass) throw new Error('RPC credentials are required.');
  return {bitcoind: {bitcoind: endpoint('setup-rpc', ['http:', 'https:']), bitcoind_auth: {'user-pass': {user, pass}}}};
}
function setupBackend() {
  const manual = $('setup-backend').value === 'manual';
  const electrum = $('setup-backend').value === 'electrum';
  $('setup-electrum-fields').hidden = !electrum;
  $('setup-electrum-fields').disabled = !electrum;
  $('setup-network').disabled = !manual && !electrum;
  if ($('setup-network').disabled) $('setup-network').value = 'mainnet';
  $('show-rpc-password').hidden = !manual;
  for (const id of ['setup-rpc', 'setup-user', 'setup-password']) {
    $(id).disabled = !manual;
    $(id).closest('label').hidden = !manual;
  }
}
$('setup-backend').onchange = setupBackend;
function setupDiceClear() {
  $('setup-dice-rolls').value = ''; $('setup-dice-ack').checked = false;
  setupSeedDisplay();
}
function setupDiceRolls() {
  const text = $('setup-dice-rolls').value.trim();
  const parts = text ? text.split(/[\s,]+/) : [];
  const sides = Number($('setup-dice-sides').value);
  if (parts.length > 1000 || parts.some(value => !/^[1-9][0-9]?$/.test(value) || Number(value) > sides))
    throw new Error('Enter valid physical dice rolls, up to 1000.');
  return parts.map(Number);
}
function setupSeedDisplay() {
  const dice = $('setup-seed-method').value === 'dice';
  $('setup-dice').hidden = !dice; $('setup-system-note').hidden = dice;
  $('setup-seed-summary').textContent = (dice ? 'Physical D' + $('setup-dice-sides').value + ' dice' : 'Secure system random') + ' \u00b7 ' + $('setup-seed-words').value + ' words';
  const minimum = {6:50,12:36,20:30}[$('setup-dice-sides').value] * ($('setup-seed-words').value === '24' ? 2 : 1);
  try { $('setup-dice-progress').textContent = setupDiceRolls().length + ' of ' + minimum + ' required rolls \u00b7 up to 1000'; }
  catch (error) { $('setup-dice-progress').textContent = error.message; }
}
function setupGeneration() {
  const method = $('setup-seed-method').value, words = Number($('setup-seed-words').value);
  if (!['system','dice'].includes(method) || ![12,24].includes(words)) throw new Error('Choose a seed source and 12 or 24 words.');
  if (method === 'system') return {method, words};
  const host = window.location.hostname;
  if (window.location.protocol !== 'https:' && !['localhost','127.0.0.1','[::1]'].includes(host) && !/^[a-z2-7]{56}\.onion$/.test(host))
    throw new Error('Use HTTPS, your Tor onion address, or a local desktop connection before entering private dice rolls.');
  const sides = Number($('setup-dice-sides').value), rolls = setupDiceRolls();
  if (![6,12,20].includes(sides) || rolls.length < {6:50,12:36,20:30}[sides] * (words === 24 ? 2 : 1) || !$('setup-dice-ack').checked)
    throw new Error('Complete the required rolls and confirm that you used fair physical dice.');
  return {method, words, sides, rolls, fair_dice_acknowledged:true};
}
for (const id of ['setup-seed-method','setup-dice-sides']) $(id).onchange = setupDiceClear;
$('setup-seed-words').onchange = () => { $('setup-dice-ack').checked = false; setupSeedDisplay(); };
$('setup-dice-rolls').oninput = setupSeedDisplay;
// A revision also invalidates a review if fields change and then change back.
let setupRevision = 0;
$('create-wallet').addEventListener('input', () => { setupRevision++; });
$('create-wallet').addEventListener('change', () => { setupRevision++; });
window.addEventListener('pagehide', () => { setupRevision++; setupDiceClear(); });
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { setupRevision++; setupDiceClear(); if (!$('setup').hidden) PaperclipReview.cancel(); }
});
$('create-wallet').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  if (!token || setupPending) throw new Error('Lock and unlock to check whether the previous setup completed before retrying.');
  const setupSession = token, revision = setupRevision;
  const selected = $('setup-network').value;
  if (!['mainnet', 'regtest'].includes(selected) || !$('setup-ack').checked) throw new Error('Choose the network and confirm the backup requirement.');
  const body = {
    network: selected, ark_server: endpoint('setup-asp', ['http:', 'https:']),
    chain_source: setupChainSource(), force: false, seed_generation: setupGeneration()
  };
  const options = await api('wallet/creation-options');
  if (options?.version !== 1 || options.dice_derivation !== 'paperclip-dice-v1' ||
      !Array.isArray(options.methods) || !Array.isArray(options.words) ||
      !options.methods?.includes(body.seed_generation.method) || !options.words?.includes(body.seed_generation.words))
    throw new Error('Update your Paperclip host before creating a wallet with these entropy options.');
  if (token !== setupSession || setupRevision !== revision || $('setup').hidden) throw new Error('Setup changed. Review it again.');
  const choice = body.seed_generation.method === 'dice' ? 'physical D' + body.seed_generation.sides + ' dice only' : 'secure system randomness';
  if (!await PaperclipReview.ask('Create a new wallet on XBT ' + selected + ' with ' + body.seed_generation.words + ' words from ' + choice + '? For an existing wallet, cancel and restore its complete backup instead.')) return;
  if (token !== setupSession || setupRevision !== revision || $('setup').hidden) throw new Error('Setup changed. Review it again.');
  setupPending = true;
  $('setup-password').value = ''; setupDiceClear();
  try { await api('wallet/create-with-entropy', body); }
  finally { body.seed_generation.rolls?.fill(0); }
  if (token !== setupSession || setupRevision !== revision) return;
  setupPending = false;
  await connectWallet();
}); };
$('setup-lock').onclick = () => {
  setupRevision++; setupDiceClear();
  token = ''; $('setup-password').value = ''; $('setup').hidden = true; $('login').hidden = false;
  status('Setup locked. Unlock to check wallet state.');
};
$('lock').onclick = () => { token = ''; network = null; $('network').textContent = 'NETWORK UNVERIFIED'; $('deposit-address').textContent = ''; $('exits').textContent = '';  $('wallet').hidden = true; $('login').hidden = false; $('vtxos').textContent = ''; $('address').textContent = ''; $('destination').value = ''; status('Wallet locked.'); };
$('reload').onclick = event => run(event.target, async () => {
  const context = walletContext();
  const complete = await update();
  if (token && currentWallet(context)) status(complete ? 'Balances updated.' : 'Some wallet data is unavailable. Check connections and retry.');
});
$('receive').onclick = event => run(event.target, async () => { const receiveSession = token; const result = await api('wallet/addresses/next', {}); if (!token || token !== receiveSession || $('wallet').hidden) return; $('address').textContent = result.address; PaperclipReceive.show('address', result.address, 'Receive on Ark'); status('New Ark receive address.'); });
$('ark-max').onchange=()=>{$('amount').disabled=$('ark-max').checked;$('amount').required=!$('ark-max').checked;$('ark-estimate').hidden=true;};
$('send').addEventListener('submit', event => { event.preventDefault(); run(event.submitter, async () => {
  const destination = $('destination').value.trim(), maximum=$('ark-max').checked,entered=maximum?null:Number($('amount').value);
  if (!maximum&&(!Number.isSafeInteger(entered) || entered <= 0)) throw new Error('Enter a positive whole number of sats.');
  if (!network) throw new Error('Unlock and verify the wallet network first.');
  if (uncertainMutation) throw new Error('Check the previous submission in Activity before another payment.');
  const context=walletContext();
  const transferRevision = window.PaperclipTransfer?.revision ?? 0;
  const unchanged=()=>(window.PaperclipTransfer?.revision ?? 0)===transferRevision&&currentWallet(context)&&token&&network&&$('destination').value.trim()===destination&&$('ark-max').checked===maximum&&(maximum||Number($('amount').value)===entered);
  $('ark-estimate').hidden = true;
  status('Estimating the recipient amount and recovery reserve. No payment has been sent.');
  const quote = await api('fees/ark/send', maximum?{destination,send_max:true}:{destination,amount_sat:entered});
  if (!unchanged()) {
    throw new Error('Wallet or payment details changed. Review the transfer again.');
  }
  const amount=quote.recipient_amount_sat;
  const fields = ['recipient_amount_sat', 'recovery_reserve_sat', 'service_fee_sat', 'total_debit_sat', 'remaining_spendable_sat', 'input_count'];
  if (fields.some(key => !Number.isSafeInteger(quote[key]) || quote[key] < 0) || quote.input_count < 1 ||
      amount<=0 || (!maximum&&amount!==entered) || (maximum&&quote.send_max!==true) || quote.total_debit_sat !== amount + quote.recovery_reserve_sat + quote.service_fee_sat) {
    throw new Error('Invalid cost estimate. No payment was sent.');
  }
  const review = (maximum?'Send Max\n':'')+'Recipient receives: ' + amount.toLocaleString() + ' sats\n' +
    'Recovery reserve: ' + quote.recovery_reserve_sat.toLocaleString() + ' sats\n' +
    'Service fee: ' + quote.service_fee_sat.toLocaleString() + ' sats\n' +
    'Total balance reduction: ' + quote.total_debit_sat.toLocaleString() + ' sats\n' +
    'Estimated remaining balance: ' + quote.remaining_spendable_sat.toLocaleString() + ' sats';
  $('ark-estimate-values').textContent = review;
  $('ark-estimate').hidden = false;
  if (!await PaperclipReview.ask(review + '\n\nRecovery allocations are not separately refundable. They are not miner fees unless recovery transactions confirm. Refresh does not refund prior allocations.\n\nSend to:\n' + destination + '?')) {
    status('Estimate ready. No payment was sent.'); return;
  }
  if (!unchanged()) throw new Error('Payment details changed. Review again.');
  status('Submitting once. If the connection fails, check history before trying again.');
  const result = await mutate('wallet/send', {destination, amount_sat: amount, max_total_sat: quote.total_debit_sat});
  if(!currentWallet(context))return;
  $('destination').value = ''; $('amount').value = ''; $('ark-max').checked=false;$('ark-max').onchange();
  if (result?.state === 'successful') transactionResult('success', 'Transfer completed', 'Your Ark transfer is recorded as successful.');
  else transactionResult(result?.state === 'failed' || result?.state === 'canceled' ? 'failed' : 'pending', 'Check transfer status', 'The wallet recorded your request. Open Activity for its current outcome.', String(result?.movement_id ?? ''));
  void update().catch(() => {});
}); });
for (const id of ['destination', 'amount']) $(id).addEventListener('input', () => { $('ark-estimate').hidden = true; });
$('refresh').onclick = event => run(event.target, async () => {
  if (!await PaperclipReview.ask('Refresh all eligible VTXOs? Transaction fees may apply.')) return;
  await mutate('wallet/refresh/all', {}); await update(); status('Refresh requested. Wait for confirmation and update to check completion.');
});

// Persisted on the server so closing a tab cannot erase an uncertain payment.
const journalOperations = new Set(['wallet/send','lightning/pay','onchain/send/commit',
  'onchain/replacement/commit','hardware/board/commit','boards/commit','withdrawals/commit','wallet/offboard/all','wallet/refresh/all',
  'exits/start/all','exits/progress','exits/claim/all']);
function submissionKey() {
  const profile=globalThis.PaperclipAccounts?.hotProfileId;
  return profile ? 'paperclip.submission.'+profile : 'paperclip.submission';
}
function uncertainKey() {
  const profile=globalThis.PaperclipAccounts?.hotProfileId;
  return profile ? 'paperclip.uncertain.'+profile : 'paperclip.uncertain';
}
function submissionWarning(uncertain) {
  uncertainMutation = uncertain; sessionWrite(uncertainKey(), uncertain ? '1' : null);
  $('submission-warning').hidden = !uncertain;
}
async function acknowledgeSubmission(id) {
  const record = await api('submissions/ack', {id});
  if (record?.id !== id || record.acknowledged !== true) throw new Error('Could not confirm receipt of this result. Check saved status.');
}
async function syncSubmissions(check = false) {
  const context = walletContext();
  // Fail closed while loading, including the first visit from a new browser.
  submissionWarning(true);
  const history = await api('submissions');
  if (!currentWallet(context) || !token) return;
  if (history?.version !== 1 || !Array.isArray(history.pending) || !Array.isArray(history.recent)) throw new Error('Saved payment status is unavailable. Try checking again before sending.');
  const localId = sessionRead(submissionKey());
  if (!localId && history.pending.length) sessionWrite(submissionKey(), history.pending[0].id);
  const ids = new Set(history.pending.map(record => record.id));
  if (localId) ids.add(localId);
  let unresolved = false, recovered = null;
  for (const id of ids) {
    if (!/^[a-f0-9]{64}$/.test(id)) throw new Error('Saved payment reference is invalid.');
    const record = check || id === localId ? await api('submissions/check', {id}) : history.pending.find(row => row.id === id);
    if (!currentWallet(context) || !token) return;
    if (record?.id !== id || !['received','recorded','rejected','unconfirmed'].includes(record.state)) throw new Error('Could not verify the saved payment result.');
    unresolved ||= record.state === 'unconfirmed';
    if (record.state !== 'unconfirmed' && (!recovered || recovered.state === 'rejected')) recovered = record;
  }
  if (recovered && !(unresolved && recovered.state === 'rejected')) {
    const detail = recovered.result?.state;
    const title = recovered.state === 'rejected' ? 'Request was not submitted' : detail === 'successful' ? 'Transfer completed' : 'Submission found';
    transactionResult(detail === 'successful' ? 'success' : recovered.state === 'rejected' ? 'failed' : 'pending', title,
      recovered.state === 'rejected' ? 'Review again when ready.' : 'The original wallet record was recovered. Check Activity or payment status for settlement.',
      recovered.payment_hash || recovered.txid || String(recovered.result?.movement_id ?? ''));
    if (recovered.state !== 'rejected') await acknowledgeSubmission(recovered.id);
    if (!currentWallet(context) || !token) return;
  }
  submissionWarning(unresolved);
  if (!unresolved) sessionWrite(submissionKey(), null);
  if (check) status(unresolved ? 'Still awaiting a confirmed result. Check again later; no payment was resent.' : 'Saved results checked. No payment was resent.');
}

// A retry uses the original receipt for observation; it never repeats a send.
async function mutate(path, body) {
  if (!token || !network) throw new Error('Unlock and verify the wallet network first.');
  if (uncertainMutation) throw new Error('A prior submission needs checking. Check its saved status before another payment.');
  if (journalOperations.has(path) && !submissionJournal) throw new Error('Update the wallet server before sending. This version requires saved submission recovery.');
  const journal = submissionJournal && journalOperations.has(path);
  const context = walletContext();
  let id;
  if (journal) {
    id = Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2,'0')).join('');
    sessionWrite(submissionKey(), id);
  }
  submissionWarning(true);
  let result;
  try {
    result = await api(journal ? 'submissions' : path, journal ? {id, operation:path, body} : body);
    if (!currentWallet(context) || !token) throw new Error('Wallet changed while submitting. Check saved status after signing in again.');
    if (journal) {
      if (result?.id !== id || result.operation !== path || !['received','rejected'].includes(result.state)) throw new Error('The wallet has not confirmed this submission. Check saved status.');
      if (result.state === 'received') {
        transactionResult('pending', 'Submission recorded', 'Check Activity or payment status for the final outcome.', result.txid || result.payment_hash || String(result.result?.movement_id ?? ''));
        await acknowledgeSubmission(id);
      }
      if (!currentWallet(context) || !token) throw new Error('Wallet changed while receiving the result. Check saved status after signing in again.');
      submissionWarning(false); sessionWrite(submissionKey(), null);
      if (result.state === 'rejected') throw Object.assign(new Error(result.result?.message || 'No payment was submitted. Review again.'), {notSubmitted:true});
      result = result.result;
    }
  } catch (error) {
    if (currentWallet(context) && token) transactionResult(error.notSubmitted ? 'failed' : 'unknown', error.notSubmitted ? 'Request was not submitted' : 'Result not confirmed',
      error.notSubmitted ? error.message : 'Check saved status before trying again. The original request will not be sent again.');
    throw error;
  }
  submissionWarning(false);
  return result;
}

function transactionResult(kind, title, detail, reference = '') {
  if (!token || $('wallet').hidden) return;
  $('transaction-result').dataset.kind = kind;
  $('transaction-result-title').textContent = title;
  $('transaction-result-detail').textContent = detail;
  $('transaction-result-reference').textContent = reference;
  $('transaction-result-reference').hidden = !reference;
  $('transaction-result').showModal();
  $('transaction-result-done').focus();
}
$('transaction-result-done').onclick = () => $('transaction-result').close();
$('transaction-result-activity').onclick = () => {
  $('transaction-result').close(); PaperclipNavigation.show('activity'); $('history-load').click();
};

function sats(id, optional = false) {
  const value = $(id).value.trim();
  if (optional && value === '') return null;
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value) <= 0) {
    throw new Error('Enter a positive whole number of sats.');
  }
  return Number(value);
}
$('chain-max').onchange = () => { $('chain-amount').disabled=$('chain-max').checked; $('chain-amount').required=!$('chain-max').checked; };
$('chain-send').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  const destination = $('chain-destination').value.trim(), maximum=$('chain-max').checked, entered=maximum?null:sats('chain-amount');
  if (!destination) throw new Error('Enter an XBT address.');
  const context = walletContext();
  const unchanged=()=>currentWallet(context)&&token&&$('chain-destination').value.trim()===destination&&$('chain-max').checked===maximum&&(maximum||sats('chain-amount')===entered);
  const quote = await api('onchain/send/prepare', maximum?{destination,send_max:true}:{destination,amount_sat:entered});
  if (!unchanged()) throw new Error('Payment changed. Review again.');
  const amount=quote.amount_sat;
  if (quote.destination !== destination || !Number.isSafeInteger(amount) || amount<=0 || (!maximum&&amount!==entered) || (maximum&&quote.send_max!==true) || !/^[0-9a-f]{64}$/.test(quote.request_id) ||
      !Number.isSafeInteger(quote.fee_sat) || quote.fee_sat < 0 || !Number.isSafeInteger(quote.total_sat) || quote.total_sat !== amount + quote.fee_sat) throw new Error('Could not verify the complete payment cost. No payment was sent.');
  if (!await PaperclipReview.ask((maximum?'Send Max \u00b7 ':'Send ') + amount.toLocaleString() + ' sats on ' + network + ' to:\n' + destination +
      '\n\nNetwork fee: ' + quote.fee_sat.toLocaleString() + ' sats\nTotal debit: ' + quote.total_sat.toLocaleString() + ' sats')) return;
  if (!unchanged()) throw new Error('Payment changed. Review again.');
  const result = await mutate('onchain/send/commit', {request_id: quote.request_id, total_sat: quote.total_sat});
  if (!currentWallet(context)) return;
  $('chain-result').textContent = result.txid;
  $('chain-destination').value = ''; $('chain-amount').value = '';
  $('chain-max').checked=false;$('chain-max').onchange();
  const submitted = result.state === 'submitted';
  transactionResult('pending', submitted ? 'Transaction submitted' : 'Broadcast not confirmed', submitted ? 'Waiting for confirmation on the XBT network. Do not send it again.' : 'The signed transaction is saved. Check its status before another action.', result.txid);
  status(submitted ? 'Transaction submitted. Wait for confirmation; do not send again.' : 'Signed payment saved. Check broadcast status; do not send again.');
}); };
$('ln-pay').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  if (!lightningEnabled) throw new Error('Lightning is not enabled in this wallet recovery profile.');
  const destination = $('ln-destination').value.trim(), amount = sats('ln-amount', true);
  const paymentSession = token, context = walletContext(), navigation = window.PaperclipNavigation?.revision;
  const unchanged = () => currentWallet(context) && navigation === window.PaperclipNavigation?.revision;
  if (!destination) throw new Error('Enter an XBT Lightning request.');
  if (!lightningDebitLimit) throw new Error('Update the wallet server before sending Lightning payments. It must support the approved payment limit.');
  const quote = await api('fees/lightning/review', {destination, amount_sat: amount});
  if (![quote.gross_amount_sat, quote.fee_sat, quote.net_amount_sat].every(Number.isSafeInteger) || quote.net_amount_sat <= 0 || (amount !== null && quote.net_amount_sat !== amount) || quote.fee_sat < 0 || quote.gross_amount_sat !== quote.net_amount_sat + quote.fee_sat) throw new Error('Invalid Lightning estimate. No payment was sent.');
  const costs = 'Maximum total: ' + quote.gross_amount_sat.toLocaleString() + ' sats\nIncludes ' + quote.fee_sat.toLocaleString() + ' sats in service fees and recovery reserves.\nIf the cost increases, you will need to review it again.';
  if (!unchanged() || !token || token !== paymentSession || $('wallet').hidden || destination !== $('ln-destination').value.trim() || amount !== sats('ln-amount', true)) throw new Error('Payment details changed. Review them again. No payment was sent.');
  if (!await PaperclipReview.ask('Pay ' + (quote.net_amount_sat.toLocaleString() + ' sats') + ' from Ark on ' + network + '?\n' + destination + '\n\n' + costs + '\nFailed payments may also consume refund reserves.')) return;
  if (!unchanged() || !token || token !== paymentSession || destination !== $('ln-destination').value.trim() || amount !== sats('ln-amount', true)) throw new Error('Payment details changed. Review again.');
  const result = await mutate('lightning/pay', {destination, amount_sat: quote.net_amount_sat, max_total_sat: quote.gross_amount_sat, comment: null});
  if (!unchanged() || !token || token !== paymentSession || $('wallet').hidden) return;
  $('ln-result').textContent = JSON.stringify(result, null, 2);
  paymentSummary('Submitted', 'Payment submitted once. Check Sent status before trying again.');
  transactionResult('pending', 'Payment submitted', 'Check Sent status to confirm whether the Lightning payment succeeded. Do not send it again.', result.payment_hash);
  if (result.payment_hash) { $('ln-identifier').value = result.payment_hash; $('ln-direction').value = 'sends'; }
  $('ln-destination').value = ''; $('ln-amount').value = '';
  status('Payment submitted. Check its status before making another payment.');
}); };
let receiveDraftVersion = 0;
function clearLightningInvoice() {
  const displayed = !!$('ln-invoice').textContent;
  $('ln-invoice').textContent = ''; $('ln-copy').hidden = true;
  PaperclipReceive.clear('ln-invoice');
  if ($('payment-summary').dataset.source === 'receive-invoice') {
    $('payment-summary').replaceChildren(); $('payment-summary').hidden = true;
    $('payment-summary').dataset.source = '';
  }
  return displayed;
}
for (const id of ['ln-receive-amount', 'ln-description']) $(id).addEventListener('input', () => {
  receiveDraftVersion++;
  if (clearLightningInvoice()) status('Receive details changed. Create a new invoice for these details.');
});
$('ln-receive').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  if (!lightningEnabled) throw new Error('Lightning is not enabled in this wallet recovery profile.');
  const context = walletContext(), version = receiveDraftVersion;
  const amount = sats('ln-receive-amount'), enteredAmount = $('ln-receive-amount').value;
  const description = $('ln-description').value.trim();
  clearLightningInvoice();
  const result = await mutate('lightning/receives/invoice', {
    amount_sat: amount, description: description || null, token: null
  });
  if (!token || !currentWallet(context) || $('wallet').hidden) return;
  // Preserve the issued invoice for read-only status checks, even when the
  // draft changed. Never automatically request a replacement or share stale QR.
  $('ln-identifier').value = result.invoice; $('ln-direction').value = 'receives';
  if (version !== receiveDraftVersion || enteredAmount !== $('ln-receive-amount').value || description !== $('ln-description').value.trim()) {
    throw new Error('Receive details changed. Create a new invoice for these details. The earlier invoice remains available in payment lookup.');
  }
  $('ln-invoice').textContent = result.invoice; $('ln-copy').hidden = true;
  PaperclipReceive.show('ln-invoice', result.invoice, 'Receive ' + amount.toLocaleString() + ' sats into Ark');
  paymentSummary('Awaiting payment', 'Share this invoice. Keep the wallet online until settlement completes.', 'receive-invoice');
  status('Invoice created. A payment is not settled until the wallet reports completion.');
}); };
$('ln-check').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  const identifier = $('ln-identifier').value.trim(), direction = $('ln-direction').value;
  if (!identifier || !['sends', 'receives'].includes(direction)) throw new Error('Choose a payment and direction.');
  const checkedSession = token;
  const result = await api('lightning/' + direction + '/' + encodeURIComponent(identifier));
  if (!token || token !== checkedSession || $('wallet').hidden || identifier !== $('ln-identifier').value.trim() || direction !== $('ln-direction').value) return;
  $('ln-result').textContent = JSON.stringify(result, null, 2);
  const state = typeof result.state === 'string' ? result.state : 'See details';
  const descriptions = {paid: 'Payment completed.', settled: 'Payment received.', 'start': 'Preparing payment.', 'htlc-received': 'Preparing the Lightning payment.', 'payment-initiated': 'Payment is in progress. Do not send it again.', 'revocable-htlcs': 'Payment did not complete. Recovering the reserved funds.', 'revocation-stuck': 'Payment recovery needs attention. Check recovery status before retrying.', 'awaiting-reimbursement': 'Waiting for the payment refund.', 'awaiting-payment': 'Waiting for someone to pay this invoice.', 'htlcs-ready': 'Receiving payment.', 'preimage-revealed': 'Finishing payment settlement.', delivering: 'Delivering the received funds.', pending: 'Payment is still in progress. Do not send it again.', succeeded: 'Your wallet reports this payment completed.', completed: 'Your wallet reports this payment completed.', failed: 'Payment failed. Check any refund or recovery status before retrying.', expired: 'The invoice expired. Check activity for a payment or refund before creating another.', unknown: 'The payment outcome is not confirmed. Check activity and the recipient before retrying.'};
  paymentSummary(state, descriptions[state] || 'Status from your wallet. Check the technical details before retrying; an unfamiliar status does not mean payment failed.');
  if (['paid', 'settled', 'succeeded', 'completed'].includes(state)) transactionResult('success', 'Transaction succeeded', 'Your wallet confirms this Lightning payment completed.', result.payment_hash || '');
  else if (state === 'failed') transactionResult('failed', 'Transaction failed', 'Your wallet reports a failed payment. Check refund or recovery status before trying again.', result.payment_hash || '');
  else transactionResult(state === 'unknown' ? 'unknown' : 'pending', state === 'unknown' ? 'Result not confirmed' : 'Payment not complete', descriptions[state] || 'Check payment status again before trying another payment.');
  status('Payment status updated.');
}); };
$('history-load').onclick = event => run(event.target, async () => {
  if (globalThis.PaperclipAccounts?.selectedId) return globalThis.PaperclipAccounts.refresh();
  const context = walletContext();
  $('activity-summary').textContent = 'Updating activity\u2026';
  const results = await Promise.allSettled([
    api('history'), api('onchain/transactions'), api('lightning/receives')
  ]);
  if (!token || !currentWallet(context) || $('wallet').hidden) return;
  const [ark, onchain, receives] = results.map(result => result.status === 'fulfilled' ? result.value : null);
  $('history').textContent = JSON.stringify({ark, onchain, lightning_receives: receives}, null, 2);
  const complete = renderActivity(ark, onchain);
  if (document.querySelector?.('[data-screen="activity"]')?.hidden !== true) status(!complete || results.some(result => result.status === 'rejected') ? 'Some activity is unavailable. This does not mean a payment failed.' : 'Activity updated.');
});
const lockSession = $('lock').onclick;
$('lock').onclick = () => {
  lockSession();
  $('transaction-result').close();
  $('transaction-result-reference').textContent = ''; $('transaction-result-detail').textContent = '';
  $('wallet-readiness').hidden = true;
  $('ark-estimate').hidden = true; $('ark-estimate-values').textContent = '';
  lightningEnabled = false; $('ln-controls').disabled = true;
  for (const id of ['ln-offer-output', 'ln-invoice', 'ln-result', 'chain-result', 'history', 'ark-balance', 'chain-balance']) $(id).textContent = '';
  for (const id of ['offer-description', 'offer-amount', 'ln-destination', 'ln-amount', 'ln-receive-amount', 'ln-description', 'ln-identifier', 'chain-destination', 'chain-amount']) $(id).value = '';
  $('chain-max').checked=false;$('chain-max').onchange();
  $('ark-max').checked=false;$('ark-max').onchange();
};
$('deposit').onclick = event => run(event.target, async () => {
  const receiveSession = token;
  const result = await api('onchain/addresses/next', {});
  if (!token || token !== receiveSession || $('wallet').hidden) return;
  $('deposit-address').textContent = result.address;
  PaperclipReceive.show('deposit-address', result.address, 'Receive on-chain XBT');
  status('Deposit address for ' + (network === 'bitcoin' ? 'XBT mainnet' : 'regtest') + '.');
});
$('board').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  const amount = sats('board-amount');
  if (amount < 20000) throw new Error('Enter at least 20,000 whole sats.');
  const context = walletContext();
  const quote = await api('boards/prepare', {amount_sat: amount});
  const unchanged = () => currentWallet(context) && token && sats('board-amount') === amount;
  if (!unchanged()) throw new Error('Wallet or boarding amount changed. Review again.');
  const fields = ['board_amount_sat', 'total_sat', 'net_sat', 'reserve_sat', 'network_fee_sat', 'boarding_fee_sat', 'recovery_anchor_sat', 'recovery_miner_fee_sat'];
  if (!quote || fields.some(key => !Number.isSafeInteger(quote[key]) || quote[key] < 0) ||
      !/^[0-9a-f]{64}$/.test(quote.request_id) || quote.board_amount_sat !== amount || quote.net_sat <= 0 ||
      quote.total_sat !== amount + quote.network_fee_sat || quote.net_sat + quote.reserve_sat !== amount ||
      quote.reserve_sat !== quote.recovery_anchor_sat + quote.recovery_miner_fee_sat || quote.recovery_anchor_sat < quote.boarding_fee_sat) {
    throw new Error('Could not verify the complete boarding cost. Nothing was submitted.');
  }
  if (!await PaperclipReview.ask('Move on-chain XBT into Ark on ' + network + '?\n\n' +
      'Available in Ark after confirmation: ' + quote.net_sat.toLocaleString() + ' sats\n' +
      'Recovery reserve: ' + quote.reserve_sat.toLocaleString() + ' sats\n' +
      'Boarding fee included in reserve: ' + quote.boarding_fee_sat.toLocaleString() + ' sats\n' +
      'Network fee: ' + quote.network_fee_sat.toLocaleString() + ' sats\n' +
      'Total debit: ' + quote.total_sat.toLocaleString() + ' sats\n\nKeep a complete backup. Boarding needs confirmations before the Ark funds become spendable.')) return;
  if (!unchanged()) throw new Error('Wallet or boarding amount changed. Review again.');
  const result = await mutate('boards/commit', {request_id: quote.request_id, amount_sat: amount, total_sat: quote.total_sat});
  if (!currentWallet(context)) return;
  transactionResult('pending', 'Boarding submitted', 'Waiting for funding confirmations. Do not submit another board for this transfer.', result.txid || '');
  await update(); status('Boarding submitted. Wait for confirmations; do not submit again.');
}); };
$('withdraw').onclick = event => run(event.target, async () => {
  const context = walletContext();
  const quote = await api('withdrawals/prepare', {});
  const unchanged = () => currentWallet(context) && token && !$('wallet').hidden;
  if (!unchanged()) return;
  if (!quote || !/^[0-9a-f]{64}$/.test(quote.request_id) || typeof quote.destination !== 'string' ||
      !quote.destination || quote.destination.length > 128 ||
      ['net_sat','fee_sat','total_sat','input_count'].some(key => !Number.isSafeInteger(quote[key]) || quote[key] < 0) ||
      quote.net_sat <= 0 || quote.input_count <= 0 || quote.net_sat + quote.fee_sat !== quote.total_sat) {
    throw new Error('Could not verify the withdrawal amount and fees. Nothing was submitted.');
  }
  if (!await PaperclipReview.withdrawal(quote)) return;
  if (!unchanged()) throw new Error('Wallet changed. Review the withdrawal again.');
  const result = await mutate('withdrawals/commit', {request_id:quote.request_id, net_sat:quote.net_sat, total_sat:quote.total_sat});
  if (!unchanged()) return;
  transactionResult('pending', 'Withdrawal submitted', 'Waiting for on-chain confirmation. Check Activity before trying again.', result.txid || '');
  await update(); status('Withdrawal submitted. Waiting for on-chain confirmation.');
});
$('exit-start').onclick = event => run(event.target, async () => {
  if (!await PaperclipReview.ask('Start emergency recovery of all Ark funds? This requires on-chain fees and a timelock. Continue only after backing up your complete wallet.')) return;
  await mutate('exits/start/all', {}); await update(); status('Exit started. Progress recovery until funds are claimable.');
});
$('exit-progress').onclick = event => run(event.target, async () => {
  await mutate('exits/progress', {wait: false}); await update(); status('Recovery progress updated.');
});
$('exit-claim').onclick = event => run(event.target, async () => {
  if (!await PaperclipReview.ask('Claim all matured exits to your on-chain wallet? Miner fees apply.')) return;
  const address = await api('onchain/addresses/next', {});
  await mutate('exits/claim/all', {destination: address.address}); await update(); status('Claim submitted. Wait for confirmation.');
});

function paymentSummary(title, detail, source = '') {
  const box = $('payment-summary'); box.hidden = false;
  box.dataset.source = source;
  box.textContent = title.replaceAll('_', ' ') + ' \u2014 ' + detail;
}
$('ln-copy').onclick = event => run(event.target, async () => {
  await navigator.clipboard.writeText($('ln-invoice').textContent); status('Invoice copied.');
});
function renderActivity(records, onchain = []) { return PaperclipActivity.set(records, onchain); }
PaperclipActivity.init();
const reviewLock = $('lock').onclick;
$('lock').onclick = () => { reviewLock(); PaperclipReceive.clear(); PaperclipActivity.reset(); $('activity-list').replaceChildren(); $('activity-summary').textContent = ''; $('payment-summary').textContent = ''; $('payment-summary').hidden = true; $('ln-copy').hidden = true; };

// A session belongs to one browser tab. Never save keys or RPC credentials here.
function sessionRead(key) { try { return sessionStorage.getItem(key); } catch { return null; } }
function sessionWrite(key, value) { try { if (value === null) sessionStorage.removeItem(key); else sessionStorage.setItem(key, value); } catch {} }
function passwordToggle(buttonId, inputId) {
  $(buttonId).onclick = () => { const shown = $(inputId).type === 'password'; $(inputId).type = shown ? 'text' : 'password'; $(buttonId).setAttribute('aria-pressed', String(shown)); $(buttonId).textContent = buttonId === 'show-token' ? (shown ? 'Hide' : 'Show') : (shown ? 'Hide password' : 'Show password'); };
}
passwordToggle('show-token', 'token'); passwordToggle('show-rpc-password', 'setup-password');
$('remember-session').onchange = () => { if (!$('remember-session').checked) sessionWrite('paperclip.session', null); };
const sessionLock = $('lock').onclick;
$('lock').onclick = () => { sessionWrite('paperclip.session', null); sessionLock(); $('token').type = 'password'; $('show-token').textContent = 'Show'; $('show-token').setAttribute('aria-pressed', 'false'); };
const sessionSetupLock = $('setup-lock').onclick;
$('setup-lock').onclick = () => { sessionWrite('paperclip.session', null); sessionSetupLock(); };
$('submission-reviewed').onclick = event => run(event.target, async () => {
  if (submissionJournal) { await syncSubmissions(true); return; }
  if (!await PaperclipReview.ask('Have you checked Activity and the payment status? Continue only after resolving the previous submission. A pending payment must not be sent again.')) return;
  uncertainMutation = false; sessionWrite(uncertainKey(), null); $('submission-warning').hidden = true;
  status('Previous result acknowledged. No payment has been resubmitted.');
});
let refreshing = false;
setInterval(async () => {
  if (!token || !network || $('wallet').hidden || document.hidden || refreshing || Date.now() < nextAutomaticUpdate) return;
  refreshing = true;
  try { const complete = await update(); if (token && !$('wallet').hidden) $('refresh-state').textContent = complete ? 'Updated ' + new Date().toLocaleTimeString() : 'Some data unavailable'; }
  catch { $('refresh-state').textContent = 'Update unavailable \u00b7 retry with Update'; }
  finally { refreshing = false; }
}, 30000);
window.addEventListener('DOMContentLoaded', async () => {
  if (globalThis.PaperclipDesktopHandoff?.pending) {
    sessionWrite('paperclip.session', null);
    $('remember-session').checked = false;
    const controls = Array.from($('unlock').elements);
    controls.forEach(control => { control.disabled = true; });
    status('Opening your desktop wallet\u2026');
    try { await unlockWallet(await PaperclipDesktopHandoff.redeem()); }
    catch {
      token = ''; network = null;
      status('Desktop sign-in expired or was interrupted. Open the wallet again from the desktop app.');
    } finally { controls.forEach(control => { control.disabled = false; }); }
    return;
  }
  const saved = sessionRead('paperclip.session'); if (!saved) return;
  token = saved; $('remember-session').checked = true;
  status('Restoring this tab\u2019s wallet session\u2026');
  try { await unlockWallet(saved); }
  catch (error) { token = ''; network = null; sessionWrite('paperclip.session', null); status(error.message || 'Unlock again to reconnect. Your wallet data is unchanged.'); }
}, {once:true});

let vtxoSnapshot = {balance: {}, rows: [], tip: null};
let vtxoRenderKey = '';
function vtxoNode(tag, text, className) {
  const node = document.createElement(tag); node.textContent = text;
  if (className) node.className = className;
  return node;
}
function renderPendingBoards(boards) {
  const list = $('pending-boards'); list.replaceChildren();
  if (!Array.isArray(boards) || boards.some(board => !Number.isSafeInteger(board.amount_sat) || board.amount_sat < 0 || !/^[0-9a-f]{64}$/.test(board.funding_tx?.txid))) {
    list.append(vtxoNode('p', 'Pending transfers are unavailable. Check the saved submission and funding transaction before trying again.', 'hint')); return;
  }
  if (!boards.length) {
    list.append(vtxoNode('p', 'No pending boarding records. This does not establish the outcome of an uncertain submission; check its saved status and Activity.', 'hint')); return;
  }
  for (const board of boards) {
    const card = vtxoNode('article', '', 'vtxo-card');
    card.append(vtxoNode('strong', board.amount_sat.toLocaleString() + ' sats'),
      vtxoNode('p', 'Awaiting confirmation or Ark registration', 'hint'));
    const details = vtxoNode('details', '');
    details.append(vtxoNode('summary', 'Funding transaction'), vtxoNode('code', board.funding_tx.txid));
    card.append(details); list.append(card);
  }
}
function renderVtxos() {
  const {balance, rows, tip} = vtxoSnapshot;
  const nextKey = JSON.stringify([vtxoSnapshot, $('vtxo-filter').value]);
  if (nextKey === vtxoRenderKey) return;
  vtxoRenderKey = nextKey;
  const openIds = new Set(Array.from($('vtxo-list').querySelectorAll?.('details[open]') || [], d => d.dataset.vtxoId));
  const summary = $('vtxo-summary'); summary.replaceChildren();
  const count = rows.length;
  const locked = rows.filter(r => r.state?.type === 'locked').reduce((sum,r) => sum + (Number.isSafeInteger(r.amount_sat) ? r.amount_sat : 0),0);
  for (const [label,value] of [['Spendable',balance.spendable_sat],['Needs refresh',balance.needs_refresh_sat],['Locked',locked]]) {
    const card = vtxoNode('article','');
    card.append(vtxoNode('span',label),vtxoNode('strong',Number.isSafeInteger(value) && value >= 0 ? value.toLocaleString()+' sats' : 'Unavailable')); summary.append(card);
  }
  $('vtxo-tip').textContent = tip === null ? 'Chain height unavailable. Expiry blocks are shown without a countdown.' : 'Chain height '+tip.toLocaleString()+' \u00b7 '+count+' current VTXOs. Expiry is measured in blocks, not a guaranteed time.';
  const list = $('vtxo-list'); list.replaceChildren();
  const filter = $('vtxo-filter').value || 'all';
  const shown = rows.filter(r => filter === 'all' || r.state?.type === filter).sort((a,b) => (a.expiry_height ?? Infinity)-(b.expiry_height ?? Infinity));
  if (!shown.length) { list.append(vtxoNode('p',count ? 'No VTXOs match this filter.' : 'No current VTXOs. Board funds or receive an Ark payment to get started.','empty-state')); return; }
  for (const row of shown) {
    const remaining = tip !== null && Number.isSafeInteger(row.expiry_height) ? row.expiry_height-tip : null;
    const card = vtxoNode('article','','vtxo-card'+(remaining !== null && remaining <=144 ? ' attention' : ''));
    const top = vtxoNode('div','','vtxo-card-top');
    top.append(vtxoNode('strong',Number.isSafeInteger(row.amount_sat) ? row.amount_sat.toLocaleString()+' sats' : 'Amount unavailable'),vtxoNode('span',row.state?.type || 'Unknown','state-pill'));
    const expiry = remaining === null ? 'Countdown unavailable' : remaining <=0 ? 'Expiry reached: review recovery immediately' : remaining.toLocaleString()+' blocks until expiry';
    card.append(top,vtxoNode('p',expiry,'expiry-label'),vtxoNode('p','Expires at block '+(Number.isSafeInteger(row.expiry_height)?row.expiry_height.toLocaleString():'unknown'),'hint'));
    if (remaining !== null && remaining >0 && remaining <=144) card.append(vtxoNode('p','Expiry is approaching. Check refresh and recovery status.','hint'));
    const details = vtxoNode('details',''); details.dataset.vtxoId = String(row.id); details.open = openIds.has(String(row.id)); details.append(vtxoNode('summary','VTXO details'),vtxoNode('pre',JSON.stringify({id:row.id,policy:row.policy_type,exit_delay_blocks:row.exit_delta,exit_depth:row.exit_depth,chain_anchor:row.chain_anchor,state:row.state},null,2)));
    card.append(details);list.append(card);
  }
}
$('vtxo-filter').onchange = renderVtxos;
$('vtxo-update').onclick = event => run(event.target,async()=>{await update();status('VTXOs updated.');});
const vtxoLock = $('lock').onclick;
$('lock').onclick = () => { vtxoLock();vtxoRenderKey='';vtxoSnapshot={balance:{},rows:[],tip:null};$('vtxo-list').replaceChildren();$('vtxo-summary').replaceChildren();$('vtxo-tip').textContent='';$('pending-boards').replaceChildren(); };

function showOffer(offer) {
  $('offer-state').textContent = offer?.active ? 'Enabled while wallet service is online' : 'Disabled';
  $('offer-disable').hidden = !offer?.active;
  $('ln-offer-output').textContent = offer?.offer || 'No reusable offer yet.';
  if (offer?.active) PaperclipReceive.show('ln-offer-output', offer.offer, 'Reusable XBT Lightning offer');
}

let messageProof = null;
function clearMessageProof() {
  messageProof = null; $('message-proof').hidden = true;
  $('message-signature').textContent = ''; $('message-verification').textContent = '';
}
function messageInput() {
  return {address: $('message-address').value.trim(), message: $('message-text').value};
}
$('message-address').oninput = clearMessageProof;
$('message-text').oninput = clearMessageProof;
$('message-verify-signature').oninput = () => { $('message-verification').textContent = ''; };
$('onchain-message').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  clearMessageProof();
  const input = messageInput(), session = token;
  if (!await PaperclipReview.ask('Sign this exact message for ' + input.address + '?\n\n' + input.message + '\n\nThis proves address ownership. No funds will move.')) return;
  const proof = await api('onchain/message/sign', input);
  if (!token || token !== session || JSON.stringify(input) !== JSON.stringify(messageInput())) return;
  if (proof.scheme !== 'bip322-simple' || proof.message !== input.message || proof.address?.toLowerCase() !== input.address.toLowerCase() || typeof proof.signature !== 'string' || !proof.signature.startsWith('smp')) throw new Error('Unexpected message proof response.');
  messageProof = proof;
  $('message-signature').textContent = proof.signature; $('message-proof').hidden = false;
  status('Message signed. Share the exact message, address, and signature with the verifier.');
}); };
$('message-copy').onclick = event => run(event.target, async () => {
  if (!messageProof || !token) throw new Error('Sign a message first.');
  await PaperclipReceive.copy(messageProof.signature);
  status('Signature copied.');
});
$('message-verify').onclick = event => run(event.target, async () => {
  const input = {...messageInput(), signature: $('message-verify-signature').value.trim()}, session = token;
  $('message-verification').textContent = '';
  const result = await api('onchain/message/verify', input);
  if (!token || token !== session || input.address !== messageInput().address || input.message !== messageInput().message || input.signature !== $('message-verify-signature').value.trim()) return;
  $('message-verification').textContent = result.valid ? 'Valid: this signature proves control of the address for the exact message.' : 'Invalid: the address, message, and signature do not match.';
});
const messageLock = $('lock').onclick;
$('lock').onclick = () => {
  messageLock(); clearMessageProof();
  $('message-address').value = ''; $('message-text').value = ''; $('message-verify-signature').value = '';
};
$('ln-offer').onsubmit = event => { event.preventDefault(); run(event.submitter, async () => {
  if (!lightningEnabled) throw new Error('Lightning is not enabled in this wallet recovery profile.');
  const session = token;
  const offer = await mutate('lightning/offers', {description: $('offer-description').value.trim(), amount_sat: sats('offer-amount', true)});
  if (!token || token !== session || $('wallet').hidden) return;
  showOffer(offer); status('Reusable offer saved. Keep the wallet service online to receive.');
}); };
$('offer-load').onclick = event => run(event.target, async () => {
  const session = token, offer = await api('lightning/offers');
  if (!token || token !== session || $('wallet').hidden) return;
  showOffer(offer);
});
$('offer-disable').onclick = event => run(event.target, async () => {
  if (!await PaperclipReview.ask('Disable this offer for new requests? Payments already in progress will remain tracked.')) return;
  const session = token;
  await api('lightning/offers', undefined, 'DELETE');
  if (!token || token !== session || $('wallet').hidden) return;
  PaperclipReceive.clear(); showOffer(null); status('Offer disabled. Existing payments remain tracked.');
});
