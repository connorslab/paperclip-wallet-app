'use strict';
// The platform affects help text only, never authentication or stored credentials.
(async () => {
  try {
    const response = await fetch('/api/ui-platform', {cache: 'no-store', signal: AbortSignal.timeout(5000)});
    if (!response.ok) return;
    const {platform} = await response.json();
    if (platform === 'startos') {
      $('token-label').textContent = 'Wallet access token';
      $('login-instructions').textContent = 'In StartOS, open Paperclip Wallet, then Actions \u2192 Show wallet access token. Paste that token below. Do not use your StartOS password or recovery phrase.';
    } else if (platform === 'umbrel') {
      $('token-label').textContent = 'App password';
      $('login-instructions').textContent = 'Use the app password shown for Paperclip Wallet in Umbrel. Do not use your Umbrel account password or recovery phrase.';
    }
  } catch { /* Generic token instructions remain usable while metadata is unavailable. */ }
})();
