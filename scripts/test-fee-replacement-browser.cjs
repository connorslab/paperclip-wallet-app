const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,1280]) {
   const page=await browser.newPage({viewport:{width,height:1100}}),errors=[],actions=[];
   page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
   const original='a'.repeat(64),replacement='b'.repeat(64);let malformed=false,hold=null,release=null;
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     if(name==='onchain/replacement/prepare') {
      actions.push('prepare');if(hold)await hold;
      return route.fulfill({json:{original_txid:original,replacement_txid:replacement,old_fee_sat:1000,new_fee_sat:2000,additional_fee_sat:malformed?2000:1000,
       recipients:[{address:'bcrt1qsyntheticrecipientforbrowserlayoutonly',amount_sat:100000}]}});
     }
     if(name==='onchain/replacement/commit') {actions.push('commit');assert.deepEqual(route.request().postDataJSON(),{replacement_txid:replacement,new_fee_sat:2000});return route.fulfill({status:503,json:{message:'Synthetic uncertain broadcast'}});}
     const value=name==='wallet'?{fingerprint:'fixture'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,lightning_enabled:false}:
      name==='wallet/balance'?{spendable_sat:0}:name==='onchain/balance'?{confirmed_sat:100000}:
      name==='onchain/transactions'?[{txid:original,balance_change_sat:-101000,onchain_fee_sat:1000,confirmation:null}]:[];
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   async function open() {
    await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();
    await page.locator('#wallet').waitFor({state:'visible'});await page.locator('.view-nav [data-view=activity]').click();
    await page.locator('.activity-row > details > summary').click();
    await page.locator('.fee-replacement > summary').click();
   }
   await open();const control=page.locator('.fee-replacement'),button=control.getByRole('button',{name:'Review fee increase'});
   await button.click();await page.locator('#review-title').waitFor({state:'visible'});
   assert.match(await page.locator('.review-content').textContent(),/Additional debit: 1,000 sats/);
   assert.match(await page.locator('.review-content').textContent(),/bcrt1qsyntheticrecipient/);
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)));
   if(process.env.PAPERCLIP_SCREENSHOT_DIR) { fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true}); await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,'fee-replacement-'+width+'.png'),fullPage:true}); }
   await page.getByRole('button',{name:'Go back',exact:true}).click();assert(!actions.includes('commit'));
   malformed=true;await button.click();await control.getByRole('status').filter({hasText:'incomplete'}).waitFor();assert(!actions.includes('commit'));malformed=false;
   await control.locator('details > summary').click();await control.locator('input').fill('-1');await button.click();assert.match(await control.getByRole('status').textContent(),/whole sats/);
   await control.locator('input').fill('');await button.click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await control.getByRole('status').filter({hasText:'uncertain'}).waitFor();assert(await button.isDisabled());assert.equal(actions.filter(x=>x==='commit').length,1);
   await page.locator('#transaction-result-done').click();await page.locator('#lock').click();await open();
   hold=new Promise(resolve=>{release=resolve});await button.click();await page.waitForFunction(()=>document.querySelector('.fee-replacement [role=status]').textContent.includes('Checking'));
   await page.locator('#lock').click();release();hold=null;await page.waitForTimeout(100);
   assert.equal(await page.locator('dialog[open]').count(),0);assert.equal(actions.filter(x=>x==='commit').length,1);
   assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS fee replacement UI: exact recipient/cost review, cancel, malformed quote, invalid fee, no mutation retry, lock during preparation, phone/desktop fit');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1)});
