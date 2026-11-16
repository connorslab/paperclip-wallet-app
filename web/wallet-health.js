'use strict';
(() => {
  let checked = null, generation = -1, reportContext = null;
  function clear() { checked = null; reportContext = null; $('health-status').textContent = 'Check your connection when you are ready.'; $('health-preview').hidden = true; $('health-report-text').textContent = ''; }
  $('health-check').onclick = async () => {
    const context = walletContext(); $('health-check').disabled = true; checked = null;
    $('health-status').textContent = 'Checking server response…';
    try {
      const result = await api('bitcoin/tip');
      if (!currentWallet(context)) return;
      if (!Number.isSafeInteger(result.tip_height) || result.tip_height < 0) throw new Error('Invalid tip');
      checked = Date.now(); $('health-status').textContent = 'Wallet server responded at ' + new Date(checked).toLocaleTimeString() + '. Its chain data may be cached. Open Connections if payments are not progressing.';
    } catch (_) { if (currentWallet(context)) $('health-status').textContent = 'Could not verify the server response. Check Connections and try again.'; }
    finally { $('health-check').disabled = false; }
  };
  $('health-report').onclick = () => {
    if (!token || !network || $('wallet').hidden) return;
    reportContext = walletContext();
    const fresh = checked !== null && Date.now() - checked >= 0 && Date.now() - checked < 75000;
    // Only enums and fixed text enter this report. Do not include errors or raw API data.
    $('health-report-text').textContent = 'Paperclip support report v1\nPlatform: web\nNetwork: ' + (network === 'bitcoin' ? 'mainnet' : 'regtest') + '\nWallet type: ' + (PaperclipAccounts.selectedId ? 'hardware' : 'hot') + '\nServer response: ' + (fresh ? 'recently verified; chain data may be cached' : 'not recently verified') + '\nHost backup verification: unavailable in browser\nSecrets and financial details: excluded';
    $('health-preview').hidden = false;
  };
  $('health-download').onclick = () => {
    if (!reportContext || !currentWallet(reportContext)) { clear(); return; }
    const url = URL.createObjectURL(new Blob([$('health-report-text').textContent], {type:'text/plain'}));
    const link = document.createElement('a'); link.href = url; link.download = 'paperclip-support.txt'; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  window.addEventListener('paperclip:view', () => { const next = PaperclipAccounts.generation; if (generation !== next) { generation = next; clear(); } });
  new MutationObserver(() => { if ($('wallet').hidden) clear(); }).observe($('wallet'), {attributes:true, attributeFilter:['hidden']});
})();
