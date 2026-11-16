'use strict';
// Navigation never repeats a wallet action or dismisses an uncertain payment.
(() => {
  const titles = {overview:'Your wallet', transfer:'Send & receive', onchain:'On-chain', lightning:'Lightning', activity:'Activity', settings:'Settings', recovery:'Recovery', health:'Wallet health', coinjoin:'CoinJoin', wallets:'Your wallets', signing:'Send with your signer'};
  let current = 'overview';
  const valid = view => Object.hasOwn(titles, view);
  const requestedView = () => valid(location.hash.slice(1)) ? location.hash.slice(1) : 'overview';
  function show(view, {record = true, focus = true} = {}) {
    if (!valid(view) || $('wallet').hidden) return;
    if (window.PaperclipAccounts?.selectedId && ['transfer','onchain'].includes(view)) view = view === 'transfer' ? 'signing' : 'overview';
    if (!window.PaperclipAccounts?.selectedId && view === 'signing') view = 'wallets';
    window.PaperclipReview?.cancel();
    if (view !== current) $('status').textContent = '';
    if (record && view !== current) history.pushState({paperclipView:view, parent:current}, '', '#' + view);
    current = view;
    const heading = $('view-title');
    heading.textContent = titles[view]; heading.tabIndex = -1;
    document.title = titles[view] + ' · Paperclip Wallet';
    document.querySelectorAll('[data-screen]').forEach(panel => {
      const kind = window.PaperclipAccounts?.selectedId ? 'hardware' : 'hot';
      panel.hidden = panel.dataset.screen !== view || (!!panel.dataset.wallet && panel.dataset.wallet !== kind);
      panel.classList.toggle('view-enter', !panel.hidden);
    });
    const section = ['recovery', 'coinjoin', 'wallets', 'health'].includes(view) ? 'settings' : ['transfer', 'onchain', 'signing'].includes(view) ? 'overview' : view;
    document.querySelectorAll('.view-nav [data-view]').forEach(button => {
      const selected = button.dataset.view === section;
      button.setAttribute('aria-pressed', String(selected));
      if (selected) button.setAttribute('aria-current', 'page'); else button.removeAttribute('aria-current');
    });
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
      window.PaperclipReview?.cancel(); current = 'overview';
      history.replaceState({paperclipView:'overview'}, '', location.pathname + location.search);
      document.title = 'Paperclip Wallet · Locked';
      $('token').focus();
    } else {
      const view = requestedView();
      history.replaceState({paperclipView:view}, '', '#' + view);
      show(view, {record:false});
    }
  }).observe($('wallet'), {attributes:true, attributeFilter:['hidden']});
  window.PaperclipNavigation = {show, refresh:()=>show(current,{record:false,focus:false})};
})();
