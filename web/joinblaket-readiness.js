'use strict';
// Setup guidance only. The server makes the final offer and bond checks.
const PaperclipMakerReadiness = {
  fixed: [0,100,200,500,1000,2000,5000,10000],
  rates: ['0.00002','0.00005','0.0001','0.0002','0.0005','0.001','0.002','0.005','0.01','0.02','0.05','0.1'],
  percentages: ['0.002','0.005','0.01','0.02','0.05','0.1','0.2','0.5','1','2','5','10'],
  perMillion: [20,50,100,200,500,1000,2000,5000,10000,20000,50000,100000],
  completed(r) { return [r.terms,r.funds,r.bond,r.server,r.fresh].filter(Boolean).length; },
  nextStep(r) {
    if (!r.fresh) return "Refresh maker status before continuing.";
    if (!r.terms) return "Review the minimum amount and fee.";
    if (!r.server) return "Wait for Jam to finish its current operation.";
    if (!r.funds) return "Fund a jar and wait for confirmation.";
    if (!r.bond) return "Set up and fund a fidelity bond.";
    return "Ready to review. Your server checks final eligibility.";
  },
  evaluate(minimum, fee, jars, session, needsRefresh, relativeFee = null) {
    const sats = text => /^[0-9]+$/.test(text) && Number.isSafeInteger(Number(text)) ? Number(text) : null;
    const min = sats(minimum), cost = sats(fee);
    const validMinimum = min !== null && min >= 27300 && min <= 2100000000000000;
    const result = {
      terms: validMinimum && cost !== null && cost < min && (relativeFee === null ? this.fixed.includes(cost) : cost === 0 && this.rates.includes(relativeFee)),
      funds: validMinimum && jars.some(jar => Number.isSafeInteger(jar.confirmed_sat) && jar.confirmed_sat >= min),
      bond: jars.some(jar => Number.isSafeInteger(jar.bond_sat) && jar.bond_sat > 0),
      server: session?.session === true && session?.maker_running === false &&
        session?.rescanning === false && session?.coinjoin_in_process === false,
      fresh: session != null && !needsRefresh
    };
    return {...result, canStart: Object.values(result).every(Boolean)};
  }
};

