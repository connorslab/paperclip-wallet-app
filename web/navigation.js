'use strict';
// Navigation never repeats a wallet action or dismisses an uncertain payment.
(() => {
  const titles = {overview:'Your wallet', transfer:'Send & receive', onchain:'On-chain', lightning:'Lightning', 'ark-lightning':'Send from Ark', 'ark-lightning-receive':'Receive into Ark', 'ark-lightning-offer':'Ark reusable offer', 'ark-lightning-status':'Ark payment status', node:'Your Lightning node', 'node-pay':'Send from your node', 'node-receive':'Receive into your node', 'node-activity':'Node payment activity', 'bridge-reusable':'Reusable bridge offers', 'bridge-send':'Pay BTC with XBT', 'bridge-send-detail':'Review Bridge payment', 'bridge-send-activity':'Bridge payment activity', bridge:'Paperclip Bridge', 'bridge-detail':'Bridge receive request', 'bridge-activity':'Bridge activity', activity:'Activity', settings:'Settings', recovery:'Recovery', health:'Wallet health', coinjoin:'Jars', wallets:'Your wallets', signing:'Send with your signer'};
  let current = 'overview', revision = 0;
  const valid = view => Object.hasOwn(titles, view);
  const requestedView = () => valid(location.hash.slice(1)) ? location.hash.slice(1) : 'overview';
  function show(view, {record = true, focus = true} = {}) {
    if (!valid(view) || $('wallet').hidden) return;
    if (window.PaperclipAccounts?.selectedId && view.startsWith('ark-lightning')) view = 'lightning';
    if (window.PaperclipAccounts?.selectedId && ['transfer','onchain'].includes(view)) view = view === 'transfer' ? 'signing' : 'overview';
    if (!window.PaperclipAccounts?.selectedId && view === 'signing') view = 'wallets';
    window.PaperclipReview?.cancel();
    if (view !== current) $('status').textContent = '';
    if (record && view !== current) history.pushState({paperclipView:view, parent:current}, '', '#' + view);
    if (view !== current) revision++;
    current = view;
    const heading = $('view-title');
    heading.textContent = titles[view]; heading.tabIndex = -1;
    document.title = titles[view] + ' · Paperclip Wallet';
    document.querySelectorAll('[data-screen]').forEach(panel => {
      const kind = window.PaperclipAccounts?.selectedId ? 'hardware' : 'hot';
      panel.hidden = (panel.dataset.screen !== view && !(panel.dataset.screen === 'ark-lightning' && view.startsWith('ark-lightning')) && !(panel.dataset.screen === 'node' && view.startsWith('node-')) && !(panel.dataset.screen === 'bridge' && ['bridge-detail','bridge-activity'].includes(view)) && !(panel.dataset.screen === 'bridge-send' && view.startsWith('bridge-send-'))) || (!!panel.dataset.wallet && panel.dataset.wallet !== kind);
      panel.classList.toggle('view-enter', !panel.hidden);
    });
    const section = ['recovery', 'wallets', 'health'].includes(view) ? 'settings' : ['transfer', 'onchain', 'signing'].includes(view) ? 'overview' : (view.startsWith('node') || view.startsWith('bridge') || view.startsWith('ark-lightning')) ? 'lightning' : view;
    document.querySelectorAll('.view-nav [data-view]').forEach(button => {
      const selected = button.dataset.view === section;
      button.setAttribute('aria-pressed', String(selected));
      if (selected) button.setAttribute('aria-current', 'page'); else button.removeAttribute('aria-current');
    });
    document.querySelectorAll('[data-ark-task]').forEach(task => { task.hidden = task.dataset.arkTask !== view; });
    document.querySelectorAll('.task-switch [data-view]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.view === view)));
    window.scrollTo({top:0, behavior:'instant'});
    if (focus) heading.focus({preventScroll:true});
    window.dispatchEvent(new CustomEvent('paperclip:view', {detail:view}));
  }
  document.querySelectorAll('[data-view]').forEach(button => button.addEventListener('click', () => {
    const view = button.dataset.view;
    if (button.hasAttribute('data-back') && history.state?.parent === view) { history.back(); return; }
    show(view);
    if (view === 'activity') $('history-load').click();
  }));
  window.addEventListener('popstate', () => {
    if ($('wallet').hidden) return;
    show(requestedView(), {record:false});
  });
  new MutationObserver(() => {
    const locked = $('wallet').hidden;
    document.body.classList.toggle('session-open', !locked);
    if (locked) {
      window.PaperclipReview?.cancel(); revision++; current = 'overview';
      history.replaceState({paperclipView:'overview'}, '', location.pathname + location.search);
      document.title = 'Paperclip Wallet · Locked';
      $('token').focus();
    } else {
      const view = requestedView();
      history.replaceState({paperclipView:view}, '', '#' + view);
      show(view, {record:false});
    }
  }).observe($('wallet'), {attributes:true, attributeFilter:['hidden']});
  window.PaperclipNavigation = {show, get revision() {return revision;}, refresh:()=>show(current,{record:false,focus:false})};
  let transferRevision = 0;
  function transfer(direction) {
    if (!['send','receive'].includes(direction)) return;
    transferRevision++;
    window.PaperclipReview?.cancel();
    $('ark-estimate').hidden = true;
    for (const name of ['send','receive']) {
      const active = name === direction;
      $('transfer-' + name).hidden = !active;
      $('transfer-' + name).classList.toggle('view-enter', active);
      $('transfer-' + name + '-choice').setAttribute('aria-pressed', String(active));
    }
  }
  $('transfer-send-choice').onclick = () => transfer('send');
  $('transfer-receive-choice').onclick = () => transfer('receive');
  window.PaperclipTransfer = {get revision() {return transferRevision;}};

})();
