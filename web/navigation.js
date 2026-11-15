// Navigation changes only the visible view, never the payment state.

function showView(view) {
  if (!document.querySelector('[data-screen="' + view + '"]')) return;
  $('view-title').textContent = ({overview:'Your wallet', transfer:'Send & receive', onchain:'On-chain', lightning:'Lightning', activity:'Activity', settings:'Settings', recovery:'Recovery', coinjoin:'CoinJoin'})[view] || 'Your wallet';
  document.querySelectorAll('[data-screen]').forEach(panel => {
    panel.hidden = panel.dataset.screen !== view;
    panel.classList.toggle('view-enter', !panel.hidden);
  });
  document.querySelectorAll('.view-nav [data-view]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.view === (['recovery', 'coinjoin'].includes(view) ? 'settings' : view))));
}
document.querySelectorAll('[data-view]').forEach(button => button.addEventListener('click', () => { showView(button.dataset.view); if (button.dataset.view === 'activity') $('history-load').click(); window.scrollTo({top: 0, behavior: 'instant'}); }));
new MutationObserver(() => {
  document.body.classList.toggle('session-open', !$('wallet').hidden);
  if ($('wallet').hidden) { window.PaperclipReview?.cancel(); showView('overview'); }
  window.scrollTo({top: 0, behavior: 'instant'});
}).observe($('wallet'), {attributes: true, attributeFilter: ['hidden']});
