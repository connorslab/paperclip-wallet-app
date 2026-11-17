const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,840,1280]) {
   const page=await browser.newPage({viewport:{width,height:width===390?844:1000}}), errors=[], commits=[];
   page.on('pageerror',error=>errors.push(error.message));page.setDefaultTimeout(10000);
   let malformed=false,oldHost=false,uncertain=false,hold=null,release=null;
   const quote={request_id:'b'.repeat(64),destination:'bcrt1q7wyp0vf3qxw77jksrrmhd5cyjw0cd4arhf9f2c',net_sat:98000,fee_sat:2000,total_sat:100000,input_count:3};
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()), name=url.pathname.replace('/api/v1/',''),body=route.request().postDataJSON();
    if(url.pathname.startsWith('/api/')) {
     if(name==='submissions'&&!body)return route.fulfill({json:{version:1,pending:[],recent:[]}});
     if(name==='submissions/ack')return route.fulfill({json:{id:body.id,acknowledged:true}});
     if(name==='submissions/check')return route.fulfill({json:{id:body.id,state:'unconfirmed'}});
     if(name==='withdrawals/prepare') {
      assert.deepEqual(body,{});if(hold)await hold;
      return oldHost?route.fulfill({status:404,json:{message:'Upgrade this host to review withdrawals.'}}):route.fulfill({json:{...quote,total_sat:malformed?99999:100000}});
     }
     if(name==='submissions') {
      assert.equal(body.operation,'withdrawals/commit');
      assert.deepEqual(body.body,{request_id:quote.request_id,net_sat:98000,total_sat:100000});commits.push(body);
      return uncertain?route.abort():route.fulfill({json:{id:body.id,operation:body.operation,state:'received',result:{state:'submitted',txid:'c'.repeat(64)}}});
     }
     assert(!['wallet/offboard/all','wallet/offboard/vtxos','withdrawals/commit'].includes(name),'No unreviewed or unjournaled fallback');
     return route.fulfill({json:name==='wallet'?{fingerprint:'fixture'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,submission_journal:1,lightning_enabled:false}:name==='wallet/balance'?{spendable_sat:100000}:name==='onchain/balance'?{confirmed_sat:100000}:[]});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   async function open() {
    await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();
    await page.locator('#wallet').waitFor({state:'visible'});await page.locator('[data-view=onchain]').first().click();
   }
   await open();const submit=page.locator('#withdraw');
   await submit.click();await page.locator('#review-title').waitFor({state:'visible'});
   const content=await page.locator('.review-content').textContent();
   for(const value of ['98,000','2,000','100,000','Selected Ark inputs3',quote.destination])assert(content.includes(value));
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)));
   assert(await page.locator('.review-content').evaluate(node=>node.scrollHeight<=node.clientHeight+1),'Withdrawal review should fit without inner scrolling at the tested height');
   assert(await page.getByRole('button',{name:'Confirm',exact:true}).isVisible());
   if(process.env.PAPERCLIP_SCREENSHOT_DIR){fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true});await page.locator('.review-sheet').evaluate(async node=>{await Promise.all(node.getAnimations().map(animation=>animation.finished));});await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,'withdrawal-review-'+width+'.png')});}
   await page.getByRole('button',{name:'Go back',exact:true}).click();assert.equal(commits.length,0);
   malformed=true;await submit.click();await page.getByText('Could not verify the withdrawal amount and fees. Nothing was submitted.',{exact:true}).waitFor();assert.equal(commits.length,0);malformed=false;
   oldHost=true;await submit.click();await page.getByText('Upgrade this host to review withdrawals.',{exact:true}).waitFor();assert.equal(commits.length,0);oldHost=false;
   hold=new Promise(resolve=>{release=resolve});await submit.click();await page.locator('#lock').click();release();hold=null;await page.waitForTimeout(100);
   assert.equal(await page.locator('dialog[open]').count(),0);assert.equal(commits.length,0);
   await open();await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#transaction-result-title').filter({hasText:'Withdrawal submitted'}).waitFor();
   assert((await page.locator('#transaction-result-detail').textContent()).includes('Waiting for on-chain confirmation'));assert.equal(commits.length,1);
   await page.locator('#transaction-result-done').click();uncertain=true;
   await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#transaction-result-title').filter({hasText:'Result not confirmed'}).waitFor();assert.equal(commits.length,2);
   await page.locator('#transaction-result-done').click();await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.getByText(/A prior submission needs checking/).waitFor();assert.equal(commits.length,2);
   assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS withdrawal: amount/fee/input review, cancel, malformed quote, old host, lock race, submitted not confirmed, lost reply/no replay; phone/foldable/desktop');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1)});
