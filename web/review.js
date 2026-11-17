'use strict';
// A review never submits a payment. The caller owns the single submission.
window.PaperclipReview = (() => {
  let pending = null;
  const dialog = document.createElement('dialog');
  dialog.className = 'review-sheet';
  dialog.setAttribute('aria-labelledby', 'review-title');
  const title = document.createElement('h2'); title.id = 'review-title'; title.textContent = 'Review and confirm';
  const text = document.createElement('div'); text.className = 'review-content';
  const actions = document.createElement('div'); actions.className = 'review-actions';
  const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'secondary'; cancel.textContent = 'Go back';
  const approve = document.createElement('button'); approve.type = 'button'; approve.textContent = 'Confirm';
  actions.append(cancel, approve); dialog.append(title, text, actions); document.body.append(dialog);
  function finish(value) { const resolve = pending; pending = null; if (dialog.open) dialog.close(); text.textContent = ''; resolve?.(value); }
  cancel.onclick = () => finish(false);
  approve.onclick = () => finish(true);
  dialog.addEventListener('cancel', event => { event.preventDefault(); finish(false); });
  dialog.addEventListener('close', () => { if (pending) finish(false); });
  function open(content, heading = 'Review and confirm') {
    if (pending) return Promise.resolve(false);
    const session = token;
    title.textContent = heading; text.replaceChildren(content);
    return new Promise(resolve => {
      pending = value => resolve(value && session === token && !!token);
      dialog.showModal(); cancel.focus();
    });
  }
  function element(tag, value, className) {
    const node = document.createElement(tag); node.textContent = value;
    if (className) node.className = className;
    return node;
  }
  return { ask: message => open(document.createTextNode(message)),
    withdrawal(quote) {
      const content = element('div', '', 'withdrawal-review');
      const amount = element('div', '', 'withdrawal-review-amount');
      amount.append(element('span', 'You receive'), element('strong', quote.net_sat.toLocaleString() + ' sats'));
      const details = element('dl', '');
      for (const [label, value] of [['Withdrawal fee', quote.fee_sat.toLocaleString() + ' sats'],
          ['Total Ark debit', quote.total_sat.toLocaleString() + ' sats'], ['Selected Ark inputs', String(quote.input_count)]]) {
        const row = element('div', ''); row.append(element('dt', label), element('dd', value)); details.append(row);
      }
      const destination = element('div', '', 'withdrawal-review-destination');
      destination.append(element('span', 'To your on-chain wallet'), element('code', quote.destination));
      content.append(element('p', 'Ark → On-chain', 'withdrawal-review-route'), amount, details, destination,
        element('p', 'Review valid for 60 seconds. Your withdrawal needs on-chain confirmation.', 'withdrawal-review-note'));
      return open(content, 'Review withdrawal');
    }, cancel: () => finish(false) };
})();
