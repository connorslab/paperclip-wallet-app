const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),vm=require('node:vm');
const policy = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../web/joinblaket-readiness.js'), 'utf8'), policy);
const cases = JSON.parse(fs.readFileSync(path.join(__dirname, '../mobile/Tests/PaperclipMobileTests/Fixtures/maker-readiness.json')));
for (const item of cases) {
 policy.item = item;
 const value = vm.runInContext('PaperclipMakerReadiness.evaluate(item.minimum,item.fee,item.jars,item.session,item.needsRefresh)', policy);
 assert.deepEqual(JSON.parse(JSON.stringify(value)), item.expected, item.name);
}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,1280,1440]) {
   const page=await browser.newPage({viewport:{width,height:1000}}),errors=[],actions=[];
   page.setDefaultTimeout(15000);
   page.on('pageerror',error=>errors.push(error.message));
   let failStatus=false, failBond=false, failRecovery=false, recoveryState='unknown';
   const recoveryCases=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/jam-recovery.json')));
   let recovery=structuredClone(recoveryCases[3].payment); recovery.quote.wallet='Sample Jars.jmdat';
   const accounts=[{id:'a'.repeat(64),label:'Krux savings',kind:'hardware'},{id:'b'.repeat(64),label:'Watch savings',kind:'watch'}];
   const received=[];
   const jars=['Apricot','Blueberry','Cherry','Date','Elderberry'].map((name,id)=>({id,name,total_sat:id===0?200000:0,confirmed_sat:id===0?200000:0,pending_sat:0,frozen_sat:0,bond_sat:0}));
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),p=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     let value={};
     if(p==='wallet') value={fingerprint:'fixture-only'};
     if(p==='wallet/identity') value={network:'regtest',exit_profile:2,lightning_enabled:false};
     if(p==='wallet/balance') value={spendable_sat:0};
     if(p==='onchain/balance') value={confirmed_sat:0};
     if(p==='wallet/vtxos') value=[];
     if(p==='hardware/accounts') value={accounts};
     if(p==='hardware/request') {
      assert.equal(route.request().postDataJSON().operation,'refresh','Jars must not spend from the selected public account');
      value={confirmed_sat:50000,pending_sat:0,transactions:[],last_broadcast:null};
     }
     if(p==='joinblaket/connection') value={configured:true,ui_url:'https://jam.example.test/'};
     if(p==='joinblaket/request') {
      const body=route.request().postDataJSON(); actions.push(body.operation);
      assert.equal(route.request().method(),'POST');
      if(!['wallets','unlock'].includes(body.operation)) {
       assert.equal(body.wallet,'Sample Jars.jmdat','Jars must retain their own wallet identity');
       assert.equal(body.token,'fixture-token','Jars must retain their separate authorization');
      }
      if(body.operation==='status'&&failStatus)return route.fulfill({status:503,json:{message:'Synthetic stale status'}});
      if(body.operation==='start_maker') return route.fulfill({status:503,json:{message:'Synthetic unknown maker outcome'}});
      if(body.operation==='wallets') value={wallets:['Sample Jars.jmdat']};
      else if(body.operation==='unlock') { assert.equal(body.bip39_passphrase,'fixture-passphrase'); value={walletname:'Sample Jars.jmdat',token:'fixture-token'}; }
      else if(body.operation==='status') value={session:true,wallet_name:'Sample Jars.jmdat',maker_running:false,coinjoin_in_process:false,rescanning:false};
      else if(body.operation==='coins') value={jars};
      else if(body.operation==='address') { assert(Number.isInteger(body.jar)&&body.jar>=0&&body.jar<5);received.push(body.jar);value={address:'bc1qsyntheticdisplayonly'+body.jar}; }
      else if(body.operation==='payments') value={payments:[recovery]};
      else if(body.operation==='check_payment') {
       assert.equal(body.payment_id,'a'.repeat(64));
       if(failRecovery)return route.fulfill({status:504,json:{message:'Synthetic lookup timeout; do not resend'}});
       value={...recovery,state:recoveryState};
      }
      else if(body.operation==='bond_address') {
       assert.equal(body.lock_month,'2099-12');
       if(failBond)return route.fulfill({status:504,json:{message:'Synthetic bond timeout; check Jam before retrying'}});
       value={address:'bc1qsyntheticbond',wallet:body.wallet,lock_month:body.lock_month};
      }
      else throw new Error('Unexpected mutation '+body.operation);
     }
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':file.endsWith('.svg')?'image/svg+xml':'image/jpeg'});
   });
   await page.goto('http://wallet.test/');
   await page.locator('#token').fill('fixture-paperclip-token');
   await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();
   await page.locator('#wallet').waitFor({state:'visible'});
   await page.locator('.view-nav [data-view="coinjoin"]').click();
   await page.locator('#jam-find').click();
   await page.waitForFunction(()=>document.querySelector('#jam-open').getAttribute('href')==='https://jam.example.test/');
   await page.locator('#jam-password').fill('fixture-password');
   await page.locator('#jam-unlock-fields summary').click();
   await page.locator('#jam-passphrase').fill('fixture-passphrase');
   await page.locator('#jam-unlock').click();
   await page.locator('#jam-dashboard').waitFor({state:'visible'});
   assert.equal(await page.locator('#jam-password').inputValue(),'');
   assert.equal(await page.locator('#jam-passphrase').inputValue(),'');
   assert.equal(await page.locator('.jam-jar').count(),5);
   await page.locator('#jam-payments-panel summary').first().click();
   await page.locator('#jam-payments-load').click();
   await page.getByRole('heading',{name:'Status unknown'}).waitFor();
   await page.getByText('This payment may have reached the network. Do not send it again.').waitFor();
   failRecovery=true;
   const checksBefore=actions.filter(x=>x==='check_payment').length;
   await page.getByRole('button',{name:'Check status',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('Synthetic lookup timeout'));
   assert.equal(actions.filter(x=>x==='check_payment').length,checksBefore+1,'No automatic recovery retries');
   await page.getByRole('heading',{name:'Status unknown'}).waitFor();
   if(process.env.SCREENSHOT_DIR) await page.locator('#jam-payments-panel').screenshot({path:path.join(process.env.SCREENSHOT_DIR,`jam-recovery-${width}.png`),animations:'disabled'});
   failRecovery=false; recoveryState='submitted';
   await page.getByRole('button',{name:'Check status',exact:true}).click();
   await page.getByRole('heading',{name:'Submitted'}).waitFor();
   await page.getByText('Seen by your node. Confirmation has not been checked.').waitFor();
   assert.equal(await page.getByRole('button',{name:'Check status',exact:true}).count(),0);
   assert(!actions.some(x=>/commit|send|cancel/.test(x)),'Recovery never creates, commits or cancels a payment');
   if(width===390) {
    for(const item of recoveryCases.filter(x=>!x.valid)) {
     recovery=structuredClone(item.payment);
     if(recovery.quote && recovery.quote.wallet==='fixture.jmdat') recovery.quote.wallet='Sample Jars.jmdat';
     await page.locator('#jam-payments-load').click();
     await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.startsWith('Invalid')||document.querySelector('#jam-status').textContent.startsWith('Missing'));
     await page.getByRole('heading',{name:'Submitted'}).waitFor();
    }
   }
   await page.locator('#jam-payments-panel summary').first().click();

   if(process.env.SCREENSHOT_DIR) {
    await page.locator('#network').evaluate(el=>el.textContent='SAMPLE WALLET · NO LIVE FUNDS');
    await page.evaluate(()=>window.scrollTo(0,0));
    await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`jars-overview-${width}.png`),animations:'disabled'});
   }
   await page.locator('.jam-jar').last().click();
   await page.locator('.jam-jar').last().focus();
   await page.keyboard.press('Enter');
   assert.equal(await page.locator('.jam-jar').last().getAttribute('aria-pressed'),'true');
   assert(await page.locator('.jam-jar').last().evaluate(el=>el===document.activeElement),'Jar selection preserves keyboard focus');
   if(width===390) {
    const bounds=await page.locator('#jam-jars').boundingBox();
    assert(bounds.height<230,'Jar selector stays in one compact row');
   }

   // The server's Jam wallet is independent of the selected hot/QR/watch account.
   for(const account of ['',...accounts.map(item=>item.id)]) {
    await page.locator('#wallet-select').selectOption(account);
    await page.waitForFunction(id=>PaperclipAccounts.selectedId===id,account);
    await page.locator('.view-nav [data-view="coinjoin"]').click();
    await page.locator('#jam-dashboard').waitFor({state:'visible'});
    assert.equal(await page.locator('#jam-wallet-name').textContent(),'Sample Jars.jmdat');
    for(let jar=0;jar<5;jar++) {
     await page.locator('.jam-jar').nth(jar).click();
     assert.equal(await page.locator('#jam-selected-name').textContent(),jars[jar].name);
     await page.locator('#jam-receive').click();
     await page.waitForFunction(id=>document.querySelector('#jam-address').textContent.includes('bc1qsyntheticdisplayonly'+id),jar);
    }
    if(account) {
     const blocked=await page.evaluate(async()=>{try{await api('onchain/send',{amount_sat:1});return false;}catch(error){return error.message.includes('hot wallet');}});
     assert(blocked,'Jars access must not enable hot-wallet sends from a public account');
    }
   }
   assert.deepEqual(received,[0,1,2,3,4,0,1,2,3,4,0,1,2,3,4]);
   await page.getByRole('button',{name:/Date.*0 sats/}).click();
   assert.equal(await page.locator('#jam-selected-name').textContent(),'Date');
   await page.locator('#jam-receive').click();
   await page.waitForFunction(()=>document.querySelector('#jam-address').textContent.includes('bc1qsynthetic'));
   assert(await page.locator('#jam-maker').isDisabled(),'No bond must not be presented as maker ready');
   assert.equal(await page.locator('#jam-maker-checklist li').count(),5);
   assert.match(await page.locator('#jam-maker-checklist').textContent(),/Needed: Set up and fund a fidelity bond/);
   assert(!actions.includes('start_maker'),'Opening jars must not start a maker');
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)),'No horizontal overflow');
   assert.deepEqual(errors,[]);
   await page.locator('#jam-bond-setup summary').click();
   await page.locator('#jam-bond-month').fill('2020-01');
   await page.locator('#jam-bond-review').click();
   await page.locator('#jam-status').filter({hasText:'future month'}).waitFor();
   assert.equal(actions.filter(action=>action==='bond_address').length,0);
   await page.locator('#jam-bond-month').fill('2099-12');
   await page.locator('#jam-bond-review').click();
   await page.getByRole('button',{name:'Go back',exact:true}).click();
   assert.equal(actions.filter(action=>action==='bond_address').length,0,'Cancel must not register an address');
   await page.locator('#jam-bond-review').click();
   assert.match(await page.locator('.review-sheet').textContent(),/Sample Jars.jmdat[\s\S]*2099-12-01[\s\S]*no funds/);
   await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#jam-bond-detail').filter({hasText:'Address ready; no funds sent'}).waitFor();
   assert.equal(actions.filter(action=>action==='bond_address').length,1);
   if(process.env.SCREENSHOT_DIR)await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`joinblaket-bond-${width}.png`),fullPage:true,animations:'disabled'});
   assert.equal(actions.filter(action=>/maker|send|fund/.test(action)).length,0);
   await page.locator('#jam-bond-month').fill('2098-12');
   assert.equal(await page.locator('#jam-bond-address').textContent(),'','Editing must clear the old bond address');
   await page.locator('#jam-bond-month').fill('2099-12');failBond=true;
   await page.locator('#jam-bond-review').click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#jam-status').filter({hasText:'Synthetic bond timeout'}).waitFor();
   assert.equal(actions.filter(action=>action==='bond_address').length,2,'Timed-out registration must not be replayed');
   assert.equal(await page.locator('#jam-bond-address').textContent(),'');
   if(process.env.SCREENSHOT_DIR) {
    await page.locator('#network').evaluate(el=>el.textContent='UI TEST FIXTURE · NOT LIVE FUNDS');
    await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`joinblaket-${width}.png`),fullPage:true,animations:'disabled'});
   }
   // An uncertain maker response requires reconciliation before another start.
   jars[0].bond_sat=100000; jars[0].total_sat=300000;
   await page.locator('#jam-refresh').click();
   await page.waitForFunction(()=>!document.querySelector('#jam-maker').disabled);
   failStatus=true;await page.locator('#jam-refresh').click();
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('stale'));
   assert(await page.locator('#jam-maker').isDisabled(),'Failed refresh invalidates earlier readiness');
   assert.match(await page.locator('#jam-maker-checklist').textContent(),/Needed: Refresh wallet status/);
   failStatus=false;await page.locator('#jam-refresh').click();await page.waitForFunction(()=>!document.querySelector('#jam-maker').disabled);
   await page.locator('#jam-maker').click();
   await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('Synthetic'));
   assert.equal(actions.filter(action=>action==='start_maker').length,1);
   assert(await page.locator('#jam-maker').isDisabled(),'Unknown maker outcome requires refresh');
   assert.match(await page.locator('#jam-maker-readiness').textContent(),/Refresh maker status/);
   await page.locator('#lock').click();
   await page.waitForFunction(()=>document.querySelector('#jam-open').getAttribute('href')===null);
   await page.close();
  }
  console.log('PASS Jar browser: phone/desktop, all five jars from hot/QR/watch accounts, separate authorization, hot-wallet isolation, password clearing, maker eligibility and uncertain-action recovery, no overflow/errors');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1)});
