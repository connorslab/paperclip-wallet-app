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
