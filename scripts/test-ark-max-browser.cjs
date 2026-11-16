const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try{
  for(const width of [390,840,1280]){
   const page=await browser.newPage({viewport:{width,height:1000}}),calls=[],errors=[];
   page.on('pageerror',error=>errors.push(error.message));page.setDefaultTimeout(10000);
   let override={},wait=null,release,arrived,record=null;
   const quote={recipient_amount_sat:70000,recovery_reserve_sat:1000,service_fee_sat:0,total_debit_sat:71000,remaining_spendable_sat:400,input_count:2,send_max:true};
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/',''),body=route.request().postDataJSON();
    if(url.pathname.startsWith('/api/')){
     calls.push({name,body});
     if(name==='fees/ark/send'){assert.deepEqual(body,{destination:'synthetic-ark-address',send_max:true});if(wait){arrived();await wait;}return route.fulfill({json:{...quote,...override}});}
     if(name==='submissions'&&body){assert.deepEqual(body.body,{destination:'synthetic-ark-address',amount_sat:70000,max_total_sat:71000});assert.equal(body.operation,'wallet/send');record={id:body.id,operation:body.operation,state:'received',result:{state:'successful',movement_id:123}};return route.fulfill({json:record});}
     const value=name==='wallet'?{fingerprint:'fixture'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,submission_journal:1}:
      name==='submissions'?{version:1,pending:[],recent:[]}:name==='submissions/ack'?{...record,acknowledged:true}:name==='wallet/balance'?{spendable_sat:71400}:name==='onchain/balance'?{confirmed_sat:0}:name==='hardware/accounts'?{accounts:[]}:[];
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});
   await page.locator('[data-wallet="hot"] [data-view="transfer"]').first().click();await page.locator('#destination').fill('synthetic-ark-address');await page.locator('#ark-max').check();assert.equal(await page.locator('#amount').isEnabled(),false);
   const submit=page.getByRole('button',{name:'Review transfer',exact:true});
   await page.locator('#transfer-receive-choice').click();
   assert(await page.locator('#receive').isVisible());assert(!(await page.locator('#send').isVisible()));
   await page.locator('#transfer-send-choice').click();
   assert.equal(await page.locator('#destination').inputValue(),'synthetic-ark-address');
   assert(await page.locator('#ark-max').isChecked());
   const tabSeen=new Promise(resolve=>arrived=resolve);wait=new Promise(resolve=>release=resolve);
   await submit.click();await tabSeen;
   await page.locator('#transfer-receive-choice').click();await page.locator('#transfer-send-choice').click();
   release();wait=null;
   await page.getByText('Wallet or payment details changed. Review the transfer again.',{exact:true}).waitFor();
   assert(!calls.some(c=>c.name==='submissions'&&c.body));

   await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).waitFor();const text=await page.locator('.review-content').textContent();for(const term of ['Send Max','70,000','1,000','71,000','400','Recovery'])assert(text.includes(term));
   if(process.env.SCREENSHOT_DIR){fs.mkdirSync(process.env.SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.SCREENSHOT_DIR,`ark-max-review-${width}.png`),fullPage:true});}
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));await page.getByRole('button',{name:'Go back',exact:true}).click();assert(!calls.some(c=>c.name==='submissions'&&c.body));
   for(const value of [{send_max:false},{recipient_amount_sat:0},{total_debit_sat:70999},{recovery_reserve_sat:-1}]){override=value;await submit.click();await page.getByText('Invalid cost estimate. No payment was sent.',{exact:true}).waitFor();}
   override={};const seen=new Promise(resolve=>arrived=resolve);wait=new Promise(resolve=>release=resolve);await submit.click();await seen;await page.locator('#ark-max').uncheck();release();wait=null;
   await page.getByText('Wallet or payment details changed. Review the transfer again.',{exact:true}).waitFor();assert(!calls.some(c=>c.name==='submissions'&&c.body));
   await page.locator('#ark-max').check();await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).waitFor();await page.evaluate(()=>document.querySelector('#destination').value='changed');await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.getByText('Payment details changed. Review again.',{exact:true}).waitFor();
   assert(!calls.some(c=>c.name==='submissions'&&c.body));await page.locator('#destination').fill('synthetic-ark-address');await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).click();
   await page.locator('#transaction-result-title').filter({hasText:'Transfer completed'}).waitFor();assert.equal(calls.filter(c=>c.name==='submissions'&&c.body).length,1);assert.equal(await page.locator('#ark-max').isChecked(),false);assert.equal(await page.locator('#amount').isEnabled(),true);
   await page.locator('#transaction-result-done').click();await page.locator('#ark-max').check();await page.locator('#lock').click();assert.equal(await page.locator('#ark-max').isChecked(),false);assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS Ark Send Max: recovery reserve review, exact capped debit, cancel, changed-mode/destination rejection, malformed/old quotes, success/lock cleanup at three widths');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1});