const PaperclipJarSend = {
  id: value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value),
  terms(jar, destination, amount, rate, limit, coinjoin = false, bondLocktime = null, bondOutpoint = null) {
    if (bondLocktime !== null && (coinjoin || !Number.isSafeInteger(bondLocktime) || (bondOutpoint === null ? bondLocktime <= Date.now()/1000 : bondLocktime < 1577836800) || bondLocktime > 4099766400)) throw new Error('Review the future bond unlock date. Bond funding cannot use CoinJoin.');
    if (typeof coinjoin !== 'boolean') throw new Error('Choose a payment type.');
    if (![amount,rate,limit].every(v=>/^\d+$/.test(v))) throw new Error('Use whole sats and a whole sat/vB rate.');
    const n=Number(amount), r=Number(rate), fee=Number(limit);
    if (!Number.isInteger(jar) || jar<0 || jar>4 || !/^[A-Za-z0-9]{14,90}$/.test(destination) ||
        ![n,r,fee,n+fee].every(Number.isSafeInteger) || n<=0 || fee<=0 || n+fee>2100000000000000 || r<1 || r>10000)
      throw new Error('Review the jar, XBT address, amount and mining fee limit.');
    if (bondOutpoint !== null && (!PaperclipBonds.outpoint(bondOutpoint) || jar !== 0 || coinjoin || bondLocktime === null || fee >= n)) throw new Error('Review the selected bond and fee limit.');
    return {jar,destination,amount_sat:n,fee_rate_millisat_vb:r*1000,max_fee_sat:fee,coinjoin,...(bondLocktime === null ? {} : {bond_locktime:bondLocktime}),...(bondOutpoint === null ? {} : {bond_outpoint:bondOutpoint})};
  },
  validate(row, id, wallet, terms, now = Math.floor(Date.now()/1000)) {
    const q=row?.quote;
    if (terms.bond_locktime != null && (terms.coinjoin || (terms.bond_outpoint == null && terms.bond_locktime <= now))) throw new Error('Bond unlock date passed. Create a new review.');
    if (!this.id(id) || row?.id!==id || row.state!=='prepared' || !this.id(row.approval) || !Number.isSafeInteger(row.expires) || row.expires<=now || row.expires>now+300 ||
        !q || q.wallet!==wallet || q.jar!==terms.jar || q.purpose!==(terms.bond_outpoint != null ? 'withdraw_bond' : terms.bond_locktime == null ? 'send' : 'fund_bond') || (q.bond_locktime??null)!==(terms.bond_locktime??null) || q.destination!==terms.destination || (terms.bond_outpoint != null ? q.total_sat : q.amount_sat)!==terms.amount_sat || (q.bond_outpoint??null)!==(terms.bond_outpoint??null) ||
        ![q.amount_sat,q.fee_sat,q.total_sat].every(v=>Number.isSafeInteger(v)&&v>=0&&v<=2100000000000000) ||
        q.fee_sat>terms.max_fee_sat || q.amount_sat+q.fee_sat!==q.total_sat || !this.id(q.txid) || q.rbf!==!Boolean(terms.coinjoin) || (q.coinjoin??false)!==(terms.coinjoin??false) ||
        !['xbt-mainnet','xbt-testnet','xbt-signet','xbt-regtest'].includes(q.network) ||
        typeof q.wallet_identity!=='string' || !q.wallet_identity.startsWith(q.network+':') || !this.id(q.wallet_identity.slice(q.network.length+1)))
      throw new Error('Jam review changed or expired. Check payment activity before another action.');
    if (q.coinjoin && (![q.maker_fee_sat,q.mining_fee_sat,q.network_fee_sat].every(v=>Number.isSafeInteger(v)&&v>=0&&v<=2100000000000000) ||
        q.maker_fee_sat+q.mining_fee_sat!==q.fee_sat || q.mining_fee_sat>q.network_fee_sat ||
        !Number.isInteger(q.maker_count) || q.maker_count<2 || q.maker_count>20 || q.broadcast_policy!=='self'))
      throw new Error('Invalid CoinJoin fee review.');
    return row;
  }
};

const PaperclipBonds = {
  outpoint: value => typeof value === 'string' && /^[0-9a-f]{64}:(0|[1-9][0-9]{0,9})$/.test(value) && Number(value.split(':')[1]) <= 4294967295,
  canWithdraw: (coin, time) => coin.locktime < time && coin.confirmations > 0 && !coin.frozen && coin.signable,
  validate(value, wallet) {
    if (!value || value.wallet !== wallet || !/^xbt-(mainnet|testnet|signet|regtest):[0-9a-f]{64}$/.test(value.identity) ||
        !Number.isSafeInteger(value.chain_time) || value.chain_time < 1577836800 || value.chain_time > 4294967295 || !Array.isArray(value.bonds) || value.bonds.length > 100) throw new Error('Invalid bond inventory.');
    let total=0; const seen=new Set();
    for (const coin of value.bonds) {
      if (!coin || !this.outpoint(coin.outpoint) || seen.has(coin.outpoint) || !Number.isSafeInteger(coin.value_sat) || coin.value_sat<=0 ||
          !Number.isSafeInteger(coin.locktime) || coin.locktime<1577836800 || coin.locktime>4099766400 ||
          !Number.isSafeInteger(coin.confirmations) || coin.confirmations<0 || coin.confirmations>4294967295 || typeof coin.frozen!=='boolean' || typeof coin.signable!=='boolean') throw new Error('Invalid bond coin.');
      seen.add(coin.outpoint); total+=coin.value_sat; if(total>2100000000000000) throw new Error('Invalid bond total.');
    }
    return value;
  }
};
