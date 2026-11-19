const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/bridge-reusable.json')));
 const offer=fixtures.find(x=>x.name==='btc').offer,destination=fixtures.find(x=>x.name==='xbt').offer;
 try { for(const [width,platform] of [[390,'startos'],[840,'umbrel'],[1280,'desktop']]) {
  const page=await browser.newPage({viewport:{width,height:1000}}),errors=[],calls=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
  let rows=[],failRegistration=true,failRevocation=true;
  await page.route('http://wallet.test/**',async route=>{
   const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/',''),body=route.request().postDataJSON();
   if(url.pathname.startsWith('/api/')) {
    let data=[];
    if(name==='bridge/reusable/info') data={available:true};
    else if(name==='bridge/reusable') {
     if(!body)data={offers:rows};
     else {
      calls.push(body);
      if(body.action==='register') {
       const row={id:'a'.repeat(64),destination,receive_xbt:true,binding:null,revocation_requested:false,created:1};
       rows=[row];if(failRegistration){failRegistration=false;return route.fulfill({status:503,json:{message:'Uncertain'}});}
       row.binding={offer,direction:'toBLAKE2b',revoked:false};data=row;
      } else if(body.action==='lookup') { rows[0].binding={offer,direction:'toBLAKE2b',revoked:false};data=rows[0]; }
      else if(body.action==='revoke') {rows[0].revocation_requested=true;if(failRevocation){failRevocation=false;return route.fulfill({status:503,json:{message:'Uncertain'}});}rows[0].binding.revoked=true;data=rows[0];}
      else if(body.action==='export_key') data={token:'b'.repeat(64)};
      else throw new Error('Unexpected operation');
     }
    } else if(name==='wallet')data={fingerprint:'fixture'};
    else if(name==='wallet/identity')data={network:'bitcoin',exit_profile:2,lightning_enabled:false};
    else if(name==='wallet/balance')data={spendable_sat:0};
    else if(name==='onchain/balance')data={confirmed_sat:0};
    else if(name==='hardware/accounts')data={accounts:[]};
    else if(name==='remote-node/connection')data={configured:false};
    else if(url.pathname==='/api/ui-platform')data={platform};
    else if(body)throw new Error('Unexpected mutation '+name);
    return route.fulfill({json:data});
   }
   const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
   return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
  });
  await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});
  await page.locator('.view-nav [data-view=lightning]').click();await page.locator('[data-screen=lightning] [data-view=bridge]').click();await page.locator('[data-screen=bridge] [data-view=bridge-reusable]').click();
  await page.locator('#reusable-health').filter({hasText:'Live'}).waitFor();
  await page.locator('#reusable-destination').fill(destination);await page.locator('#reusable-create button').last().click();
  await page.locator('.review-sheet').waitFor({state:'visible'});assert.match(await page.locator('.review-sheet').textContent(),/Recipient receivesXBT/);await page.keyboard.press('Escape');assert.equal(calls.length,0);
  await page.locator('#reusable-create button').last().click();await page.locator('.review-sheet .review-actions button').last().click();await page.locator('#reusable-message').filter({hasText:'not confirmed'}).waitFor();
  await page.locator('#reusable-records button').click();assert(await page.locator('#reusable-retry').isVisible());
  await page.locator('#reusable-check').click();await page.locator('#reusable-state').filter({hasText:'ready'}).waitFor();await page.locator('[data-screen=bridge-reusable] .receive-qr').waitFor({state:'visible'});
  assert.equal(calls.filter(x=>x.action==='register').length,1,'Lookup never creates another registration');
  assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)),'No horizontal overflow');
  if(process.env.PAPERCLIP_SCREENSHOT_DIR){fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,`reusable-${platform}-${width}.png`),fullPage:true});}
  await page.locator('#reusable-revoke').click();await page.locator('.review-sheet .review-actions button').last().click();await page.locator('#reusable-state').filter({hasText:'Revocation not confirmed'}).waitFor();
  assert.equal(await page.locator('[data-screen=bridge-reusable] .receive-qr').count(),0);
  await page.locator('#reusable-check').click();await page.locator('#reusable-check').waitFor({state:'visible'});assert.equal(await page.locator('[data-screen=bridge-reusable] .receive-qr').count(),0,'Uncertain revocation cannot silently resume sharing');
  await page.locator('#reusable-private summary').click();await page.locator('#reusable-export').click();await page.locator('#reusable-exported').filter({hasText:'b'.repeat(64)}).waitFor();
  const storage=await page.evaluate(()=>JSON.stringify([localStorage,sessionStorage]));assert(!storage.includes('b'.repeat(64)));
  // An XBT wrapper is handed to existing payment review; navigation never pays.
  rows=[{...rows[0],receive_xbt:false,destination:offer,revocation_requested:false,binding:{offer:destination,direction:'toSHA256',revoked:false}}];
  await page.locator('[data-screen=bridge-reusable] [data-view=lightning]').click();
  await page.locator('[data-screen=lightning] [data-view=bridge]').click();await page.locator('[data-screen=bridge] [data-view=bridge-reusable]').click();
  await page.locator('#reusable-back').click();await page.locator('#reusable-records button').filter({hasText:'Receive BTC'}).click();
  await page.locator('#reusable-pay-node').click();assert.equal(await page.locator('#node-destination').inputValue(),destination);
  assert.equal(await page.locator('#node-amount').inputValue(),'');
  await page.locator('.view-nav [data-view=lightning]').click();await page.locator('[data-screen=lightning] [data-view=bridge]').click();await page.locator('[data-screen=bridge] [data-view=bridge-reusable]').click();
  await page.locator('#reusable-back').click();await page.locator('#reusable-records button').filter({hasText:'Receive BTC'}).click();await page.locator('#reusable-pay-ark').click();
  assert.equal(await page.locator('#destination').inputValue(),destination);assert.equal(await page.locator('#amount').inputValue(),'');assert.equal(await page.locator('#ark-max').isChecked(),false);
  await page.locator('#lock').click();await page.waitForTimeout(1100);assert.equal(await page.locator('#reusable-exported').textContent(),'');assert.deepEqual(errors,[]);
  await page.close();
 }
 console.log('PASS reusable bridge: review cancellation, interrupted registration recovery, no automatic payment, uncertain revocation, private key isolation and responsive layouts across server/desktop shells');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
