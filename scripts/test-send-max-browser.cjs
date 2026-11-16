const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const width of [390,840,1280]) {
   const page=await browser.newPage({viewport:{width,height:1000}}),errors=[],calls=[];
   page.on('pageerror',error=>errors.push(error.message));page.setDefaultTimeout(10000);
   let malformed=false,wait=null,release,arrived;
   const quote={request_id:'a'.repeat(64),destination:'synthetic-recipient',amount_sat:9900,fee_sat:100,total_sat:10000,send_max:true};
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/',''),body=route.request().postDataJSON();
    if(url.pathname.startsWith('/api/')) {
     calls.push({name,body});
     if(name==='onchain/send/prepare') {assert.deepEqual(body,{destination:quote.destination,send_max:true});if(wait){arrived();await wait;}return route.fulfill({json:{...quote,send_max:!malformed}});}
     if(name==='submissions'&&body) {assert.equal(body.operation,'onchain/send/commit');assert.deepEqual(body.body,{request_id:quote.request_id,total_sat:10000});return route.fulfill({status:503,json:{message:'Synthetic lost response'}});}
     assert.notEqual(name,'onchain/drain','Never use unreviewed drain');assert.notEqual(name,'onchain/send','Never use unreviewed send');
     const value=name==='wallet'?{fingerprint:'fixture'}:name==='wallet/identity'?{network:'regtest',exit_profile:2,submission_journal:1,lightning_enabled:false}:
      name==='submissions'?{version:1,pending:[],recent:[]}:name==='submissions/check'?{id:body.id,state:'unconfirmed'}:
      name==='wallet/balance'?{spendable_sat:0}:name==='onchain/balance'?{confirmed_sat:10000}:name==='hardware/accounts'?{accounts:[]}:[];
     return route.fulfill({json:value});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});
   await page.locator('.overview-note [data-view="onchain"]').click();await page.locator('#chain-destination').fill(quote.destination);await page.locator('#chain-max').check();assert.equal(await page.locator('#chain-amount').isEnabled(),false);
   const submit=page.getByRole('button',{name:'Review on-chain payment',exact:true});
   await submit.click();await page.locator('#review-title').waitFor({state:'visible'});
   const text=await page.locator('.review-content').textContent();for(const term of ['Send Max','9,900','100','10,000'])assert(text.includes(term));
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
   await page.getByRole('button',{name:'Go back',exact:true}).click();assert(!calls.some(c=>c.name==='submissions'&&c.body));
   malformed=true;await submit.click();await page.getByText('Could not verify the complete payment cost. No payment was sent.',{exact:true}).waitFor();malformed=false;
   let seen=new Promise(resolve=>arrived=resolve);wait=new Promise(resolve=>release=resolve);await submit.click();await seen;await page.locator('#chain-max').uncheck();release();wait=null;
   await page.getByText('Payment changed. Review again.',{exact:true}).waitFor();assert(!calls.some(c=>c.name==='submissions'&&c.body));
   await page.locator('#chain-max').check();await submit.click();await page.locator('#review-title').waitFor({state:'visible'});
   await page.evaluate(()=>document.querySelector('#chain-max').checked=false);await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.getByText('Payment changed. Review again.',{exact:true}).waitFor();assert(!calls.some(c=>c.name==='submissions'&&c.body));
   await page.locator('#chain-max').check();await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.locator('#transaction-result-title').filter({hasText:'Result not confirmed'}).waitFor();
   assert.equal(calls.filter(c=>c.name==='submissions'&&c.body).length,1);await page.locator('#transaction-result-done').click();
   await submit.click();await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.getByText(/A prior submission needs checking/).waitFor();assert.equal(calls.filter(c=>c.name==='submissions'&&c.body).length,1);
   await page.locator('#lock').click();assert.equal(await page.locator('#chain-max').isChecked(),false);assert.equal(await page.locator('#chain-amount').isEnabled(),true);assert.deepEqual(errors,[]);await page.close();
  }
  console.log('PASS Send Max: exact net/fee/total review, cancel, old-server refusal, mode-change races, uncertain result without replay, and lock cleanup at three widths');
 }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1});
