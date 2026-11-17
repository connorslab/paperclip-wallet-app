// Synthetic transport only. This suite cannot contact a wallet or broadcast.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),vm=require('node:vm');
const context=vm.createContext({});vm.runInContext(fs.readFileSync(path.join(__dirname,'../web/joinblaket-readiness.js'),'utf8'),context);
const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/jam-send-review.json')));
for(const item of fixtures) {
 context.row=item.review;context.mode=item.coinjoin??false;context.bondTime=item.bond_locktime??null;context.bondPoint=item.bond_outpoint??null;
 // The host binds wallet identity against authenticated Jam before returning a review.
 const valid=vm.runInContext(`(()=>{try {PaperclipJarSend.validate(row,'a'.repeat(64),'fixture.jmdat',{jar:0,destination:'bcrt1qsyntheticrecipient',amount_sat:20000,max_fee_sat:500,coinjoin:mode,bond_locktime:bondTime,bond_outpoint:bondPoint},2000000000);return row.quote.wallet_identity==='xbt-regtest:'+'c'.repeat(64);}catch{return false}})()`,context);
 assert.equal(valid,item.valid,item.name);
}
const inventories=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/jam-bonds.json')));
for(const item of inventories) {
 context.inventory=item.inventory;
 const valid=vm.runInContext(`(()=>{try {PaperclipBonds.validate(inventory,'fixture.jmdat');return true;}catch{return false}})()`,context);
 assert.equal(valid,item.valid,item.name);
 if(valid) assert.equal(JSON.stringify(vm.runInContext('inventory.bonds.map(coin=>PaperclipBonds.canWithdraw(coin,inventory.chain_time))',context)),JSON.stringify(item.withdrawable));
}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,1280]) for (const mode of ["direct","coinjoin","bond","withdrawal"]) {
   const coinjoin=mode==="coinjoin",bond=mode==="bond",withdrawal=mode==="withdrawal";
   const page=await browser.newPage({viewport:{width,height:1000}}), actions=[],errors=[];
   page.on('pageerror',e=>errors.push(e.message));let saved=null, badQuote=false;
   const jars=['Apricot','Blueberry','Cherry','Date','Elderberry'].map((name,id)=>({name,id,total_sat:200000,confirmed_sat:200000,pending_sat:0,frozen_sat:0,bond_sat:0}));
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url());let value={};
    if(url.pathname.startsWith('/api/')) {
     const p=url.pathname.replace('/api/v1/','');
     if(p==='wallet')value={fingerprint:'fixture-only'};
     if(p==='wallet/identity')value={network:'regtest',exit_profile:2,lightning_enabled:false};
     if(p==='wallet/balance')value={spendable_sat:0};
     if(p==='onchain/balance')value={confirmed_sat:0};
     if(p==='wallet/vtxos')value=[];
     if(p==='hardware/accounts')value={accounts:[]};
     if(p==='joinblaket/connection')value={configured:true,ui_url:null};
     if(p==='joinblaket/request') {
      const body=route.request().postDataJSON();actions.push(body.operation);
      if(body.operation==='wallets')value={wallets:['fixture.jmdat']};
      else if(body.operation==='unlock')value={walletname:'fixture.jmdat',token:'fixture-jam-token'};
      else {
       assert.equal(body.wallet,'fixture.jmdat');assert.equal(body.token,'fixture-jam-token');
       if(body.operation==='status')value={session:true,wallet_name:'fixture.jmdat',maker_running:false,coinjoin_in_process:false,rescanning:false};
       else if(body.operation==='coins')value={jars};
       else if(body.operation==='bonds')value=inventories[0].inventory;
       else if(body.operation==='bond_address')value={address:'bcrt1qsyntheticrecipient',wallet:body.wallet,lock_month:body.lock_month};
       else if(body.operation==='prepare_payment') {
        await new Promise(resolve=>setTimeout(resolve,500));
        assert.deepEqual(body.send,{jar:bond?1:0,destination:'bcrt1qsyntheticrecipient',amount_sat:20000,fee_rate_millisat_vb:1000,max_fee_sat:1000,coinjoin,...(withdrawal?{bond_locktime:1800000000,bond_outpoint:"1".repeat(64)+":0"}:{}),...(bond?{bond_locktime:Date.parse("2099-12-01T00:00:00Z")/1000}:{})});
        saved=structuredClone((withdrawal?fixtures.find(v=>v.name==='reviewed bond withdrawal'):coinjoin?fixtures.find(v=>v.name==='reviewed CoinJoin'):fixtures[0]).review);if(bond) { saved.quote.jar=1;saved.quote.purpose="fund_bond";saved.quote.bond_locktime=body.send.bond_locktime; } saved.id=body.payment_id;saved.expires=Math.floor(Date.now()/1000)+200;
        if(badQuote)saved.quote.destination='bcrt1qdifferentrecipient';value=saved;
       } else if(body.operation==='commit_payment') {
        assert.equal(body.payment_id,saved.id);assert.equal(body.approval,saved.approval);assert.equal(body.wallet_identity,saved.quote.wallet_identity);
        saved.state='unknown';return route.fulfill({status:504,json:{message:'Synthetic lost commit'}});
       } else if(body.operation==='payments')value={payments:saved?[saved]:[]};
       else throw Error('Unexpected request '+body.operation);
      }
     }
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':file.endsWith('.svg')?'image/svg+xml':'image/png'});
   });
   await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture-owner-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();
   await page.locator('#wallet').waitFor({state:'visible'});await page.locator('.view-nav [data-view="coinjoin"]').click();
   await page.locator('#jam-find').click();await page.locator('#jam-wallet option').waitFor({state:'attached'});await page.locator('#jam-password').fill('synthetic-password');await page.locator('#jam-unlock').click();
   await page.locator('#jam-dashboard').waitFor({state:'visible'});
   if(withdrawal) {
    await page.locator('[data-jam-tool-open="bond"]').click();await page.locator('#jam-bonds-load').click();
    await page.getByRole('button',{name:'Review withdrawal',exact:true}).click();
    assert(await page.locator('#jam-send-amount').getAttribute('readonly') !== null);assert(await page.locator('#jam-send-coinjoin').isHidden());
    await page.locator('#jam-send-address').fill('bcrt1qsyntheticrecipient');
   } else if(bond) {
    await page.locator('[data-jam-tool-open="bond"]').click();await page.locator('#jam-bond-month').fill('2099-12');
    await page.locator('#jam-bond-review').click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
    await page.locator('#jam-tool-close').click(); await page.locator('#jam-jars button').nth(1).click();
    await page.locator('[data-jam-tool-open="bond"]').click();
    assert.equal(await page.locator('#jam-bond-fund').textContent(),'Fund from Blueberry');
    await page.locator('#jam-bond-fund').click();
    assert(await page.locator('#jam-send-address').getAttribute('readonly') !== null);assert(await page.locator('#jam-send-coinjoin').isHidden());
   } else await page.locator('#jam-send').click();
   if(!bond && !withdrawal) { await page.locator('#jam-send-coinjoin').check();assert(await page.locator('#jam-send-prepare').isEnabled());assert(!actions.includes('prepare_payment'));
   if (!coinjoin) await page.locator('#jam-send-coinjoin').uncheck();await page.locator('#jam-send-address').fill('bcrt1qsyntheticrecipient'); } if(!withdrawal) await page.locator('#jam-send-amount').fill('20000');
   await page.locator('#jam-send-prepare').click();await page.locator('#jam-send-progress').waitFor({state:'visible'});
   assert.equal(await page.locator('#jam-send-progress-title').textContent(),coinjoin?'Preparing CoinJoin':'Preparing payment');
   assert(await page.locator('#jam-send-recovery').isHidden());await page.locator('#jam-send-review').waitFor({state:'visible'});
   assert.match(await page.locator('#jam-send-costs').textContent(),withdrawal?/Bond withdrawal.*Bond unlock date/:bond?/Bond funding.*Bond unlock date.*2099-12/:coinjoin?/Maker fees.*100 sats.*Your mining fee.*100 sats/:/Direct · no CoinJoin/);
   assert.equal(await page.locator('#jam-send-destination').textContent(),'bcrt1qsyntheticrecipient');
   if(process.env.SCREENSHOT_DIR){fs.mkdirSync(process.env.SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`jar-send-${mode}-review-${width}.png`)});}
   await page.locator('#jam-send-commit').click();await page.locator('#jam-send-status').filter({hasText:'Synthetic lost commit'}).waitFor();
   assert(await page.locator('#jam-send-commit').isHidden());assert.equal(actions.filter(v=>v==='commit_payment').length,1);
   await page.locator('#jam-send-activity').click();await page.waitForFunction(()=>document.querySelector('#jam-payments').textContent.includes('Status unknown'));
   assert.equal(actions.filter(v=>v==='commit_payment').length,1);
   // A malformed recipient can never reach an actionable review.
   badQuote=true;if(withdrawal) { await page.locator('[data-jam-tool-open="bond"]').click();await page.getByRole('button',{name:'Review withdrawal',exact:true}).click();await page.locator('#jam-send-address').fill('bcrt1qsyntheticrecipient'); } else if(bond) { await page.locator('[data-jam-tool-open="bond"]').click(); await page.locator('#jam-bond-fund').click(); } else await page.locator('#jam-send').click();await page.locator('#jam-send-prepare').click();
   await page.locator('#jam-send-status').filter({hasText:'review changed'}).waitFor();assert(await page.locator('#jam-send-commit').isHidden());
   await page.evaluate(()=>{document.querySelector('#wallet').hidden=true;});await page.waitForFunction(()=>!document.querySelector('#jam-send-dialog').open);
   assert.deepEqual(errors,[]);assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)));
   await page.close();console.log('Jars '+mode+' review, lost submission and wallet lock passed at '+width+'px');
  }
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1});
