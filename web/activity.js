'use strict';
// Keep the two ledgers distinct: a board can have both an Ark and an on-chain entry.
// On-chain records do not include timestamps, so never invent a combined chronology.
const PaperclipActivity = (() => {
  let ark=null, onchain=null, filter='all';
  const labels={ark:'Ark',onchain:'On-chain'};
  const element=(tag,text,className='')=>{const node=document.createElement(tag);node.textContent=text;node.className=className;return node;};
  const amount=value=>Number.isSafeInteger(value)?value:null;
  const format=value=>value===null?'Amount unavailable':(value>0?'+':'')+value.toLocaleString()+' sats';
  const records=value=>Array.isArray(value)&&value.every(row=>row&&typeof row==='object'&&!Array.isArray(row))?value:null;
  function chainRow(row,qr=false) {
    const change=amount(qr?row.amount_sat:row.balance_change_sat);
    const height=Number.isSafeInteger(row.confirmation?.height)&&row.confirmation.height>=0?row.confirmation.height:null;
    const confirmed=qr?row.confirmed===true:height!==null;
    const unconfirmed=qr?row.confirmed===false:row.confirmation===null;
    return {kind:'onchain',qr,change,reference:typeof row.txid==='string'?row.txid:'',
      title:row.is_cpfp===true?'Network fee bump':change===null||change===0?'On-chain transfer':change>0?'Received on-chain':'Sent on-chain',
      state:confirmed?'confirmed':unconfirmed?'pending':'unknown',badge:confirmed?'Confirmed':unconfirmed?'Unconfirmed':'Status unavailable',
      when:height===null?'':('Block '+height.toLocaleString()),fee:amount(row.onchain_fee_sat),raw:row,
      explanation:confirmed?'Recorded on-chain. This is the change to this wallet\u2019s balance.':unconfirmed?'Waiting for a block confirmation. Do not send again because a transaction is unconfirmed.':'Confirmation data is unavailable. Refresh before taking another action.'};
  }
  function arkRow(row) {
    const date=typeof row.time?.created_at==='string'?new Date(row.time.created_at):null;
    const state=({successful:'completed',pending:'pending',failed:'failed',canceled:'cancelled'})[row.status]||'unknown';
    return {kind:'ark',change:amount(row.effective_balance_sat),reference:typeof row.id==='string'||Number.isSafeInteger(row.id)?String(row.id):'',
      title:({'bark.arkoor':'Ark transfer','bark.lightning_send':'Lightning send','bark.lightning_receive':'Lightning receive','bark.board':'Board into Ark','bark.round':'Ark round','bark.offboard':'Withdraw from Ark'}[row.subsystem?.name]||'Ark movement'),
      state,badge:({completed:'Movement completed',pending:'Pending',failed:'Failed',cancelled:'Cancelled',unknown:'Status unavailable'})[state],
      when:date&&Number.isFinite(date.getTime())?date.toLocaleString():'Time unavailable',fee:amount(row.offchain_fee_sat),raw:row,
      explanation:state==='pending'?'Still in progress. Check payment status before another attempt.':state==='failed'?'This operation failed. Check any refund or recovery before retrying.':state==='cancelled'?'This movement was cancelled. Check related payments and recovery before retrying.':state==='unknown'?'The wallet returned an unfamiliar status. It does not confirm success or failure.':'This confirms an Ark balance movement. For a multi-step payment, check payment status and the recipient to confirm settlement.'};
  }
  function card(row) {
    const node=element('article','','activity-row');node.dataset.activityKind=row.kind;node.dataset.activityState=row.state;
    const icon=element('span',row.change>0?'\u2199':row.change<0?'\u2197':'\u2194','activity-icon');icon.setAttribute('aria-hidden','true');
    const heading=element('div','','activity-description');heading.append(element('strong',row.title),element('span',row.badge,'activity-state state-'+row.state));
    const value=element('span',format(row.change),row.change>0?'positive':'amount');
    const when=element('p',row.when,'activity-date');
    const details=element('details','');details.append(element('summary','Details'),element('p',row.explanation));
    const facts=element('dl','','activity-facts');
    facts.append(element('dt','Balance change'),element('dd',format(row.change)));
    facts.append(element('dt',row.kind==='onchain'?'Transaction fee':'Ark fee'),element('dd',row.fee!==null&&row.fee>=0?row.fee.toLocaleString()+' sats':'Unavailable'));
    if(row.reference){facts.append(element('dt',row.kind==='onchain'?'Transaction ID':'Movement ID'),element('dd',row.reference,'activity-reference'));}
    details.append(facts);
    if(row.kind==='onchain'&&!row.qr&&row.state==='pending'&&row.change<0&&/^[0-9a-f]{64}$/.test(row.reference)&&globalThis.PaperclipFeeReplacement) details.append(PaperclipFeeReplacement.control(row.reference));
    if(row.kind==='onchain')details.append(element('p','The balance change includes the wallet\u2019s debit and any fee it paid. The transaction fee is the total network fee, not an extra debit.','hint'));
    const technical=element('details','');technical.append(element('summary','Technical record'),element('pre',JSON.stringify(row.raw,null,2)));details.append(technical);
    node.append(icon,heading,value,when,details);return node;
  }
  function selectedFilters() {
    document.querySelectorAll?.('[data-activity-filter]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.activityFilter===filter)));
  }
  function appendRows(container,rows) {
    let shown=0;
    const paging=element('div','','activity-paging'),count=element('span','','hint'),more=element('button','Show more','secondary');
    more.type='button';more.setAttribute('aria-label','Show more '+labels[rows[0].kind]+' records');
    paging.append(count,more);container.append(paging);
    function show(focus=false) {
      const end=Math.min(shown+25,rows.length);let first=null;
      while(shown<end){const node=card(rows[shown++]);first??=node;container.insertBefore(node,paging);}
      count.textContent='Showing '+shown+' of '+rows.length+' records';
      more.hidden=shown===rows.length;paging.hidden=rows.length<=25;
      if(focus&&first){first.tabIndex=-1;first.focus();}
    }
    more.onclick=()=>show(true);show();
  }
  function render() {
    const list=document.getElementById('activity-list'),summary=document.getElementById('activity-summary');list.replaceChildren();selectedFilters();
    const sources=filter==='all'?['onchain','ark']:[filter];
    const groups=sources.map(kind=>({kind,rows:kind==='ark'?ark:onchain}));
    const known=groups.flatMap(group=>group.rows||[]),missing=groups.filter(group=>group.rows===null);
    summary.textContent=missing.length?missing.map(group=>labels[group.kind]).join(' and ')+' activity unavailable. Refresh to try again.':known.length+' records \u00b7 '+known.filter(row=>row.state==='pending').length+' awaiting completion';
    if(!known.length&&!missing.length){list.textContent=filter==='all'?'No activity yet. Deposits and payments will appear here.':'No '+labels[filter]+' activity yet.';return;}
    for(const group of groups) {
      const container=element('div','','activity-group');container.dataset.activityGroup=group.kind;
      container.append(element('h3',labels[group.kind]));
      if(group.rows===null)container.append(element('p','Could not load '+labels[group.kind]+' activity. This does not mean a payment failed.','activity-empty'));
      else if(!group.rows.length)container.append(element('p','No '+labels[group.kind]+' activity yet.','activity-empty'));
      else appendRows(container,group.rows);
      list.append(container);
    }
  }
  function reset() {
    ark=null;onchain=null;filter='all';selectedFilters();
    document.getElementById('activity-list').replaceChildren();document.getElementById('activity-summary').textContent='';
  }
  return {
    init(){document.getElementById('activity-filters').addEventListener('click',event=>{const next=event.target.closest('[data-activity-filter]')?.dataset.activityFilter;if(['all','ark','onchain'].includes(next)){filter=next;render();}});},
    set(arkRecords,chainRecords){ark=records(arkRecords)?.map(arkRow)??null;onchain=records(chainRecords)?.slice().reverse().map(row=>chainRow(row))??null;render();return ark!==null&&onchain!==null;},
    reset,
    renderQR(rows,list){list.replaceChildren();const valid=records(rows);if(valid===null){list.textContent='Could not read account activity. Refresh to try again.';return;}if(!valid.length){list.textContent='No transactions in this account yet.';return;}appendRows(list,valid.map(row=>chainRow(row,true)));}
  };
})();
