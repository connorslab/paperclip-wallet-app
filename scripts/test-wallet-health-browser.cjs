const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,840,1280]) {
   const page=await browser.newPage({viewport:{width,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
   let bad=false;
   await page.route('http://wallet.test/**',route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     assert.equal(route.request().method(),'GET','Health must not mutate a wallet');
     const data=name==='wallet'?{fingerprint:'PRIVATE-FINGERPRINT'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,lightning_enabled:false}:
      name==='wallet/balance'?{spendable_sat:12345678}:name==='onchain/balance'?{confirmed_sat:87654321}:
      name==='hardware/accounts'?{accounts:[]}:
      name==='bitcoin/tip'?{tip_height:bad?'malformed':1000,server:'SECRET-URL',macaroon:'SECRET-CREDENTIAL'}:[];
     return route.fulfill({json:data});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   await page.goto('http://wallet.test/');await page.locator('#token').fill('SECRET-TOKEN');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});
   await page.locator('.view-nav [data-view=settings]').click();await page.locator('[data-view=health]').click();
   await page.locator('#health-report').click();assert.match(await page.locator('#health-report-text').textContent(),/not recently verified/);
   await page.locator('#health-check').click();await page.locator('#health-status').filter({hasText:'responded'}).waitFor();await page.locator('#health-report').click();
   const report=await page.locator('#health-report-text').textContent();assert.match(report,/recently verified; chain data may be cached/);
   for(const forbidden of ['SECRET','PRIVATE','12345678','87654321','1000']) assert(!report.includes(forbidden));
   const downloadPromise=page.waitForEvent('download');await page.locator('#health-download').click();const download=await downloadPromise;
   assert.equal(fs.readFileSync(await download.path(),'utf8'),report);
   bad=true;await page.locator('#health-check').click();await page.locator('#health-status').filter({hasText:'Could not verify'}).waitFor();await page.locator('#health-report').click();assert.match(await page.locator('#health-report-text').textContent(),/not recently verified/);
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)));
   if(process.env.PAPERCLIP_SCREENSHOT_DIR) { fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true}); await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,'wallet-health-'+width+'.png'),fullPage:true}); }
   await page.locator('[data-screen=health] [data-back]').click();await page.locator('[data-view=health]').waitFor({state:'visible'});
   await page.locator('#lock').click();assert.equal(await page.locator('#health-report-text').textContent(),'');assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS wallet health: phone/foldable/desktop fit, back navigation, connection failure, allowlisted downloaded report, lock clearing, no wallet mutations');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
