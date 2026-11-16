const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,840,1280]) {
   const page=await browser.newPage({viewport:{width,height:1000}}), errors=[], actions=[];
   page.on('pageerror',error=>errors.push(error.message)); page.setDefaultTimeout(10000);
   let malformed=false,hold=null,release=null;
   const quote={request_id:'b'.repeat(64),board_amount_sat:25000,total_sat:26000,net_sat:23000,reserve_sat:2000,network_fee_sat:1000,boarding_fee_sat:500,recovery_anchor_sat:1000,recovery_miner_fee_sat:1000};
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     if(name==='boards/prepare') {actions.push('prepare');if(hold)await hold;return route.fulfill({json:{...quote,total_sat:malformed?25000:26000}});}
     if(name==='boards/commit') {actions.push('commit');assert.deepEqual(route.request().postDataJSON(),{request_id:quote.request_id,amount_sat:25000,total_sat:26000});return route.fulfill({status:503,json:{message:'Synthetic uncertain response'}});}
     assert.notEqual(name,'boards/board-amount','Do not fall back to an unreviewed boarding contract');
     return route.fulfill({json:name==='wallet'?{fingerprint:'fixture'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,lightning_enabled:false}:name==='wallet/balance'?{spendable_sat:0}:name==='onchain/balance'?{confirmed_sat:100000}:[]});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   async function open() {await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});await page.locator('[data-view=onchain]').first().click();await page.locator('#board-amount').fill('25000');}
   await open(); const submit=page.getByRole('button',{name:'Review boarding',exact:true});
   await submit.click(); await page.locator('#review-title').waitFor({state:'visible'});
   const content=await page.locator('.review-content').textContent();
   for(const value of ['23,000','2,000','500','1,000','26,000']) assert(content.includes(value));
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)));
   if(process.env.PAPERCLIP_SCREENSHOT_DIR) {fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,'boarding-review-'+width+'.png'),fullPage:true});}
   await page.getByRole('button',{name:'Go back',exact:true}).click(); assert(!actions.includes('commit'));
   malformed=true;await submit.click();await page.getByText('Could not verify the complete boarding cost. Nothing was submitted.',{exact:true}).waitFor();assert(!actions.includes('commit'));malformed=false;
   hold=new Promise(resolve=>{release=resolve});await submit.click();await page.locator('#board-amount').fill('26000');release();hold=null;
   await page.getByText('Wallet or boarding amount changed. Review again.',{exact:true}).waitFor();assert(!actions.includes('commit'));
   await page.locator('#board-amount').fill('25000');await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#transaction-result-title').filter({hasText:'Result not confirmed'}).waitFor();assert.equal(actions.filter(a=>a==='commit').length,1);
   await page.locator('#transaction-result-done').click();await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.getByText(/A prior submission needs checking/).waitFor();assert.equal(actions.filter(a=>a==='commit').length,1);
   await page.locator('#lock').click();await open();hold=new Promise(resolve=>{release=resolve});await submit.click();await page.locator('#lock').click();release();hold=null;await page.waitForTimeout(100);
   assert.equal(await page.locator('dialog[open]').count(),0);assert.equal(actions.filter(a=>a==='commit').length,1);assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS boarding: exact recovery/fee/total review, cancel, tampered quote, edited amount, lock race, no automatic retry; phone/foldable/desktop');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1)});
