'use strict';
// Destination lookup reveals an address in a saved wallet; it never switches or spends.
(() => {
  for (const id of ['chain-destination', 'cold-destination']) {
    const input = $(id), area = document.createElement('div'); area.className = 'own-wallet-transfer';
    const load = document.createElement('button'); load.type = 'button'; load.className = 'secondary'; load.textContent = 'Move to my other wallet';
    const select = document.createElement('select'); select.hidden = true; select.setAttribute('aria-label', 'Destination wallet');
    const output = document.createElement('p'); output.setAttribute('role', 'status');
    area.append(load, select, output); input.closest('label').before(area);
    let revision = 0, destination = '', generation = globalThis.PaperclipAccounts?.generation ?? 0;
    const clear = () => { revision++; select.hidden = true; select.replaceChildren(); output.textContent = ''; destination = ''; };
    load.onclick = async () => {
      const context = walletContext(), ticket = ++revision;
      load.disabled = true; output.textContent = 'Loading your wallets…';
      try {
        const data = await api('hardware/accounts');
        if (!currentWallet(context) || ticket !== revision) return;
        if (!Array.isArray(data.accounts) || data.accounts.some(a => !/^[0-9a-f]{64}$/.test(a.id) || typeof a.label !== 'string')) throw new Error('Could not verify saved wallets.');
        const source = globalThis.PaperclipAccounts?.selectedId || '';
        const targets = [{id:'', label:'Hot wallet'}, ...data.accounts].filter(a => a.id !== source);
        select.replaceChildren(new Option('Choose a destination wallet', '__none__'));
        for (const target of targets) select.add(new Option(target.label, target.id));
        select.hidden = !targets.length;
        output.textContent = targets.length ? 'Choose the receiving wallet. You will review the address and total cost before approval.' : 'Add another wallet in Settings → Your wallets first.';
      } catch (error) { if (currentWallet(context) && ticket === revision) output.textContent = error.message; }
      finally { load.disabled = false; }
    };
    select.onchange = async () => {
      const target = select.value; if (target === '__none__') return;
      const context = walletContext(), ticket = ++revision, source = globalThis.PaperclipAccounts?.selectedId || '';
      select.disabled = true; load.disabled = true; input.value = ''; output.textContent = 'Getting the receiving address…';
      try {
        const data = await api('hardware/request', {operation:'destination', account:source, target_account:target});
        if (!currentWallet(context) || ticket !== revision) return;
        if (data.account !== target || typeof data.address !== 'string' || !data.address || typeof data.label !== 'string' || data.network !== network) throw new Error('Destination wallet changed. Choose it again.');
        destination = data.address; input.value = destination; input.dispatchEvent(new Event('input', {bubbles:true}));
        output.textContent = 'To ' + data.label + ' · On-chain transfer. Network fees apply. Verify a hardware receiving address on its signer, then review the payment.';
        input.focus();
      } catch (error) { if (currentWallet(context) && ticket === revision) output.textContent = error.message; }
      finally { select.disabled = false; load.disabled = false; }
    };
    input.addEventListener('input', () => { if (input.value !== destination) { revision++; destination = ''; select.value = '__none__'; output.textContent = ''; } });
    $('wallet-select').addEventListener('change', clear);
    window.addEventListener('paperclip:view', () => { const next = globalThis.PaperclipAccounts?.generation ?? 0; if (next !== generation) { generation = next; clear(); } });
    new MutationObserver(() => { if ($('wallet').hidden) clear(); }).observe($('wallet'), {attributes:true, attributeFilter:['hidden']});
  }
})();
