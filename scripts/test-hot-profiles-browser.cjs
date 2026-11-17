// Synthetic balances and keys only; no live nodes or transactions.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const a='a'.repeat(64), b='b'.repeat(64), cold='c'.repeat(64);
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {for(const [width,platform] of [[390,'startos'],[840,'umbrel'],[1280,'standalone']]){
  const context=await browser.newContext({viewport:{width,height:1000}}),page=await context.newPage(),calls=[],errors=[];
  let profiles=[{id:a,label:'Everyday'},{id:b,label:'Savings'}],missing=false,registered=null,blocked=null;
  const initialized=new Set(['',a,b]);
  page.setDefaultTimeout(10000);
  page.on('pageerror',e=>errors.push(e.message));
  await context.route('http://wallet.test/**',async route=>{
   const url=new URL(route.request().url()),body=route.request().postDataJSON();
   if(url.pathname.startsWith('/api/')){
    const matched=url.pathname.match(/^\/api\/profiles\/([a-f0-9]{64})\/v1\/(.*)$/),profile=matched?.[1]||'',name=matched?.[2]||url.pathname.replace('/api/v1/','');
    calls.push({profile,name,body,method:route.request().method()});
    if(blocked&&name===blocked.name&&profile===blocked.profile){const hold=blocked;blocked=null;hold.arrived();await hold.wait;}
    let value;
    if(url.pathname==='/api/profiles'){
     if(body){registered=body;if(!profiles.some(p=>p.id===body.id))profiles.push(body);value=body;}
     else value={version:1,profiles:missing?profiles.filter(p=>p.id!==a):profiles};
    }else if(/\/receive$/.test(url.pathname)){value={account:'hot:'+url.pathname.split('/')[3],label:'Other hot wallet',network:'regtest',address:'synthetic-receiving-address'};}else if(/\/name$/.test(url.pathname)){profiles=profiles.map(p=>p.id===body.id?body:p);value=body;}
    else if(name==='wallet')value={fingerprint:initialized.has(profile)?'synthetic':null};
    else if(name==='wallet/identity')value={network:'regtest',exit_profile:2,submission_journal:1,lightning_enabled:true,lightning_debit_limit:true};
    else if(name==='hardware/accounts')value={accounts:[{id:cold,label:'Offline '+(profile||'main'),kind:'hardware'}]};
    else if(name==='wallet/balance')value={spendable_sat:profile===a?111:profile===b?222:333};
    else if(name==='onchain/balance')value={confirmed_sat:0};
    else if(name==='submissions')value={version:1,pending:[],recent:[]};
    else if(name==='wallet/platform-node')value={available:false};
    else if(name==='hardware/request')value={confirmed_sat:444,pending_sat:0,transactions:[]};
    else if(url.pathname==='/api/ui-platform')value={platform};
    else value=[];
    return route.fulfill({json:value}).catch(()=>{});
   }
   const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
   await route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
  });
  const unlock=async target=>{await target.locator('#token').fill('synthetic');await target.getByRole('button',{name:'Unlock wallet',exact:true}).click();await target.locator('#wallet').waitFor({state:'visible'});};
  const balance=async value=>page.waitForFunction(v=>document.querySelector('#ark-balance').textContent===String(v),value);
  await page.goto('http://wallet.test/');await unlock(page);await balance(333);
  await page.waitForFunction(()=>document.querySelector('#wallet-select').options.length===4);
  await page.locator('#wallet-select').selectOption('hot:'+a);await balance(111);
  assert.equal(await page.evaluate(()=>PaperclipAccounts.hotProfileId),a);
  // Reload keeps this tab's selected hot wallet; another tab starts independently.
  await page.reload();await balance(111);
  const other=await context.newPage();await other.goto('http://wallet.test/');await unlock(other);
  assert.equal(await other.evaluate(()=>PaperclipAccounts.hotProfileId),'');
  await other.close();
  // A late old balance cannot overwrite the next wallet or cross its route.
  await page.evaluate(()=>PaperclipNavigation.show('onchain'));
  const transfer=page.locator('#chain-send .own-wallet-transfer');
  await transfer.getByRole('button',{name:'Move to my other wallet'}).click();
  await transfer.locator('select').selectOption('hot:'+b);
  await page.waitForFunction(()=>document.querySelector('#chain-destination').value==='synthetic-receiving-address');
  assert.equal(await page.evaluate(()=>PaperclipAccounts.hotProfileId),a,'Destination lookup must keep the sending wallet selected');
  assert(calls.some(c=>c.name==='/api/profiles/'+b+'/receive'&&c.body.network==='regtest'));
  await page.evaluate(()=>PaperclipNavigation.show('overview'));
  await page.waitForFunction(()=>updateInFlight===null);
  let release,arrived;const seen=new Promise(r=>arrived=r),wait=new Promise(r=>release=r);
  blocked={name:'wallet/balance',profile:a,arrived,wait};
  await page.evaluate(()=>{void update();});await Promise.race([seen,new Promise((_,reject)=>setTimeout(()=>reject(new Error('Expected balance read did not start')),10000))]);
  await page.evaluate(a=>sessionStorage.setItem('paperclip.submission.'+a,'d'.repeat(64)),a);
  await page.locator('#wallet-select').selectOption('hot:'+b);await balance(222);release();
  assert.equal(await page.evaluate(a=>sessionStorage.getItem('paperclip.submission.'+a),a),'d'.repeat(64));
  assert(!calls.some(c=>c.profile===b&&c.name==='submissions/check'&&c.body?.id==='d'.repeat(64)));
  await page.evaluate(a=>sessionStorage.removeItem('paperclip.submission.'+a),a);
  await page.waitForTimeout(100);assert.equal(await page.locator('#ark-balance').textContent(),'222');
  await page.waitForFunction(()=>document.querySelector('#wallet-select').options.length===4);
  await page.locator('#wallet-select').selectOption(cold);
  await page.waitForFunction(()=>PaperclipAccounts.selectedId==='c'.repeat(64));
  assert(calls.some(c=>c.profile===b&&c.name==='hardware/request'));
  // Jars remains the host's independent wallet even from a public account.
  await page.evaluate(()=>api('joinblaket/connection'));
  assert.equal(calls.at(-1).profile,'');
  // Adding a hot wallet opens entropy setup without creating keys or touching existing wallets.
  await page.locator('#wallet-select').selectOption('hot:'+b);await balance(222);
  await page.evaluate(()=>PaperclipNavigation.show('wallets'));
  await page.locator('#add-hot-wallet summary').click();await page.locator('#hot-wallet-name').fill('Travel');
  await page.locator('#hot-wallet-form button').click();await page.locator('#setup').waitFor({state:'visible'});
  assert(registered&&/^[a-f0-9]{64}$/.test(registered.id));
  assert.equal(await page.evaluate(()=>PaperclipAccounts.hotProfileId),registered.id);
  assert.equal(calls.filter(c=>/wallet\/create/.test(c.name)).length,0);
  await page.locator('#setup-back-wallets').click();await balance(333);
  // The per-wallet uncertainty warning never clears a different wallet's saved warning.
  await page.evaluate(a=>{sessionStorage.setItem('paperclip.uncertain.'+a,'1');submissionWarning(false);},a);
  assert.equal(await page.evaluate(a=>sessionStorage.getItem('paperclip.uncertain.'+a),a),'1');
  await page.locator('#wallet-select').selectOption('hot:'+a);await balance(111);
  missing=true;await page.reload();
  await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('unavailable'));
  assert(await page.locator('#wallet').isHidden());
  assert(await page.locator('#forget-selected-wallet').isVisible());
  await page.locator('#forget-selected-wallet').click();await unlock(page);await balance(333);
  assert.deepEqual(errors,[]);console.log('PASS profile switching, tab isolation, reload, stale response, public/Jars routing, entropy setup, uncertainty and missing-wallet rejection '+platform+'/'+width);
  await context.close();
 }}finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
