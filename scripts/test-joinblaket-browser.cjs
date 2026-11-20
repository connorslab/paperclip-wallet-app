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
const bookCases=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/jars-orderbook.json')));
for(const item of bookCases) {
 policy.book=item.value;
 let valid=true;try { vm.runInContext('PaperclipOrderBook.validate(book,50000)',policy); } catch(_) { valid=false; }
 assert.equal(valid,item.valid,item.name);
 if(valid && item.value.offers) {
  for(const [eligible,largest,expected] of [[false,false,[1,0,2]],[true,false,[0]],[false,true,[2,1,0]]]) {
   assert.deepEqual(JSON.parse(JSON.stringify(vm.runInContext(`PaperclipOrderBook.rows(book,${eligible},${largest}).map(r=>r.id)`,policy))),expected);
  }
 }
}
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of (process.env.PAPERCLIP_TEST_WIDTH ? [Number(process.env.PAPERCLIP_TEST_WIDTH)] : [320,390,840,1280,1440])) {
   const page=await browser.newPage({viewport:{width,height:1000}}),errors=[],actions=[];
   page.setDefaultTimeout(15000);
   const closeTool = async () => {
    if(await page.locator('#jam-tools-dialog').evaluate(el=>el.open)) await page.locator('#jam-tool-close').click();
   };
   const openTool = async key => {
    await closeTool();
    await page.locator(`[data-jam-tool-open="${key}"]`).click();
    await page.locator('#jam-tools-dialog').waitFor({state:'visible'});
    assert.equal(await page.locator('[data-jam-tool]:visible').count(),1,'Show only the selected task');
    assert.equal(await page.locator('[data-jam-tool]:visible').getAttribute('data-jam-tool'),key);
   };

   page.on('pageerror',error=>errors.push(error.message));
   let failStatus=false, failBond=false, failRecovery=false, recoveryState='unknown', marketStatus='fresh', failCancel=false;
   const recoveryCases=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/jam-recovery.json')));
   let recovery=structuredClone(recoveryCases[3].payment); recovery.quote.wallet='Sample Jars.jmdat';
   const accounts=[{id:'a'.repeat(64),label:'Krux savings',kind:'hardware'},{id:'b'.repeat(64),label:'Watch savings',kind:'watch'}];
   const received=[]; let pairings=[], pairingCreates=0, pairingRevokes=0, trustGate=null, releaseTrust=null, trustWaiting=false, hidePairingOnion=false;
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
     if(p==='joinblaket/pairings/connection') {
      if(url.searchParams.has('endpoint') && trustGate) { trustWaiting=true; await trustGate; }
      value={onion_endpoint:hidePairingOnion?null:'http://'+'a'.repeat(56)+'.onion/',https_endpoints:['https://host.example.invalid/']};
      if(url.searchParams.get('endpoint')==='https://host.example.invalid/') Object.assign(value,{https_endpoint:'https://host.example.invalid/',certificate_sha256:'b'.repeat(64)});
      if(url.searchParams.get('endpoint')==='https://wrong.local/') Object.assign(value,{https_endpoint:'https://other.local/',certificate_sha256:'c'.repeat(64)});
     }
     if(p==='joinblaket/pairings') {
      if(route.request().method()==='POST') {
       const body=route.request().postDataJSON(); assert.equal(body.wallet,'Sample Jars.jmdat'); assert.equal(body.token,'fixture-token');
       assert(['jars_manage_v1','jars_pay_v1'].includes(body.scope));
       pairingCreates++; const row={id:'c'.repeat(64),label:body.label,wallet:body.wallet,scope:body.scope,expires:Math.floor(Date.now()/1000)+2592000};
       pairings=[row]; value={...row,token:'pj1_'+'d'.repeat(64)};
      } else value={pairings};
     }
     if(p==='joinblaket/pairings/revoke') { assert.equal(route.request().postDataJSON().id,'c'.repeat(64)); pairingRevokes++;pairings=[];value={revoked:true}; }
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
      else if(body.operation==='coins') value={jars,utxos:[{mixdepth:0,utxo:"1".repeat(64)+":0",confirmations:2,value:200000,frozen:false,locktime:null}]};
      else if(body.operation==='address') { assert(Number.isInteger(body.jar)&&body.jar>=0&&body.jar<5);received.push(body.jar);value={address:'bc1qsyntheticdisplayonly'+body.jar}; }
      else if(body.operation==='payments') value={payments:[recovery]};
      else if(body.operation==='check_payment') {
       assert.equal(body.payment_id,'a'.repeat(64));
       if(failRecovery)return route.fulfill({status:504,json:{message:'Synthetic lookup timeout; do not resend'}});
       value={...recovery,state:recoveryState};
      }
      else if(body.operation==='market') {
       const now=Math.floor(Date.now()/1000);
       value={amount_sat:body.comparison_sat,fetched_at:now,book_updated_at:marketStatus==='stale'?now-121:now,status:marketStatus,maker_count:marketStatus==='fresh'?2:0,median_fee_sat:marketStatus==='fresh'?'75.5':null,excluded_offer_count:1,offers:marketStatus==='fresh'?Array.from({length:12},(_,id)=>({id,maker:'J5Synthetic'+id,fee:'100',relative:false,min_sat:27300,max_sat:1000000+id,fee_sat:100,mining_contribution_sat:0,bond_verified:id%2===0})):[]};
      }
      else if(body.operation==='cancel_payment') {
       if(failCancel)return route.fulfill({status:504,json:{message:'Synthetic cancellation timeout'}});
       value={...recovery,state:'cancelled'};
      }
      else if(body.operation==='prepare_payment') {
       assert.deepEqual(body.send.funding_inputs,['1'.repeat(64)+':0']);
       assert.equal(body.send.amount_sat,200000);
       value={id:body.payment_id,state:'prepared',approval:'e'.repeat(64),expires:Math.floor(Date.now()/1000)+120,quote:{
        wallet:body.wallet,jar:0,network:'xbt-regtest',wallet_identity:'xbt-regtest:'+ '2'.repeat(64),purpose:'fund_bond',
        bond_locktime:body.send.bond_locktime,destination:body.send.destination,fee_sat:150,total_sat:200000,
        amount_sat:199850,rbf:true,txid:'3'.repeat(64)}};
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
   await page.locator('#jam-unlock-fields').waitFor({state:'visible'});
   assert.equal(await page.locator('#jam-create-panel').evaluate(el=>el.open),false,'Existing wallets default to unlock');
   assert.equal(await page.locator('#jam-connect a[href]').count(),0);
   await page.locator('#jam-password').fill('fixture-password');
   await page.locator('#jam-unlock-fields summary').click();
   await page.locator('#jam-passphrase').fill('fixture-passphrase');
   await page.locator('#jam-unlock').click();
   await page.locator('#jam-dashboard').waitFor({state:'visible'});
   assert.equal(await page.locator('#jam-password').inputValue(),'');
   assert.equal(await page.locator('#jam-passphrase').inputValue(),'');
   assert.equal(await page.locator('.jam-jar').count(),5);
   if(width<=640) {
    const grid=await page.locator('#jam-jars').evaluate(el=>({width:el.clientWidth,scrollWidth:el.scrollWidth}));
    assert(grid.scrollWidth<=grid.width,'All five jars fit without sideways scrolling');
    const boxes=await Promise.all((await page.locator('.jam-jar').all()).map(el=>el.boundingBox()));
    for(const box of boxes) assert(box.x>=0&&box.x+box.width<=width&&box.width>=44&&box.height>=44,'Jar remains readable and tappable');
    assert(Math.abs(boxes[0].y-boxes[1].y)<1&&Math.abs(boxes[2].y-boxes[3].y)<1,'Two jars per row');
    assert(boxes[2].y>=boxes[0].y+boxes[0].height&&boxes[4].y>=boxes[2].y+boxes[2].height,'Rows do not overlap');
    const center=(boxes[0].x+boxes[1].x+boxes[1].width)/2;
    assert(Math.abs(boxes[4].x+boxes[4].width/2-center)<1,'Fifth jar is centered');
    if(process.env.SCREENSHOT_DIR) await page.locator('#jam-jars').screenshot({path:path.join(process.env.SCREENSHOT_DIR,`jars-grid-${width}.png`),animations:'disabled'});
   }
   assert(await page.locator('#jam-minimum').isHidden(),'Maker form is not on the overview');
   if(process.env.SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`jars-overview-clean-${width}.png`),fullPage:true,animations:'disabled'});
   await openTool('settings');
   await page.locator('#jam-fee-mode').selectOption('relative');
   assert.equal(await page.locator('#jam-fee').inputValue(),'0.00005');
   await page.getByText('At 1,000,000 sats, your fee is 50 sats.',{exact:true}).waitFor();
   await openTool('market');
   await page.waitForSelector('#jam-book-offers tbody tr');
   await page.locator('#jam-book-search').fill('Synthetic11');
   assert.equal(await page.locator('#jam-book-offers tbody tr').count(),1);
   await page.locator('#jam-book-search').fill('');
   await page.locator('#jam-book-comparison summary').click();
   for(const status of ['fresh','stale','empty','unavailable']) {
    marketStatus=status;await page.locator('#jam-market-refresh').click();
    await page.waitForFunction(status=>document.querySelector('#jam-market-summary').textContent.includes({fresh:'Median maker fee: 75.5 sats',stale:'stale',empty:'No verified bonded offers',unavailable:'unavailable'}[status]),status);
    assert.equal(await page.locator('#jam-fee').inputValue(),'0.00005','A market fetch must not change the selected fee');
   }
   marketStatus='fresh';await page.locator('#jam-market-refresh').click();
   await page.waitForFunction(()=>document.querySelector('#jam-market-summary').textContent.includes('Median maker fee'));
   assert.equal(await page.locator('.jam-book-offer').count(),10);
   await page.locator('#jam-book-next').click();
   assert.equal(await page.locator('.jam-book-offer').count(),2);
   assert.equal(await page.locator('#jam-book-page').textContent(),'2 / 2');
   await page.locator('#jam-book-eligible').check();
   assert.equal(await page.locator('.jam-book-offer').count(),6);
   assert.equal(await page.locator('#jam-book-page').textContent(),'1 / 1');
   await page.locator('#jam-book-sort').selectOption('size');
   assert.equal(await page.locator('.jam-book-offer td:first-child').first().textContent(),'J5Synthetic10');
   await page.locator('#jam-book-eligible').uncheck();
   await page.locator('#jam-book-sort').selectOption('fee');
   assert.equal(await page.locator('.jam-book-offer td:first-child').first().textContent(),'J5Synthetic0');
   await page.locator('#jam-tools-dialog').evaluate(el=>el.scrollTop=0);
   if(process.env.SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`jam-market-${width}.png`),animations:'disabled'});
   await page.locator('#jam-market-amount').fill('200000');
   assert.match(await page.locator('#jam-market-summary').textContent(),/Refresh to compare/);
   await page.locator('#jam-market-refresh').click();
   await page.waitForFunction(()=>document.querySelector('#jam-market-summary').textContent.includes('200,000 sats'));
   assert.equal(await page.locator('#jam-minimum').inputValue(),'100000','Comparison must not change maker minimum');
   assert.equal(await page.locator('#jam-fee').inputValue(),'0.00005','Comparison must not change maker fee');
   await openTool('settings');
   assert.equal(await page.locator('#jam-fee').inputValue(),'0.00005','Fee draft survives page navigation');
   if(process.env.SCREENSHOT_DIR) await page.locator('#jam-tools-dialog').screenshot({path:path.join(process.env.SCREENSHOT_DIR,`maker-settings-${width}.png`),animations:'disabled'});
   await page.locator('#jam-fee-mode').selectOption('fixed');
   await closeTool();
   await page.evaluate(() => {
    const encode = PaperclipReceive.encode;
    PaperclipReceive.encode = value => { if(value.startsWith('paperclip-jars:')) window.syntheticPairing = JSON.parse(atob(value.slice(15).replaceAll('-','+').replaceAll('_','/'))); return encode(value); };
   });
   hidePairingOnion=true;
   await page.locator('#jam-pairing-panel > summary').click();
   await page.waitForFunction(()=>document.querySelector('#jam-pairing-transport').value==='https');
   assert.equal(await page.locator('#jam-pairing-endpoint').inputValue(),'https://host.example.invalid/','HTTPS-only host has a ready-to-use address');
   await page.locator('#jam-pairing-transport').selectOption('tor');
   await page.locator('#jam-pairing-panel > summary').click();
   hidePairingOnion=false;
   await page.locator('#jam-pairing-panel > summary').click();
   await page.waitForFunction(()=>document.querySelector('#jam-pairing-endpoint').value.endsWith('.onion/'));
   assert.equal(await page.locator('#jam-pairing-transport').inputValue(),'tor');
   await page.locator('#jam-pairing-transport').selectOption('https');
   assert.equal(await page.locator('#jam-pairing-endpoint').inputValue(),'https://host.example.invalid/','Published HTTPS is filled automatically');
   await page.locator('#jam-pairing-endpoint').fill('http://wallet.test/');
   await page.locator('#jam-pairing-label').fill('Fixture phone');
   await page.locator('#jam-pairing-create').click();
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('HTTPS'));
   assert.equal(pairingCreates,0,'Plain LAN HTTP must not issue a pairing');
   for(const address of ['https://start.local/','https://wrong.local/']) {
    await page.locator('#jam-pairing-endpoint').fill(address);
    await page.locator('#jam-pairing-create').click();
    await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('could not add a verified certificate'));
    assert.equal(pairingCreates,0,'No grant for missing or mismatched private-host trust');
   }
   await page.locator('#jam-pairing-endpoint').fill('https://host.example.invalid/');
   trustGate=new Promise(resolve=>{releaseTrust=resolve;});
   await page.locator('#jam-pairing-create').click();
   for(let i=0;i<100&&!trustWaiting;i++) await new Promise(resolve=>setTimeout(resolve,10));
   assert(trustWaiting,'Certificate discovery began');
   await page.evaluate(()=>{const field=document.querySelector('#jam-pairing-endpoint');field.value='https://changed.local/';field.dispatchEvent(new Event('input',{bubbles:true}));});
   releaseTrust();trustGate=null;
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('Connection changed'));
   assert.equal(pairingCreates,0,'A delayed certificate cannot attach to an edited endpoint');
   await page.locator('#jam-pairing-endpoint').fill('https://host.example.invalid/');
   await page.locator('#jam-pairing-create').click();
   await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#jam-pairing-code').waitFor({state:'visible'});
   assert.equal(pairingCreates,1);
   assert.equal(await page.evaluate(()=>window.syntheticPairing.certificate_sha256),'b'.repeat(64),'QR includes verified leaf without manual entry');
   assert.equal(await page.locator('#jam-pairing-code input, #jam-pairing-code textarea').count(),0,'Bearer is not shown as plaintext');
   await page.locator('#jam-pairing-hide').click();
   assert(await page.locator('#jam-pairing-code').isHidden());
   assert.equal(await page.locator('#jam-pairing-qr').getAttribute('src'),null);
   await page.getByRole('button',{name:'Revoke access',exact:true}).click();
   await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.getByText('No paired devices.',{exact:true}).waitFor();
   assert.equal(pairingRevokes,1);
   await page.locator('#jam-pairing-scope').selectOption('jars_pay_v1');
   await page.locator('#jam-pairing-create').click();
   await page.getByText(/This phone can manage and send funds/).waitFor();
   await page.getByRole('button',{name:'Go back',exact:true}).click();
   assert.equal(pairingCreates,1,'Cancelling spending permission cannot issue a grant');
   await page.locator('#jam-pairing-create').click();
   await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#jam-pairing-code').waitFor({state:'visible'});
   assert.equal(pairings[0].scope,'jars_pay_v1');
   await page.locator('#jam-pairing-scope').selectOption('jars_manage_v1');
   assert(await page.locator('#jam-pairing-code').isHidden(),'Changing permission hides the previous private code');
   assert.equal(pairings[0].scope,'jars_pay_v1','UI selection does not silently change an existing grant');
   await page.getByRole('button',{name:'Revoke access',exact:true}).click();
   await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.getByText('No paired devices.',{exact:true}).waitFor();
   assert.equal(pairingRevokes,2);
   await page.locator('#jam-pairing-transport').selectOption('tor');
   await page.locator('#jam-pairing-endpoint').fill('http://short.onion');
   await page.locator('#jam-pairing-create').click();
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent === 'Use a full v3 onion address for Tor pairing.');
   assert.equal(pairingCreates,2,'Malformed onion cannot create a grant');
   await page.locator('#jam-pairing-endpoint').fill('http://'+'a'.repeat(56)+'.onion/');
   await page.locator('#jam-pairing-create').click();
   await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#jam-pairing-code').waitFor({state:'visible'});
   assert.equal(pairingCreates,3);
   assert.equal(await page.evaluate(()=>window.syntheticPairing.certificate_sha256),'','HTTPS fingerprint must not carry into Tor pairing');
   if(process.env.SCREENSHOT_DIR) { fs.mkdirSync(process.env.SCREENSHOT_DIR,{recursive:true}); await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`jars-tor-${width}.png`),fullPage:true}); }
   await page.locator('#jam-pairing-endpoint').fill('http://'+'b'.repeat(56)+'.onion/');
   assert(await page.locator('#jam-pairing-code').isHidden(),'Editing the host hides the old private code');
   await page.getByRole('button',{name:'Revoke access',exact:true}).click();
   await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.getByText('No paired devices.',{exact:true}).waitFor();
   assert.equal(pairingRevokes,3);
   await page.locator('#jam-pairing-panel > summary').click();
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
   recovery.state='prepared';await page.locator('#jam-payments-load').click();
   await page.getByRole('button',{name:'Discard review',exact:true}).click();
   await page.getByRole('button',{name:'Go back',exact:true}).click();
   assert.equal(actions.filter(x=>x==='cancel_payment').length,0);
   failCancel=true;
   await page.getByRole('button',{name:'Discard review',exact:true}).click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('Synthetic cancellation timeout'));
   assert.equal(actions.filter(x=>x==='cancel_payment').length,1);
   await page.getByRole('heading',{name:'Review saved'}).waitFor();
   failCancel=false;
   await page.getByRole('button',{name:'Discard review',exact:true}).click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.getByRole('heading',{name:'Cancelled'}).waitFor();
   assert.equal(await page.getByRole('button',{name:'Discard review',exact:true}).count(),0);
   recovery.state='submitted';await page.locator('#jam-payments-load').click();
   for (const item of recoveryCases.filter(x=>x.valid && x.payment.quote && x.payment.quote.purpose !== 'send')) {
    recovery=structuredClone(item.payment); recovery.quote.wallet='Sample Jars.jmdat';
    await page.locator('#jam-payments-load').click();
    await page.getByText(recovery.quote.purpose==='fund_bond'?'Bond funding':'Bond withdrawal',{exact:true}).waitFor();
    await page.locator('#jam-payments .jam-payment details summary').click();
    await page.getByText(recovery.quote.bond_locktime ? 'Bond unlock date: 2030-01-01 00:00:00 UTC' : 'Bond unlock date: Unavailable — check your Jam host',{exact:true}).waitFor();
    if(process.env.SCREENSHOT_DIR && recovery.quote.bond_locktime) await page.locator('#jam-payments').screenshot({path:path.join(process.env.SCREENSHOT_DIR,`bond-history-${width}.png`),animations:'disabled'});
   }
   recovery=structuredClone(recoveryCases.find(x=>x.name==='CoinJoin total fee split').payment); recovery.quote.wallet='Sample Jars.jmdat';
   await page.locator('#jam-payments-load').click();
   await page.getByText('Total fees',{exact:true}).waitFor();
   await page.locator('#jam-payments .jam-payment details summary').click();
   await page.getByText('Maker fees: 40 sats',{exact:true}).waitFor();
   await page.getByText('Your mining fee: 100 sats',{exact:true}).waitFor();
   if(process.env.SCREENSHOT_DIR) await page.locator('#jam-payments').screenshot({path:path.join(process.env.SCREENSHOT_DIR,`coinjoin-history-${width}.png`),animations:'disabled'});
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
   assert(await page.locator('#jam-jars').evaluate(el=>el.scrollWidth<=el.clientWidth),'Selection does not move a jar offscreen');

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
   assert.equal(await page.locator('#jam-maker-checks').evaluate(el=>el.open),false,'Detailed setup checks start collapsed');
   assert.match(await page.locator('#jam-maker-readiness').textContent(),/Set up and fund a fidelity bond/);
   await openTool('settings');
   await page.locator('#jam-maker-checks summary').click();
   await page.getByText('Ready: Amount and fee valid',{exact:true}).waitFor();
   await page.locator('#jam-maker-checks summary').click();
   assert(await page.locator('#jam-maker').evaluate(el=>Boolean(el.compareDocumentPosition(document.querySelector('#jam-market-panel')) & Node.DOCUMENT_POSITION_FOLLOWING)),'Review action precedes optional market help');
   assert.match(await page.locator('#jam-maker-checklist').textContent(),/Needed: Set up and fund a fidelity bond/);
   await closeTool();
   assert(!actions.includes('start_maker'),'Opening jars must not start a maker');
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)),'No horizontal overflow');
   assert.deepEqual(errors,[]);
   await openTool('bond');
   await page.locator('#jam-bond-month').fill('2020-01');
   await page.locator('#jam-bond-review').click();
   await page.locator('#jam-status').filter({hasText:'future month'}).waitFor();
   assert.equal(actions.filter(action=>action==='bond_address').length,0);
   assert.equal(await page.locator('#jam-bond-coins input').count(),0);
   await closeTool(); await page.locator('.jam-jar').nth(0).click(); await openTool('bond');
   await page.locator('#jam-bond-month').fill('2099-12');
   await page.locator('#jam-bond-review').click();
   assert.equal(actions.filter(action=>action==='bond_address').length,0);
   await page.locator('#jam-bond-coins input').check();
   await page.locator('#jam-bond-review').click();
   await page.locator('#jam-send-dialog').waitFor();
   assert(await page.locator('#jam-send-address').isHidden());
   assert(await page.locator('#jam-send-amount').isHidden());
   assert.match(await page.locator('#jam-send-mode').textContent(),/200,000 sats/);
   await page.locator('#jam-send-prepare').click();
   await page.locator('#jam-send-commit').waitFor();
   assert.equal(await page.locator('#jam-send-hero').textContent(),'199,850 sats');
   assert.match(await page.locator('#jam-send-costs').textContent(),/150 sats/);
   await page.locator('#jam-send-close').click();
   assert.equal(actions.filter(action=>action==='commit_payment').length,0);
   await openTool('bond'); await page.locator('#jam-bond-coins input').check(); failBond=true;
   await page.locator('#jam-bond-review').click();
   await page.locator('#jam-status').filter({hasText:'Synthetic bond timeout'}).waitFor();
   assert.equal(actions.filter(action=>action==='bond_address').length,2);
   if(process.env.SCREENSHOT_DIR) {
    await page.locator('#network').evaluate(el=>el.textContent='UI TEST FIXTURE · NOT LIVE FUNDS');
    await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`joinblaket-${width}.png`),fullPage:true,animations:'disabled'});
   }
   // An uncertain maker response requires reconciliation before another start.
   jars[0].bond_sat=100000; jars[0].total_sat=300000;
   await closeTool();await page.locator('#jam-refresh').click();
   await page.waitForFunction(()=>!document.querySelector('#jam-maker').disabled);
   failStatus=true;await closeTool();await page.locator('#jam-refresh').click();
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('stale'));
   assert(await page.locator('#jam-maker').isDisabled(),'Failed refresh invalidates earlier readiness');
   assert.match(await page.locator('#jam-maker-checklist').textContent(),/Needed: Refresh wallet status/);
   failStatus=false;await closeTool();await page.locator('#jam-refresh').click();await page.waitForFunction(()=>!document.querySelector('#jam-maker').disabled);
   await openTool('settings');
   await page.locator('#jam-maker').click();
   await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('Synthetic'));
   assert.equal(actions.filter(action=>action==='start_maker').length,1);
   assert(await page.locator('#jam-maker').isDisabled(),'Unknown maker outcome requires refresh');
   assert.match(await page.locator('#jam-maker-readiness').textContent(),/Refresh maker status/);
   await closeTool();await page.locator('#jam-refresh').click();await page.waitForFunction(()=>!document.querySelector('#jam-maker').disabled);
   await openTool('settings');
   await page.locator('#jam-maker').click();
   await page.evaluate(()=>{document.querySelector('#wallet').hidden=true;});
   await page.getByRole('button',{name:'Confirm',exact:true}).waitFor({state:'hidden'});
   assert.equal(await page.locator('#jam-open').count(),0);
   assert.equal(actions.filter(action=>action==='start_maker').length,1,'A review from an ended session cannot start a maker');
   assert.equal(await page.locator('#jam-open').count(),0);
   await page.close();
  }
  console.log('PASS Jar browser: phone/desktop, all five jars from hot/QR/watch accounts, separate authorization, hot-wallet isolation, password clearing, maker eligibility and uncertain-action recovery, no overflow/errors');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1)});
