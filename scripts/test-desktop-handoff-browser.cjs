const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.BROWSER_CHANNEL ? {channel:process.env.BROWSER_CHANNEL} : {})});
  try {
    if (process.argv.includes('--native')) {
      // Read the one-time URL from a private pipe, never argv or an artifact.
      const url = fs.readFileSync(0, 'utf8').trim(), parsed = new URL(url);
      assert.equal(parsed.hostname, '127.0.0.1');
      assert.equal(parsed.protocol, 'http:');
      const page = await browser.newPage(), mutations = [], errors = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('request', request => { if (request.method() !== 'GET') mutations.push(new URL(request.url()).pathname); });
      await page.goto(url);
      await page.locator('#setup').waitFor({state:'visible',timeout:10000});
      assert.equal(await page.evaluate(() => location.hash), '');
      assert.equal(await page.locator('#token').inputValue(), '');
      assert.equal(await page.evaluate(() => sessionStorage.getItem('paperclip.session')), null);
      assert.deepEqual(mutations, ['/api/desktop/handoff/redeem']);
      assert.deepEqual(errors, []);
      console.log('PASS native browser handoff: real daemon sign-in to empty-wallet setup; no keys created or payment submitted');
      return;
    }
    for (const width of [390, 1280]) for (const scenario of ['success', 'expired', 'interrupted', 'malformed', 'nonlocal']) {
      const page = await browser.newPage({viewport:{width,height:1000}}), errors = [];
      page.setDefaultTimeout(10000);
      page.on('pageerror', error => errors.push(error.message));
      const origin = scenario === 'nonlocal' ? 'http://wallet.test' : 'http://127.0.0.1:39999';
      const code = 'A'.repeat(44), owner = 'B'.repeat(44);
      let redeemed = 0;
      await page.route(origin + '/**', async route => {
        const request = route.request(), url = new URL(request.url());
        if (url.pathname === '/api/desktop/handoff/redeem') {
          redeemed++;
          assert.equal(request.method(), 'POST');
          assert.equal(request.headers().authorization, undefined);
          assert.equal(request.headers().origin, origin);
          assert.equal(request.postDataJSON().code, code);
          assert.equal(url.search, '');
          if (scenario === 'interrupted') return route.abort();
          return route.fulfill({status:scenario === 'expired' ? 403 : 200, json:scenario === 'expired' ? {} : {token:owner}});
        }
        if (url.pathname.startsWith('/api/')) {
          assert.equal(request.method(), 'GET', 'No wallet or payment mutation permitted');
          if (url.pathname === '/api/v1/wallet') assert.equal(request.headers().authorization, 'Bearer ' + owner);
          const value = url.pathname === '/api/v1/wallet' ? {fingerprint:null} :
            url.pathname === '/api/ui-platform' ? {platform:'standalone'} :
            url.pathname === '/api/v1/wallet/platform-node' ? {available:false} : {};
          return route.fulfill({json:value});
        }
        const file = path.join(__dirname, '../web', url.pathname === '/' ? 'index.html' : url.pathname.slice(1));
        return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js') ? 'application/javascript' : file.endsWith('.css') ? 'text/css' : file.endsWith('.html') ? 'text/html' : 'image/svg+xml'});
      });
      await page.goto(origin + '/#desktop-handoff=' + (scenario === 'malformed' ? 'bad' : code));
      if (scenario === 'success') await page.locator('#setup').waitFor({state:'visible'});
      else await page.waitForFunction(() => document.querySelector('#status').textContent.includes('Desktop sign-in expired or was interrupted'));
      assert.equal(await page.evaluate(() => location.hash), '');
      assert.equal(await page.locator('#token').inputValue(), '');
      assert.equal(await page.evaluate(() => sessionStorage.getItem('paperclip.session')), null);
      assert.equal(redeemed, ['malformed','nonlocal'].includes(scenario) ? 0 : 1);
      assert.equal(await page.evaluate(() => Array.from(document.querySelector('#unlock').elements).some(control => control.disabled)), false);
      assert.equal(await page.evaluate(async () => { try { await PaperclipDesktopHandoff.redeem(); return true; } catch { return false; } }), false);
      assert.equal(redeemed, ['malformed','nonlocal'].includes(scenario) ? 0 : 1, 'Never retry an already consumed handoff');
      assert.deepEqual(errors, []);
      await page.close();
    }
    console.log('PASS desktop handoff browser: empty-wallet setup, URL removal, no credential persistence, expired/interrupted/malformed/nonlocal rejection, no replay; phone and desktop widths');
  } finally { await browser.close(); }
})().catch(error => { console.error(process.argv.includes('--native') ? 'Native desktop browser handoff failed; credentials omitted.' : error); process.exit(1); });
