const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  const context=await browser.newContext(), records=new Map(), sends=[], errors=[];
  let outcome='unknown', acknowledgementGate=null;
  await context.route('http://localhost/**',async route=>{
   const url=new URL(route.request().url()), name=url.pathname.replace('/api/v1/','');
   if(url.pathname.startsWith('/api/')) {
    const body=route.request().method()==='POST'?route.request().postDataJSON():null;
    if(name==='submissions'&&body) {
     assert.equal(body.operation,'wallet/send');assert.match(body.id,/^[a-f0-9]{64}$/);
     assert(!records.has(body.id));sends.push(body);
     const record={id:body.id,operation:body.operation,state:outcome==='rejected'?'rejected':['pending','lost-reply'].includes(outcome)?'received':'unconfirmed',
      result:outcome==='rejected'?{message:'No payment was submitted. Review again.'}:{state:'pending',movement_id:42}};
     records.set(body.id,record);
     return ['unknown','lost-reply'].includes(outcome)?route.abort():route.fulfill({json:record});
    }
    if(name==='submissions')return route.fulfill({json:{version:1,pending:[...records.values()].filter(r=>r.state==='unconfirmed'||(!r.acknowledged&&r.state==='received')),recent:[...records.values()]}});
    if(name==='submissions/ack'){if(acknowledgementGate)await acknowledgementGate;records.get(body.id).acknowledged=true;return route.fulfill({json:{id:body.id,acknowledged:true}});}
    if(name==='submissions/check')return route.fulfill({json:records.get(body.id)||{id:body.id,state:'rejected',result:null}});
    assert.notEqual(name,'wallet/send','No legacy payment bypass');
    return route.fulfill({json:name==='wallet'?{fingerprint:'fixture'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,submission_journal:1}:name==='wallet/balance'?{spendable_sat:100000}:name==='onchain/balance'?{confirmed_sat:100000}:name==='fees/ark/send'?{recipient_amount_sat:body.amount_sat,recovery_reserve_sat:1000,service_fee_sat:0,total_debit_sat:body.amount_sat+1000,remaining_spendable_sat:98000,input_count:1}:[]});
   }
   const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
   return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
  });
  async function open() {
   const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));page.setDefaultTimeout(10000);
   await page.goto('http://localhost/');await page.locator('#token').fill('fixture-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();
   await page.locator('#wallet').waitFor({state:'visible'});await page.waitForFunction(()=>network==='regtest');return page;
  }
  async function send(page) {
   // Navigation identifiers may evolve; focus the form through its containing screen.
   await page.evaluate(()=>{const screen=document.getElementById('send').closest('[data-screen]');PaperclipNavigation.show(screen.dataset.screen);});
   await page.locator('#destination').fill('ark1-synthetic-recipient');await page.locator('#amount').fill('1000');
   await page.locator('#send button').click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
  }
  const first=await open();await send(first);
  await first.locator('#transaction-result-title').filter({hasText:'Result not confirmed'}).waitFor();assert.equal(sends.length,1);
  await first.close();
  const second=await open();await second.locator('#submission-warning').waitFor({state:'visible'});
  await second.locator('#submission-reviewed').click();await second.getByText('Still awaiting a confirmed result. Check again later; no payment was resent.',{exact:true}).waitFor();assert.equal(sends.length,1);
  records.get(sends[0].id).state='recorded';
  let releaseAcknowledgement;
  acknowledgementGate=new Promise(resolve=>{releaseAcknowledgement=resolve;});
  await second.locator('#submission-reviewed').click();await second.locator('#transaction-result-title').filter({hasText:'Submission found'}).waitFor();
  assert.equal(sends.length,1);
  assert(await second.locator('#submission-warning').isVisible(),'Showing the result must not unblock sending before acknowledgement');
  const guarded=await second.evaluate(async()=>{try{await mutate('wallet/send',{destination:'fixture',amount_sat:1});return false;}catch(error){return error.message.includes('prior submission');}});
  assert(guarded,'Recovery must remain fail-closed until the result acknowledgement is durable');
  releaseAcknowledgement();acknowledgementGate=null;
  await second.locator('#submission-warning').waitFor({state:'hidden'});
  assert(records.get(sends[0].id).acknowledged);
  await second.evaluate(()=>document.getElementById('transaction-result').close());
  outcome='pending';await send(second);await second.locator('#transaction-result-title').filter({hasText:'Check transfer status'}).waitFor();
  assert.equal(await second.locator('#transaction-result').getAttribute('data-kind'),'pending');assert.equal(sends.length,2);
  await second.evaluate(()=>document.getElementById('transaction-result').close());
  outcome='rejected';await send(second);await second.locator('#transaction-result-title').filter({hasText:'Request was not submitted'}).waitFor();
  assert(await second.locator('#submission-warning').isHidden());assert.equal(sends.length,3);
  assert.equal(new Set(sends.map(s=>s.id)).size,3);
  await second.evaluate(()=>document.getElementById('transaction-result').close());
  outcome='lost-reply';await send(second);await second.locator('#transaction-result-title').filter({hasText:'Result not confirmed'}).waitFor();await second.close();
  const third=await open();await third.locator('#transaction-result-title').filter({hasText:'Submission found'}).waitFor();
  await third.waitForFunction(()=>document.getElementById('submission-warning').hidden);assert.equal(sends.length,4);
  assert(records.get(sends[3].id).acknowledged,'A delivered server result must be recovered even without the original tab');
  const refused=await third.evaluate(async()=>{submissionJournal=false;try{await mutate('wallet/send',{destination:'fixture',amount_sat:1});return false;}catch(error){return error.message.includes('Update the wallet server');}});
  assert(refused,'An older server must not allow a legacy payment bypass');assert.equal(sends.length,4);assert.deepEqual(errors,[]);
  await context.close();console.log('Durable browser recovery: new tab, read-only check, pending outcome and rejected request passed.');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
