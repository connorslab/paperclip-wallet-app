'use strict';
// Remove the one-time code before the rest of the UI loads. It is never saved in
// storage, copied into a form, or sent in a query string or Authorization header.
(() => {
  let fragment = location.hash;
  const pending = fragment.startsWith('#desktop-handoff');
  let cleared = false;
  if (pending) {
    try { history.replaceState(null, '', location.pathname + location.search); cleared = true; }
    catch { /* Fail closed if the browser cannot clear the address. */ }
  }
  let code = pending && /^#desktop-handoff=[A-Za-z0-9_-]{44}$/.test(fragment) ? fragment.slice(17) : null;
  fragment = null;
  globalThis.PaperclipDesktopHandoff = {
    pending,
    async redeem() {
      const once = code;
      code = null;
      if (!pending || !cleared || !once || location.protocol !== 'http:' ||
          !['127.0.0.1', '[::1]'].includes(location.hostname)) throw new Error('Desktop sign-in unavailable.');
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 10000);
      try {
        const response = await fetch('/api/desktop/handoff/redeem', {
          method: 'POST', headers: {'Content-Type':'application/json'},
          credentials: 'omit', redirect: 'error', cache: 'no-store', signal: controller.signal,
          body: JSON.stringify({code: once})
        });
        if (!response.ok) throw new Error('Desktop sign-in expired.');
        const result = await response.json();
        if (typeof result?.token !== 'string' || !/^[A-Za-z0-9_-]{44}$/.test(result.token)) throw new Error('Desktop sign-in unavailable.');
        return result.token;
      } finally { clearTimeout(timer); }
    }
  };
})();
