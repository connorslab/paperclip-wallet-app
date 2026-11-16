const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const [width,platform,scheme='https'] of [[390,'startos'],[840,'umbrel'],[1280,'standalone'],[390,'startos','http']]) {
   const page=await browser.newPage({viewport:{width,height:1000}}),errors=[],creations=[];
   page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
   let supported=true;
   await page.route(scheme+'://wallet.test/**',async route=>{
    const url=new URL(route.request().url());
    if(url.pathname.startsWith('/api/')) {
     if(url.pathname==='/api/v1/wallet/create-with-entropy') {
      creations.push(route.request().postDataJSON());
      return route.fulfill({status:503,json:{message:'Synthetic lost creation reply'}});
     }
     assert.equal(route.request().method(),'GET','No other mutation is allowed');
     const value=url.pathname==='/api/v1/wallet'?{fingerprint:null}:
      url.pathname==='/api/ui-platform'?{platform}:
      url.pathname==='/api/v1/wallet/platform-node'?{available:true}:
      url.pathname==='/api/v1/wallet/creation-options'&&supported?
       {version:1,methods:['system','dice'],words:[12,24],dice_derivation:'paperclip-dice-v1'}:{};
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   await page.goto(scheme+'://wallet.test/');await page.locator('#token').fill('synthetic-token');
   await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#setup').waitFor({state:'visible'});
   await page.waitForFunction(()=>document.querySelector('#setup-backend').value==='installed');
   await page.locator('#setup-ack').check();await page.locator('#setup-entropy > summary').click();
   const create=()=>page.getByRole('button',{name:'Create new wallet',exact:true}).click();
   const cancel=()=>page.getByRole('button',{name:'Go back',exact:true}).click();
   assert.equal(await page.locator('#setup-seed-method').inputValue(),'system');
   for(const words of [12,24]) {
    await page.locator('#setup-seed-words').selectOption(String(words));await create();
    await page.locator('.review-sheet[open]').waitFor();assert.match(await page.locator('.review-content').textContent(),new RegExp(words+' words from secure system randomness'));await cancel();
   }
   supported=false;await create();await page.locator('#status').filter({hasText:'Update your Paperclip host'}).waitFor();assert.equal(creations.length,0);supported=true;
   await page.locator('#setup-seed-method').selectOption('dice');
   if(scheme==='http') {
    await page.locator('#setup-dice-rolls').fill(Array(100).fill('2').join(' '));await page.locator('#setup-dice-ack').check();await create();
    await page.locator('#status').filter({hasText:'Use HTTPS'}).waitFor();assert.equal(creations.length,0);
    await page.close();console.log('PASS entropy setup: private dice rejected over ordinary plaintext LAN');continue;
   }
   for(const sides of [6,12,20]) for(const words of [12,24]) {
    await page.locator('#setup-dice-sides').selectOption(String(sides));await page.locator('#setup-seed-words').selectOption(String(words));
    const minimum={6:50,12:36,20:30}[sides]*(words===12?1:2);
    const rolls=Array.from({length:minimum},(_,i)=>String(i%sides+1)); // Synthetic vectors, never wallet suggestions.
    await page.locator('#setup-dice-rolls').fill(rolls.slice(1).join(' '));await page.locator('#setup-dice-ack').check();await create();
    await page.locator('#status').filter({hasText:'Complete the required rolls'}).waitFor();assert.equal(creations.length,0);
    await page.locator('#setup-dice-rolls').fill(rolls.join(' '));await create();await page.locator('.review-sheet[open]').waitFor();
    assert.match(await page.locator('.review-content').textContent(),new RegExp(words+' words from physical D'+sides+' dice only'));
    assert(!await page.locator('.review-content').textContent().then(text=>text.includes(rolls.join(' '))));await cancel();
   }
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
   if(process.env.SCREENSHOT_DIR){fs.mkdirSync(process.env.SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,'entropy-'+platform+'-'+width+'.png'),fullPage:true});}
   // A background transition discards the private draft and cancels its review.
   await create();await page.locator('.review-sheet[open]').waitFor();
   await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});
   assert.equal(await page.locator('#setup-dice-rolls').inputValue(),'');assert.equal(await page.locator('.review-sheet[open]').count(),0);assert.equal(creations.length,0);
   await page.evaluate(()=>{delete document.hidden;});
   await page.locator('#setup-dice-rolls').fill(Array(60).fill('2').join(' '));await page.locator('#setup-dice-ack').check();
   // Editing behind a review invalidates its snapshot, including edits then undone.
   await create();await page.locator('.review-sheet[open]').waitFor();
   await page.evaluate(()=>document.querySelector('#setup-seed-words').dispatchEvent(new Event('change',{bubbles:true})));
   await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.locator('#status').filter({hasText:'Setup changed'}).waitFor();assert.equal(creations.length,0);
   await page.locator('#setup-dice-ack').check();await create();await page.locator('.review-sheet[open]').waitFor();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#status').filter({hasText:'Synthetic lost creation reply'}).waitFor();assert.equal(creations.length,1);
   assert.deepEqual(creations[0].seed_generation,{method:'dice',words:24,sides:20,rolls:Array(60).fill(2),fair_dice_acknowledged:true});
   assert.equal(await page.locator('#setup-dice-rolls').inputValue(),'');
   await create();await page.locator('#status').filter({hasText:'previous setup completed'}).waitFor();assert.equal(creations.length,1);
   await page.locator('#setup-lock').click();assert.equal(await page.locator('#setup-dice-rolls').inputValue(),'');assert.deepEqual(errors,[]);
   await page.close();console.log('PASS entropy setup '+platform+'/'+width+': system/dice, thresholds, review, old-host refusal, draft clearing and no ambiguous retry');
  }
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});
