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
  function clearAddress() { window.PaperclipReceive?.clear('jam-address'); $('jam-address').textContent = ''; }
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
    $('jam-jars').replaceChildren(); $('jam-amounts').replaceChildren();
    for (const jar of jars) {
      const button = document.createElement('button'); button.type = 'button'; button.className = 'jam-jar';
      button.style.setProperty('--jar-color', colors[jar.id]); button.setAttribute('aria-pressed', String(jar.id === selected));
      const art = document.createElement('span'); art.className = 'jar-art' + (jar.total_sat > 0 ? ' funded' : ''); art.setAttribute('aria-hidden', 'true');
      const name = document.createElement('strong'); name.textContent = jar.name;
      const balance = document.createElement('span'); balance.textContent = amount(jar.total_sat);
      button.append(art, name, balance); button.onclick = () => { selected = jar.id; clearAddress(); render(); };
      $('jam-jars').append(button);
    }
    const jar = jars.find(jar => jar.id === selected);
    if (jar) {
      $('jam-selected-name').textContent = jar.name; $('jam-receive').textContent = 'Receive into ' + jar.name;
      for (const [field, label] of [['confirmed_sat','Confirmed'],['pending_sat','Pending'],['frozen_sat','Frozen'],['bond_sat','Fidelity bonds']]) {
        if (jar[field] === 0 && field !== 'confirmed_sat') continue;
        const dt = document.createElement('dt'), dd = document.createElement('dd'); dt.textContent = label; dd.textContent = amount(jar[field]);
        $('jam-amounts').append(dt, dd);
      }
    }
    const running = session?.maker_running === true, values = terms();
    $('jam-maker-status').textContent = running ? 'Running on your server' : 'Not running';
    $('jam-maker-fields').hidden = running; $('jam-maker').textContent = running ? 'Stop maker' : 'Review maker setup';
    const ready = values && jars.some(jar => jar.confirmed_sat >= values.minimum_sat) && jars.some(jar => jar.bond_sat > 0) &&
      session?.rescanning === false && session?.coinjoin_in_process === false;
    $('jam-maker-readiness').textContent = needsRefresh ? 'Refresh maker status before another action.' : running ? '' : !jars.some(jar => jar.bond_sat > 0)
      ? 'No fidelity bond found. JoinBlaket’s default taker policy selects bonded makers. Create or review a bond in Jam before starting.'
      : !ready ? 'Check your terms, confirmed jar funds, and Jam sync status.' : 'Review your terms before starting.';
    panel.querySelectorAll('button, input, select').forEach(control => { control.disabled = busy; });
    $('jam-maker').disabled = busy || needsRefresh || (!running && !ready);
  }
  async function work(action) {
    if (busy) return;
    busy = true; $('jam-status').textContent = 'Connecting…'; render();
    try { await action(); $('jam-status').textContent = ''; }
    catch (error) { $('jam-status').textContent = error.message; }
    finally { busy = false; render(); }
  }
  async function refresh() {
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
    const result = await call('wallets');
    if (!Array.isArray(result.wallets) || result.wallets.some(name => typeof name !== 'string')) throw new Error('Jam returned an invalid wallet list.');
    $('jam-wallet').replaceChildren();
    for (const name of result.wallets) { const option = document.createElement('option'); option.value = name; option.textContent = name; $('jam-wallet').append(option); }
    $('jam-unlock-fields').hidden = result.wallets.length === 0;
    $('jam-connection-state').textContent = result.wallets.length ? 'Select your separate Jam wallet.' : 'Create a separate wallet in Jam, then refresh this connection.';
  });
  $('jam-unlock').onclick = () => work(async () => {
    const wallet = $('jam-wallet').value, password = $('jam-password').value, bip39_passphrase = $('jam-passphrase').value;
    $('jam-password').value = ''; $('jam-passphrase').value = '';
    const result = await call('unlock', {wallet, password, bip39_passphrase});
    if (result.walletname !== wallet || typeof result.token !== 'string' || !result.token) throw new Error('Jam did not unlock the selected wallet.');
    authorization = {wallet, token: result.token}; await refresh();
  });
  $('jam-refresh').onclick = () => work(refresh);
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
    generation++; authorization = null; jars = []; session = null; selected = 0;
    $('jam-password').value = ''; $('jam-passphrase').value = ''; needsRefresh = false; $('jam-wallet').replaceChildren(); $('jam-unlock-fields').hidden = true;
    clearAddress(); render();
  }).observe($('wallet'), {attributes:true, attributeFilter:['hidden']});
})();
