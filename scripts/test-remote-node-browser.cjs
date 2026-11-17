const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const [width,platform,implementation] of [[390,'startos','lnd'],[840,'umbrel','cln'],[1280,'startos','cln'],[1280,'umbrel','lnd']]) {
   const page=await browser.newPage({viewport:{width,height:1000}}),errors=[],calls=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
   const node='02'+'01'.repeat(32),hash='02'.repeat(32),request='03'.repeat(32);
   let saved=null,records=[],malformed=false,failedRefresh=false,releasePrepare=null,holdPrepare=false;
   let legacy=false,assigned=false,holdRecovery=false,releaseRecovery=null;
   const balance={sendable_msat:'0',receivable_msat:'700000000',local_msat:'230000000',reserve_msat:'250000000',active_channels:1};
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     let data=[];const body=route.request().postDataJSON();
     if(name==='remote-node/connection') {
      if(legacy&&!assigned) return route.fulfill({status:400,json:{message:'Older records need ownership verification.'}});
      data=saved?{...saved,payments:records}:{configured:false};
     } else if(name==='remote-node/recovery/review') {
      calls.push({operation:'recovery-review'});
      if(assigned) return route.fulfill({status:400,json:{message:'Already assigned. Reopen the connection.'}});
      if(holdRecovery) await new Promise(resolve=>releaseRecovery=resolve);
      data={request_id:request,wallet_id:'04'.repeat(32),network:'regtest',payment_count:1,unresolved_sends:1,connection:{implementation,endpoint:'https://node.local:8180',node_id:node}};
     } else if(name==='remote-node/recovery/assign') {
      calls.push({operation:'recovery-assign',...body});assert.equal(body.owner_confirmed,true);assert.equal(body.backup_confirmed,true);
      assigned=true;saved={configured:true,implementation,endpoint:'https://node.local:8180',node_id:node};records=[{node_id:node,payment_hash:hash,amount_msat:'100000',receive:false,state:'unknown'}];
      return route.abort('failed'); // The durable assignment succeeded; its reply was lost.
     }
     else if(name==='remote-node/request') {
      calls.push(body);
      if(body.operation==='connect') { assert.equal(body.connection.credential,'ab'.repeat(32));saved={...body.connection,configured:true,node_id:node,alias:'My node'};delete saved.credential;data=saved; }
      if(body.operation==='refresh') { if(failedRefresh) return route.fulfill({status:400,json:{message:'Could not verify node certificate.'}});data={node_id:node,alias:'My node',balance}; }
      if(body.operation==='prepare') {
       if(holdPrepare) await new Promise(resolve=>releasePrepare=resolve);
       data={request_id:request,payment_hash:hash,node_id:node,amount_msat:'100000',maximum_fee_sat:10,maximum_total_msat:malformed?'1':'110000'};
      }
      if(body.operation==='pay') { records=[{node_id:node,payment_hash:hash,amount_msat:'100000',receive:false,state:'unknown'}];return route.abort('failed'); }
      if(body.operation==='status') { data={...records[0],state:'succeeded'};records=[data]; }
      if(body.operation==='offer') data={node_id:node,offer:'lno1fixture'};
     } else if(url.pathname==='/api/ui-platform') data={platform};
     else if(name==='wallet') data={fingerprint:'fixture'};
     else if(name==='wallet/identity') data={network:'regtest',exit_profile:2,lightning_enabled:false};
     else if(name==='hardware/accounts') data={accounts:[]};
     else if(name==='wallet/balance') data={spendable_sat:0};
     else if(name==='onchain/balance') data={confirmed_sat:0};
     return route.fulfill({json:data});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   async function unlock(){await page.locator('#token').fill('test-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});await page.locator('.view-nav [data-view=lightning]').click();await page.locator('.node-entry [data-view=node]').click();}
   await page.goto('http://wallet.test/');await unlock();
   await page.locator('#node-status').filter({hasText:'Connect CLN'}).waitFor();
   assert(await page.locator('#node-credential').evaluate(input=>input.required));
   await page.locator('#node-kind').selectOption(implementation);await page.locator('#node-endpoint').fill('https://node.local:8180');await page.locator('#node-credential').fill('ab'.repeat(32));await page.locator('#node-pins').fill('04'.repeat(32));
   await page.getByRole('button',{name:'Verify and save connection'}).click();await page.locator('#node-status').filter({hasText:'verified and saved'}).waitFor();assert.equal(await page.locator('#node-credential').inputValue(),'');assert.equal(await page.locator('#node-credential').evaluate(input=>input.required),false);
   await page.locator('#node-refresh').click();await page.locator('#node-status').filter({hasText:'Connected ·'}).waitFor();assert.equal(await page.locator('#node-balance').textContent(),'0 sats');assert.match(await page.locator('#node-balance-detail').textContent(),/230,000 sats/);
   failedRefresh=true;await page.locator('#node-refresh').click();await page.locator('#node-status').filter({hasText:'certificate'}).waitFor();assert.equal(await page.locator('#node-balance').textContent(),'Unavailable');failedRefresh=false;
   await page.locator('#node-open-pay').click();
   await page.locator('#node-destination').fill('lno1fixture');
   malformed=true;await page.locator('#node-pay button').click();await page.locator('#node-status').filter({hasText:'Invalid payment review'}).waitFor();assert.equal(calls.filter(c=>c.operation==='pay').length,0);
   malformed=false;await page.locator('#node-pay button').click();await page.locator('.review-sheet').waitFor({state:'visible'});await page.getByRole('button',{name:'Go back',exact:true}).click();assert.equal(calls.filter(c=>c.operation==='pay').length,0);
   await page.locator('#node-pay button').click();await page.locator('.review-sheet').waitFor({state:'visible'});assert.match(await page.locator('.review-content').textContent(),/Maximum total: 110 sats/);await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.locator('#node-status').filter({hasText:'result is uncertain'}).waitFor();assert.equal(calls.filter(c=>c.operation==='pay').length,1);
   // A fresh browser session restores the server record and only observes it.
   await page.reload();await page.locator('#wallet').waitFor({state:'visible'});await page.locator('.view-nav [data-view=lightning]').click();await page.locator('.node-entry [data-view=node]').click();await page.locator('[data-view=node-activity]').click();await page.locator('#node-payments').filter({hasText:'Outcome unknown'}).waitFor();await page.locator('#node-payments button').filter({hasText:'Check status'}).click();await page.locator('#node-payments').filter({hasText:'Payment succeeded'}).waitFor();assert.equal(calls.filter(c=>c.operation==='pay').length,1);
   await page.locator('#node-back').click();await page.locator('[data-view=node-receive]').click();
   await page.locator('#node-request-kind').selectOption('offer');await page.locator('#node-receive button').click();await page.locator('#node-status').filter({hasText:'Reusable offer ready'}).waitFor();assert.equal(await page.locator('#node-request').textContent(),'lno1fixture');
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)));
   if(process.env.PAPERCLIP_SCREENSHOT_DIR){fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,`node-${platform}-${implementation}-${width}.png`),fullPage:true});}
   // Late preparation must not open a review after a draft edit or lock.
   await page.locator('#node-back').click();await page.locator('#node-open-pay').click();
   holdPrepare=true;await page.locator('#node-destination').fill('lno1second');await page.locator('#node-pay button').click();await page.waitForFunction(()=>document.querySelector('#node-status').textContent.includes('preparing'));
   const deadline=Date.now()+10000;while(!releasePrepare&&Date.now()<deadline) await new Promise(resolve=>setTimeout(resolve,10));assert(releasePrepare,'Prepare request did not start');
   await page.locator('#node-destination').fill('lno1changed');releasePrepare();await page.locator('#node-pay button').waitFor({state:'visible'});await page.waitForTimeout(100);assert.equal(await page.locator('.review-sheet').isVisible(),false);
   await page.locator('#lock').click();assert.equal(await page.locator('#node-request').textContent(),'');assert.equal(await page.locator('#node-payments').textContent(),'');assert.equal(await page.locator('#node-endpoint').inputValue(),'');assert(await page.locator('#node-credential').evaluate(input=>input.required));assert.equal(await page.locator('#node-credential').getAttribute('placeholder'),'');
   const storage=await page.evaluate(()=>JSON.stringify([localStorage,sessionStorage]));assert(!storage.includes('node.local'));assert(!storage.includes('ab'.repeat(32)));
   // Recovery is explicit, retains unknown outcomes and never repeats an uncertain assignment.
   legacy=true;assigned=false;saved=null;await unlock();await page.locator('#node-status').filter({hasText:'ownership verification'}).waitFor();
   await page.locator('#node-recovery summary').click();await page.locator('#node-recovery-review').click();await page.locator('.review-sheet').waitFor({state:'visible'});
   const confirm=page.getByRole('button',{name:'Confirm',exact:true});assert(await confirm.isDisabled());
   await page.locator('.review-sheet input[type=checkbox]').nth(0).check();assert(await confirm.isDisabled());
   await page.locator('.review-sheet input[type=checkbox]').nth(1).check();assert(await confirm.isEnabled());
   assert.match(await page.locator('.review-content').textContent(),/Sends to check1/);
   if(process.env.PAPERCLIP_SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,`node-recovery-${platform}-${implementation}-${width}.png`)});
   await page.getByRole('button',{name:'Go back',exact:true}).click();assert.equal(calls.filter(c=>c.operation==='recovery-assign').length,0);
   await page.locator('#node-recovery-review').click();await page.locator('.review-sheet').waitFor({state:'visible'});assert(await confirm.isDisabled());
   for(const input of await page.locator('.review-sheet input[type=checkbox]').all()) await input.check();
   await confirm.click();await page.locator('#node-status').filter({hasText:'never retried automatically'}).waitFor();assert.equal(calls.filter(c=>c.operation==='recovery-assign').length,1);
   await page.locator('#node-recovery-reopen').click();await page.locator('#node-status').filter({hasText:'Saved connection loaded'}).waitFor();
   await page.locator('[data-view=node-activity]').click();await page.locator('#node-payments').filter({hasText:'Outcome unknown'}).waitFor();assert.equal(calls.filter(c=>c.operation==='pay').length,1);
   await page.locator('#node-back').click();await page.locator('#node-recovery-review').click();await page.locator('#node-status').filter({hasText:'Already assigned'}).waitFor();assert.equal(calls.filter(c=>c.operation==='recovery-assign').length,1);
   // A late read cannot offer ownership confirmation after the user locks.
   assigned=false;holdRecovery=true;await page.locator('#node-recovery-review').click();
   const recoveryDeadline=Date.now()+10000;while(!releaseRecovery&&Date.now()<recoveryDeadline) await new Promise(resolve=>setTimeout(resolve,10));assert(releaseRecovery);
   await page.locator('#lock').click();releaseRecovery();await page.waitForTimeout(100);assert.equal(await page.locator('.review-sheet').isVisible(),false);
   assert.equal(calls.filter(c=>c.operation==='recovery-assign').length,1);assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS CLN/LND browser flows on StartOS/Umbrel: setup, reserves, TLS error, strict review, cancel, uncertain send once, reload/status, BOLT12 receive, stale draft, lock clearing, responsive layout');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
