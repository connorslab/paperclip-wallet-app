'use strict';
(() => {
  let authorization = null, jars = [], session = null, selected = 0, busy = false, generation = 0, needsRefresh = false;
  const panel = document.querySelector('[data-screen="coinjoin"]');
  const colors = ['#ff9e54', '#7aabff', '#ff777b', '#ca9a75', '#bf98f4'];
  const amount = value => Number.isSafeInteger(value) && value >= 0 ? value.toLocaleString() + ' sats' : 'Unavailable';
  async function call(operation, fields = {}) {
    const identity = token, ticket = generation;
    const result = await api('joinblaket/request', {operation, ...authorization, ...fields});
    if (!token || token !== identity || ticket !== generation) throw new Error('Wallet session ended.');
    return result;
  }
  // Only the filename survives reloads. Passwords, tokens and recovery words
  // remain in memory; sensitive results arriving after hiding are discarded.
  let pendingSetup = sessionRead('paperclip.jars.setup') || '', backupWallet = '', backupWords = [], backupTicket = 0, creationRetry = false;
  const backupDialog = $('jam-backup-dialog');
  function clearBackup() {
    backupTicket++; backupWords = [];
    $('jam-backup-password').value = ''; $('jam-backup-passphrase').value = '';
    $('jam-backup-words').replaceChildren(); $('jam-backup-challenges').replaceChildren();
    $('jam-backup-words-step').hidden = true; $('jam-backup-verify-step').hidden = true;
    $('jam-backup-auth').hidden = false; $('jam-backup-status').textContent = '';
    $('jam-backup-finish').disabled = true;
  }
  function closeBackup() { clearBackup(); backupDialog.close(); }
  function openBackup(wallet) {
    if (!wallet) throw new Error('Select the Jam wallet to back up.');
    clearBackup(); backupWallet = wallet;
    $('jam-backup-wallet').textContent = 'Jars wallet: ' + wallet;
    backupDialog.showModal(); $('jam-backup-password').focus();
  }
  function pendingWallet(wallet) {
    pendingSetup = wallet; creationRetry = false; sessionWrite('paperclip.jars.setup', wallet || null);
    $('jam-setup-pending').hidden = !wallet;
    $('jam-setup-pending-detail').textContent = wallet ? 'Finish backing up ' + wallet + ' before adding funds.' : '';
  }
  pendingWallet(pendingSetup);
  $('jam-create').onclick = () => work(async () => {
    if (pendingSetup && !creationRetry) throw new Error('Finish the existing Jars wallet backup first.');
    const name = $('jam-create-name').value.trim(), password = $('jam-create-password').value;
    if (!/^[A-Za-z0-9_-]{1,48}$/.test(name)) throw new Error('Use 1 to 48 letters, numbers, hyphens or underscores for the wallet name.');
    if ([...password].length < 12 || !password.trim() || password !== $('jam-create-confirm').value) throw new Error('Use at least 12 characters and matching passwords.');
    const wallet = name + '.jmdat';
    if (pendingSetup && wallet !== pendingSetup) throw new Error('Check the same wallet after an interrupted creation.');
    const ticket = backupTicket;
    const config = await api('joinblaket/connection');
    if (!config.configured) throw new Error('Enable the bundled JoinBlaket service in your Paperclip host settings first.');
    if (ticket !== backupTicket || document.hidden || panel.hidden) return;
    if (!await PaperclipReview.ask('Create ' + wallet + ' on your connected JoinBlaket server? It has separate keys and five jars. Back up its recovery words before adding funds. No funds will move.')) return;
    if (ticket !== backupTicket || document.hidden || panel.hidden) return;
    $('jam-create-password').value = ''; $('jam-create-confirm').value = '';
    pendingWallet(wallet); // Set before submission, including lost responses.
    try {
      const result = await call('create_wallet', {wallet,password});
      if (ticket !== backupTicket || document.hidden || panel.hidden) return;
      if (result.walletname !== wallet || typeof result.token !== 'string' || !result.token) throw new Error('Invalid Jam creation response.');
      authorization = {wallet,token:result.token}; $('jam-create-panel').open = false;
      openBackup(wallet);
    } catch (error) {
      throw new Error('Creation may have finished. Find and unlock ' + wallet + ', or resume its backup. Check that same wallet before retrying.');
    }
  });
  $('jam-setup-check').onclick = () => work(async () => {
    const wallet = pendingSetup;
    if (!wallet) return;
    const result = await call('wallets');
    if (!Array.isArray(result.wallets) || result.wallets.some(name => typeof name !== 'string')) throw new Error('Could not check Jam wallets.');
    if (pendingSetup !== wallet) return;
    if (result.wallets.includes(wallet)) { openBackup(wallet); return; }
    creationRetry = true;
    $('jam-create-name').value = wallet.replace(/\.jmdat$/, ''); $('jam-create-panel').open = true;
    $('jam-setup-pending-detail').textContent = wallet + ' is not listed. You may review a retry with the same name. An existing wallet will never be overwritten.';
  });
  $('jam-setup-resume').onclick = () => { if (!busy) openBackup(pendingSetup); };
  $('jam-backup-open').onclick = () => { if (!busy) openBackup(authorization?.wallet); };
  $('jam-backup-close').onclick = closeBackup;
  backupDialog.addEventListener('cancel', event => { event.preventDefault(); closeBackup(); });
  backupDialog.addEventListener('close', () => { if (!backupDialog.open) clearBackup(); });
  $('jam-backup-reveal').onclick = async () => {
    if (busy) return;
    const wallet = backupWallet, password = $('jam-backup-password').value, bip39_passphrase = $('jam-backup-passphrase').value;
    const ticket = backupTicket;
    $('jam-backup-password').value = ''; $('jam-backup-passphrase').value = '';
    if (!password) { $('jam-backup-status').textContent = 'Enter this Jam wallet’s password.'; return; }
    busy = true; render(); $('jam-backup-status').textContent = 'Verifying wallet…';
    try {
      const result = await call('backup_wallet', {wallet,password,bip39_passphrase});
      if (ticket !== backupTicket || !backupDialog.open || document.hidden || panel.hidden) return;
      const words = typeof result.seedphrase === 'string' ? result.seedphrase.trim().split(/\s+/) : [];
      if (result.walletname !== wallet || typeof result.token !== 'string' || !result.token || ![12,15,18,21,24].includes(words.length) || words.some(word => !/^[a-z]+$/.test(word))) throw new Error('Could not validate the Jam backup.');
      authorization = {wallet,token:result.token}; backupWords = words;
      $('jam-backup-auth').hidden = true; $('jam-backup-words-step').hidden = false;
      for (const word of words) { const item = document.createElement('li'); item.textContent = word; $('jam-backup-words').append(item); }
      $('jam-backup-status').textContent = '';
    } catch (error) {
      if (ticket === backupTicket && backupDialog.open) $('jam-backup-status').textContent = 'Could not read the backup. Check the Jam wallet password, passphrase and server connection.';
    } finally { busy = false; render(); }
  };
  $('jam-backup-next').onclick = () => {
    if (!backupWords.length) return;
    $('jam-backup-words').replaceChildren(); $('jam-backup-words-step').hidden = true;
    $('jam-backup-verify-step').hidden = false;
    const positions = [0, Math.floor(backupWords.length / 2), backupWords.length - 1];
    for (const index of positions) {
      const label = document.createElement('label'), input = document.createElement('input');
      label.textContent = 'Word ' + (index + 1); input.type = 'password'; input.autocomplete = 'off'; input.spellcheck = false;
      input.setAttribute('autocapitalize','none'); input.dataset.position = String(index);
      label.append(input); $('jam-backup-challenges').append(label);
      input.oninput = () => { $('jam-backup-finish').disabled = busy || [...$('jam-backup-challenges').querySelectorAll('input')].some(field => field.value.trim().toLowerCase() !== backupWords[Number(field.dataset.position)]); };
    }
    $('jam-backup-challenges').querySelector('input')?.focus();
  };
  $('jam-backup-finish').onclick = () => work(async () => {
    const fields = [...$('jam-backup-challenges').querySelectorAll('input')];
    if (!backupWords.length || fields.length !== 3 || fields.some(field => field.value.trim().toLowerCase() !== backupWords[Number(field.dataset.position)])) throw new Error('Check the words in your written backup.');
    if (pendingSetup === backupWallet) pendingWallet('');
    closeBackup(); await refresh();
  });
  function hideSetupSecrets() { closeBackup(); $('jam-create-password').value = ''; $('jam-create-confirm').value = ''; }
  document.addEventListener('visibilitychange', () => { if (document.hidden) hideSetupSecrets(); });
  window.addEventListener('pagehide', hideSetupSecrets);
  new MutationObserver(() => { if (panel.hidden) hideSetupSecrets(); }).observe(panel, {attributes:true, attributeFilter:['hidden']});
  let pairingCode = '', pairingQR = null;
  function clearPairingCode() {
    pairingCode = ''; $('jam-pairing-code').hidden = true; $('jam-pairing-qr').removeAttribute('src');
    if (pairingQR) URL.revokeObjectURL(pairingQR); pairingQR = null;
  }
  async function pairingCall(path, body) {
    const identity = token, ticket = generation, wallet = authorization?.wallet;
    const value = await api(path, body);
    if (!token || token !== identity || ticket !== generation || wallet !== authorization?.wallet) throw new Error('Jars session changed.');
    return value;
  }
  async function loadPairings() {
    const value = await pairingCall('joinblaket/pairings'), root = $('jam-pairing-list');
    if (!Array.isArray(value.pairings) || value.pairings.length > 16) throw new Error('Could not read paired devices.');
    root.replaceChildren();
    if (!value.pairings.length) { root.textContent = 'No paired devices.'; return; }
    for (const row of value.pairings) {
      if (typeof row.id !== 'string' || !/^[0-9a-f]{64}$/.test(row.id) || typeof row.label !== 'string' || typeof row.wallet !== 'string' || !Number.isSafeInteger(row.expires)) throw new Error('Invalid paired-device record.');
      const card = document.createElement('div'); card.className = 'action-card';
      const label = document.createElement('strong'); label.textContent = row.label;
      const detail = document.createElement('p'); detail.className = 'hint'; detail.textContent = row.wallet + ' · Expires ' + new Date(row.expires*1000).toLocaleDateString();
      const revoke = document.createElement('button'); revoke.className = 'secondary'; revoke.textContent = 'Revoke access';
      revoke.onclick = () => work(async () => {
        if (!await window.PaperclipReview.ask('Revoke Jars access for '+row.label+'? This stops new requests from that pairing.')) return;
        await pairingCall('joinblaket/pairings/revoke', {id:row.id}); clearPairingCode(); await loadPairings();
      });
      card.append(label,detail,revoke); root.append(card);
    }
  }
  $('jam-pairing-endpoint').value = location.origin;
  $('jam-pairing-create').onclick = () => work(async () => {
    clearPairingCode();
    const endpoint = new URL($('jam-pairing-endpoint').value.trim()), pin = $('jam-pairing-pin').value.trim().toLowerCase(), label = $('jam-pairing-label').value.trim();
    if (!label || [...label].length > 48 || /[\x00-\x1f\x7f]/.test(label)) throw new Error('Name this device using 1 to 48 characters.');
    if (!(endpoint.protocol === 'https:' || (endpoint.protocol === 'http:' && endpoint.hostname.endsWith('.onion'))) || endpoint.username || endpoint.password || endpoint.search || endpoint.hash || (pin && (!/^[0-9a-f]{64}$/.test(pin) || endpoint.protocol !== 'https:'))) throw new Error('Use the Paperclip HTTPS address or its onion address, with a verified certificate fingerprint if needed.');
    if (!await window.PaperclipReview.ask('Pair a phone with '+authorization.wallet+' through '+endpoint.href+'? The code grants Jars receiving, maker controls and status access for up to 30 days. Keep it private.')) return;
    const wallet = authorization.wallet;
    const value = await pairingCall('joinblaket/pairings', {label,wallet,token:authorization.token});
    if (value.wallet !== wallet || value.scope !== 'jars_manage_v1' || typeof value.token !== 'string' || !/^pj1_[0-9a-f]{64}$/.test(value.token) || !Number.isSafeInteger(value.expires) || value.expires*1000 <= Date.now()) throw new Error('Invalid pairing response. Check paired devices before creating another.');
    const payload = JSON.stringify({kind:'paperclip-jars-v1',scope:value.scope,endpoint:endpoint.href,wallet,token:value.token,expires:value.expires,certificate_sha256:pin});
    pairingCode = 'paperclip-jars:'+btoa(String.fromCharCode(...new TextEncoder().encode(payload))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
    pairingQR = URL.createObjectURL(new Blob([PaperclipReceive.encode(pairingCode)], {type:'image/svg+xml'}));
    $('jam-pairing-qr').src = pairingQR; $('jam-pairing-code').hidden = false;
    await loadPairings();
  });
  $('jam-pairing-copy').onclick = () => work(async () => { if (pairingCode) { await PaperclipReceive.copy(pairingCode); $('jam-status').textContent = 'Private pairing code copied.'; } });
  $('jam-pairing-hide').onclick = clearPairingCode;
  $('jam-pairing-load').onclick = () => work(loadPairings);
  $('jam-pairing-panel').addEventListener('toggle', () => { if (!$('jam-pairing-panel').open) clearPairingCode(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) clearPairingCode(); });
  new MutationObserver(() => { if (panel.hidden) clearPairingCode(); }).observe(panel, {attributes:true, attributeFilter:['hidden']});
  let payments = null;
  function paymentRecord(value, expectedID) {
    const hex = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
    if (!value || !hex(value.id) || (expectedID && value.id !== expectedID) ||
        !['preparing','prepared','submitting','unknown','submitted','cancelled'].includes(value.state)) throw new Error('Invalid saved Jam payment.');
    const q = value.quote;
    if (q == null) {
      if (!['preparing','cancelled'].includes(value.state)) throw new Error('Missing saved Jam payment details.');
    } else if (q.wallet !== authorization?.wallet || !Number.isInteger(q.jar) || q.jar < 0 || q.jar > 4 ||
      !['send','fund_bond','withdraw_bond'].includes(q.purpose) || !hex(q.txid) ||
      typeof q.destination !== 'string' || !/^[A-Za-z0-9]{14,90}$/.test(q.destination) ||
      ['amount_sat','fee_sat','total_sat'].some(key => !Number.isSafeInteger(q[key]) || q[key] < 0 || q[key] > 2100000000000000) ||
      q.amount_sat === 0 || q.amount_sat + q.fee_sat !== q.total_sat) throw new Error('Invalid saved Jam payment details.');
    return value;
  }
  function renderPayments() {
    const root = $('jam-payments'); root.replaceChildren();
    if (payments === null) return;
    if (!payments.length) { root.textContent = 'No saved Paperclip payments in this Jam wallet.'; return; }
    for (const payment of payments) {
      const card = document.createElement('article'); card.className = 'jam-payment';
      const heading = document.createElement('h3');
      heading.textContent = {preparing:'Review incomplete',prepared:'Review saved',
        submitting:'Status unknown',unknown:'Status unknown',
        submitted:'Submitted',cancelled:'Cancelled'}[payment.state];
      const top = document.createElement('div'); top.className = 'jam-payment-top';
      const icon = document.createElement('span'); icon.className = 'jam-payment-icon'; icon.textContent = '↗'; icon.setAttribute('aria-hidden','true');
      top.append(heading); card.append(top);
      if (payment.quote) {
        const q = payment.quote, summary = document.createElement('p'); summary.className = 'jam-payment-amount';
        summary.textContent = amount(q.amount_sat);
        const hero = document.createElement('div'); hero.className = 'payment-hero';
        const caption = document.createElement('p'); caption.textContent = {send:'Payment amount',fund_bond:'Bond funding',withdraw_bond:'Bond withdrawal'}[q.purpose];
        const subtitle = document.createElement('p'); subtitle.className = 'jam-payment-subtitle';
        subtitle.textContent = 'From Jar ' + (q.jar + 1);
        hero.append(icon, caption, summary, subtitle);
        const costs = document.createElement('dl'); costs.className = 'jam-payment-costs';
        for (const [label,value] of [['Mining fee',q.fee_sat],['Total debit',q.total_sat]]) {
          const cell = document.createElement('div'), term = document.createElement('dt'), total = document.createElement('dd');
          term.textContent = label; total.textContent = amount(value); cell.append(term,total); costs.append(cell);
        }
        const details = document.createElement('details'), title = document.createElement('summary'); title.textContent = 'Payment details'; details.append(title);
        for (const text of ['Destination: '+q.destination,'Transaction ID: '+q.txid]) {
          const line = document.createElement('p'); line.textContent = text; line.style.overflowWrap = 'anywhere'; details.append(line);
        }
        card.append(hero, costs, details);
      }
      if (['submitting','unknown'].includes(payment.state)) {
        const warning = document.createElement('p'); warning.textContent = 'This payment may have reached the network. Do not send it again.';
        const button = document.createElement('button'); button.textContent = 'Check status'; button.className = 'jam-payment-check';
        button.onclick = () => work(async () => {
          const updated = paymentRecord(await call('check_payment', {payment_id:payment.id}), payment.id);
          payments = payments.map(row => row.id === payment.id ? updated : row); renderPayments();
        });
        card.append(warning, button);
      } else {
        const note = document.createElement('p'); note.className = 'hint';
        note.textContent = payment.state === 'submitted' ? 'Seen by your node. Confirmation has not been checked.' : 'This review has not been sent.';
        card.append(note);
      }
      root.append(card);
    }
  }
  function clearAddress() { window.PaperclipReceive?.clear('jam-address'); $('jam-address').textContent = ''; }
  function clearBond() { window.PaperclipReceive?.clear('jam-bond-address'); $('jam-bond-address').textContent = ''; $('jam-bond-detail').textContent = ''; }
  function validateBondMonth(month) {
    const year = Number(month.slice(0,4)), number = Number(month.slice(5));
    if (!/^[0-9]{4}-[0-9]{2}$/.test(month) || year < 2020 || year > 2099 || number < 1 || number > 12 || Date.UTC(year,number-1,1) <= Date.now())
      throw new Error('Choose a future month before 2100. Bonds unlock on its first day at 00:00 UTC.');
  }
  function terms() {
    const rawMinimum = $('jam-minimum').value, rawFee = $('jam-fee').value;
    if (!/^\d+$/.test(rawMinimum) || !/^\d+$/.test(rawFee)) return null;
    const minimum = Number(rawMinimum), fee = Number(rawFee);
    return Number.isSafeInteger(minimum) && minimum >= 27300 && minimum <= 2100000000000000 &&
      Number.isSafeInteger(fee) && fee >= 0 && fee < minimum ? {minimum_sat: minimum, fee_sat: fee} : null;
  }
  function render() {
    const connected = !!session;
    $('jam-wallet-name').textContent = authorization?.wallet || '';
    $('jam-connect').hidden = connected; $('jam-dashboard').hidden = !connected; $('jam-refresh').hidden = !connected;
    const jarScroll = $('jam-jars').scrollLeft;
    const focusedJar = document.activeElement?.closest('.jam-jar')?.dataset.jar;
    $('jam-jars').replaceChildren(); $('jam-amounts').replaceChildren();
    for (const jar of jars) {
      const button = document.createElement('button'); button.type = 'button'; button.className = 'jam-jar';
      button.dataset.jar = String(jar.id);
      button.style.setProperty('--jar-color', colors[jar.id]); button.setAttribute('aria-pressed', String(jar.id === selected));
      const art = document.createElement('span'); art.className = 'jar-art' + (jar.total_sat > 0 ? ' funded' : ''); art.setAttribute('aria-hidden', 'true');
      const name = document.createElement('strong'); name.textContent = jar.name;
      const balance = document.createElement('span'); balance.textContent = amount(jar.total_sat);
      const selection = document.createElement('span'); selection.className = 'jar-selection'; selection.textContent = jar.id === selected ? 'Selected' : 'Select jar';
      button.append(art, name, balance, selection); button.onclick = () => { selected = jar.id; clearAddress(); render(); };
      $('jam-jars').append(button);
    }
    $('jam-jars').scrollLeft = jarScroll;
    if (focusedJar !== undefined) $('jam-jars').querySelector(`[data-jar="${focusedJar}"]`)?.focus({preventScroll:true});
    const jar = jars.find(jar => jar.id === selected);
    if (jar) {
      $('jam-selected-name').textContent = jar.name; $('jam-receive').textContent = 'Receive into ' + jar.name;
      for (const [field, label] of [['confirmed_sat','Confirmed'],['pending_sat','Pending'],['frozen_sat','Frozen'],['bond_sat','Fidelity bonds']]) {
        if (jar[field] === 0 && field !== 'confirmed_sat') continue;
        const dt = document.createElement('dt'), dd = document.createElement('dd'); dt.textContent = label; dd.textContent = amount(jar[field]);
        $('jam-amounts').append(dt, dd);
      }
    }
    const running = session?.maker_running === true;
    $('jam-maker-status').textContent = running ? 'Running on your server' : 'Not running';
    $('jam-maker-fields').hidden = running; $('jam-maker').textContent = running ? 'Stop maker' : 'Review maker setup';
    const readiness=PaperclipMakerReadiness.evaluate($('jam-minimum').value,$('jam-fee').value,jars,session,needsRefresh);
    const checklist=$('jam-maker-checklist');checklist.replaceChildren();checklist.hidden=running;
    for(const [key,complete,needed] of [
      ['terms','Amount and fee valid','Review the minimum amount and fee'],
      ['funds','One jar covers the minimum','Fund one jar and wait for confirmation'],
      ['bond','Bond funds detected','Set up and fund a fidelity bond'],
      ['server','Jam is idle','Wait for Jam to finish syncing or its current operation'],
      ['fresh','Status refreshed','Refresh wallet status before continuing']
    ]) {
      const item=document.createElement('li');item.dataset.ready=String(readiness[key]);
      item.textContent=(readiness[key]?'Ready: ':'Needed: ')+(readiness[key]?complete:needed);checklist.append(item);
    }
    $('jam-maker-readiness').textContent = needsRefresh ? 'Refresh maker status before another action.' : running ? '' : readiness.canStart
      ? 'Review your terms. Your server checks final eligibility; earnings are not guaranteed.' : 'Complete the remaining setup steps. Bond coins stay locked until the date you choose and remain separate from your maker offer.';
    panel.querySelectorAll('button, input, select').forEach(control => { control.disabled = busy; });
    $('jam-backup-close').disabled = false;
    $('jam-create').disabled = busy || (!!pendingSetup && !creationRetry);
    $('jam-create-name').disabled = busy || !!pendingSetup;
    $('jam-backup-finish').disabled = busy || !backupWords.length || [...$('jam-backup-challenges').querySelectorAll('input')].length !== 3 || [...$('jam-backup-challenges').querySelectorAll('input')].some(field => field.value.trim().toLowerCase() !== backupWords[Number(field.dataset.position)]);
    $('jam-maker').disabled = busy || needsRefresh || (!running && !readiness.canStart);
  }
  async function work(action) {
    if (busy) return;
    busy = true; $('jam-status').textContent = 'Connecting…'; render();
    try { await action(); $('jam-status').textContent = ''; }
    catch (error) { $('jam-status').textContent = error.message; }
    finally { busy = false; render(); }
  }
  async function refresh() {
    needsRefresh = true;
    const current = await call('status'), result = await call('coins');
    if (!Array.isArray(result.jars) || result.jars.length !== 5 || result.jars.some((jar, id) =>
      jar.id !== id || typeof jar.name !== 'string' || ['total_sat','confirmed_sat','pending_sat','frozen_sat','bond_sat'].some(field => !Number.isSafeInteger(jar[field]) || jar[field] < 0))) {
      throw new Error('JoinBlaket returned invalid jar balances. Refresh before continuing.');
    }
    session = current; jars = result.jars; needsRefresh = false;
  }
  $('jam-find').onclick = () => work(async () => {
    const identity = token, ticket = generation;
    const config = await api('joinblaket/connection');
    if (identity !== token || ticket !== generation) return;
    if (!config.configured) throw new Error('Connect the JoinBlaket service in your wallet server settings first.');
    const handoff = $('jam-open'); handoff.hidden = true; handoff.removeAttribute('href');
    if (typeof config.ui_url === 'string') {
      const url = new URL(config.ui_url);
      if (url.protocol === 'https:' && !url.hostname.endsWith('.onion') && !url.username && !url.password && !url.search && !url.hash) {
        handoff.href = url.href; handoff.hidden = false;
      }
    }
    const result = await call('wallets');
    if (!Array.isArray(result.wallets) || result.wallets.some(name => typeof name !== 'string')) throw new Error('Jam returned an invalid wallet list.');
    $('jam-wallet').replaceChildren();
    for (const name of result.wallets) { const option = document.createElement('option'); option.value = name; option.textContent = name; $('jam-wallet').append(option); }
    $('jam-unlock-fields').hidden = result.wallets.length === 0;
    $('jam-connection-state').textContent = result.wallets.length ? 'Select your separate Jam wallet.' : 'Create your Jars wallet here to get started.';
  });
  $('jam-unlock').onclick = () => work(async () => {
    const wallet = $('jam-wallet').value, password = $('jam-password').value, bip39_passphrase = $('jam-passphrase').value;
    $('jam-password').value = ''; $('jam-passphrase').value = '';
    const result = await call('unlock', {wallet, password, bip39_passphrase});
    if (result.walletname !== wallet || typeof result.token !== 'string' || !result.token) throw new Error('Jam did not unlock the selected wallet.');
    authorization = {wallet, token: result.token};
    if (wallet === pendingSetup) openBackup(wallet); else await refresh();
  });
  $('jam-payments-load').onclick = () => work(async () => {
    const result = await call('payments');
    if (!Array.isArray(result.payments) || result.payments.length > 100 || new Set(result.payments.map(row => row.id)).size !== result.payments.length)
      throw new Error('Invalid Jam payment history.');
    const rows = result.payments.map(row => paymentRecord(row));
    payments = rows; renderPayments();
    $('jam-payments-load').textContent = 'Refresh saved payments';
  });
  $('jam-refresh').onclick = () => work(refresh);
  $('jam-bond-month').oninput = clearBond;
  $('jam-bond-review').onclick = () => work(async () => {
    const month = $('jam-bond-month').value, wallet = authorization?.wallet;
    validateBondMonth(month);
    if (!wallet) throw new Error('Unlock your Jars wallet first.');
    if (!await window.PaperclipReview.ask('Create a bond address for ' + wallet + '?\n\nCoins sent here will be locked until ' + month + '-01 at 00:00 UTC. Creating the address sends no funds. Review the amount and mining fee separately when funding. Earnings are not guaranteed.')) return;
    validateBondMonth(month); clearBond();
    const result = await call('bond_address', {lock_month:month});
    if (result.wallet !== wallet || result.lock_month !== month || typeof result.address !== 'string' || !result.address || result.address.length > 128 || /\s/.test(result.address))
      throw new Error('Jam returned an invalid bond address. No funding was requested.');
    $('jam-bond-detail').textContent = 'Wallet: ' + wallet + ' · Unlocks ' + month + '-01 at 00:00 UTC. Address ready; no funds sent. Back up your Jam wallet before funding.';
    $('jam-bond-address').textContent = result.address;
    window.PaperclipReceive.show('jam-bond-address', result.address, 'Bond · unlocks ' + month + '-01 UTC');
  });
  $('jam-receive').onclick = () => work(async () => {
    const result = await call('address', {jar: selected});
    if (typeof result.address !== 'string' || !result.address) throw new Error('Jam returned an invalid receive address.');
    $('jam-address').textContent = result.address;
    window.PaperclipReceive.show('jam-address', result.address, 'Receive into ' + jars[selected].name);
  });
  $('jam-minimum').oninput = render; $('jam-fee').oninput = render;
  $('jam-maker').onclick = () => work(async () => {
    const stopping = session?.maker_running === true, values = terms();
    if (!stopping && !values) throw new Error('Review your maker amount and fee.');
    const review = stopping ? 'Stop the maker running on your Jam server?' :
      'Start your Jam maker? Minimum CoinJoin: ' + amount(values.minimum_sat) + '. Your fee: ' + amount(values.fee_sat) +
      ' per CoinJoin. Mining fee contribution: 0 sats. It uses eligible Jam jars and keeps running when Paperclip closes. This does not create a bond or transfer Paperclip funds.';
    if (!await window.PaperclipReview.ask(review)) return;
    needsRefresh = true;
    await call(stopping ? 'stop_maker' : 'start_maker', stopping ? {} : values); await refresh();
  });
  new MutationObserver(() => {
    if (!$('wallet').hidden) return;
    closeBackup(); $('jam-create-password').value = ''; $('jam-create-confirm').value = '';
    clearPairingCode(); $('jam-pairing-list').replaceChildren(); $('jam-pairing-panel').open = false;
    generation++; payments = null; renderPayments(); $('jam-payments-panel').open = false; authorization = null; jars = []; session = null; selected = 0;
    $('jam-open').hidden = true; $('jam-open').removeAttribute('href');
    $('jam-password').value = ''; $('jam-passphrase').value = ''; needsRefresh = false; $('jam-wallet').replaceChildren(); $('jam-unlock-fields').hidden = true;
    clearAddress(); clearBond(); $('jam-bond-month').value = ''; render();
  }).observe($('wallet'), {attributes:true, attributeFilter:['hidden']});
})();
