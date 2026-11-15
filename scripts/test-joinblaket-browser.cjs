const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,1280]) {
   const page=await browser.newPage({viewport:{width,height:1000}}),errors=[],actions=[];
   page.setDefaultTimeout(15000);
   page.on('pageerror',error=>errors.push(error.message));
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
     if(p==='joinblaket/connection') value={configured:true,ui_url:'https://jam.example.test/'};
     if(p==='joinblaket/request') {
      const body=route.request().postDataJSON(); actions.push(body.operation);
      assert.equal(route.request().method(),'POST');
      if(body.operation==='start_maker') return route.fulfill({status:503,json:{message:'Synthetic unknown maker outcome'}});
      if(body.operation==='wallets') value={wallets:['fixture.jmdat']};
      else if(body.operation==='unlock') { assert.equal(body.bip39_passphrase,'fixture-passphrase'); value={walletname:'fixture.jmdat',token:'fixture-token'}; }
      else if(body.operation==='status') value={session:true,wallet_name:'fixture.jmdat',maker_running:false,coinjoin_in_process:false,rescanning:false};
      else if(body.operation==='coins') value={jars};
      else if(body.operation==='address') { assert.equal(body.jar,3); value={address:'bc1qsyntheticdisplayonly'}; }
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
   await page.locator('.view-nav [data-view="settings"]').click();
   await page.locator('[data-view="coinjoin"]').click();
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
   await page.getByRole('button',{name:/Date.*0 sats/}).click();
   assert.equal(await page.locator('#jam-selected-name').textContent(),'Date');
   await page.locator('#jam-receive').click();
   await page.waitForFunction(()=>document.querySelector('#jam-address').textContent.includes('bc1qsynthetic'));
   assert(await page.locator('#jam-maker').isDisabled(),'No bond must not be presented as maker ready');
   assert(!actions.includes('start_maker'),'Opening jars must not start a maker');
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)),'No horizontal overflow');
   assert.deepEqual(errors,[]);
   if(process.env.SCREENSHOT_DIR) {
    await page.locator('#network').evaluate(el=>el.textContent='UI TEST FIXTURE · NOT LIVE FUNDS');
    await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`joinblaket-${width}.png`),fullPage:true,animations:'disabled'});
   }
   // An uncertain maker response requires reconciliation before another start.
   jars[0].bond_sat=100000; jars[0].total_sat=300000;
   await page.locator('#jam-refresh').click();
   await page.waitForFunction(()=>!document.querySelector('#jam-maker').disabled);
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
  console.log('PASS Jar browser: phone/desktop, five jars, correct receive account, password clearing, maker eligibility, no automatic mutation, no overflow/errors');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1)});
