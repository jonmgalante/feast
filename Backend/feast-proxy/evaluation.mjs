import {validDiscovery,WEB_RESERVATION} from './discovery.mjs';
export const EVALUATION_RUN='local-extraction-20261025-v1';
export const EVALUATION_TESTER='feast-dev-tester-two';
export const EVALUATION_MAX=3;
export const EVALUATION_CASES=Object.freeze([
 {id:'manhattan-cafe-month',criteria:{category:'cafe',region:'Manhattan',intent:'recent_openings',windowDays:30,period:'calendar_month'}},
 {id:'philadelphia-bakery-today',criteria:{category:'bakery',region:'Philadelphia',intent:'recent_openings',windowDays:1,period:'today'}},
 {id:'london-bakery-upcoming30',criteria:{category:'bakery',region:'London',intent:'upcoming_openings',windowDays:30}}
]);
const canonical=value=>JSON.stringify(Object.fromEntries(Object.entries(value).sort(([a],[b])=>a.localeCompare(b))));
export function evaluationCase(payload){return validDiscovery(payload)?EVALUATION_CASES.find(x=>canonical(x.criteria)===canonical(payload.criteria)):undefined}
export function verifiedEvaluationStatus(s){
 if(!(s?.protocol===1&&s.runID===EVALUATION_RUN&&s.readOnly===true&&s.reservationMicroUSD===WEB_RESERVATION&&s.maximumAttempts===EVALUATION_MAX&&s.maximumReservationMicroUSD===600000&&s.totalCapMicroUSD===5000000&&s.userCapMicroUSD===2500000&&Number.isSafeInteger(s.totalReservedMicroUSD)&&s.totalReservedMicroUSD>=0&&s.totalReservedMicroUSD<=5000000&&Number.isSafeInteger(s.userReservedMicroUSD)&&s.userReservedMicroUSD>=0&&s.userReservedMicroUSD<=2500000&&s.userReservedMicroUSD<=s.totalReservedMicroUSD&&Number.isSafeInteger(s.attemptedCount)&&s.attemptedCount>=0&&s.attemptedCount<=3&&typeof s.halted==='boolean'&&Array.isArray(s.cases)&&s.cases.length===3))return false;
 if(s.totalRemainingMicroUSD!==5000000-s.totalReservedMicroUSD||s.userRemainingMicroUSD!==2500000-s.userReservedMicroUSD)return false;
 if(s.cases.some((c,i)=>c.caseID!==EVALUATION_CASES[i].id||!['not-attempted','reserved','complete','stopped'].includes(c.state)||(c.state==='not-attempted'?!!c.requestID:!c.requestID)))return false;
 if(s.cases.filter(x=>x.requestID).length!==s.attemptedCount)return false;
 const pending=s.cases.some(x=>x.state==='reserved');
 return s.availableAttempts===(s.halted||pending?0:Math.max(0,Math.min(3-s.attemptedCount,Math.floor(s.totalRemainingMicroUSD/200000),Math.floor(s.userRemainingMicroUSD/200000))));
}
export function compareEvaluation(baseline,candidate,timings,candidateMS){
 const key=x=>[x.name.toLowerCase(),x.region,x.openingDate,x.openingKind,x.sourceURL].join('|');
 const baselineKeys=new Set(baseline.places.map(key)),candidateKeys=new Set(candidate.places.map(key));
 const candidateExtra=[...candidateKeys].filter(x=>!baselineKeys.has(x)).length;
 return {protocol:1,runID:EVALUATION_RUN,candidateKind:'local-extraction',baselineCalls:2,candidateAdditionalCalls:0,
  candidate:{places:candidate.places,usage:candidate.usage,status:candidate.unsupported?'unsupported':'valid'},
  comparison:{baselineCount:baselineKeys.size,candidateCount:candidateKeys.size,matchedCount:[...candidateKeys].filter(x=>baselineKeys.has(x)).length,candidateExtraCount:candidateExtra,baselineOnlyCount:[...baselineKeys].filter(x=>!candidateKeys.has(x)).length},
  timings:{...timings,candidateLocal:Math.max(0,Math.min(120000,Math.round(candidateMS)||0))},
  humanSourceReviewRequired:true,stop:candidateExtra>0||candidate.unsupported===true};
}
