// Synthetic QR payloads and balances only. No network nodes, keys or payments.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/krux.json'))).find(f=>f.script==='segwit');
const account='a'.repeat(64),txid='b'.repeat(64);
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {for(const width of [390,840,1280])for(const lost of [false,true]){
  const page=await browser.newPage({viewport:{width,height:1100},reducedMotion:'reduce'}),errors=[],calls=[];
  let malformed=true,receipt=null,boardsMode='pending';
  page.setDefaultTimeout(10000);page.on('pageerror',e=>errors.push(e.message));
  await page.route('http://wallet.test/**',async route=>{
   const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/',''),body=route.request().postDataJSON();
   if(url.pathname.startsWith('/api/')){
    calls.push({name,body});let value=[];
    if(name==='wallet')value={fingerprint:'synthetic'};
    if(name==='wallet/identity')value={network:'bitcoin',exit_profile:2,submission_journal:1,hardware_ark_boarding:true};
    if(name==='wallet/balance')value={spendable_sat:100000};
    if(name==='boards/pending'){if(boardsMode==='unavailable')return route.fulfill({status:503,json:{error:'unavailable'}});value=boardsMode==='empty'?[]:[{funding_tx:{txid},amount_sat:68000}];}
    if(name==='onchain/balance')value={confirmed_sat:50000};
    if(name==='hardware/accounts')value={accounts:[{id:account,label:'Offline savings',kind:'hardware'}]};
    if(name==='hardware/request'){
     if(body.operation==='refresh')value={confirmed_sat:100000,pending_sat:0,transactions:[]};
     if(body.operation==='ark_prepare')value={account,kind:'ark_board',request_id:txid,destination:fixture.receive_address,amount_sat:70000,fee_sat:1000,total_sat:71000,net_sat:malformed?69999:68000,reserve_sat:2000,recovery_anchor_sat:1000,recovery_miner_fee_sat:1000,psbt:fixture.original};
     if(body.operation==='ark_verify')value={verified:true,kind:'ark_board',txid,fee_sat:1000};
     assert(!['verify','broadcast'].includes(body.operation),'Ark signing must never use ordinary verification/broadcast');
    }
    if(name==='submissions'&&!body)value={version:1,pending:receipt?[receipt]:[],recent:[]};
    if(name==='submissions'&&body){
     assert.equal(body.operation,'hardware/board/commit');
     assert.deepEqual(body.body,{account,request_id:txid,amount_sat:70000,total_sat:71000});
     receipt={id:body.id,operation:body.operation,state:lost?'unconfirmed':'received',txid,result:{state:'pending',kind:'ark_board',txid,amount_sat:68000}};
     if(lost)return route.abort('failed');value=receipt;
    }
    if(name==='submissions/ack'){value={id:body.id,acknowledged:true};receipt=null;}
    if(name==='submissions/check')value=receipt;
    return route.fulfill({json:value});
   }
   const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
   return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
  });
  await page.goto('http://wallet.test/');await page.locator('#token').fill('synthetic');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('#wallet-select').options.length===2);
  await page.locator('#wallet-select').selectOption(account);await page.waitForFunction(()=>PaperclipAccounts.selectedId==='a'.repeat(64));
  await page.getByRole('button',{name:'↗ Send',exact:true}).click();await page.locator('#cold-purpose').selectOption('ark');
  assert(await page.locator('#cold-destination').isHidden());assert(await page.locator('#cold-max').isHidden());
  assert.match(await page.locator('#cold-ark-detail').textContent(),/Main wallet.*hot wallet’s keys/);
  await page.locator('#cold-amount').fill('70000');await page.getByRole('button',{name:'Review signing request',exact:true}).click();
  await page.locator('#signing-status').filter({hasText:'Invalid Ark recovery review'}).waitFor();
  assert(await page.locator('#signing-request').isHidden());
  malformed=false;await page.getByRole('button',{name:'Review signing request',exact:true}).click();await page.getByRole('button',{name:'Go back',exact:true}).click();
  assert.equal(calls.filter(c=>c.name==='submissions'&&c.body).length,0);
  await page.getByRole('button',{name:'Review signing request',exact:true}).click();
  if(process.env.SCREENSHOT_DIR&&!lost){fs.mkdirSync(process.env.SCREENSHOT_DIR,{recursive:true});await page.locator('.review-sheet').screenshot({path:path.join(process.env.SCREENSHOT_DIR,'qr-ark-review-'+width+'.png')});}
  await page.getByRole('button',{name:'Confirm',exact:true}).click();
  await page.locator('#signing-request').waitFor({state:'visible'});
  assert.match(await page.locator('#signing-review').textContent(),/Net Ark amount: 68,000 sats/);
  await page.locator('#signed-file').setInputFiles({name:'signed.psbt',mimeType:'application/octet-stream',buffer:Buffer.from(fixture.signed,'base64')});
  await page.waitForFunction(()=>!document.querySelector('#signed-broadcast').disabled);
  await page.locator('#signed-broadcast').click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
  await page.locator('#cold-relay').filter({hasText:lost?'uncertain':'Ark boarding is pending'}).waitFor();
  assert.equal(calls.filter(c=>c.name==='submissions'&&c.body).length,1);
  assert(calls.some(c=>c.body?.operation==='ark_verify'));
  assert(!calls.some(c=>c.body?.operation==='broadcast'));
  await page.locator('#transaction-result-done').click();
  await page.locator('#cold-ark-recovery').click();
  await page.locator('#pending-boards').filter({hasText:'68,000 sats'}).waitFor();
  assert.match(await page.locator('#pending-boards').textContent(),/Awaiting confirmation/);
  assert.equal(await page.evaluate(()=>PaperclipAccounts.selectedId),'');
  await page.locator('#pending-boards summary').click();
  assert.equal(await page.locator('#pending-boards code').textContent(),txid);
  boardsMode='empty';await page.locator('#vtxo-update').click();
  await page.locator('#pending-boards').filter({hasText:'does not establish the outcome'}).waitFor();
  boardsMode='unavailable';await page.locator('#vtxo-update').click();
  await page.locator('#pending-boards').filter({hasText:'Pending transfers are unavailable'}).waitFor();
  await page.reload();await page.locator('#wallet').waitFor({state:'visible'});
  assert.equal(calls.filter(c=>c.name==='submissions'&&c.body).length,1,'Reload must never repeat boarding');
  assert(!await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth));
  assert.deepEqual(errors,[]);
  console.log('PASS QR Ark review, recovery reserve, custody, cancel, dedicated signature path, journaled '+(lost?'unknown':'pending')+' result and no replay '+width);
  await page.close();
 }}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
