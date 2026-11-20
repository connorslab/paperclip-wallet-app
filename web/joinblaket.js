'use strict';
(() => {
  let authorization = null, jars = [], session = null, selected = 0, busy = false, generation = 0, needsRefresh = false;
  const panel = document.querySelector('[data-screen="coinjoin"]');
  const toolsDialog = $('jam-tools-dialog');
  const toolTitles = {settings:'Maker settings',market:'Order book',bond:'Fidelity bond',guide:'How earning works'};
  panel.querySelectorAll('[data-jam-tool-open]').forEach(button => {
    button.onclick = () => {
      if (busy || !authorization) return;
      const key = button.dataset.jamToolOpen;
      $('jam-tool-title').textContent = toolTitles[key];
      toolsDialog.dataset.tool = key;
      toolsDialog.querySelectorAll('[data-jam-tool]').forEach(section => { section.hidden = section.dataset.jamTool !== key; });
      toolsDialog.showModal();
      toolsDialog.scrollTop = 0;
      $('jam-tool-close').focus();
    };
  });
  $('jam-tool-close').onclick = () => toolsDialog.close();
  new MutationObserver(() => { if (panel.hidden) toolsDialog.close(); }).observe(panel, {attributes:true,attributeFilter:['hidden']});
  new MutationObserver(() => { $('jam-tool-status').textContent = $('jam-status').textContent; })
    .observe($('jam-status'), {childList:true,subtree:true,characterData:true});

  const sendDialog = $('jam-send-dialog');
  let sendDraft = null, sendReview = null, sendAttempted = false, sendJar = 0, sendTicket = 0, sendSubmitting = false, sendBond = null, bondTarget = null, sendWithdrawal = null;
  function renderSend() {
    $('jam-send-form').hidden = sendAttempted;
    $('jam-send-review').hidden = !sendReview;
    $('jam-send-recovery').hidden = busy || !sendAttempted || !!sendReview;
    $('jam-send-progress').hidden = !busy || !sendAttempted || !!sendReview;
    $('jam-send-progress-title').textContent = sendSubmitting ? 'Submitting payment' : sendDraft?.terms.coinjoin ? 'Preparing CoinJoin' : 'Preparing payment';
    $('jam-send-progress-detail').textContent = sendSubmitting ? 'Waiting for your Jam node. Keep this screen open; the payment will not be sent again automatically.' : sendDraft?.terms.coinjoin ? 'Finding participants and checking the exact fees. This can take up to three minutes. Nothing is broadcast until you review and send.' : 'Checking the recipient, coins and fees before review.';
    $('jam-send-mode').textContent = sendWithdrawal ? 'Withdraws the entire bond, less the mining fee. This bond will no longer support your maker. Your node checks maturity again before sending.' : sendBond ? 'Unlocks '+sendBond.month+'-01 at 00:00 UTC. Back up your Jam wallet first; these coins will be locked. Bond funding is public and earnings are not guaranteed.' : $('jam-send-coinjoin').checked ?
      'Pay with other participants. Review maker and mining fees before sending. If CoinJoin is unavailable, no direct payment is made.' : 'Direct payment. This transaction will not use CoinJoin.';
    sendDialog.querySelectorAll('button,input').forEach(el=>el.disabled=busy);
    $('jam-send-address').readOnly = !!sendBond;
    $('jam-send-coinjoin').closest('label').hidden = !!sendBond || !!sendWithdrawal;
    $('jam-send-amount').readOnly = !!sendWithdrawal;
    $('jam-send-close').disabled = false;
    $('jam-send-prepare').disabled = busy || sendAttempted;
  }
  $('jam-send-coinjoin').onchange = renderSend;
  function openSend(bond = null, withdrawal = null) {
    if (busy || !authorization) return;
    const wasBond=!!sendBond, wasWithdrawal=!!sendWithdrawal; sendBond=bond; sendWithdrawal=withdrawal;
    if(withdrawal) { $('jam-send-address').value=''; $('jam-send-amount').value=String(withdrawal.value_sat); $('jam-send-coinjoin').checked=false; }
    else if(wasWithdrawal) $('jam-send-amount').value='';
    if(bond) { $('jam-send-address').value=bond.address; $('jam-send-coinjoin').checked=false; }
    else if(wasBond) { $('jam-send-address').value=''; }
    sendTicket++; sendDraft=null; sendReview=null; sendAttempted=false; sendSubmitting=false; sendJar=withdrawal ? 0 : selected;
    $('jam-send-result').textContent='Check payment activity'; $('jam-send-status').textContent='';
    $('jam-send-title').textContent=withdrawal?'Withdraw fidelity bond':(bond?'Fund from ':'Send from ')+jars.find(jar=>jar.id===sendJar).name;
    renderSend(); sendDialog.showModal(); $('jam-send-address').focus();
  };
  $('jam-send').onclick = () => openSend();
  $('jam-bond-fund').onclick = () => { if(!bondTarget || busy) return; toolsDialog.close(); openSend({...bondTarget}); };
  $('jam-send-close').onclick = () => sendDialog.close();
  sendDialog.addEventListener('close',()=>{ sendTicket++; sendReview=null; sendDraft=null; });
  new MutationObserver(()=>{ if(panel.hidden || !$('jam-dashboard').hidden && !authorization) sendDialog.close(); }).observe(panel,{attributes:true,attributeFilter:['hidden']});
  $('jam-send-prepare').onclick = () => work(async()=>{
    if (sendAttempted || !sendDialog.open) return;
    const terms=PaperclipJarSend.terms(sendJar,$('jam-send-address').value.trim(),$('jam-send-amount').value,$('jam-send-rate').value,$('jam-send-limit').value,$('jam-send-coinjoin').checked,sendWithdrawal?.locktime ?? sendBond?.locktime ?? null,sendWithdrawal?.outpoint ?? null);
    const id=Array.from(crypto.getRandomValues(new Uint8Array(32)),v=>v.toString(16).padStart(2,'0')).join('');
    const ticket=sendTicket, wallet=authorization.wallet;
    sendDraft={id,wallet,terms}; sendAttempted=true; renderSend();
    const row=await call('prepare_payment',{payment_id:id,send:terms});
    if(ticket!==sendTicket || !sendDialog.open) return;
    sendReview=PaperclipJarSend.validate(row,id,wallet,terms);
    $('jam-send-review-title').textContent=terms.bond_outpoint != null?'Review bond withdrawal':terms.bond_locktime == null?'Review jar payment':'Review bond funding';
    $('jam-send-caption').textContent=terms.bond_outpoint != null || terms.bond_locktime == null?'Recipient receives':'Amount to lock';
    $('jam-send-hero').textContent=amount(row.quote.amount_sat);
    $('jam-send-costs').replaceChildren();
    for(const [label,value] of [['Payment type',terms.bond_outpoint != null?'Bond withdrawal':terms.bond_locktime != null?'Bond funding':terms.coinjoin?'CoinJoin':'Direct · no CoinJoin'],...(terms.bond_locktime != null?[['Bond unlock date',new Date(terms.bond_locktime*1000).toISOString().slice(0,16).replace('T',' ')+' UTC'],[terms.bond_outpoint ? 'Withdrawal' : 'Lock',terms.bond_outpoint ? 'Withdraws the whole bond less fees; it will no longer support your maker.' : 'Coins cannot be spent before this date; earnings are not guaranteed.']]:[]),['Wallet',wallet],['From',jars.find(jar=>jar.id===sendJar).name],...(terms.coinjoin?[['Maker fees',amount(row.quote.maker_fee_sat)],['Your mining fee',amount(row.quote.mining_fee_sat)],['Participants',row.quote.maker_count+' makers'],['Broadcast','Your Jam node · no RBF']]:[['Mining fee',amount(row.quote.fee_sat)]]),['Total debit',amount(row.quote.total_sat)]]) {
      const group=document.createElement('div'), dt=document.createElement('dt'), dd=document.createElement('dd'); dt.textContent=label;dd.textContent=value;group.append(dt,dd);$('jam-send-costs').append(group);
    }
    $('jam-send-commit').textContent=terms.bond_outpoint != null?'Withdraw bond':terms.bond_locktime == null?'Send payment':'Fund bond';
    $('jam-send-destination').textContent=row.quote.destination;
    sendDialog.querySelector('.jam-tool-body').scrollTop=0;
    $('jam-send-expiry').textContent='Review expires '+new Date(row.expires*1000).toLocaleTimeString()+(terms.coinjoin?'. Discarding may leave coins reserved briefly.':'');
  });
  $('jam-send-commit').onclick = () => work(async()=>{
    if(!sendDraft || !sendReview || !sendDialog.open) return;
    const {id,wallet,terms}=sendDraft, row=sendReview, ticket=sendTicket;
    PaperclipJarSend.validate(row,id,wallet,terms);
    if(authorization?.wallet!==wallet) throw new Error('Jam wallet changed since review.');
    sendSubmitting=true; sendReview=null; renderSend();
    const result=await call('commit_payment',{payment_id:id,approval:row.approval,wallet_identity:row.quote.wallet_identity});
    if(ticket!==sendTicket || !sendDialog.open) return;
    if(result.id!==id || !['submitted','submitting','unknown'].includes(result.state) || !['wallet','jar','purpose','destination','txid','amount_sat','fee_sat','total_sat','coinjoin','maker_fee_sat','mining_fee_sat','network_fee_sat','maker_count','broadcast_policy','bond_locktime','bond_outpoint'].every(key=>result.quote?.[key]===row.quote[key])) throw new Error('Check Jars payment activity before another action.');
    $('jam-send-result').textContent=result.state==='submitted'?'Submitted · awaiting confirmation':'Status unknown';
  });
  $('jam-send-discard').onclick = () => work(async()=>{
    if(!sendDraft || !sendReview) return;
    const ticket=sendTicket, result=await call('cancel_payment',{payment_id:sendDraft.id});
    if(ticket!==sendTicket) return;
    if(result.id!==sendDraft.id || result.state!=='cancelled') throw new Error('Check Jars payment activity before another action.');
    sendReview=null; sendDraft=null; sendAttempted=false;
  });
  $('jam-send-activity').onclick = () => { sendDialog.close(); $('jam-payments-panel').open=true; $('jam-payments-load').click(); $('jam-payments-panel').scrollIntoView({block:'start'}); };
  new MutationObserver(()=>{ $('jam-send-status').textContent=$('jam-status').textContent; }).observe($('jam-status'),{childList:true,subtree:true,characterData:true});

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
    if (!config.configured) throw new Error('Jars is not ready yet. Check Paperclip’s service status and try Refresh wallets.');
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
      const detail = document.createElement('p'); detail.className = 'hint'; detail.textContent = row.wallet + (row.scope === 'jars_pay_v1' ? ' · Manage and send' : ' · Manage only') + ' · Expires ' + new Date(row.expires*1000).toLocaleDateString();
      const revoke = document.createElement('button'); revoke.className = 'secondary'; revoke.textContent = 'Revoke access';
      revoke.onclick = () => work(async () => {
        if (!await window.PaperclipReview.ask('Revoke Jars access for '+row.label+'? This stops new requests from that pairing.')) return;
        await pairingCall('joinblaket/pairings/revoke', {id:row.id}); clearPairingCode(); await loadPairings();
      });
      card.append(label,detail,revoke); root.append(card);
    }
  }
  const onionHost = host => /^[a-z2-7]{56}\.onion$/.test(host);
  let hostOnion = onionHost(location.hostname) ? location.origin : '';
  let pairingEdit = 0;
  function pairingRoute() {
    const tor = $('jam-pairing-transport').value === 'tor';
    $('jam-pairing-route-hint').textContent = tor
      ? 'Use this Paperclip host’s onion address. Your phone starts Tor automatically; no VPN or port forwarding is needed.'
      : 'Use an HTTPS address reachable by your phone. A local address works only on your home network.';
    $('jam-pairing-endpoint').placeholder = tor ? 'http://…onion' : 'https://your-host';
  }
  $('jam-pairing-endpoint').value = hostOnion;
  pairingRoute();
  $('jam-pairing-transport').onchange = () => {
    pairingEdit++; clearPairingCode();
    $('jam-pairing-endpoint').value = $('jam-pairing-transport').value === 'tor' ? hostOnion : (location.protocol === 'https:' && !onionHost(location.hostname) ? location.origin : '');
    $('jam-pairing-pin').value = ''; pairingRoute();
  };
  for (const id of ['jam-pairing-endpoint','jam-pairing-pin','jam-pairing-label']) $(id).addEventListener('input', () => { pairingEdit++; clearPairingCode(); });
  async function discoverPairingAddress() {
    const edit = pairingEdit;
    try {
      const value = await pairingCall('joinblaket/pairings/connection');
      if (!value.onion_endpoint) return;
      const url = new URL(value.onion_endpoint);
      if (!onionHost(url.hostname) || !['http:','https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') return;
      hostOnion = url.href;
      if (edit === pairingEdit && $('jam-pairing-transport').value === 'tor' && !$('jam-pairing-endpoint').value) $('jam-pairing-endpoint').value = hostOnion;
    } catch { /* Older hosts allow entering their published onion address. */ }
  }
  $('jam-pairing-create').onclick = () => work(async () => {
    clearPairingCode();
    const scope = $('jam-pairing-scope').value;
    if (!['jars_manage_v1','jars_pay_v1'].includes(scope)) throw new Error('Choose phone permissions.');
    if (!$('jam-pairing-endpoint').value.trim()) throw new Error($('jam-pairing-transport').value === 'tor' ? 'Enter your Paperclip host’s onion address, or choose HTTPS for a direct connection.' : 'Enter your Paperclip host’s HTTPS address.');
    const endpoint = new URL($('jam-pairing-endpoint').value.trim()), pin = $('jam-pairing-pin').value.trim().toLowerCase(), label = $('jam-pairing-label').value.trim();
    const tor = $('jam-pairing-transport').value === 'tor', edit = pairingEdit;
    if (tor ? !onionHost(endpoint.hostname) : endpoint.protocol !== 'https:' || endpoint.hostname.endsWith('.onion')) throw new Error(tor ? 'Use a full v3 onion address for Tor pairing.' : 'Use HTTPS, or select Tor for an onion address.');
    if (!label || [...label].length > 48 || /[\x00-\x1f\x7f]/.test(label)) throw new Error('Name this device using 1 to 48 characters.');
    if (!(endpoint.protocol === 'https:' || (endpoint.protocol === 'http:' && endpoint.hostname.endsWith('.onion'))) || endpoint.username || endpoint.password || endpoint.search || endpoint.hash || (pin && (!/^[0-9a-f]{64}$/.test(pin) || endpoint.protocol !== 'https:'))) throw new Error('Use the Paperclip HTTPS address or its onion address, with a verified certificate fingerprint if needed.');
    if (!await window.PaperclipReview.ask('Pair a phone with '+authorization.wallet+' through '+endpoint.href+'? '+(scope === 'jars_pay_v1' ? 'This phone can manage and send funds from this Jars wallet for up to 30 days.' : 'This phone can manage Jars receiving, maker controls and status for up to 30 days. Sending is not allowed.')+' Keep the code private.')) return;
    if (edit !== pairingEdit) throw new Error('Connection changed. Review the new connection before pairing.');
    const wallet = authorization.wallet;
    const value = await pairingCall('joinblaket/pairings', {label,wallet,token:authorization.token,scope});
    if (value.wallet !== wallet || value.scope !== scope || typeof value.token !== 'string' || !/^pj1_[0-9a-f]{64}$/.test(value.token) || !Number.isSafeInteger(value.expires) || value.expires*1000 <= Date.now()) throw new Error('Invalid pairing response. Check paired devices before creating another.');
    if (edit !== pairingEdit) { await loadPairings(); throw new Error('Connection changed while creating access. Revoke the new device entry before creating another code.'); }
    const payload = JSON.stringify({kind:'paperclip-jars-v1',scope:value.scope,endpoint:endpoint.href,wallet,token:value.token,expires:value.expires,certificate_sha256:pin});
    pairingCode = 'paperclip-jars:'+btoa(String.fromCharCode(...new TextEncoder().encode(payload))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
    pairingQR = URL.createObjectURL(new Blob([PaperclipReceive.encode(pairingCode)], {type:'image/svg+xml'}));
    $('jam-pairing-qr').src = pairingQR; $('jam-pairing-code').hidden = false;
    await loadPairings();
  });
  $('jam-pairing-copy').onclick = () => work(async () => { if (pairingCode) { await PaperclipReceive.copy(pairingCode); $('jam-status').textContent = 'Private pairing code copied.'; } });
  $('jam-pairing-hide').onclick = clearPairingCode;
  $('jam-pairing-scope').onchange = () => { pairingEdit++; clearPairingCode(); };
  $('jam-pairing-load').onclick = () => work(loadPairings);
  $('jam-pairing-panel').addEventListener('toggle', () => { if (!$('jam-pairing-panel').open) { pairingEdit++; clearPairingCode(); } else discoverPairingAddress(); });
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
    if (q?.coinjoin !== undefined && typeof q.coinjoin !== 'boolean') throw new Error('Invalid saved payment mode.');
    if (q?.coinjoin && (q.purpose !== 'send' ||
        ['maker_fee_sat','mining_fee_sat','network_fee_sat'].some(key => !Number.isSafeInteger(q[key]) || q[key] < 0 || q[key] > 2100000000000000) ||
        q.maker_fee_sat + q.mining_fee_sat !== q.fee_sat || q.mining_fee_sat > q.network_fee_sat ||
        !Number.isInteger(q.maker_count) || q.maker_count < 2 || q.maker_count > 20 || q.broadcast_policy !== 'self')) throw new Error('Invalid saved CoinJoin fees.');
    if (q?.bond_outpoint != null && (q.purpose !== 'withdraw_bond' || q.jar !== 0 || !PaperclipBonds.outpoint(q.bond_outpoint))) throw new Error('Invalid saved bond outpoint.');
    if (q?.bond_locktime != null && (q.purpose === 'send' || !Number.isSafeInteger(q.bond_locktime) || q.bond_locktime < 1577836800 || q.bond_locktime > 4099766400)) throw new Error('Invalid saved bond unlock date.');
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
        for (const [label,value] of [[q.coinjoin ? 'Total fees' : 'Mining fee',q.fee_sat],['Total debit',q.total_sat]]) {
          const cell = document.createElement('div'), term = document.createElement('dt'), total = document.createElement('dd');
          term.textContent = label; total.textContent = amount(value); cell.append(term,total); costs.append(cell);
        }
        const details = document.createElement('details'), title = document.createElement('summary'); title.textContent = 'Payment details'; details.append(title);
        const references = [];
        if (q.purpose !== 'send') {
          const unlock = q.bond_locktime == null ? 'Unavailable — check your Jam host' :
            new Date(q.bond_locktime*1000).toISOString().replace('T',' ').replace('.000Z',' UTC');
          references.push('Bond unlock date: '+unlock);
        }
        if (q.coinjoin) references.push('Maker fees: '+amount(q.maker_fee_sat),'Your mining fee: '+amount(q.mining_fee_sat));
        references.push('Destination: '+q.destination,'Transaction ID: '+q.txid);
        for (const text of references) {
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
      if (['preparing','prepared'].includes(payment.state)) {
        const discard = document.createElement('button'); discard.textContent = 'Discard review'; discard.className = 'secondary';
        discard.onclick = () => work(async () => {
          const identity = token, ticket = generation, wallet = authorization?.wallet;
          if (!await PaperclipReview.ask('Discard this unsent review in ' + wallet + '? This releases its reserved coins and does not send a transaction. A submission that has already started cannot be discarded.')) return;
          if (!token || token !== identity || ticket !== generation || authorization?.wallet !== wallet || panel.hidden) return;
          const updated = paymentRecord(await call('cancel_payment', {payment_id:payment.id}), payment.id);
          if (updated.state !== 'cancelled') throw new Error('Could not confirm cancellation. Refresh saved payments.');
          payments = payments.map(row => row.id === payment.id ? updated : row); renderPayments();
        });
        card.append(discard);
      }
      root.append(card);
    }
  }
  function clearAddress() { window.PaperclipReceive?.clear('jam-address'); $('jam-address').textContent = ''; }
  function clearBond() { bondTarget=null; $('jam-bond-fund').hidden=true; window.PaperclipReceive?.clear('jam-bond-address'); $('jam-bond-address').textContent = ''; $('jam-bond-detail').textContent = ''; }
  function validateBondMonth(month) {
    const year = Number(month.slice(0,4)), number = Number(month.slice(5));
    if (!/^[0-9]{4}-[0-9]{2}$/.test(month) || year < 2020 || year > 2099 || number < 1 || number > 12 || Date.UTC(year,number-1,1) <= Date.now())
      throw new Error('Choose a future month before 2100. Bonds unlock on its first day at 00:00 UTC.');
  }
  function feeChoices() {
    const relative = $('jam-fee-mode').value === 'relative';
    $('jam-fee').replaceChildren();
    for (const [index, value] of (relative ? PaperclipMakerReadiness.rates : PaperclipMakerReadiness.fixed).entries()) {
      const option = document.createElement('option'); option.value = String(value);
      option.textContent = relative ? PaperclipMakerReadiness.percentages[index] + '%' : value + ' sats';
      $('jam-fee').append(option);
    }
    $('jam-fee').value = relative ? '0.00005' : '100';
  }
  feeChoices();
  $('jam-fee-mode').onchange = () => { feeChoices(); render(); };
  function feeLabel(values) {
    return values.relative_fee ? PaperclipMakerReadiness.percentages[PaperclipMakerReadiness.rates.indexOf(values.relative_fee)] + '% of the CoinJoin amount' : amount(values.fee_sat) + ' per CoinJoin';
  }
  let market = null, marketPage = 0;
  function renderMarket() {
    const now = Math.floor(Date.now()/1000), root = $('jam-market-summary');
    root.textContent = !market ? 'Refresh to compare current offers.' : market.status === 'stale' || (market.book_updated_at !== null && now-market.book_updated_at > 120) ? 'Order book is stale. Refresh before comparing fees.' : market.status === 'empty' ? 'No verified bonded offers cover this amount. No median is available.' : market.status === 'fresh' ? 'Median maker fee: '+market.median_fee_sat+' sats for a '+amount(market.amount_sat)+' CoinJoin · '+market.maker_count+' makers. Fetched '+new Date(market.fetched_at*1000).toLocaleTimeString()+'.' : 'Order book unavailable. Your selected fee is unchanged.';
    renderOrderBook();
  }
  function renderOrderBook() {
    const root = $('jam-book-offers'); root.replaceChildren();
    $('jam-book-pagination').hidden = true;
    $('jam-book-excluded').textContent = '';
    const count = $('jam-book-count'); count.textContent = '';
    if (!market) return;
    if (!['fresh','empty'].includes(market.status) || !Number.isInteger(market.book_updated_at) || Date.now()/1000-market.book_updated_at > 120) { count.textContent = 'Refresh to browse current offers.'; return; }
    if (!market.offers) { count.textContent = 'Update your Paperclip host to browse individual offers.'; return; }
    const rows = PaperclipOrderBook.rows(market, $('jam-book-eligible').checked, $('jam-book-sort').value === 'size');
    marketPage = Math.min(marketPage, Math.max(0, Math.ceil(rows.length/10)-1));
    count.textContent = rows.length+' offers · '+new Set(rows.map(row=>row.maker)).size+' makers'+(rows.length?'':'. No offers match this filter.');
    for (const row of rows.slice(marketPage*10,marketPage*10+10)) {
      const card = document.createElement('article'); card.className = 'jam-book-offer';
      const maker = document.createElement('h3'); maker.textContent = row.maker; maker.className = 'mono'; card.append(maker);
      const data = document.createElement('dl');
      const fee = row.relative ? PaperclipMakerReadiness.percentages[PaperclipMakerReadiness.rates.indexOf(row.fee)]+'%' : row.fee+' sats';
      for (const [label, value] of [['Maker fee',fee],['Amount range',amount(row.min_sat)+' – '+amount(row.max_sat)],['At your amount',row.min_sat<=market.amount_sat && market.amount_sat<=row.max_sat ? amount(row.fee_sat) : 'Outside range'],['Mining contribution',amount(row.mining_contribution_sat)],['Fidelity bond',row.bond_verified?'Verified':'Not verified']]) {
        const group=document.createElement('div'),dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=label;dd.textContent=value;group.append(dt,dd);data.append(group);
      }
      card.append(data);root.append(card);
    }
    $('jam-book-pagination').hidden = rows.length === 0;
    $('jam-book-page').textContent = (marketPage+1)+' / '+Math.max(1,Math.ceil(rows.length/10));
    $('jam-book-prev').disabled = busy || marketPage === 0; $('jam-book-next').disabled = busy || (marketPage+1)*10 >= rows.length;
    $('jam-book-excluded').textContent = market.excluded_offer_count ? market.excluded_offer_count+' unsupported or malformed offers excluded.' : '';
  }
  for (const id of ['jam-book-eligible','jam-book-sort']) $(id).onchange = () => { marketPage=0; renderOrderBook(); };
  $('jam-book-prev').onclick = () => { marketPage=Math.max(0,marketPage-1); renderOrderBook(); $('jam-book-count').scrollIntoView({block:'center'}); };
  $('jam-book-next').onclick = () => { marketPage++; renderOrderBook(); $('jam-book-count').scrollIntoView({block:'center'}); };
  setInterval(renderMarket,15000);
  $('jam-market-refresh').onclick = () => work(async () => {
    const comparison = Number($('jam-market-amount').value);
    if (!/^[0-9]+$/.test($('jam-market-amount').value) || !Number.isSafeInteger(comparison) || comparison < 27300 || comparison > 2100000000000000) throw new Error('Choose a valid comparison amount.');
    market = null; marketPage = 0; renderMarket();
    try {
      const value = await call('market', {comparison_sat:comparison}), now = Math.floor(Date.now()/1000);
      if (value.amount_sat !== comparison || !['fresh','stale','empty','unavailable'].includes(value.status) || !Number.isInteger(value.fetched_at) || value.fetched_at < now-120 || value.fetched_at > now+30 || !Number.isInteger(value.maker_count) || value.maker_count < 0 || value.maker_count > 10000) throw new Error('Invalid market data');
      if (value.status === 'fresh') {
        if (value.maker_count === 0 || !Number.isInteger(value.book_updated_at) || value.book_updated_at < now-120 || value.book_updated_at > now+30 || typeof value.median_fee_sat !== 'string' || !/^[0-9]{1,16}(\.5)?$/.test(value.median_fee_sat) || Number(value.median_fee_sat) > 2100000000000000) throw new Error('Invalid market data');
      } else if (value.median_fee_sat !== null || value.maker_count !== 0) throw new Error('Invalid market data');
      PaperclipOrderBook.validate(value, comparison);
      if (comparison === Number($('jam-market-amount').value)) market = value;
    } catch (_) { market = {status:'unavailable',book_updated_at:null}; }
    renderMarket();
  });
  function terms() {
    const rawMinimum = $('jam-minimum').value, rawFee = $('jam-fee').value;
    if (!/^\d+$/.test(rawMinimum)) return null;
    if ($('jam-fee-mode').value === 'relative') return Number.isSafeInteger(Number(rawMinimum)) && Number(rawMinimum) >= 27300 && Number(rawMinimum) <= 2100000000000000 && PaperclipMakerReadiness.rates.includes(rawFee) ? {minimum_sat:Number(rawMinimum), relative_fee:rawFee} : null;
    if ($('jam-fee-mode').value !== 'fixed' || !/^\d+$/.test(rawFee)) return null;
    const minimum = Number(rawMinimum), fee = Number(rawFee);
    return Number.isSafeInteger(minimum) && minimum >= 27300 && minimum <= 2100000000000000 &&
      Number.isSafeInteger(fee) && PaperclipMakerReadiness.fixed.includes(fee) && fee < minimum ? {minimum_sat: minimum, fee_sat: fee} : null;
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
      if (bondTarget) $('jam-bond-fund').textContent = 'Fund from ' + jar.name;
      $('jam-selected-name').textContent = jar.name; $('jam-receive').textContent = 'Receive into ' + jar.name;
      for (const [field, label] of [['confirmed_sat','Confirmed'],['pending_sat','Pending'],['frozen_sat','Frozen'],['bond_sat','Fidelity bonds']]) {
        if (jar[field] === 0 && field !== 'confirmed_sat') continue;
        const dt = document.createElement('dt'), dd = document.createElement('dd'); dt.textContent = label; dd.textContent = amount(jar[field]);
        $('jam-amounts').append(dt, dd);
      }
    }
    const running = session?.maker_running === true;
    $('jam-maker-status').textContent = running ? 'Maker running' : 'Maker paused';
    $('jam-maker-fields').hidden = running; $('jam-maker').textContent = running ? 'Stop maker' : 'Review maker setup';
    const relative = $('jam-fee-mode').value === 'relative', rate = relative ? $('jam-fee').value : null;
    const rateIndex = PaperclipMakerReadiness.rates.indexOf(rate);
    $('jam-fee-example').textContent = rateIndex >= 0 ? 'At 1,000,000 sats, your fee is ' + PaperclipMakerReadiness.perMillion[rateIndex].toLocaleString() + ' sats.' : '';
    const readiness=PaperclipMakerReadiness.evaluate($('jam-minimum').value,relative ? '0' : $('jam-fee').value,jars,session,needsRefresh,rate);
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
    $('jam-maker-next').textContent = running ? 'Your server keeps making while Paperclip is closed.' : PaperclipMakerReadiness.nextStep(readiness);
    $('jam-maker-checks').hidden = running;
    $('jam-maker-readiness').dataset.ready = String(readiness.canStart);
    $('jam-maker-checks-title').textContent = 'Setup checks · '+PaperclipMakerReadiness.completed(readiness)+' of 5';
    $('jam-maker-readiness').textContent = running ? (needsRefresh ? 'Refresh maker status before continuing.' : '') : PaperclipMakerReadiness.nextStep(readiness);
    panel.querySelectorAll('button, input, select').forEach(control => { control.disabled = busy; });
    $('jam-backup-close').disabled = false;
    $('jam-tool-close').disabled = false;
    $('jam-create').disabled = busy || (!!pendingSetup && !creationRetry);
    $('jam-create-name').disabled = busy || !!pendingSetup;
    $('jam-backup-finish').disabled = busy || !backupWords.length || [...$('jam-backup-challenges').querySelectorAll('input')].length !== 3 || [...$('jam-backup-challenges').querySelectorAll('input')].some(field => field.value.trim().toLowerCase() !== backupWords[Number(field.dataset.position)]);
    $('jam-maker').disabled = busy || needsRefresh || (!running && !readiness.canStart);
    renderOrderBook();
    renderSend();
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
  async function discoverWallets() {
    const identity = token, ticket = generation;
    $('jam-connection-state').textContent = 'Checking your Jars wallet…';
    try {
      const config = await api('joinblaket/connection');
      if (identity !== token || ticket !== generation || panel.hidden) return;
      if (!config.configured) throw new Error('Jars is not ready yet. Check Paperclip’s service status and try Refresh wallets.');
      const result = await call('wallets');
      if (!Array.isArray(result.wallets) || result.wallets.some(name => typeof name !== 'string')) throw new Error('Jam returned an invalid wallet list.');
      if (identity !== token || ticket !== generation || panel.hidden) return;
      $('jam-wallet').replaceChildren();
      for (const name of result.wallets) { const option = document.createElement('option'); option.value = name; option.textContent = name; $('jam-wallet').append(option); }
      $('jam-unlock-fields').hidden = result.wallets.length === 0;
      $('jam-create-panel').open = result.wallets.length === 0;
      $('jam-connect').dataset.empty = String(result.wallets.length === 0);
      $('jam-connection-state').textContent = result.wallets.length ? 'Unlock your Jars wallet to continue.' : 'Create your Jars wallet here to get started.';
    } catch (error) {
      if (identity === token && ticket === generation && !panel.hidden) $('jam-connection-state').textContent = 'Your Jars wallet is currently unavailable. Refresh to try again.';
      throw error;
    }
  }
  $('jam-find').onclick = () => work(discoverWallets);
  // Opening Jars only discovers wallets. Creation always requires a fresh review.
  new MutationObserver(() => {
    if (!panel.hidden && token && !authorization && !busy) work(discoverWallets);
  }).observe(panel, {attributes:true, attributeFilter:['hidden']});
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
  $('jam-bonds-load').onclick = () => work(async () => {
    $('jam-bonds').replaceChildren();
    const inventory=PaperclipBonds.validate(await call('bonds'),authorization.wallet);
    const root=$('jam-bonds');
    if (!inventory.bonds.length) root.textContent='No bond coins found in this Jam wallet.';
    for(const coin of inventory.bonds) {
      const card=document.createElement('article'); card.className='action-card';
      const heading=document.createElement('h3'); heading.textContent=amount(coin.value_sat);
      const date=document.createElement('p'); date.textContent='Unlocks '+new Date(coin.locktime*1000).toISOString().slice(0,16).replace('T',' ')+' UTC';
      const point=document.createElement('p'); point.className='mono'; point.textContent=coin.outpoint;
      const status=document.createElement('p'); status.textContent=coin.frozen?'Frozen in Jam':!coin.signable?'Signer unavailable':coin.confirmations===0?'Awaiting confirmation':coin.locktime>=inventory.chain_time?'Locked · waiting for chain time':'Ready to withdraw';
      card.append(heading,date,point,status);
      if (PaperclipBonds.canWithdraw(coin,inventory.chain_time)) {
        const button=document.createElement('button'); button.textContent='Review withdrawal';
        button.onclick=()=>{ if(busy) return; toolsDialog.close(); openSend(null,{...coin}); }; card.append(button);
      }
      root.append(card);
    }
    const hint=document.createElement('p'); hint.className='hint'; hint.textContent='Stop your maker before withdrawing. Maturity uses your node’s chain time and is checked again before review and broadcast.'; root.append(hint);
  });
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
    bondTarget={address:result.address,month,locktime:Date.parse(month+'-01T00:00:00Z')/1000};
    $('jam-bond-fund').hidden=false; $('jam-bond-fund').textContent='Fund from '+jars.find(jar=>jar.id===selected).name;
    $('jam-bond-address').textContent = result.address;
    window.PaperclipReceive.show('jam-bond-address', result.address, 'Bond · unlocks ' + month + '-01 UTC');
  });
  $('jam-receive').onclick = () => work(async () => {
    const result = await call('address', {jar: selected});
    if (typeof result.address !== 'string' || !result.address) throw new Error('Jam returned an invalid receive address.');
    $('jam-address').textContent = result.address;
    window.PaperclipReceive.show('jam-address', result.address, 'Receive into ' + jars[selected].name);
  });
  $('jam-market-amount').oninput = () => { market = null; renderMarket(); };
  $('jam-minimum').oninput = render; $('jam-fee').oninput = render;
  $('jam-maker').onclick = () => work(async () => {
    const stopping = session?.maker_running === true, values = terms();
    const identity = token, ticket = generation, wallet = authorization?.wallet;
    if (!stopping && !values) throw new Error('Review your maker amount and fee.');
    const review = stopping ? 'Stop the maker running on your Jam server?' :
      'Start your Jam maker? Minimum CoinJoin: ' + amount(values.minimum_sat) + '. Your fee: ' + feeLabel(values) +
      '. Mining fee contribution: 0 sats. It uses eligible Jam jars and keeps running when Paperclip closes. This does not create a bond or transfer Paperclip funds.';
    if (!await window.PaperclipReview.ask(review)) return;
    if (!authorization || wallet !== authorization.wallet || token !== identity || ticket !== generation || document.hidden || panel.hidden) return;
    needsRefresh = true;
    await call(stopping ? 'stop_maker' : 'start_maker', stopping ? {} : values); await refresh();
  });
  new MutationObserver(() => {
    if (!$('wallet').hidden) return;
    sendDialog.close();
    toolsDialog.close();
    closeBackup(); $('jam-create-password').value = ''; $('jam-create-confirm').value = '';
    clearPairingCode(); $('jam-pairing-list').replaceChildren(); $('jam-pairing-panel').open = false;
    market = null; renderMarket();
    generation++; payments = null; renderPayments(); $('jam-payments-panel').open = false; authorization = null; jars = []; session = null; selected = 0;
    $('jam-password').value = ''; $('jam-passphrase').value = ''; needsRefresh = false; $('jam-wallet').replaceChildren(); $('jam-unlock-fields').hidden = true;
    clearAddress(); clearBond(); $('jam-bonds').replaceChildren(); $('jam-bond-month').value = ''; render();
  }).observe($('wallet'), {attributes:true, attributeFilter:['hidden']});
})();
