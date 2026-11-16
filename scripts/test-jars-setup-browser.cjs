// Unfunded synthetic UI fixtures only. Never capture recovery-word screens.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,1280]) {
   const page=await browser.newPage({viewport:{width,height:900}}), errors=[];
   page.setDefaultTimeout(15000); page.on('pageerror',e=>errors.push(e.message));
   let created=false, creates=0, backups=0, delayBackup=false, releaseBackup;
   const wallet='Test-Jars.jmdat', password='synthetic-password', phrase=Array(12).fill('fixture').join(' ');
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),p=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     let value={};
     if(p==='wallet')value={fingerprint:'fixture-only'};
     if(p==='wallet/identity')value={network:'regtest',exit_profile:2,lightning_enabled:false};
     if(p==='wallet/balance')value={spendable_sat:0};
     if(p==='onchain/balance')value={confirmed_sat:0};
     if(p==='wallet/vtxos')value=[];
     if(p==='hardware/accounts')value={accounts:[]};
     if(p==='joinblaket/connection')value={configured:true,ui_url:null};
     if(p==='joinblaket/request') {
      const body=route.request().postDataJSON();
      if(body.operation==='wallets')value={wallets:created?[wallet]:[]};
      else if(body.operation==='create_wallet') {
       assert.equal(body.wallet,wallet); assert.equal(body.password,password); creates++; created=width!==1280 || creates>1;
       // The server created the wallet, but the browser lost the response.
       return route.fulfill({status:504,json:{message:'Synthetic interrupted creation'}});
      } else if(body.operation==='unlock')value={walletname:wallet,token:'fixture-jam-token'};
      else if(body.operation==='backup_wallet') {
       backups++;assert.equal(body.wallet,wallet);
       if(body.password!==password)return route.fulfill({status:401,json:{message:'Wrong synthetic password'}});
       if(delayBackup)await new Promise(resolve=>{releaseBackup=resolve;});
       value={walletname:wallet,token:'fixture-jam-token',seedphrase:phrase};
      } else if(body.operation==='status')value={session:true,wallet_name:wallet,maker_running:false,coinjoin_in_process:false,rescanning:false};
      else if(body.operation==='coins')value={jars:Array.from({length:5},(_,id)=>({id,name:'Jar '+(id+1),total_sat:0,confirmed_sat:0,pending_sat:0,frozen_sat:0,bond_sat:0}))};
      else throw new Error('Unexpected Jars operation: '+body.operation);
     }
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    await route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':file.endsWith('.svg')?'image/svg+xml':'image/jpeg'});
   });
   async function login(){await page.locator('#remember-session').uncheck();await page.locator('#token').fill('fixture-owner-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});await page.locator('.view-nav [data-view="coinjoin"]').click();}
   await page.goto('http://wallet.test/');await login();
   await page.locator('#jam-find').click();await page.getByText('Create your Jars wallet here to get started.',{exact:true}).waitFor();
   await page.locator('#jam-create-panel summary').click();
   await page.locator('#jam-create-name').fill('Test-Jars');await page.locator('#jam-create-password').fill(password);await page.locator('#jam-create-confirm').fill(password);
   await page.locator('#jam-create').click();await page.getByRole('button',{name:'Go back',exact:true}).click();assert.equal(creates,0);
   await page.locator('#jam-create').click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('Creation may have finished'));
   assert.equal(creates,1);assert.equal(await page.locator('#jam-create-password').inputValue(),'');assert(await page.locator('#jam-create').isDisabled());
   await page.reload();await login();
   assert(await page.locator('#jam-setup-pending').isVisible());
   if(width===1280) {
    await page.locator('#jam-setup-check').click();
    await page.waitForFunction(()=>!document.querySelector('#jam-create').disabled);
    assert(await page.locator('#jam-create-name').isDisabled());
    assert.equal(await page.locator('#jam-create-name').inputValue(),'Test-Jars');
    await page.locator('#jam-create-password').fill(password);await page.locator('#jam-create-confirm').fill(password);
    await page.locator('#jam-create').click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#jam-status').textContent.includes('Creation may have finished'));
    assert.equal(creates,2,'Retry requires a fresh review and retains the original filename');
   }
   await page.locator('#jam-setup-check').click();await page.locator('#jam-backup-dialog').waitFor({state:'visible'});
   if(process.env.SCREENSHOT_DIR) { fs.mkdirSync(process.env.SCREENSHOT_DIR,{recursive:true}); await page.locator('#jam-backup-dialog').screenshot({path:path.join(process.env.SCREENSHOT_DIR,`jars-backup-password-${width}.png`),animations:'disabled'}); }
   await page.locator('#jam-backup-password').fill('wrong-fixture');await page.locator('#jam-backup-reveal').click();
   await page.waitForFunction(()=>document.querySelector('#jam-backup-status').textContent.includes('Could not read'));
   assert.equal(await page.locator('#jam-backup-words li').count(),0);
   await page.locator('#jam-backup-password').fill(password);await page.locator('#jam-backup-reveal').click();
   await page.locator('#jam-backup-words-step').waitFor({state:'visible'});assert.equal(await page.locator('#jam-backup-words li').count(),12);
   assert.equal(await page.locator('#jam-backup-password').inputValue(),'');
   const bounds=await page.locator('#jam-backup-dialog').boundingBox();assert(bounds.x>=0&&bounds.width<=width,'Backup fits viewport');
   assert(await page.evaluate(()=>![...Object.values(sessionStorage),...Object.values(localStorage)].some(value=>value.includes('synthetic-password')||value.includes('fixture fixture'))),'Recovery secrets must not enter browser storage');
   await page.locator('#jam-backup-next').click();assert.equal(await page.locator('#jam-backup-words li').count(),0);assert(await page.locator('#jam-backup-finish').isDisabled());
   for(const field of await page.locator('#jam-backup-challenges input').all())await field.fill('wrong');
   assert(await page.locator('#jam-backup-finish').isDisabled());
   for(const field of await page.locator('#jam-backup-challenges input').all())await field.fill('fixture');
   await page.locator('#jam-backup-finish').click();await page.locator('#jam-dashboard').waitFor({state:'visible'});
   assert(await page.locator('#jam-backup-dialog').isHidden());assert.equal(await page.locator('#jam-backup-challenges input').count(),0);assert.equal(creates,width===1280?2:1);
   assert.equal(await page.evaluate(()=>sessionStorage.getItem('paperclip.jars.setup')),null);
   await page.locator('#jam-backup-open').click();delayBackup=true;
   await page.locator('#jam-backup-password').fill(password);await page.locator('#jam-backup-reveal').click();
   while(!releaseBackup)await new Promise(resolve=>setTimeout(resolve,10));
   await page.locator('#jam-backup-close').click();releaseBackup();
   await page.waitForFunction(()=>!document.querySelector('#jam-backup-open').disabled);
   assert(await page.locator('#jam-backup-dialog').isHidden());assert.equal(await page.locator('#jam-backup-words li').count(),0);
   delayBackup=false;await page.locator('#jam-backup-open').click();await page.locator('#jam-backup-password').fill(password);await page.locator('#jam-backup-reveal').click();
   await page.locator('#jam-backup-words-step').waitFor({state:'visible'});
   await page.evaluate(()=>{document.querySelector('[data-screen="coinjoin"]').hidden=true;});
   await page.locator('#jam-backup-dialog').waitFor({state:'hidden'});assert.equal(await page.locator('#jam-backup-words li').count(),0);
   assert.deepEqual(errors,[]);assert.equal(backups,4);
   await page.close();console.log(`Jars interrupted setup, password backup, verification and secret clearing passed at ${width}px`);
  }
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});
