const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/krux.json')));
const urFixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/seedsigner.json')));
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try{
  for(const width of [390,1280]){
   const page=await browser.newPage({viewport:{width,height:1000},reducedMotion:'reduce'}),errors=[],calls=[],receipts={};
   const accounts=[{id:'a'.repeat(64),label:'Travel Krux',kind:'hardware'},{id:'b'.repeat(64),label:'Savings Krux',kind:'hardware'}];
   page.on('pageerror',error=>errors.push(error.message));
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')){
     const body=route.request().postDataJSON();calls.push({name,body});let value=[];
     if(name==='wallet')value={fingerprint:'synthetic'};
     if(name==='wallet/identity')value={network:'bitcoin',exit_profile:2,lightning_enabled:true,lightning_debit_limit:true};
     if(name==='wallet/balance')value={spendable_sat:100000};if(name==='onchain/balance')value={confirmed_sat:50000};
     if(name==='hardware/accounts')value={accounts};
     if(name==='hardware/request'){
      if(body.operation==='refresh')value={confirmed_sat:body.account===accounts[0].id?11111:22222,pending_sat:0,transactions:[],last_broadcast:receipts[body.account]||null};
      if(body.operation==='address')value={address:fixtures[0].receive_address};
      if(body.operation==='prepare')value={account:body.account,request_id:'c'.repeat(64),destination:body.destination,amount_sat:70000,fee_sat:1000,total_sat:71000,psbt:fixtures[0].original};
      if(body.operation==='verify')value={verified:true,fee_sat:1000,txid:'d'.repeat(64)};
      if(body.operation==='broadcast'){value={state:'pending_broadcast',txid:body.txid};receipts[body.account]=value;}
      if(body.operation==='pair'){const account={id:'e'.repeat(64),label:body.label,kind:'hardware'};accounts.push(account);value={...account,first_address:fixtures[2].receive_address};}
     }
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   await page.goto('http://wallet.test/');
   assert.equal(await page.locator('#wallet #cold-send').count(),1,'Cold-wallet controls must be inside the authenticated container');
   if(width===390){
    const result=await page.evaluate(async({fixtures,urFixtures})=>{
     const {Collector,frames,binary,toBase64}=PaperclipSigningQR;let checked=0;
     for(const fixture of fixtures){const parts=frames(binary(fixture.signed)),collector=new Collector();let result=null;for(const frame of parts.reverse()){const next=await collector.accept(frame);if(next)result=next;}if(toBase64(result)!==fixture.signed)throw Error('BBQr mismatch');checked++;}
     for(const fixture of urFixtures){const collector=new Collector();let result=null;for(const frame of fixture.ur){const next=await collector.accept(frame);if(next)result=next;if(result)break;}if(!result||toBase64(result)!==fixture.signed)throw Error('UR mismatch');checked++;}
     let rejected=0;for(const value of ['ur:crypto-account/abcd','B$2P0000AAAA','B$2P0100A','B$2P0100AAAAAAAA!']){try{await new Collector().accept(value);}catch{rejected++;}}
     const mixed=new Collector();await mixed.accept('B$2P0200AAAAAAAA');try{await mixed.accept('B$2P0301AAAAAAAA');}catch{rejected++;}
     try{await new Collector().accept(Array(12).fill('synthetic').join(' '),true);}catch{rejected++;}
     return {checked,rejected};
    },{fixtures,urFixtures});
    assert.deepEqual(result,{checked:8,rejected:6});
   }
   await page.locator('#token').fill('synthetic-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});
   await page.waitForFunction(()=>document.querySelector('#wallet-select').options.length===3);
   await page.locator('#wallet-select').selectOption(accounts[0].id);await page.waitForFunction(()=>document.querySelector('#cold-balance').textContent==='11,111');
   assert.equal(await page.locator('#ark-balance').isVisible(),false);assert.equal(await page.locator('#wallet-kind').textContent(),'QR WALLET · KEYS OFFLINE');
   const rejected=await page.evaluate(async()=>{try{await api('wallet/send',{destination:'wrong-wallet',amount_sat:1});return false;}catch{return true;}});assert(rejected);assert(!calls.some(c=>c.name==='wallet/send'));
   await page.getByRole('button',{name:'↙ Receive',exact:true}).click();await page.locator('#cold-address').filter({hasText:fixtures[0].receive_address}).waitFor();
   await page.locator('.view-nav [data-view="lightning"]').click();await page.getByRole('heading',{name:'Your keys stay offline'}).waitFor();assert.equal(await page.locator('#ln-pay').isVisible(),false);
   await page.locator('.view-nav [data-view="overview"]').click();await page.getByRole('button',{name:'↗ Send',exact:true}).click();
   async function prepare(){await page.locator('#cold-destination').fill(fixtures[0].receive_address);await page.locator('#cold-amount').fill('70000');await page.getByRole('button',{name:'Review signing request',exact:true}).click();await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.locator('#signing-request').waitFor({state:'visible'});}
   await prepare();assert.match(await page.locator('#signing-review').textContent(),/71,000 sats/);assert.equal(await page.locator('#signing-pause').textContent(),'Play QR');
   const decoded=await page.evaluate(async()=>{
    const source=document.querySelector('#signing-qr svg').outerHTML,url=URL.createObjectURL(new Blob([source],{type:'image/svg+xml'}));
    try{const image=new Image();image.src=url;await image.decode();const canvas=document.createElement('canvas');canvas.width=800;canvas.height=800;const ctx=canvas.getContext('2d');ctx.drawImage(image,0,0,800,800);const pixels=ctx.getImageData(0,0,800,800);return PaperclipQRVendor.jsQR(pixels.data,800,800)?.data;}finally{URL.revokeObjectURL(url);}
   });assert.match(decoded,/^B\$2P/,'Displayed QR must decode with the camera decoder');
   await page.locator('#signed-file').setInputFiles({name:'signed.psbt',mimeType:'application/octet-stream',buffer:Buffer.from(fixtures[0].signed,'base64')});
   await page.waitForFunction(()=>!document.querySelector('#signed-broadcast').disabled);
   await page.locator('#wallet-select').selectOption(accounts[1].id);await page.waitForFunction(()=>document.querySelector('#cold-balance').textContent==='22,222');
   assert.equal(await page.locator('#cold-address').textContent(),'');assert.equal(await page.locator('#signing-qr').textContent(),'');assert.equal(await page.locator('#signed-broadcast').isEnabled(),false);
   assert(!calls.some(c=>c.body?.operation==='broadcast'));assert(calls.some(c=>c.body?.operation==='cancel'&&c.body.account===accounts[0].id));
   await page.getByRole('button',{name:'↗ Send',exact:true}).click();await prepare();
   await page.locator('#signed-file').setInputFiles({name:'signed.psbt',mimeType:'application/octet-stream',buffer:Buffer.from(fixtures[0].signed,'base64')});await page.waitForFunction(()=>!document.querySelector('#signed-broadcast').disabled);
   await page.locator('#signed-broadcast').click();await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.waitForFunction(()=>document.querySelector('#cold-relay').textContent.includes('uncertain'));
   assert.equal(calls.filter(c=>c.body?.operation==='broadcast').length,1);assert.equal(await page.locator('#transaction-result').isVisible(),false);
   await page.locator('#reload').click();await page.waitForFunction(()=>document.querySelector('#cold-relay').textContent.includes('uncertain'));assert.equal(calls.filter(c=>c.body?.operation==='broadcast').length,1);
   if(process.env.SCREENSHOT_DIR){fs.mkdirSync(process.env.SCREENSHOT_DIR,{recursive:true});await page.evaluate(()=>{const note=document.createElement('p');note.textContent='Synthetic UI test · no live funds';note.id='test-watermark';document.body.prepend(note);});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`krux-wallet-${width}.png`),fullPage:true});}
   await page.getByRole('button',{name:'Manage wallets',exact:true}).click();await page.locator('#pair-wallet > summary').click();await page.locator('#pair-name').fill('Home Krux');await page.locator('#pair-key').fill(fixtures[2].public_key);await page.getByRole('button',{name:'Pair public account',exact:true}).click();await page.locator('#pair-confirmation').waitFor({state:'visible'});
   await page.locator('#pair-use').click();await page.waitForFunction(()=>document.querySelector('#cold-name').textContent==='Home Krux');
   await page.locator('#wallet-select').selectOption('');await page.locator('#ark-balance').waitFor({state:'visible'});assert.equal(await page.locator('#cold-balance').isVisible(),false);
   await page.locator('#lock').click();await page.goBack();assert.equal(await page.locator('#wallet').isVisible(),false);assert.equal(await page.locator('#pair-key').inputValue(),'');assert.deepEqual(errors,[]);
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));await page.close();
  }
  console.log('PASS: Krux/UR codecs, public pairing, wallet isolation, draft cancellation, verified signing, uncertain broadcast, and lock cleanup at phone/desktop widths');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
