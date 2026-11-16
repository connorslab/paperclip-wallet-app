const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,800,1280]) {
   const page=await browser.newPage({viewport:{width,height:1100},reducedMotion:'reduce'}),errors=[],mutations=[];
   page.setDefaultTimeout(10000);page.on('pageerror',error=>errors.push(error.message));
   const cold='c'.repeat(64),deposit='a'.repeat(64),send='b'.repeat(64);
   let failArk=false,failChain=false,malformed=false,empty=false,large=false,requests=0;
   const chain=[{txid:deposit,balance_change_sat:230000,confirmation:{height:1200,hash:'d'.repeat(64)},tx:'00'},
    {txid:send,balance_change_sat:-71000,onchain_fee_sat:1000,confirmation:null,tx:'00'},
    {txid:'f'.repeat(64),balance_change_sat:0,confirmation:{height:1201,hash:'e'.repeat(64)},tx:'00'}];
   const ark=[{id:'settled-movement',effective_balance_sat:-237915,offchain_fee_sat:7915,status:'successful',subsystem:{name:'bark.lightning_send'},time:{created_at:'2026-11-15T10:20:00Z'}},
    {id:'future-state',status:'unexpected-state',effective_balance_sat:900,subsystem:{name:'<img src=x onerror="window.pwned=true">'},time:{created_at:'invalid'}},
    {id:'cancelled-movement',status:'canceled',effective_balance_sat:0,offchain_fee_sat:0}];
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     requests++;
     const body=route.request().postDataJSON();
     if(route.request().method()!=='GET'&&body?.operation!=='refresh')mutations.push(name);
     if((name==='history'&&failArk)||(name==='onchain/transactions'&&failChain))return route.fulfill({status:500,json:{message:'Synthetic unavailable source'}});
     const value=name==='wallet'?{fingerprint:'synthetic'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,lightning_enabled:true,lightning_debit_limit:true}:
      name==='wallet/balance'?{spendable_sat:12000}:name==='onchain/balance'?{confirmed_sat:230000}:
      name==='history'?(empty?[]:ark):name==='onchain/transactions'?(malformed?{}:large?Array.from({length:70},(_,i)=>({...chain[0],txid:String(i).padStart(64,'0')})):empty?[]:chain):
      name==='hardware/accounts'?{accounts:[{id:cold,label:'Savings signer',kind:'hardware'}]}:
      name==='hardware/request'?{confirmed_sat:12000,pending_sat:1000,transactions:[{txid:deposit,amount_sat:12000,confirmed:true},{txid:send,amount_sat:-1000,confirmed:false}]}:[];
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   async function refresh(){await page.locator('#history-load').click();await page.waitForFunction(()=>!document.querySelector('#history-load').disabled);}
   await page.goto('http://wallet.test/');await page.locator('#token').fill('synthetic-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});
   await page.locator('.view-nav [data-view="activity"]').click();await page.waitForFunction(()=>document.querySelector('#activity-summary').textContent.includes('6 records'));
   assert.equal(await page.locator('#activity-list .activity-row').count(),6);
   assert.equal(await page.locator('#activity-list [data-activity-state="unknown"]').count(),1,'Unfamiliar status must not imply completion');
   assert.equal(await page.locator('#activity-list [data-activity-state="cancelled"]').count(),1);
   assert.match(await page.locator('#activity-list').textContent(),/Movement completed/);
   assert.match(await page.locator('#activity-list').textContent(),/recipient to confirm settlement/);
   assert.match(await page.locator('#activity-list').textContent(),/-71,000 sats/,'Net debit must not have the fee subtracted twice');
   assert.match(await page.locator('#activity-list').textContent(),/Transaction feeUnavailable/,'Missing fee must not become zero');
   assert.match(await page.locator('#activity-list').textContent(),/Block 1,200/);
   assert.equal(await page.locator('#activity-list img').count(),0);assert.equal(await page.evaluate(()=>window.pwned),undefined);
   await page.locator('[data-activity-filter="onchain"]').click();assert.equal(await page.locator('#activity-list .activity-row').count(),3);
   assert.equal(await page.locator('[data-activity-filter="onchain"]').getAttribute('aria-pressed'),'true');
   assert.match(await page.locator('#activity-list .activity-row').first().textContent(),/On-chain transfer/,'Keep server observation order, newest first');
   await page.locator('#activity-list .activity-row').nth(1).locator('> details > summary').click();
   assert(!(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth)),'Expanded details must fit');
   for(const button of await page.locator('[data-activity-filter]').all())assert((await button.boundingBox()).height>=44);
   if(process.env.SCREENSHOT_DIR){await page.locator('#network').evaluate(element=>element.textContent='UI FIXTURE · NO LIVE FUNDS');await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`activity-${width}.png`),fullPage:true});}
   await page.locator('[data-activity-filter="all"]').click();failArk=true;await refresh();
   assert.match(await page.locator('#activity-summary').textContent(),/Ark activity unavailable/);assert.equal(await page.locator('#activity-list .activity-row').count(),3);
   failArk=false;failChain=true;await refresh();assert.match(await page.locator('#activity-summary').textContent(),/On-chain activity unavailable/);assert.equal(await page.locator('#activity-list .activity-row').count(),3);
   failChain=false;malformed=true;await refresh();assert.match(await page.locator('#activity-summary').textContent(),/On-chain activity unavailable/);
   malformed=false;empty=true;await refresh();assert.match(await page.locator('#activity-list').textContent(),/No activity yet/);
   large=true;await page.locator('[data-activity-filter="onchain"]').click();await refresh();
   assert.equal(await page.locator('#activity-list .activity-row').count(),25);assert.match(await page.locator('#activity-summary').textContent(),/70 records/);
   await page.locator('#activity-list .activity-row').first().locator('> details > summary').click();
   const beforeMore=requests;await page.getByRole('button',{name:'Show more On-chain records',exact:true}).click();
   assert.equal(await page.locator('#activity-list .activity-row').count(),50);assert.equal(requests,beforeMore);
   assert.equal(await page.locator('#activity-list .activity-row').first().locator('> details').evaluate(element=>element.open),true,'Loading more preserves open details');
   assert.equal(await page.locator('#activity-list .activity-row').nth(25).evaluate(element=>element===document.activeElement),true);
   await page.getByRole('button',{name:'Show more On-chain records',exact:true}).click();assert.equal(await page.locator('#activity-list .activity-row').count(),70);
   assert.equal(await page.getByRole('button',{name:'Show more On-chain records',exact:true}).isVisible(),false);large=false;
   await page.locator('[data-activity-filter="ark"]').click();
   await page.waitForFunction(()=>document.querySelector('#wallet-select').options.length===2);await page.locator('#wallet-select').selectOption(cold);
   await page.locator('.view-nav [data-view="activity"]').click();await page.waitForFunction(()=>document.querySelectorAll('#cold-history .activity-row').length===2);
   assert.match(await page.locator('#cold-history').textContent(),/Received on-chain/);assert.match(await page.locator('#cold-history').textContent(),/Unconfirmed/);
   await page.locator('#cold-history-refresh').click();await page.waitForFunction(()=>!document.querySelector('#wallet-select').disabled);
   await page.locator('#wallet-select').selectOption('');
   assert.equal(await page.locator('[data-activity-filter="all"]').getAttribute('aria-pressed'),'true','Account change resets filters and data');
   assert.equal(await page.locator('#cold-history').textContent(),'');
   await page.locator('#lock').click();assert.equal(await page.locator('#activity-list').textContent(),'');
   assert.deepEqual(mutations,[]);assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS Activity: on-chain/Ark/QR records, signed balance changes, honest fee/status handling, partial failures, filters, lock/account isolation and responsive details');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1});
