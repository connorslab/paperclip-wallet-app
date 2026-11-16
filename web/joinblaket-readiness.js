'use strict';
// Setup guidance only. The server makes the final offer and bond checks.
const PaperclipMakerReadiness = {
  evaluate(minimum, fee, jars, session, needsRefresh) {
    const sats = text => /^[0-9]+$/.test(text) && Number.isSafeInteger(Number(text)) ? Number(text) : null;
    const min = sats(minimum), cost = sats(fee);
    const validMinimum = min !== null && min >= 27300 && min <= 2100000000000000;
    const result = {
      terms: validMinimum && cost !== null && cost < min,
      funds: validMinimum && jars.some(jar => Number.isSafeInteger(jar.confirmed_sat) && jar.confirmed_sat >= min),
      bond: jars.some(jar => Number.isSafeInteger(jar.bond_sat) && jar.bond_sat > 0),
      server: session?.session === true && session?.maker_running === false &&
        session?.rescanning === false && session?.coinjoin_in_process === false,
      fresh: session != null && !needsRefresh
    };
    return {...result, canStart: Object.values(result).every(Boolean)};
  }
};
