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
  function open(content, heading = 'Review and confirm', canApprove = () => true) {
    if (pending) return Promise.resolve(false);
    const session = token;
    title.textContent = heading; text.replaceChildren(content);
    approve.disabled = !canApprove();
    content.addEventListener('change', () => { approve.disabled = !canApprove(); });
    return new Promise(resolve => {
      pending = value => resolve(value && session === token && !!token && canApprove());
      dialog.showModal(); cancel.focus();
    });
  }
  function element(tag, value, className) {
    const node = document.createElement(tag); node.textContent = value;
    if (className) node.className = className;
    return node;
  }
  return { ask: message => open(document.createTextNode(message)),
    nodeRecovery(review) {
      const content = element('div', '', 'withdrawal-review node-recovery-review');
      const details = element('dl', '', 'jam-payment-costs');
      for (const [label, value] of [['Network', review.network], ['Saved records', String(review.payment_count)], ['Sends to check', String(review.unresolved_sends)]]) {
        const row = element('div', ''); row.append(element('dt', label), element('dd', value)); details.append(row);
      }
      content.append(details);
      const identities = element('details', ''); identities.append(element('summary', 'Wallet and node identities'));
      identities.append(element('p', 'Assign to the current hot wallet'), element('code', review.wallet_id));
      if (review.connection) identities.append(element('p', review.connection.endpoint), element('code', review.connection.node_id));
      else identities.append(element('p', 'No saved node connection.'));
      content.append(identities, element('p', 'Credentials and payment outcomes stay unchanged. Nothing is sent or retried. Check unresolved payments after recovery.', 'withdrawal-review-note'));
      function confirmation(label) {
        const row = element('label', '', 'node-toggle'), input = document.createElement('input'); input.type = 'checkbox';
        row.append(input, document.createTextNode(label)); content.append(row); return input;
      }
      const owner = confirmation('These records belong to this hot wallet. I checked the identities above.');
      const backup = confirmation('I have a complete host backup, including the older node records.');
      content.append(element('p', 'A matching short fingerprint does not prove ownership. If unsure, go back and check the original node and backup.', 'hint'));
      return open(content, 'Recover node records', () => owner.checked && backup.checked);
    },
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
