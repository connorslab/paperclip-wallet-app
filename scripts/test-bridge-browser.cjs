const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const [width,platform,implementation] of [[390,'startos','lnd'],[840,'umbrel','cln'],[1280,'startos','cln'],[1280,'umbrel','lnd']]) {
   const page=await browser.newPage({viewport:{width,height:1000}}),errors=[],calls=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
   const node='02'+'01'.repeat(32),hash='02'.repeat(32),invoice='lnbc1syntheticnodeinvoice',hold='lnbc1syntheticbtcinvoice';
   let records=[],payments=[],receipt=false,bridgeOutage=false,availabilityMode="live",malformed=false,holdQuote=false,releaseQuote=null;
   const record=()=>({direction:'toBLAKE2b',hash,target_invoice:invoice,target_msat:'100000',hold_invoice:hold,funding_msat:'200001',pay_sat:201,rate:2,spread:0.01,expires_at:Math.floor(Date.now()/1000)+600,created:Math.floor(Date.now()/1000),state:'quoted',verified_settlement:false,bridge_settled:false,receive_node_id:node});
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     let data=[];const body=route.request().postDataJSON();
     if(name==='remote-node/connection') data={configured:true,node_id:node,implementation,endpoint:'https://node.local',payments};
     else if(name==='remote-node/request') {
      calls.push({name,body});assert.equal(body.operation,'invoice','Bridge must never send or prepare a payment');
      data={node_id:node,payment_hash:hash,invoice,amount_msat:'100000',receive:true,state:'pending'};payments=[data];
     } else if(name==='bridge/info') {calls.push({name});if(availabilityMode==='error')return route.fulfill({status:503,json:{message:'Unavailable'}});data={direction:'toBLAKE2b',open:availabilityMode==='malformed'?'true':availabilityMode==='live'};}
     else if(name==='bridge/quotes') {
      if(body){calls.push({name,body});assert.equal(body.invoice,invoice);assert.equal(body.direction,'toBLAKE2b');
       if(holdQuote)await new Promise(resolve=>releaseQuote=resolve);
       records=[record()];data=malformed?{...records[0],target_msat:'101000'}:records[0];
      } else data={quotes:records};
     } else if(name==='bridge/check') {
      calls.push({name,body});assert.equal(body.hash,hash);
      records=[{...records[0],state:'settled',bridge_settled:true,verified_settlement:receipt,node_checked:receipt,bridge_checked:!bridgeOutage}];data=records[0];
     } else if(url.pathname==='/api/ui-platform') data={platform};
     else if(name==='wallet') data={fingerprint:'fixture'};
     else if(name==='wallet/identity') data={network:'bitcoin',exit_profile:2,lightning_enabled:false};
     else if(name==='hardware/accounts') data={accounts:[]};
     else if(name==='wallet/balance') data={spendable_sat:0};
     else if(name==='onchain/balance') data={confirmed_sat:0};
     else if(body) throw new Error('Unexpected mutation '+name);
     return route.fulfill({json:data});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   async function entry(){await page.locator('.view-nav [data-view=lightning]').click();await page.locator('[data-screen=lightning] [data-view=bridge]').click();await page.locator('#bridge-create').waitFor({state:'visible'});}
   await page.clock.install();await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});await entry();
   assert.equal(calls.filter(c=>c.name==='remote-node/request').length,0);
   await page.locator('[data-screen=bridge] [data-bridge-health]').filter({hasText:'Live'}).waitFor();
   await page.locator('#bridge-amount').fill('100');await page.locator('#bridge-create button').click();
   await page.locator('#bridge-detail').waitFor({state:'visible'});assert.equal(await page.locator('#bridge-target').textContent(),'100 XBT sats');assert.equal(await page.locator('#bridge-funding').textContent(),'200.001 BTC sats');
   assert.equal(await page.locator('#bridge-share').isVisible(),false);assert.equal(calls.filter(c=>c.name==='remote-node/request').length,1);
   if(process.env.PAPERCLIP_SCREENSHOT_DIR){fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,`bridge-review-${platform}-${width}.png`),fullPage:true});}
   await page.locator('#bridge-show').click();await page.locator('#bridge-share .receive-qr').waitFor({state:'visible'});
   assert.match(await page.locator('#bridge-share').textContent(),/Pay this invoice once/);assert(!/XBT-compatible/.test(await page.locator('#bridge-share').textContent()));
   assert.equal(await page.locator('#bridge-invoice').textContent(),hold);
   // Availability must expire, never coerce strings, and remain separate from receipt.
   availabilityMode='error';await page.clock.fastForward(91000);await page.locator('[data-screen=bridge] [data-bridge-health]').filter({hasText:'Status unknown'}).waitFor();
   availabilityMode='malformed';await page.clock.fastForward(31000);await page.locator('[data-screen=bridge] [data-bridge-health]').filter({hasText:'Status unknown'}).waitFor();
   availabilityMode='paused';await page.clock.fastForward(31000);await page.locator('[data-screen=bridge] [data-bridge-health]').filter({hasText:'Paused'}).waitFor();
   // A bridge proof alone cannot display received, even if upstream said settled.
   await page.locator('#bridge-check').click();await page.locator('#bridge-status').filter({hasText:'could not verify receipt'}).waitFor();assert.equal(await page.locator('#bridge-result-title').textContent(),'Your conversion');assert.equal(await page.locator('#bridge-share').isVisible(),false);
   // Reload restores the same request; checking is not a second invoice/payment.
   await page.reload();await page.locator('#wallet').waitFor({state:'visible'});await entry();await page.locator('[data-view=bridge-activity]').click();await page.locator('#bridge-records button').click();
   receipt=true;bridgeOutage=true;await page.locator('#bridge-check').click();await page.locator('#bridge-result-title').filter({hasText:'XBT received'}).waitFor();assert.equal(calls.filter(c=>c.name==='remote-node/request').length,1);
   assert.equal(await page.locator('#bridge-show').isVisible(),false);
   // An expired history record never exposes a QR; prior successful receipt is not reused.
   records=[{...record(),expires_at:Math.floor(Date.now()/1000)-1}];await page.locator('#bridge-back').click();await page.locator('[data-view=bridge-activity]').click();await page.locator('#bridge-records button').filter({hasText:'expired'}).click();
   assert.equal(await page.locator('#bridge-show').isVisible(),false);assert.equal(await page.locator('#bridge-share').isVisible(),false);assert.match(await page.locator('#bridge-result-state').textContent(),/expired/);
   // Paused service stops before creating a new node invoice.
   await page.locator('#bridge-back').click();await page.locator('#bridge-create').waitFor({state:'visible'});await page.locator('#bridge-amount').fill('100');
   const beforePaused=calls.filter(c=>c.name==='remote-node/request').length;availabilityMode='paused';await page.locator('#bridge-create button').click();await page.locator('#bridge-status').filter({hasText:'Bridge is paused'}).waitFor();assert.equal(calls.filter(c=>c.name==='remote-node/request').length,beforePaused);
   // Conversion commitment mismatch is rejected before sharing.
   availabilityMode='live';malformed=true;await page.locator('#bridge-amount').fill('100');await page.locator('#bridge-create button').click();await page.locator('#bridge-status').filter({hasText:'differs from your node request'}).waitFor();assert.equal(await page.locator('#bridge-share').isVisible(),false);
   // Recover the saved quote without creating another node invoice.
   const beforeRecover=calls.filter(c=>c.name==='remote-node/request').length;
   await page.locator('[data-view=bridge-activity]').click();await page.locator('#bridge-records button').click();assert.equal(await page.locator('#bridge-target').textContent(),'100 XBT sats');
   assert.equal(calls.filter(c=>c.name==='remote-node/request').length,beforeRecover);
   await page.locator('#bridge-back').click();await page.locator('#bridge-create').waitFor({state:'visible'});
   // A lock clears amounts and invoice text; a delayed quote cannot reopen review.
   malformed=false;holdQuote=true;await page.locator('#bridge-create button').click();
   const deadline=Date.now()+10000;while(!releaseQuote&&Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,10));assert(releaseQuote);
   await page.locator('#lock').click();releaseQuote();await page.waitForTimeout(100);
   for(const id of ['bridge-invoice','bridge-reference','bridge-recipient','bridge-records','bridge-target','bridge-funding'])assert.equal(await page.locator('#'+id).textContent(),'');
   assert.equal(await page.locator('#wallet').isVisible(),false);
   const storage=await page.evaluate(()=>JSON.stringify([localStorage,sessionStorage]));assert(!storage.includes(invoice)&&!storage.includes(hold));assert.deepEqual(errors,[]);
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)));await page.close();
  }
  console.log('PASS Bridge browser receive: both hosts/CLN/LND, exact conversion, explicit BTC share, proof is not receipt, outage receipt, durable history, expiry, mismatch, lock and no payment requests');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
