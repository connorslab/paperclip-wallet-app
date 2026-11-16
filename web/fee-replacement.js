'use strict';
// Fee replacement is a distinct, single-use review. Never replay a timed-out commit.
window.PaperclipFeeReplacement = {
  control(txid) {
    const area = document.createElement('details'); area.className = 'fee-replacement';
    const heading = document.createElement('summary'); heading.textContent = 'Payment assistance'; area.append(heading);
    const custom = document.createElement('details'), summary = document.createElement('summary');
    summary.textContent = 'Custom total fee';
    const label = document.createElement('label'); label.textContent = 'New total fee in sats (optional)';
    const fee = document.createElement('input'); fee.inputMode = 'numeric'; label.append(fee);
    const help = document.createElement('p'); help.className = 'hint';
    help.textContent = 'Leave blank to review twice the original fee. Confirmation time is not guaranteed.';
    custom.append(summary, label, help);
    const button = document.createElement('button'); button.type = 'button'; button.className = 'secondary'; button.textContent = 'Review fee increase';
    const output = document.createElement('p'); output.setAttribute('role', 'status');
    area.append(custom, button, output);
    button.onclick = async () => {
      if (button.disabled) return;
      const context = walletContext(), entered = fee.value;
      button.disabled = true; fee.disabled = true; output.textContent = 'Checking payment…';
      let submitted = false;
      try {
        if (entered && (!/^[0-9]+$/.test(entered) || !Number.isSafeInteger(Number(entered)))) throw new Error('Enter a total fee in whole sats.');
        const review = await api('onchain/replacement/prepare', {txid, new_fee_sat: entered ? Number(entered) : 0});
        if (!currentWallet(context) || !token || !area.isConnected) return;
        if (review.original_txid !== txid || review.replacement_txid === txid || !/^[0-9a-f]{64}$/.test(review.replacement_txid) ||
          !['old_fee_sat', 'new_fee_sat', 'additional_fee_sat'].every(key => Number.isSafeInteger(review[key]) && review[key] >= 0) ||
          review.new_fee_sat > 1_000_000 || review.new_fee_sat <= review.old_fee_sat || review.additional_fee_sat !== review.new_fee_sat - review.old_fee_sat ||
          !Array.isArray(review.recipients) || !review.recipients.length || review.recipients.some(r => typeof r.address !== 'string' || !r.address.length || r.address.length > 128 || !Number.isSafeInteger(r.amount_sat) || r.amount_sat <= 0 || r.amount_sat > 2_100_000_000_000_000)) {
          throw new Error('The fee review is incomplete. No replacement was submitted.');
        }
        const recipients = review.recipients.map(r => r.amount_sat.toLocaleString() + ' sats to\n' + r.address).join('\n\n');
        output.textContent = '';
        if (!await PaperclipReview.ask('Increase the fee for this payment?\n\n' + recipients +
          '\n\nOriginal fee: ' + review.old_fee_sat.toLocaleString() + ' sats\nNew total fee: ' + review.new_fee_sat.toLocaleString() +
          ' sats\nAdditional debit: ' + review.additional_fee_sat.toLocaleString() + ' sats\n\nRecipients and amounts stay the same. Confirmation is still required.')) return;
        if (!currentWallet(context) || !token || !area.isConnected || fee.value !== entered) return;
        submitted = true; output.textContent = 'Submitting replacement…';
        const result = await mutate('onchain/replacement/commit', {replacement_txid: review.replacement_txid, new_fee_sat: review.new_fee_sat});
        if (!currentWallet(context)) return;
        output.textContent = (result.state === 'submitted' ? 'Replacement submitted. Awaiting confirmation.' : 'Replacement saved. Broadcast is not confirmed; check status before another action.') + '\n' + review.replacement_txid;
      } catch (error) {
        if (currentWallet(context)) output.textContent = (submitted ? 'Check payment status before another action. ' : '') + error.message;
      } finally {
        button.disabled = submitted; fee.disabled = submitted;
      }
    };
    return area;
  }
};
