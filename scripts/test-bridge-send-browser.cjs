const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'playwright');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_CHANNEL?{channel:process.env.BROWSER_CHANNEL}:{})});
 try {
  for(const [width,platform,implementation] of [[390,'startos','lnd'],[840,'umbrel','cln'],[1280,'startos','cln'],[1280,'umbrel','lnd']]) {
   const page=await browser.newPage({viewport:{width,height:1000}}),errors=[],calls=[];page.on('pageerror',e=>errors.push(e.message));page.setDefaultTimeout(10000);
   const node='02'+'01'.repeat(32),hash='02'.repeat(32),invoice='lnbc1syntheticbtcinvoice',hold='lnbc1syntheticxbtinvoice';
   let records=[],mode='unknown',malformed=false,delay=false,release=null,availability='live';
   const quote=()=>({direction:'toSHA256',hash,target_invoice:invoice,target_msat:'100000',hold_invoice:hold,funding_msat:'200001',pay_sat:201,rate:2,spread:0.01,expires_at:Math.floor(Date.now()/1000)+600,created:Math.floor(Date.now()/1000),state:'offered',verified_settlement:false,bridge_settled:false,receive_node_id:null,funding:null});
   await page.route('http://wallet.test/**',async route=>{
    const url=new URL(route.request().url()),name=url.pathname.replace('/api/v1/','');
    if(url.pathname.startsWith('/api/')) {
     let data=[];const body=route.request().postDataJSON();
     if(name==='remote-node/connection')data={configured:true,node_id:node,implementation,endpoint:'https://node.local',receive_only:false,payments:[]};
     else if(name==='bridge/info'){data={direction:url.searchParams.get('direction'),open:availability==='malformed'?'true':availability==='live'};}
     else if(name==='bridge/quotes'){
      if(body){assert.equal(body.direction,'toSHA256');assert.equal(body.invoice,invoice);records=[quote()];data=records[0];calls.push({name,body});}
      else data={quotes:records};
     } else if(name==='bridge/prepare-funding'){
      calls.push({name,body});assert.equal(body.hash,hash);assert.equal(body.maximum_fee_sat,10);
      if(delay)await new Promise(resolve=>release=resolve);
      data={quote:records[0],review:{request_id:'03'.repeat(32),payment_hash:hash,node_id:node,amount_msat:malformed?'200002':'200001',maximum_fee_sat:10,maximum_total_msat:'210001'}};
     } else if(name==='bridge/fund'){
      calls.push({name,body});assert.equal(body.hash,hash);assert.equal(body.maximum_fee_sat,10);assert.equal(body.request_id,'03'.repeat(32));
      records=[{...records[0],funding:{node_id:node,maximum_fee_sat:10,state:'unknown'}}];
      return route.fulfill({status:503,json:{message:'Response lost'}});
     } else if(name==='bridge/check'){
      calls.push({name,body});assert.equal(body.hash,hash);assert.equal(body.direction,'toSHA256');
      records=[{...records[0],funding:{node_id:node,maximum_fee_sat:10,state:mode==='settled'?'succeeded':mode},verified_settlement:mode==='settled',bridge_settled:mode==='settled',funding_checked:true,bridge_checked:true}];data=records[0];
     } else if(url.pathname==='/api/ui-platform')data={platform};
     else if(name==='wallet')data={fingerprint:'fixture'};
     else if(name==='wallet/identity')data={network:'bitcoin',exit_profile:2,lightning_enabled:false};
     else if(name==='hardware/accounts')data={accounts:[]};
     else if(name==='wallet/balance')data={spendable_sat:0};
     else if(name==='onchain/balance')data={confirmed_sat:0};
     else if(body)throw new Error('Unexpected mutation '+name);
     return route.fulfill({json:data});
    }
    const file=path.join(__dirname,'../web',url.pathname==='/'?'index.html':url.pathname.slice(1));
    return route.fulfill({body:fs.readFileSync(file),contentType:file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.html')?'text/html':'image/svg+xml'});
   });
   async function entry(){await page.locator('.view-nav [data-view=lightning]').click();await page.locator('[data-screen=lightning] [data-view=bridge-send]').click();await page.locator('#bridge-pay-create').waitFor({state:'visible'});}
   async function create(){await entry();await page.locator('#bridge-pay-invoice').fill(invoice);await page.locator('#bridge-pay-create button').click();await page.locator('#bridge-pay-approve').waitFor({state:'visible'});}
   const sends=()=>calls.filter(c=>c.name==='bridge/fund').length;
   await page.clock.install();await page.goto('http://wallet.test/');await page.locator('#token').fill('fixture-token');await page.getByRole('button',{name:'Unlock wallet',exact:true}).click();await page.locator('#wallet').waitFor({state:'visible'});
   await create();assert.equal(sends(),0);assert.equal(await page.locator('[data-screen=bridge]').isVisible(),false);
   assert.equal(await page.locator('#bridge-pay-target').textContent(),'100 BTC sats');assert.equal(await page.locator('#bridge-pay-funding').textContent(),'200.001 XBT sats');
   await page.locator('[data-screen=bridge-send] [data-bridge-health]').filter({hasText:'Live'}).waitFor();
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
   if(process.env.PAPERCLIP_SCREENSHOT_DIR){fs.mkdirSync(process.env.PAPERCLIP_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:path.join(process.env.PAPERCLIP_SCREENSHOT_DIR,`bridge-send-${platform}-${width}.png`),fullPage:true});}
   malformed=true;await page.locator('#bridge-pay-approve button').click();await page.locator('#bridge-pay-status').filter({hasText:'review changed'}).waitFor();assert.equal(sends(),0);malformed=false;
   // Closing the sheet does not fund, and expiry while reviewing is checked again.
   await page.locator('#bridge-pay-approve button').click();await page.locator('.review-sheet[open]').waitFor();assert.match(await page.locator('.review-content').textContent(),/Maximum total: 210.001 XBT sats/);
   await page.getByRole('button',{name:'Go back',exact:true}).click();assert.equal(sends(),0);
   await page.locator('#bridge-pay-approve button').click();await page.locator('.review-sheet[open]').waitFor();await page.clock.fastForward(601000);await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.locator('#bridge-pay-status').filter({hasText:'expired while'}).waitFor();assert.equal(sends(),0);
   await page.clock.setSystemTime(new Date());await create();await page.locator('#bridge-pay-approve button').click();await page.locator('.review-sheet[open]').waitFor();await page.getByRole('button',{name:'Confirm',exact:true}).click();await page.locator('#bridge-pay-status').filter({hasText:'uncertain'}).waitFor();assert.equal(sends(),1);assert.equal(await page.locator('#bridge-pay-approve').isVisible(),false);
   // Restart retains the uncertain request, and funding success is not BTC settlement.
   await page.reload();await page.locator('#wallet').waitFor({state:'visible'});await entry();await page.locator('[data-view=bridge-send-activity]').click();await page.locator('#bridge-pay-records button').click();assert.equal(await page.locator('#bridge-pay-approve').isVisible(),false);
   mode='succeeded';await page.locator('#bridge-pay-check').click();await page.locator('#bridge-pay-result').filter({hasText:'Node funded'}).waitFor();assert.equal(await page.locator('#bridge-pay-title').textContent(),'Your conversion');assert.equal(sends(),1);
   mode='settled';await page.locator('#bridge-pay-check').click();await page.locator('#bridge-pay-title').filter({hasText:'BTC payment settled'}).waitFor();assert.equal(sends(),1);
   // Availability for this direction expires without presenting it as settlement.
   availability='malformed';await page.clock.fastForward(91000);await page.locator('[data-screen=bridge-send] [data-bridge-health]').filter({hasText:'Status unknown'}).waitFor();assert.equal(await page.locator('#bridge-pay-title').textContent(),'BTC payment settled');
   // A delayed prepare cannot restore approval after navigation away and back.
   delay=true;release=null;await create();await page.locator('#bridge-pay-approve button').click();
   for(let i=0;i<100&&!release;i++)await page.waitForTimeout(10);assert(release);
   await page.locator('#bridge-pay-back').click();release();await page.waitForTimeout(100);assert.equal(await page.locator('.review-sheet[open]').count(),0);assert.equal(sends(),1);
   delay=false;await page.locator('[data-view=bridge-send-activity]').click();await page.locator('#bridge-pay-records button').click();
   delay=true;release=null;await page.locator('#bridge-pay-approve button').click();for(let i=0;i<100&&!release;i++)await page.waitForTimeout(10);assert(release);
   await page.locator('#lock').click();release();await page.waitForTimeout(100);
   for(const id of ['bridge-pay-target','bridge-pay-reference','bridge-pay-source'])assert.equal(await page.locator('#'+id).textContent(),'');
   assert.equal(await page.locator('#bridge-pay-invoice').inputValue(),'');assert.equal(await page.locator('.review-sheet[open]').count(),0);assert.equal(sends(),1);assert.deepEqual(errors,[]);
   await page.close();console.log(`outgoing Bridge ${platform}/${implementation} ${width}: pass`);
  }
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});
