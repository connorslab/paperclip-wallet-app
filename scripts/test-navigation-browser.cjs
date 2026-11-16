const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
(async () => {
 const browser = await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL ? {channel:process.env.BROWSER_CHANNEL} : {})});
 try {
  for (const width of [390,800,1280]) {
   const page = await browser.newPage({viewport:{width,height:1000},reducedMotion:'reduce'}), errors=[], mutations=[];
   page.on('pageerror', error => errors.push(error.message));
   await page.route('http://wallet.test/**', async route => {
    const url=new URL(route.request().url()), name=url.pathname.replace('/api/v1/','');
    if (url.pathname.startsWith('/api/')) {
     if (route.request().method() !== 'GET') mutations.push(name);
     const value = name==='wallet' ? {fingerprint:'synthetic'} : name==='wallet/identity'
       ? {network:'regtest',exit_profile:2,lightning_enabled:true,lightning_debit_limit:true}
       : name==='wallet/balance' ? {spendable_sat:0} : name==='onchain/balance' ? {confirmed_sat:0}
       : name==='bitcoin/tip' ? {tip_height:1000} : [];
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   await page.goto('http://wallet.test/');
   await page.locator('#token').fill('synthetic-token');
   await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();
   await page.locator('#wallet').waitFor({state:'visible'});
   for (const view of ['transfer','onchain','lightning','coinjoin','activity','settings','overview']) {
    const nested=['transfer','onchain'].includes(view);
    const menu=page.locator(`.view-nav [data-view="${nested?'overview':view}"]`);
    await menu.click();
    if (nested) await page.locator(`.overview-note [data-view="${view}"]`).click();
    assert.equal(await menu.getAttribute('aria-current'),'page');
    assert.equal(await page.locator('.view-nav [aria-current="page"]').count(),1);
    assert(await page.locator('#view-title').evaluate(el=>el===document.activeElement));
    assert(await page.locator('[data-screen]:visible').evaluateAll((panels,v)=>panels.every(p=>p.dataset.screen===v),view));
    assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)),'No horizontal overflow');
    assert((await menu.boundingBox()).height>=44,'Navigation touch target');
    assert.equal(await page.locator('[data-screen]:visible').first().evaluate(el=>getComputedStyle(el).animationName),'none','Reduced motion');
    if (view === 'settings') {
      assert(await page.locator('.menu-row small.hot-wallet-tool').isVisible(),'Hot wallet recovery guidance visible');
      assert(!(await page.locator('.menu-row small.cold-wallet-tool').isVisible()),'Signer recovery guidance hidden for hot wallets');
    }
    if (process.env.SCREENSHOT_DIR && ['overview','coinjoin','settings'].includes(view)) {
      await page.locator('#network').evaluate(el=>el.textContent='UI FIXTURE · NO LIVE FUNDS');
      await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`navigation-${view}-${width}.png`),fullPage:true});
    }
   }
   await page.locator('.view-nav [data-view="overview"]').click();
   await page.locator('.overview-note [data-view="transfer"]').click();
   await page.locator('#destination').fill('ark-synthetic-draft');
   await page.locator('.view-nav [data-view="settings"]').click();
   await page.goBack();
   await page.waitForFunction(()=>document.querySelector('[data-screen="transfer"]').hidden===false);
   assert.equal(await page.locator('#destination').inputValue(),'ark-synthetic-draft');
   await page.goForward();
   await page.waitForFunction(()=>document.querySelector('.view-nav [data-view="settings"]').getAttribute('aria-current')==='page');
   await page.locator('[data-screen="settings"] [data-view="recovery"]').click();
   assert.equal(await page.locator('.view-nav [data-view="settings"]').getAttribute('aria-current'),'page');
   await page.locator('[data-screen="recovery"] [data-back]').click();
   await page.waitForFunction(()=>document.querySelector('[data-screen="settings"]').hidden===false);
   await page.evaluate(()=>{ window.reviewResult=null; window.PaperclipReview.ask('Synthetic review; no payment').then(result=>window.reviewResult=result); });
   await page.keyboard.press('Escape');
   assert.equal(await page.evaluate(()=>window.reviewResult),false);
   await page.evaluate(()=>transactionResult('pending','Transaction submitted','Synthetic receipt; no payment'));
   await page.locator('#transaction-result-activity').click();
   await page.waitForFunction(()=>document.querySelector('[data-screen="activity"]').hidden===false);
   assert.equal(await page.locator('.view-nav [data-view="activity"]').getAttribute('aria-current'),'page');
   assert.equal(await page.locator('#transaction-result').isVisible(),false);
   await page.locator('#lock').click();
   await page.locator('#login').waitFor({state:'visible'});
   await page.goBack();
   assert(await page.locator('#wallet').isHidden(),'Browser Back must not unlock private views');
   assert.deepEqual(mutations,[],'Navigation must not submit wallet actions');
   assert.deepEqual(errors,[]);
   await page.close();
  }
  console.log('PASS navigation: compact/tablet/desktop, selected menu, focus, browser Back/Forward, nested parent, draft preservation, lock, review cancellation, no wallet mutations');
 } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exit(1)});
