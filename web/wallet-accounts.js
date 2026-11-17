'use strict';
(() => {
  let hotProfiles=[], hotId='', profilesSupported=false, registering=null;
  let accounts=[], selected=null, generation=0, busy=false, pending=null, signed=null, history=[], lastRelay=null, paired=null, renaming=null, removing=null;
  let collector=new PaperclipSigningQR.Collector(), qrFrames=[], frame=0, paused=false, stream=null, scanning=false, scanPublic=false, cameraGeneration=0;
  const dialog=$('qr-scanner'), video=$('scanner-video'), canvas=document.createElement('canvas'), context=canvas.getContext('2d',{willReadFrequently:true});
  const sats=value=>Number.isSafeInteger(value)?value.toLocaleString()+' sats':'Unavailable';
  function controls() {
    $('wallet-select').disabled=busy||walletMutations>0;
    document.querySelectorAll('#paired-wallets button, [data-hot-wallet]').forEach(button=>button.disabled=busy||walletMutations>0);
    for(const id of ['hot-wallet-form','pair-form','cold-send','wallet-rename-form','wallet-remove-form']) $(id).querySelectorAll('button,input,textarea,select').forEach(control=>control.disabled=busy);
    $('cold-amount').disabled=busy||$('cold-max').checked;$('cold-amount').required=!$('cold-max').checked;
    $('signed-broadcast').disabled=busy||!signed;
    $('cold-send').hidden=!!pending||selected?.kind==='watch';
    document.querySelectorAll('[data-wallet="hardware"] [data-view="signing"]').forEach(button=>button.hidden=selected?.kind==='watch');
    $('watch-only-notice').hidden=selected?.kind!=='watch';
    $('wallet-remove-confirm').disabled=busy||!removing||$('wallet-remove-name').value!=='REMOVE '+removing.label||!$('wallet-remove-backup').checked;
    $('signing-request').hidden=!pending;
  }
  async function call(operation, fields={}) {return api('hardware/request',{operation,account:selected?.id||'',...fields});}
  async function work(output, action) {
    if(busy)return;busy=true;controls();$(output).textContent='Working…';const ticket=generation,session=token;
    try {await action();if(ticket===generation&&token===session&&$(output).textContent==='Working…')$(output).textContent='';}
    catch(error){if(ticket===generation&&token===session)$(output).textContent=error.message;}
    finally{busy=false;controls();}
  }
  function stopCamera() {cameraGeneration++;scanning=false;if(stream)stream.getTracks().forEach(track=>track.stop());stream=null;video.srcObject=null;if(dialog.open)dialog.close();}
  function clearSigning() {
    pending=null;signed=null;qrFrames=[];frame=0;collector=new PaperclipSigningQR.Collector();
    $('signing-qr').replaceChildren();$('signed-text').value='';$('signing-review').textContent='';$('signing-status').textContent='';$('signing-progress').textContent='';
    $('cold-send').reset();stopCamera();controls();
  }
  function cancelRequest() {
    const old=selected?.id;
    if(old&&pending&&token)void api('hardware/request',{operation:'cancel',account:old}).catch(()=>{});
    clearSigning();
  }
  function clearWalletView() {
    resetWalletControls();PaperclipActivity.reset();PaperclipReview.cancel();PaperclipReceive.clear();$('transaction-result').close();$('wallet-rename').close();renaming=null;$('wallet-rename-form').reset();
    $('wallet-remove').close();removing=null;$('wallet-remove-form').reset();
    for(const id of ['cold-address','cold-relay','cold-history','cold-history-status','activity-list','history','ln-result','ln-invoice','ln-offer-output','address','deposit-address']) $(id)?.replaceChildren();
    for(const id of ['destination','amount','ln-destination','ln-amount','chain-destination','chain-amount','ln-identifier']) if($(id))$(id).value='';
    $('chain-max').checked=false;$('chain-max').onchange();
    $('ark-max').checked=false;$('ark-max').onchange();
    $('cold-balance').textContent='Loading…';$('cold-pending').textContent='Loading…';history=[];lastRelay=null;
  }
  async function choose(id) {
    if(busy||walletMutations>0)return;
    try { if(id.startsWith('hot:'))await selectHot(id.slice(4));else if(!id&&hotId)await selectHot('');else await selectAccount(id); }
    catch(error){status(error.message);showIdentity();}
  }
  async function selectAccount(id) {
    const next=accounts.find(account=>account.id===id)||null;if(id&&!next)throw new Error('Select a saved wallet.');
    cancelRequest();generation++;selected=next;clearWalletView();
    sessionWrite('paperclip.selected-qr', selected?.id || null);
    showIdentity();
    $('wallet-readiness').hidden=true;status('');PaperclipNavigation.show('overview');renderAccounts();
    if($('wallet').hidden)return;
    if(selected){const ticket=generation;void refresh().catch(error=>{if(ticket===generation)$('cold-relay').textContent=error.message;});}else { if (submissionJournal) void syncSubmissions().catch(error=>status(error.message)); void update(); }
  }
  async function loadHot() {
    const session=token;
    let result;
    try {result=await api('/api/profiles');}
    catch(error){if(error.status!==404)throw error;result=null;}
    if(token!==session||!session)throw new Error('Session changed. Unlock again.');
    profilesSupported=result?.version===1&&Array.isArray(result.profiles);
    if(profilesSupported&&result.profiles.some(p=>!/^[0-9a-f]{64}$/.test(p.id)||typeof p.label!=='string'))throw new Error('Could not load hot wallets.');
    hotProfiles=profilesSupported?result.profiles:[];
    $('add-hot-wallet').hidden=!profilesSupported;
  }
  async function restoreHot() {
    const id=sessionRead('paperclip.selected-hot')||'';
    await loadHot();
    if(id&&!hotProfiles.some(p=>p.id===id)){
      $('forget-selected-wallet').hidden=false;
      throw new Error('Your selected hot wallet is unavailable. Retry, or explicitly choose the main wallet.');
    }
    hotId=id;selected=null;showIdentity();
  }
  async function selectHot(id) {
    if(id&&!hotProfiles.some(p=>p.id===id))throw new Error('Select a saved hot wallet.');
    cancelRequest();generation++;selected=null;clearWalletView();
    sessionWrite('paperclip.selected-qr',null);sessionWrite('paperclip.selected-hot',id||null);
    // Hiding the old wallet clears node, Bridge and QR drafts before the new identity loads.
    $('wallet').hidden=true;await Promise.resolve();hotId=id;generation++;
    network=null;submissionJournal=false;lightningEnabled=false;lightningDebitLimit=false;
    $('ark-balance').textContent='Loading…';$('chain-balance').textContent='Loading…';
    try {await unlockWallet(token);PaperclipNavigation.show('overview');renderAccounts();}
    catch(error){$('login').hidden=false;status(error.message);throw error;}
  }
  $('hot-wallet-form').onsubmit=event=>{event.preventDefault();void work('wallet-account-status',async()=>{
    const label=$('hot-wallet-name').value.trim();if(!label)throw new Error('Enter a wallet name.');
    // Preserve the request ID after a lost response; registration never creates keys.
    if(!registering||registering.label!==label)registering={id:Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join(''),label};
    const result=await api('/api/profiles',registering);
    if(result.id!==registering.id||result.label!==label)throw new Error('Wallet registration was not confirmed. Reload the wallet list.');
    const id=result.id;registering=null;await loadHot();$('hot-wallet-form').reset();
    await selectHot(id);
  });};
  $('setup-back-wallets').onclick=()=>{if(setupPending||walletMutations>0)return;setupRevision++;setupDiceClear();$('setup-password').value='';void selectHot('').catch(error=>status(error.message));};
  function showIdentity() {
    $('wallet-select').value=selected?.id||(hotId?'hot:'+hotId:'');$('wallet-kind').textContent=selected?.kind==='watch'?'WATCH-ONLY WALLET':selected?'QR WALLET · KEYS OFFLINE':'HOT WALLET';
    $('cold-name').textContent=selected?.label||'QR wallet';$('signing-name').textContent=selected?'Send from '+selected.label:'Send from QR wallet';
    $('public-wallet-detail').textContent=selected?.kind==='watch'?'On-chain XBT · View balances and receive. Send from the wallet that holds the keys.':'On-chain XBT · Approve payments on your XBT SeedSigner or XBT Krux.';
    document.body.classList.toggle('qr-account-active',!!selected);
  }
  function renderAccounts() {
    const select=$('wallet-select');select.replaceChildren(new Option('Main wallet · Ark & on-chain',''));
    for(const profile of hotProfiles)select.add(new Option(profile.label+' · Hot wallet','hot:'+profile.id));
    for(const account of accounts)select.add(new Option(account.label+(account.kind==='watch'?' · Watch-only':' · QR wallet'),account.id));select.value=selected?.id||(hotId?'hot:'+hotId:'');
    const rows=$('paired-wallets');rows.replaceChildren();
    for(const account of [{id:'',label:'Main wallet',kind:'hot'},...hotProfiles.map(p=>({...p,id:'hot:'+p.id,kind:'hot'})),...accounts]) {
      const button=document.createElement('button');button.className='menu-row secondary';button.type='button';
      const title=document.createElement('strong'),detail=document.createElement('small'),copy=document.createElement('span');title.textContent=account.label;
      detail.textContent=account.kind==='hot'?'Ark, Lightning & on-chain':account.kind==='watch'?'Watch-only · View and receive':'QR Signer · Public account only';copy.append(title,detail);button.append(copy);
      button.setAttribute('aria-pressed',String((selected?.id||(hotId?'hot:'+hotId:''))===account.id));button.onclick=()=>void choose(account.id);
      const card=document.createElement('div');card.className='wallet-choice';card.append(button);
      if(account.id){
        const rename=document.createElement('button');rename.type='button';rename.className='secondary';rename.textContent='Rename';rename.dataset.renameAccount=account.id;rename.setAttribute('aria-label','Rename '+account.label);
        rename.onclick=()=>{renaming=account.id;$('wallet-rename-name').value=account.label;$('wallet-rename-error').textContent='';$('wallet-rename').showModal();$('wallet-rename-name').focus();};card.append(rename);
        if(account.kind==='hot'){rows.append(card);continue;}
        const manage=document.createElement('details'),summary=document.createElement('summary');summary.textContent='More options';manage.append(summary);
        const exportButton=document.createElement('button');exportButton.type='button';exportButton.className='secondary';exportButton.textContent='Export public account';exportButton.setAttribute('aria-label','Export '+account.label+' public account');
        exportButton.onclick=()=>void work('wallet-account-status',async()=>{
          const context=walletContext();
          if(!await PaperclipReview.ask('Export '+account.label+'?\n\nThis file contains public descriptors. Anyone with it can track this wallet’s addresses and activity. It does not contain spending keys.'))return;
          if(!currentWallet(context))return;
          const result=await call('export',{account:account.id});if(!currentWallet(context))return;
          if(result.id!==account.id||result.kind!==account.kind||typeof result.descriptor!=='string'||typeof result.change_descriptor!=='string')throw new Error('Public export did not match this wallet.');
          const url=URL.createObjectURL(new Blob([result.descriptor],{type:'text/plain'})),link=document.createElement('a');link.href=url;link.download='paperclip-public-'+account.id.slice(0,8)+'.txt';link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
        });manage.append(exportButton);
        const remove=document.createElement('button');remove.type='button';remove.className='secondary';remove.textContent='Remove from list';remove.setAttribute('aria-label','Remove '+account.label);
        remove.onclick=()=>{removing=account;$('wallet-remove-form').reset();$('wallet-remove-label').textContent='Type REMOVE '+account.label;$('wallet-remove-error').textContent='';$('wallet-remove').showModal();controls();$('wallet-remove-name').focus();};manage.append(remove);card.append(manage);
      }
      rows.append(card);
    }
    controls();
  }
  async function load() {
    const ticket=generation,session=token;await loadHot();const result=await api('hardware/accounts');if(ticket!==generation||session!==token)return;
    if(!Array.isArray(result.accounts)||result.accounts.some(a=>!/^[0-9a-f]{64}$/.test(a.id)||typeof a.label!=='string'||!['hardware','watch'].includes(a.kind)))throw new Error('Could not load public wallets.');
    accounts=result.accounts;if(selected)selected=accounts.find(account=>account.id===selected.id)||selected;renderAccounts();showIdentity();
  }
  async function restore() {
    // Save only a public account ID in this tab. Validate it against the
    // authenticated server before showing balances or enabling wallet actions.
    const id=sessionRead('paperclip.selected-qr');
    $('forget-selected-wallet').hidden=true;
    if(!id)return;
    const session=token;
    try {
      await load();
      if(token!==session||!token)throw new Error('Session changed. Unlock again.');
      if(!accounts.some(account=>account.id===id))throw new Error('The previously selected QR wallet is unavailable.');
      // Restore identity even while an earlier session has an operation in flight.
      // Ordinary user switching remains disabled until that operation finishes.
      await selectAccount(id);
    } catch(error) {
      $('forget-selected-wallet').hidden=false;
      throw new Error('Could not restore your selected QR wallet. Retry, or choose the hot wallet explicitly.');
    }
  }
  $('forget-selected-wallet').onclick=()=>{
    sessionWrite('paperclip.selected-qr',null);sessionWrite('paperclip.selected-hot',null);hotId='';$('forget-selected-wallet').hidden=true;
    status('Hot wallet selected. Enter your access token to unlock.');$('token').focus();
  };
  async function refresh() {
    if(!selected)return false;const ticket=generation;
    const result=await call('refresh');if(ticket!==generation||!selected)return false;
    for(const key of ['confirmed_sat','pending_sat'])if(!Number.isSafeInteger(result[key])||result[key]<0)throw new Error('The QR wallet returned an invalid balance.');
    $('cold-balance').textContent=result.confirmed_sat.toLocaleString();$('cold-pending').textContent=result.pending_sat.toLocaleString();
    lastRelay=result.last_broadcast;history=result.transactions;
    $('cold-relay').textContent=lastRelay?.state==='pending_broadcast'?'Broadcast outcome is uncertain. Check transaction '+lastRelay.txid+' before another payment.':lastRelay?.state==='submitted'?'Transaction submitted. Waiting for confirmation.':'';
    PaperclipActivity.renderQR(history,$('cold-history'));
    nextAutomaticUpdate=Date.now()+30000;return true;
  }
  function showFrame() {
    if(!qrFrames.length)return;const qr=qrcode(0,'M');qr.addData(qrFrames[frame],'Alphanumeric');qr.make();
    // QR renderer emits coordinates only; no user strings are inserted as markup.
    $('signing-qr').innerHTML=qr.createSvgTag({scalable:true,cellSize:2,margin:8});
    $('signing-frame').textContent='Frame '+(frame+1)+' of '+qrFrames.length;
  }
  setInterval(()=>{if(pending&&!paused&&!document.hidden&&!document.querySelector('[data-screen="signing"]').hidden){frame=(frame+1)%qrFrames.length;showFrame();}},350);
  $('signing-pause').onclick=()=>{paused=!paused;$('signing-pause').textContent=paused?'Play QR':'Pause QR';};
  $('signing-next').onclick=()=>{if(qrFrames.length){paused=true;$('signing-pause').textContent='Play QR';frame=(frame+1)%qrFrames.length;showFrame();}};
  $('wallet-select').onchange=event=>void choose(event.target.value);
  $('wallet-rename-cancel').onclick=()=>{$('wallet-rename').close();renaming=null;};
  $('wallet-remove-cancel').onclick=()=>{$('wallet-remove').close();removing=null;};
  $('wallet-remove-name').oninput=controls;$('wallet-remove-backup').onchange=controls;
  $('wallet-remove-form').onsubmit=event=>{event.preventDefault();const account=removing,context=walletContext();if(!account)return;void work('wallet-remove-error',async()=>{
    const result=await call('remove',{account:account.id,confirmation:$('wallet-remove-name').value,backup_acknowledged:$('wallet-remove-backup').checked});
    if(!currentWallet(context))return;if(result.removed!==true||result.id!==account.id)throw new Error('Removal was not confirmed. Reload your wallet list.');
    $('wallet-remove').close();removing=null;
    if(selected?.id===account.id)await selectAccount('');
    await load();PaperclipNavigation.show('wallets');$('wallet-account-status').textContent='Removed from the wallet list. Import the same public account to restore it.';
  });};
  $('wallet-rename-form').onsubmit=event=>{event.preventDefault();const account=renaming,ticket=generation;void work('wallet-rename-error',async()=>{
    const label=$('wallet-rename-name').value.trim();
    if(!account||!label)throw new Error('Enter a wallet name.');
    if(account.startsWith('hot:'))await api('/api/profiles/'+account.slice(4)+'/name',{id:account.slice(4),label});else await call('rename',{account,label});
    if(selected?.id===account)clearSigning();
    await load();$('wallet-rename').close();renaming=null;$('wallet-rename-form').reset();
  }).then(()=>{
    if(ticket===generation&&!$('wallet-rename').open)document.querySelector('[data-rename-account="'+account+'"]')?.focus();
  });};
  document.querySelectorAll('[data-hot-wallet]').forEach(button=>button.onclick=()=>void choose(hotId?'hot:'+hotId:''));
  $('pair-form').onsubmit=event=>{event.preventDefault();void work('wallet-account-status',async()=>{
    const publicKey=await new PaperclipSigningQR.Collector().accept($('pair-key').value,true);
    if(!publicKey)throw new Error('Finish scanning the public account first.');
    const result=await call('pair',{label:$('pair-name').value,kind:$('pair-kind').value,public_key:publicKey,script:$('pair-script').value,origin:$('pair-origin').value.trim()});
    paired=result.id;await load();$('pair-address').textContent=result.first_address;$('pair-confirmation').hidden=false;$('pair-wallet').open=false;$('pair-form').reset();
  });};
  $('pair-use').onclick=()=>{if(paired){$('pair-confirmation').hidden=true;void choose(paired);}};
  $('cold-history-refresh').onclick=()=>void work('cold-history-status',refresh);
  $('cold-receive').onclick=()=>void work('cold-relay',async()=>{const result=await call('address');$('cold-address').textContent=result.address;PaperclipReceive.show('cold-address',result.address,'Receive to '+selected.label);});
  $('cold-max').onchange=controls;
  $('cold-send').onsubmit=event=>{event.preventDefault();void work('signing-status',async()=>{
    if(!selected||selected.kind!=='hardware')throw new Error('Select a QR signing wallet first.');
    const context=walletContext(),destination=$('cold-destination').value.trim(),maximum=$('cold-max').checked,amount=$('cold-amount').value;
    if(!destination)throw new Error('Enter a recipient address.');
    if(!maximum&&(!/^[1-9][0-9]*$/.test(amount)||!Number.isSafeInteger(Number(amount))))throw new Error('Enter a whole number of sats.');
    const unchanged=()=>currentWallet(context)&&token&&$('cold-destination').value.trim()===destination&&$('cold-max').checked===maximum&&(maximum||$('cold-amount').value===amount);
    const result=await call('prepare',maximum?{destination,send_max:true}:{destination,amount_sat:Number(amount)});
    if(!unchanged())throw new Error('Payment changed. Review again.');
    if(result.account!==selected.id||result.destination!==destination||!maximum&&result.amount_sat!==Number(amount)||maximum&&result.send_max!==true||
      !/^[0-9a-f]{64}$/.test(result.request_id)||![result.amount_sat,result.fee_sat,result.total_sat].every(Number.isSafeInteger)||result.amount_sat<=0||result.fee_sat<0||
      result.total_sat!==result.amount_sat+result.fee_sat)throw new Error('Invalid signing review. Refresh and try again.');
    const summary=selected.label+(maximum?' \u00b7 Send Max':'')+'\n\nRecipient: '+result.destination+'\nAmount: '+sats(result.amount_sat)+'\nNetwork fee: '+sats(result.fee_sat)+'\nTotal debit: '+sats(result.total_sat);
    if(!await PaperclipReview.ask(summary+'\n\nCreate the QR request for your signer?')){if(currentWallet(context)&&token)await call('cancel');return;}
    if(!unchanged())throw new Error('Payment changed. Review again.');
    pending=result;signed=null;collector=new PaperclipSigningQR.Collector();qrFrames=PaperclipSigningQR.frames(PaperclipSigningQR.binary(result.psbt));frame=0;
    paused=matchMedia('(prefers-reduced-motion: reduce)').matches;$('signing-pause').textContent=paused?'Play QR':'Pause QR';$('signing-review').textContent=summary;showFrame();
  });};
  function signingContext() {return {wallet:walletContext(),collector,pending};}
  function currentSigning(input) {return currentWallet(input.wallet)&&collector===input.collector&&pending===input.pending;}
  async function acceptFrame(text,isPublic,input=signingContext()) {
    if(!currentSigning(input))return;
    let result;
    try {result=await input.collector.accept(text,isPublic);}
    catch(error){if(currentSigning(input))throw error;return;}
    if(!currentSigning(input))return;
    const progress=collector.total?'Read '+collector.received+' of '+collector.total+' fragments':'Reading QR…';$('scanner-progress').textContent=progress;$('signing-progress').textContent=progress;
    if(result===null)return;
    stopCamera();
    if(isPublic){$('pair-key').value=result;$('pair-wallet').open=true;return;}
    if(!pending||!selected)throw new Error('Review a transaction in this wallet first.');
    let response;
    try {response=await call('verify',{request_id:input.pending.request_id,signed:PaperclipSigningQR.toBase64(result)});}
    catch(error){if(!currentSigning(input))return;collector=new PaperclipSigningQR.Collector();throw error;}
    if(!currentSigning(input))return;
    if(response.verified!==true||response.fee_sat!==input.pending.fee_sat)throw new Error('Signature verification did not match this review.');
    signed=response;$('signing-progress').textContent='Signature verified. Review once more before broadcast.';controls();
  }
  async function scan(isPublic) {
    if(busy)return;if(!isPublic&&!pending)return;collector=new PaperclipSigningQR.Collector();scanPublic=isPublic;
    $('scanner-title').textContent=isPublic?'Scan public account':'Scan signed response';$('scanner-progress').textContent='Point the camera at the QR code.';dialog.showModal();
    const ticket=generation,camera=++cameraGeneration;
    const active=()=>ticket===generation&&camera===cameraGeneration&&dialog.open;
    try{
      if(!navigator.mediaDevices?.getUserMedia)throw new Error('Camera access needs HTTPS or a trusted local origin. Use a QR image or PSBT file instead.');
      const acquired=await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment',width:{ideal:1280}},audio:false});
      if(!active()){acquired.getTracks().forEach(track=>track.stop());return;}stream=acquired;video.srcObject=stream;await video.play();
      if(!active()){acquired.getTracks().forEach(track=>track.stop());return;}scanning=true;
      while(scanning&&active()){
        if(video.readyState>=2){
          canvas.width=Math.min(video.videoWidth,1280);canvas.height=Math.round(video.videoHeight*canvas.width/video.videoWidth);context.drawImage(video,0,0,canvas.width,canvas.height);
          const pixels=context.getImageData(0,0,canvas.width,canvas.height),qr=PaperclipQRVendor.jsQR(pixels.data,pixels.width,pixels.height);
          if(qr)try{await acceptFrame(qr.data,isPublic);}catch(error){
            if(active())throw error;
            // A complete QR closes the camera before server verification.
            // Keep a current verification failure visible on the signing form.
            if(ticket===generation)$(isPublic?'wallet-account-status':'signing-status').textContent=error.message;
          }
        }
        await new Promise(resolve=>setTimeout(resolve,125));
      }
    }catch(error){if(!active())return;$('scanner-progress').textContent=error.message;scanning=false;if(stream)stream.getTracks().forEach(track=>track.stop());stream=null;video.srcObject=null;}
  }
  async function readFile(file,isPublic) {
    if(!file)return;if(file.size>10*1024*1024)throw new Error('File is too large.');
    const input=signingContext();
    let text;
    try {
      if(file.type.startsWith('image/')) {
        const image=await createImageBitmap(file);
        try {
          if(!currentSigning(input))return;
          if(image.width*image.height>16000000)throw new Error('QR image is too large.');
          canvas.width=image.width;canvas.height=image.height;context.drawImage(image,0,0);
          const pixels=context.getImageData(0,0,canvas.width,canvas.height),qr=PaperclipQRVendor.jsQR(pixels.data,pixels.width,pixels.height);
          if(!qr)throw new Error('No QR code found in this image.');
          text=qr.data;
        } finally {image.close();}
      } else {
        if(file.size>PaperclipSigningQR.MAX*2)throw new Error('Response is too large.');
        const bytes=new Uint8Array(await file.arrayBuffer());
        if(!currentSigning(input))return;
        text=!isPublic&&bytes.slice(0,5).every((v,i)=>v===[112,115,98,116,255][i])?PaperclipSigningQR.toBase64(bytes):new TextDecoder('utf-8',{fatal:true}).decode(bytes);
      }
    } catch(error) {if(currentSigning(input))throw error;return;}
    await acceptFrame(text,isPublic,input);
  }
  for(const [id,isPublic] of [['pair-file',true],['signed-file',false]])$(id).onchange=event=>{const file=event.target.files[0];event.target.value='';void work(isPublic?'wallet-account-status':'signing-status',()=>readFile(file,isPublic));};
  $('pair-scan').onclick=()=>void scan(true);$('signed-scan').onclick=()=>void scan(false);
  $('signed-paste').onclick=()=>void work('signing-status',()=>acceptFrame($('signed-text').value,false));
  $('scanner-reset').onclick=()=>{collector=new PaperclipSigningQR.Collector();$('scanner-progress').textContent='Scan one complete response.';if(!scanning){stopCamera();void scan(scanPublic);}};
  $('scanner-close').onclick=stopCamera;dialog.addEventListener('cancel',stopCamera);dialog.addEventListener('close',stopCamera);
  $('signing-cancel').onclick=cancelRequest;
  $('signing-download').onclick=()=>{if(!pending)return;const url=URL.createObjectURL(new Blob([PaperclipSigningQR.binary(pending.psbt)],{type:'application/octet-stream'}));const a=document.createElement('a');a.href=url;a.download='paperclip-unsigned.psbt';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
  $('signed-broadcast').onclick=()=>void work('signing-status',async()=>{
    if(!pending||!signed)throw new Error('Scan and verify the signature first.');
    if(!await PaperclipReview.ask('Broadcast from '+selected.label+'?\n\n'+$('signing-review').textContent+'\n\nTransaction: '+signed.txid))return;
    // Disable a second submission even if the reply is lost. The server journals before relay.
    const ticket=generation,txid=signed.txid,request_id=pending.request_id;signed=null;controls();
    let result;
    try{result=await call('broadcast',{request_id,txid});}
    catch(error){if(ticket!==generation)throw error;clearSigning();PaperclipNavigation.show('overview');$('cold-relay').textContent='Broadcast result is uncertain. Refresh and check transaction '+txid+' before another payment.';throw error;}
    clearSigning();PaperclipNavigation.show('overview');$('cold-relay').textContent=result.state==='submitted'?'Transaction submitted. Waiting for confirmation.':'Broadcast result is uncertain. Check transaction '+txid+' before another payment.';
  });
  window.addEventListener('paperclip:view',event=>{stopCamera();if(event.detail==='wallets'&&token)void work('wallet-account-status',load);});
  document.addEventListener('visibilitychange',()=>{if(document.hidden)stopCamera();});
  new MutationObserver(()=>{
    if($('wallet').hidden){generation++;selected=null;accounts=[];cancelRequest();clearWalletView();$('pair-form').reset();$('pair-confirmation').hidden=true;$('wallet-account-status').textContent='';document.body.classList.remove('qr-account-active');renderAccounts();}
    else void load().catch(()=>{$('wallet-account-status').textContent='Could not load QR wallets. Open Manage wallets to retry.';});
  }).observe($('wallet'),{attributes:true,attributeFilter:['hidden']});
  window.PaperclipAccounts={get hotProfiles(){return hotProfiles.map(p=>({...p}));},get hotProfileId(){return hotId;},restoreHot,get selectedId(){return selected?.id||'';},get generation(){return generation;},restore,refresh,busyChanged:controls};
})();
