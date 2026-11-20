const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const signer=JSON.parse(fs.readFileSync(path.join(__dirname,'../mobile/Tests/PaperclipMobileTests/Fixtures/krux.json')))[0];
const cold='a'.repeat(64);
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 const failures=[];
 async function scenario(name,test,{width=1000,platform="startos"}={}){
  const page=await browser.newPage({viewport:{width,height:1000}}),calls=[],errors=[];
  page.setDefaultTimeout(10000);
  let blocker=null;const receipts=new Map();
  const hold=match=>{let release,arrived;const wait=new Promise(r=>release=r),seen=new Promise(r=>arrived=r);blocker={match,wait,arrived};return{release,seen};};
  page.on('pageerror',error=>errors.push(error.message));
  await page.route('http://wallet.test/**',async route=>{
   const url=new URL(route.request().url());let name=url.pathname.replace('/api/v1/','');
   if(url.pathname.startsWith('/api/')){
    let body=route.request().postDataJSON(),envelope=null;
    if(name==='submissions'&&!body)return route.fulfill({json:{version:1,pending:[...receipts.values()].filter(r=>r.state==='unconfirmed'),recent:[...receipts.values()]}});
    if(name==='submissions/ack')return route.fulfill({json:{id:body.id,acknowledged:true}});
    if(name==='submissions/check')return route.fulfill({json:receipts.get(body.id)||{id:body.id,state:'rejected'}});
    if(name==='submissions'){envelope=body;name=body.operation;body=body.body;receipts.set(envelope.id,{id:envelope.id,operation:name,state:'unconfirmed'});}
    calls.push({name,body});
    if(blocker?.match(name,body)){const blocked=blocker;blocker=null;blocked.arrived();await blocked.wait;}
    const value=url.pathname==='/api/ui-platform'?{platform}:name==='wallet'?{fingerprint:'synthetic'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,submission_journal:1,lightning_enabled:true,lightning_debit_limit:true}:
     name==='hardware/accounts'?{accounts:[{id:cold,label:'Savings signer',kind:'hardware'}]}:
     name==='wallet/balance'?{spendable_sat:12345}:name==='onchain/balance'?{confirmed_sat:6789}:
     name==='fees/lightning/review'?{net_amount_sat:1000,fee_sat:10,gross_amount_sat:1010}:
     name==='lightning/receives/invoice'?{invoice:'ln-test-'+body.amount_sat}:
     name==='onchain/send/prepare'?{...body,request_id:'d'.repeat(64),fee_sat:100,total_sat:body.amount_sat+100}:
     name==='onchain/send/commit'?{txid:'b'.repeat(64),state:'submitted'}:
     name==='history'?[{id:'fresh-record',status:'successful',effective_balance_sat:123,subsystem:{name:'bark.arkoor',kind:'send'},time:{created_at:'2026-11-15T12:00:00Z'},offchain_fee_sat:0}]:
     name==='hardware/request'?(body.operation==='refresh'?{confirmed_sat:22222,pending_sat:0,transactions:[]}:
      body.operation==='address'?{address:signer.receive_address}:
      body.operation==='prepare'?{account:cold,request_id:'c'.repeat(64),destination:body.destination,amount_sat:70000,fee_sat:1000,total_sat:71000,psbt:signer.original}:
      body.operation==='verify'?{verified:true,fee_sat:1000,txid:'d'.repeat(64)}:
      body.operation==='broadcast'?{state:'submitted',txid:'d'.repeat(64)}:{}):[];
    if(envelope){const receipt={id:envelope.id,operation:name,state:'received',result:value};receipts.set(envelope.id,receipt);return route.fulfill({json:receipt}).catch(()=>{});}
    return route.fulfill({json:value}).catch(()=>{});
   }
   const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
   return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
  });
  const unlock=async()=>{await page.locator('#token').fill('synthetic-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});};
  const select=async id=>{await page.waitForFunction(()=>document.querySelector('#wallet-select').options.length===2);await page.locator('#wallet-select').selectOption(id);await page.waitForFunction(id=>PaperclipAccounts.selectedId===id,id);};
  const settled=async()=>{await page.waitForFunction(()=>walletMutations===0&&window.testRequests===0);await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));};
  try{await page.goto('http://wallet.test/');await unlock();await page.evaluate(()=>{window.testRequests=0;const request=PaperclipTransport.request;PaperclipTransport.request=async(...args)=>{window.testRequests++;try{return await request(...args);}finally{window.testRequests--;}};});await test({page,calls,hold,unlock,select,settled});assert.deepEqual(errors,[]);console.log('PASS '+name);}
  catch(error){failures.push(name+': '+error.message);console.error('FAIL '+name+': '+error.message);}
  finally{await page.close();}
 }
 try{
  await scenario('Ark quote cannot reopen review after switching Lightning tasks',async({page,hold,settled,calls})=>{
   await page.locator('.view-nav [data-view=lightning]').click();
   await page.locator('[data-screen=lightning] [data-view=ark-lightning]').click();
   await page.locator('#ln-destination').fill('synthetic-xbt-invoice');
   const delayed=hold(name=>name==='fees/lightning/review');
   await page.locator('#ln-pay button').click();await delayed.seen;
   await page.locator('.task-switch [data-view=ark-lightning-receive]').click();
   await page.locator('.task-switch [data-view=ark-lightning]').click();
   delayed.release();await settled();
   assert.equal(await page.locator('.review-sheet[open]').count(),0,'Returning to the same form does not restore approval');
   assert.equal(calls.filter(call=>call.name==='lightning/pay').length,0);
   await page.locator('#ln-pay button').click();
   await page.getByRole('button',{name:'Go back',exact:true}).click();await settled();
   assert.equal(calls.filter(call=>call.name==='lightning/pay').length,0,'Fresh review can be cancelled');
  });
  for(const [width,platform] of [[390,'startos'],[1280,'umbrel']]) {
   await scenario('receive draft edits invalidate QR '+platform+'/'+width,async({page,hold,settled,calls})=>{
    await page.locator('.view-nav [data-view="lightning"]').click();
    await page.locator('[data-screen=lightning] [data-view=ark-lightning-receive]').click();
    await page.locator('#ln-receive-amount').fill('1000');
    await page.locator('#ln-description').fill('First request');
    const delayed=hold(name=>name==='lightning/receives/invoice');
    await page.locator('#ln-receive button').click();await delayed.seen;
    await page.locator('#ln-receive-amount').fill('2000');
    delayed.release();await settled();
    assert.equal(await page.locator('#ln-invoice').textContent(),'','Old invoice must not be shown beside the edited amount');
    assert.equal(await page.locator('.receive-card').count(),0);
    assert.match(await page.locator('#status').textContent(),/details changed/i);
    assert.equal(calls.filter(call=>call.name==='lightning/receives/invoice').length,1,'Editing must not automatically create another invoice');
    await page.locator('#ln-receive button').click();await settled();
    assert.equal(await page.locator('#ln-invoice').textContent(),'ln-test-2000');
    assert.equal(await page.locator('.receive-card').count(),1);
    assert.match(await page.locator('.receive-caption').textContent(),/2,000 sats/);
    assert.equal(await page.locator('#payment-summary').isVisible(),true);
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'Receive page must fit its viewport');
    if(process.env.PAPERCLIP_SCREENSHOT_DIR){fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true});await page.locator("#ln-receive").locator("..").screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,`receive-${platform}-${width}.png`)});}
    await page.locator('#ln-description').fill('Changed request');
    assert.equal(await page.locator('#ln-invoice').textContent(),'','Editing a shown invoice must clear its shareable request');
    assert.equal(await page.locator('.receive-card').count(),0);
    assert.equal(await page.locator('#payment-summary').isVisible(),false,'Old share guidance must clear with the QR');
    assert.equal(await page.locator('#ln-identifier').inputValue(),'ln-test-2000','The original invoice must remain available for status checks');
    await page.locator('#ln-receive button').click();await settled();
    assert.equal(await page.locator('.receive-card').count(),1);
    assert.equal(calls.filter(call=>call.name==='lightning/receives/invoice').length,3);
    await page.evaluate(()=>paymentSummary('Observed payment', 'Keep this separate status visible.'));
    await page.locator('#ln-receive-amount').fill('3000');
    assert.match(await page.locator('#payment-summary').textContent(),/Keep this separate status visible/);
    assert.equal(await page.locator('#payment-summary').isVisible(),true);
   },{width,platform});
  }
  await scenario('late manual refresh cannot overwrite the locked status',async({page,hold,settled})=>{
   const delayed=hold(name=>name==='wallet/balance');
   await page.locator('#reload').click();await delayed.seen;
   await page.locator('#lock').click();delayed.release();await settled();
   assert.equal(await page.locator('#status').textContent(),'Wallet locked.');
   assert.equal(await page.locator('#wallet').isVisible(),false);
  });
  await scenario('restore cold selection during an old address request',async({page,hold,select,unlock,settled})=>{
   await select(cold);const delayed=hold((name,body)=>name==='hardware/request'&&body.operation==='address');
   await page.locator('#cold-receive').click();await delayed.seen;
   await page.locator('#lock').click();await unlock();
   const selected=await page.locator('#wallet-select').inputValue();delayed.release();await settled();
   assert.equal(selected,cold,'Unlock must not silently fall back to the hot wallet');
   assert.equal(await page.locator('#cold-address').textContent(),'','Old receive response must not populate the new session');
  });
  await scenario('late hot-send response cannot reopen a receipt after relock',async({page,hold,unlock,settled,calls})=>{
   await page.locator('.overview-note [data-view="onchain"]').click();
   await page.locator('#chain-destination').fill(signer.receive_address);await page.locator('#chain-amount').fill('1000');
   const delayed=hold(name=>name==='onchain/send/commit');
   await page.getByRole('button',{name:'Review on-chain payment',exact:true}).click();await page.getByRole('button',{name:'Confirm',exact:true}).click();await delayed.seen;
   await page.locator('#lock').click();await unlock();
   // Finish the new login's independent journal recovery while the old request
   // is still held. Releasing it earlier legitimately lets that recovery find
   // the result; it would no longer test an obsolete response updating the UI.
   await page.waitForFunction(()=>window.testRequests===1&&!document.querySelector('#unlock button').disabled&&!document.querySelector('#submission-warning').hidden);
   delayed.release();await settled();
   assert.equal(await page.locator('#transaction-result').isVisible(),false,'Old request must not show a receipt in a new login');
   assert.equal(calls.filter(call=>call.name==='onchain/send/commit').length,1,'Never replay the payment');
   assert.equal(await page.locator('#submission-warning').isVisible(),true,'Unknown outcome must remain visible');
  });
  await scenario('old activity response cannot clear a newer wallet view',async({page,hold,select,settled})=>{
   const delayed=hold(name=>name==='history');
   await page.locator('.view-nav [data-view="activity"]').click();await delayed.seen;
   await select(cold);await select('');
   await page.locator('.view-nav [data-view="activity"]').click();
   await page.waitForFunction(()=>document.querySelector('#activity-list').textContent.includes('fresh-record'));
   delayed.release();
   await settled();
   assert.match(await page.locator('#activity-list').textContent(),/fresh-record/,'Late history must not erase current records');
  });
  async function reviewedSigner(page,select){
   await select(cold);await page.getByRole('button',{name:'↗ Send',exact:true}).click();
   await page.locator('#cold-destination').fill(signer.receive_address);await page.locator('#cold-amount').fill('70000');
   await page.getByRole('button',{name:'Review signing request',exact:true}).click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#signing-request').waitFor({state:'visible'});
  }
  const signedFile={name:'signed.psbt',mimeType:'application/octet-stream',buffer:Buffer.from(signer.signed,'base64')};
  await scenario('failed signature verification stays visible and allows a new import',async({page,select,settled})=>{
   await reviewedSigner(page,select);let reject=true;
   await page.route('http://wallet.test/api/v1/hardware/request',route=>{
    if(reject&&route.request().postDataJSON()?.operation==='verify'){reject=false;return route.fulfill({status:400,json:{message:'Signature does not match the reviewed transaction.'}});}
    return route.fallback();
   });
   await page.locator('#signed-file').setInputFiles(signedFile);
   await page.waitForFunction(()=>document.querySelector('#signing-status').textContent.includes('Signature does not match'));
   assert.equal(await page.locator('#signed-broadcast').isEnabled(),false);
   await page.locator('#signed-file').setInputFiles(signedFile);await settled();
   await page.waitForFunction(()=>!document.querySelector('#signed-broadcast').disabled);
   assert.equal(await page.locator('#signing-status').textContent(),'');
  });
  await scenario('cancelled file import cannot enter a new signing request',async({page,select,settled,calls})=>{
   await reviewedSigner(page,select);
   await page.evaluate(()=>{
    const read=File.prototype.arrayBuffer;
    File.prototype.arrayBuffer=async function(){window.fileReadStarted=true;await new Promise(resolve=>window.finishFileRead=resolve);return read.call(this);};
   });
   await page.locator('#signed-file').setInputFiles(signedFile);await page.waitForFunction(()=>window.fileReadStarted);
   await page.locator('#signing-cancel').click();await page.evaluate(()=>window.finishFileRead());
   await page.waitForFunction(()=>!document.querySelector('#cold-amount').disabled);await settled();
   assert.equal(await page.locator('#signing-status').textContent(),'','Cancelled file import must not update the new form');
   assert.equal(calls.filter(call=>call.body?.operation==='verify').length,0);
  });
  await scenario('camera verification failure remains visible after the scanner closes',async({page,select})=>{
   await reviewedSigner(page,select);
   await page.route('http://wallet.test/api/v1/hardware/request',route=>route.request().postDataJSON()?.operation==='verify'
    ?route.fulfill({status:400,json:{message:'Signature does not match the reviewed transaction.'}}):route.fallback());
   await page.evaluate(signed=>{
    Object.defineProperty(navigator,'mediaDevices',{configurable:true,value:{getUserMedia:async()=>document.createElement('canvas').captureStream()}});
    HTMLMediaElement.prototype.play=async()=>{};
    const video=document.querySelector('#scanner-video');
    for(const [key,value] of Object.entries({readyState:2,videoWidth:32,videoHeight:32}))Object.defineProperty(video,key,{get:()=>value});
    CanvasRenderingContext2D.prototype.drawImage=()=>{};
    let consumed=false;PaperclipQRVendor={...PaperclipQRVendor,jsQR:()=>{if(consumed)return null;consumed=true;return{data:signed};}};
   },signer.signed);
   await page.locator('#signed-scan').click();
   await page.waitForFunction(()=>document.querySelector('#signing-status').textContent.includes('Signature does not match')).catch(async error=>{throw Error(error.message+' '+JSON.stringify(await page.evaluate(()=>({scanner:document.querySelector('#scanner-progress').textContent,signing:document.querySelector('#signing-status').textContent,progress:document.querySelector('#signing-progress').textContent}))))});
   assert.equal(await page.locator('#qr-scanner').isVisible(),false);
   assert.equal(await page.locator('#signed-broadcast').isEnabled(),false);
  });
  await scenario('cancelled signature verification cannot revive a request',async({page,hold,select,settled})=>{
   await reviewedSigner(page,select);const delayed=hold((name,body)=>name==='hardware/request'&&body.operation==='verify');
   await page.locator('#signed-file').setInputFiles(signedFile);await delayed.seen;
   await page.locator('#signing-cancel').click();delayed.release();await settled();
   assert.equal(await page.locator('#signed-broadcast').isEnabled(),false);
   assert.equal(await page.locator('#signing-status').textContent(),'','Cancelled verification must not report an error in the new form');
  });
  await scenario('late QR broadcast cannot navigate the next session',async({page,hold,select,unlock,settled,calls})=>{
   await reviewedSigner(page,select);await page.locator('#signed-file').setInputFiles(signedFile);
   await page.waitForFunction(()=>!document.querySelector('#signed-broadcast').disabled);
   const delayed=hold((name,body)=>name==='hardware/request'&&body.operation==='broadcast');
   await page.locator('#signed-broadcast').click();await page.getByRole('button',{name:'Confirm',exact:true}).click();await delayed.seen;
   await page.locator('#lock').click();await unlock();await page.locator('.view-nav [data-view="activity"]').click();
   delayed.release();await settled();
   assert.equal(await page.locator('.view-nav [data-view="activity"]').getAttribute('aria-current'),'page','Old broadcast must not navigate the current session');
   assert.equal(calls.filter(call=>call.body?.operation==='broadcast').length,1);
  });
  await scenario('an old camera permission response cannot replace a reopened scanner',async({page})=>{
   await page.evaluate(()=>{
    window.cameraRequests=[];
    Object.defineProperty(navigator,'mediaDevices',{configurable:true,value:{getUserMedia:()=>new Promise(resolve=>window.cameraRequests.push(resolve))}});
    HTMLMediaElement.prototype.play=async()=>{};
    window.testStreams=[document.createElement('canvas').captureStream(),document.createElement('canvas').captureStream()];
   });
   await page.locator('.wallet-switch [data-view="wallets"]').click();await page.locator('#pair-wallet').evaluate(element=>element.open=true);
   await page.locator('#pair-scan').click();await page.waitForFunction(()=>window.cameraRequests.length===1);
   await page.locator('#scanner-close').click();await page.locator('#pair-scan').click();await page.waitForFunction(()=>window.cameraRequests.length===2);
   await page.evaluate(()=>window.cameraRequests[1](window.testStreams[1]));
   await page.waitForFunction(()=>document.querySelector('#scanner-video').srcObject===window.testStreams[1]);
   await page.evaluate(()=>window.cameraRequests[0](window.testStreams[0]));
   await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
   assert.equal(await page.evaluate(()=>document.querySelector('#scanner-video').srcObject===window.testStreams[1]),true,'Old permission response must not replace the active camera');
   assert.equal(await page.evaluate(()=>window.testStreams[0].getTracks().every(track=>track.readyState==='ended')),true,'Discarded camera tracks must stop');
   await page.locator('#scanner-close').click();
   assert.equal(await page.evaluate(()=>window.testStreams[1].getTracks().every(track=>track.readyState==='ended')),true);
  });
 }finally{await browser.close();}
 if(failures.length)throw Error(failures.join('\n'));
})().catch(error=>{console.error(error.message);process.exitCode=1});
