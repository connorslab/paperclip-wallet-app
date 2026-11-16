const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,1280]) {
   const page=await browser.newPage({viewport:{width,height:1100}}),errors=[],actions=[];
   page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
   const cold='c'.repeat(64);let hold=null,release=null,wrongNetwork=false;
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     const body=route.request().postDataJSON();
     if(name==='hardware/request'&&body.operation==='destination') {
      actions.push(body);if(hold)await hold;
      assert.notEqual(body.account,body.target_account);
      return route.fulfill({json:{account:body.target_account,label:body.target_account?'Savings signer':'Hot wallet',address:body.target_account?'bcrt1qsyntheticcold':'bcrt1qsynthetichot',network:wrongNetwork?'bitcoin':'regtest'}});
     }
     const value=name==='wallet'?{fingerprint:'fixture'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,lightning_enabled:false}:
      name==='wallet/balance'?{spendable_sat:0}:name==='onchain/balance'?{confirmed_sat:100000}:
      name==='hardware/accounts'?{accounts:[{id:cold,label:'Savings signer',kind:'hardware'}]}:
      name==='hardware/request'?{confirmed_sat:10000,pending_sat:0,transactions:[]}:[];
     if(route.request().method()!=='GET'&&name!=='hardware/request')throw Error('Unexpected wallet action '+name);
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});
   await page.locator('[data-view=onchain]').first().click();
   const hot=page.locator('#chain-send .own-wallet-transfer');
   await hot.getByRole('button').click();await hot.locator('select').selectOption(cold);
   await page.waitForFunction(()=>document.querySelector('#chain-destination').value==='bcrt1qsyntheticcold');
   assert.equal(await page.locator('#wallet-select').inputValue(),'','Generating a destination must not switch the source');
   assert.match(await hot.getByRole('status').textContent(),/Savings signer/);
   await page.locator('#chain-destination').fill('manual-address');assert.equal(await hot.getByRole('status').textContent(),'');
   hold=new Promise(resolve=>{release=resolve});await hot.locator('select').selectOption(cold);
   await page.waitForFunction(()=>document.querySelector('#chain-send .own-wallet-transfer select').disabled);
   await page.locator('#chain-destination').fill('edited-during-lookup');release();hold=null;
   await page.waitForFunction(()=>!document.querySelector('#chain-send .own-wallet-transfer select').disabled);
   assert.equal(await page.locator('#chain-destination').inputValue(),'edited-during-lookup');
   wrongNetwork=true;await hot.locator('select').selectOption(cold);await hot.getByRole('status').filter({hasText:'changed'}).waitFor();assert.equal(await page.locator('#chain-destination').inputValue(),'');wrongNetwork=false;
   await page.locator('#wallet-select').selectOption(cold);await page.waitForFunction(()=>document.body.classList.contains('qr-account-active'));
   await page.locator('.cold-overview [data-view=signing]').click();
   const qr=page.locator('#cold-send .own-wallet-transfer');await qr.getByRole('button').click();await qr.locator('select').selectOption('');
   await page.waitForFunction(()=>document.querySelector('#cold-destination').value==='bcrt1qsynthetichot');
   assert.equal(await page.locator('#wallet-select').inputValue(),cold);assert.match(await qr.getByRole('status').textContent(),/Hot wallet/);
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)));
   if(process.env.PAPERCLIP_SCREENSHOT_DIR) { fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true}); await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,'wallet-transfers-'+width+'.png'),fullPage:true}); }assert.deepEqual(errors,[]);assert.equal(actions.length,4);
   await page.close();
  }
  console.log('PASS own-wallet transfers: hot/QR directions, unchanged source, fresh destination, manual-edit race, wrong network, phone/desktop fit, no sends');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1)});
