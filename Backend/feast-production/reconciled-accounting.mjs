import {attemptOwnershipBatch} from './attempt-ownership.mjs';
import {pilotAccountingFetch} from './pilot-accounting.mjs';
import {nativeAccountingFetch,NATIVE_PROFILE,NATIVE_ESTIMATE,NATIVE_PROFILES,nativeUsageCost} from './native-accounting.mjs';
import {knownProviderRejection} from './provider-errors.mjs';
import {VALIDATION_CAP_MICRO_USD} from './budget-policy.mjs';
import {validLookupDiagnostic} from './public-business.mjs';
// Candidate only: opt-in accounting on the SAME namespace. Historical v1 records/counters are never rewritten.
import {PUBLIC_PROFILES} from './public-policy.mjs';
import {STAGE_POLICY,STAGE_HOLDS,stageCost} from './stage-policy.mjs';
import {stageID} from './stage-accounting.mjs';
export const CAP=VALIDATION_CAP_MICRO_USD, PROFILES=Object.freeze({saved:2_500_000,public:1_250_000,...Object.fromEntries(Object.entries(PUBLIC_PROFILES).map(([k,v])=>[k,v.holdMicroUSD])),...STAGE_HOLDS,...Object.fromEntries(Object.entries(NATIVE_PROFILES).map(([k,v])=>[k,v.estimate]))});
const V1='production-validation-v1:',V2='production-validation-v2:';
const integer=x=>Number.isSafeInteger(x)&&x>=0;
const json=(v,status=200)=>Response.json(v,{status,headers:{'Cache-Control':'no-store'}});
export function usageCost(calls,profile){
 if(Object.hasOwn(NATIVE_PROFILES,profile))return nativeUsageCost(calls,profile);
 if(Object.hasOwn(STAGE_POLICY,profile))return stageCost(calls,profile);
 if(!Array.isArray(calls)||!calls.length||calls.length>(profile==='saved'?3:2))throw Error('usage_shape');
 const publicPolicy=PUBLIC_PROFILES[profile];
 let input=0,output=0,web=0,cost=0;
 for(let i=0;i<calls.length;i++){
  const c=calls[i];if(!c||Object.keys(c).sort().join(',')!=='inputTokens,model,outputTokens,webCalls'||![c.inputTokens,c.outputTokens,c.webCalls].every(integer))throw Error('usage_shape');
  if(profile==='saved'){
   if(c.model!=='gpt-6-astra'||c.inputTokens>8192||c.outputTokens>8192||c.webCalls!==0)throw Error('usage_limit');
   cost+=c.inputTokens*20+c.outputTokens*100;
  }else if(publicPolicy!==undefined){
   if(c.model!==publicPolicy.model||c.inputTokens>(i===0?publicPolicy.maxResearchInput:publicPolicy.maxExtractionInput)||c.outputTokens>(i===0?publicPolicy.maxResearchOutput:publicPolicy.maxExtractionOutput)||c.webCalls!==(i===0?1:0))throw Error('usage_limit');
   cost+=c.inputTokens*(publicPolicy.inputRate??20)+c.outputTokens*(publicPolicy.outputRate??100)+c.webCalls*10000;
  }else{
   if(c.model!=='gpt-6-luna'||c.inputTokens>(i===0?2100000:8192)||c.outputTokens>(i===0?1800:1200)||c.webCalls!==(i===0?1:0))throw Error('usage_limit');
   // >=long-context/cache-write/regional pricing; fixed Standard tier, no other tools.
   cost+=c.inputTokens*0.5+c.outputTokens+c.webCalls*10000;
  }
  input+=c.inputTokens;output+=c.outputTokens;web+=c.webCalls;
 }
 if(profile==='saved'&&output>16384)throw Error('usage_limit');
 const total=Math.ceil(publicPolicy!==undefined?cost*11/10:cost*1.1);if(total>PROFILES[profile])throw Error('usage_limit');return total;
}
async function rows(tx,prefix){let startAfter;const values=[];for(;;){const m=await tx.list({prefix,limit:1000,...(startAfter?{startAfter}:{})});if(!(m instanceof Map))throw Error('accounting_incomplete');if(!m.size)return values;const last=[...m.keys()].at(-1);if(startAfter&&last<=startAfter)throw Error('accounting_incomplete');values.push(...m.values());if(m.size<1000)return values;startAfter=last;}}
async function view(tx,reconcileLegacy){
 const legacyTotal=(await tx.get(V1+'total'))??0,oldHalted=(await tx.get(V1+'halted'))??false;
 if(!integer(legacyTotal)||typeof oldHalted!=='boolean')throw Error('accounting_corrupt');
 const legacy=await rows(tx,V1+'request:');let historical=0,legacyCharged=0,legacyUncertain=0;
 for(const r of legacy){
  if(!r||r.reservedMicroUSD!==2500000||!['pending','complete','uncertain'].includes(r.state))throw Error('legacy_incomplete');
  historical+=r.reservedMicroUSD;
  if(r.state==='complete'){
   if(!integer(r.inputTokens)||r.inputTokens>24576||!integer(r.outputTokens)||r.outputTokens>16384||!Number.isInteger(r.calls)||(r.calls<1&&!knownProviderRejection({diagnostic:r}))||r.calls>3)throw Error('legacy_usage_missing');
   const cost=Math.ceil((r.inputTokens*20+r.outputTokens*100)*11/10);
   if(cost!==r.conservativeUsageMicroUSD||cost>r.reservedMicroUSD)throw Error('legacy_usage_unverified');legacyCharged+=cost;
  }else legacyUncertain+=r.reservedMicroUSD;
 }
 if(historical!==legacyTotal)throw Error('legacy_index_mismatch');
 let charged=reconcileLegacy?legacyCharged:legacyTotal,pending=reconcileLegacy?legacyUncertain:0;
 const newer=await rows(tx,V2+'request:');let newHistorical=0;
 for(const r of newer){
  if(!r||!Object.hasOwn(PROFILES,r.profile)||r.reservedMicroUSD!==PROFILES[r.profile])throw Error('accounting_corrupt');newHistorical+=r.reservedMicroUSD;
  if(r.state==='complete'){
   const cost=usageCost(r.usage,r.profile);if(cost!==r.conservativeUsageMicroUSD)throw Error('accounting_corrupt');charged+=cost;
  }else if(r.state==='cancelled'){if(r.undispatched!==true||r.conservativeUsageMicroUSD!==0)throw Error('accounting_corrupt');}else if(r.state==='rejected'){if(!(Object.hasOwn(NATIVE_PROFILES,r.profile)&&r.undispatched===true)&&!knownProviderRejection({diagnostic:r})||r.conservativeUsageMicroUSD!==0)throw Error('accounting_corrupt');}else if(['pending','uncertain'].includes(r.state))pending+=r.reservedMicroUSD;else throw Error('accounting_corrupt');
 }
 const halted=oldHalted||((await tx.get(V2+'halted'))??false);
 if(typeof halted!=='boolean'||!integer(charged+pending))throw Error('accounting_corrupt');
 return {protocol:1,accountingVersion:2,capMicroUSD:CAP,reservedMicroUSD:charged+pending,chargedMicroUSD:charged,pendingMicroUSD:pending,remainingMicroUSD:null,historicalReservedMicroUSD:historical+newHistorical,legacyHistoricalReservedMicroUSD:legacyTotal,legacyVerifiedUsageMicroUSD:legacyCharged,legacyUncertainMicroUSD:legacyUncertain,legacyReconciliationEnabled:reconcileLegacy,halted};
}
async function publicDiagnostics(tx){
 const raw=await tx.get(V2+'public-diagnostics');
 if(!Array.isArray(raw))return [];
 return raw.slice(-3).filter(item=>{
  if(!item||typeof item!=='object'||Array.isArray(item))return false;
  const {requestID,...diagnostic}=item;
  return /^[a-f0-9-]{36}$/i.test(requestID??'')&&validLookupDiagnostic(diagnostic);
 });
}
export async function reconciledFetch(storage,request,reconcileLegacy=false,env={}){
 try{
  const path=new URL(request.url).pathname;
  if(path.startsWith('/pilot-')&&path.endsWith('-v2')&&request.method==='POST')return await pilotAccountingFetch(storage,request,env);
  if(path.startsWith('/native-')&&path.endsWith('-v2')&&request.method==='POST')return nativeAccountingFetch(storage,request,tx=>view(tx,reconcileLegacy),rows);
  if(path==='/status-v2'&&request.method==='GET'){
   const budget=await storage.transaction(tx=>view(tx,reconcileLegacy));let diagnostics=[];
   try{diagnostics=await storage.transaction(publicDiagnostics)}catch{}
   return json({...budget,publicLookupDiagnostics:diagnostics});
  }
  if(path==='/fence-v2'&&request.method==='POST'){
   const p=await request.json();
   if(!p||!/^[a-f0-9]{64}$/.test(p.userHash??'')||!Array.isArray(p.roots)||!p.roots.length||p.roots.length>64||new Set(p.roots).size!==p.roots.length||p.roots.some(x=>!/^[a-f0-9-]{36}$/i.test(x)))return json({error:'invalid_attempt'},400);
   return await storage.transaction(async tx=>{
    const owners=await attemptOwnershipBatch(tx,p.roots,p.userHash);
    for(const root of p.roots){
     const ownership=owners.get(root.toLowerCase());
     if(!ownership.owned)return json({error:'attempt_unavailable'},403);
     if(ownership.accounting.some(r=>!['complete','rejected','cancelled'].includes(r.state)))return json({error:'attempt_unsettled'},409);
    }
    for(const root of p.roots)await tx.put(V2+'closed-root:'+root.toLowerCase(),{userHash:p.userHash});
    return json({version:9,state:'fenced',roots:p.roots});
   });
  }
  if(request.method!=='POST'||!['/reserve-v2','/complete-v2','/uncertain-v2','/diagnostic-v2','/cancel-undispatched-v2'].includes(path))return json({error:'not_available'},503);
  const p=await request.json();if(!p||!/^[a-f0-9-]{36}$/i.test(p.requestID??'')||!/^[a-f0-9]{64}$/.test(p.userHash??''))return json({error:'invalid_accounting_request'},400);
  if(path==='/reserve-v2'&&Object.hasOwn(STAGE_POLICY,p.profile)){
   if(!/^[a-f0-9-]{36}$/i.test(p.rootRequestID??'')||!Number.isSafeInteger(p.stageIndex)||p.stageIndex<0||p.stageIndex>=12||await stageID(p.rootRequestID,p.stageIndex)!==p.requestID)return json({error:'invalid_stage_identity'},400);
  }
  if(path==='/diagnostic-v2'){
   if(!validLookupDiagnostic(p.publicDiagnostic))return json({error:'invalid_diagnostic'},400);
   await storage.transaction(async tx=>{
    const record=await tx.get(V2+'request:'+p.requestID);
    if(record?.state!=='complete'||record.userHash!==p.userHash||!['astraResearchStageV1','astraExtractionStageV1','solResearchStageV1','solExtractionStageV1'].includes(record.profile))throw Error('diagnostic_record');
    const history=await publicDiagnostics(tx);await tx.put(V2+'public-diagnostics',[...history.slice(-2),{requestID:p.requestID,...p.publicDiagnostic}]);
   });return json({accepted:true});
  }
  const outcome=await storage.transaction(async tx=>{
   const current=await view(tx,reconcileLegacy),k=V2+'request:'+p.requestID,prior=await tx.get(k);
   if(path==='/reserve-v2'){
    if(Object.hasOwn(NATIVE_PROFILES,p.profile))return json({error:'native_accounting_required'},400);
    if(current.halted)return json({error:'validation_halted'},503);
    if(prior||await tx.get(V1+'request:'+p.requestID))return json({error:'already_reserved'},409);
    if(await tx.get(V2+'stage-root:'+p.requestID))return json({error:'already_reserved'},409);
    if(await tx.get(V2+'closed-root:'+(p.rootRequestID??p.requestID).toLowerCase()))return json({error:'attempt_closed'},409);
    const staged=Object.hasOwn(STAGE_POLICY,p.profile),rootKey=staged?V2+'stage-root:'+p.rootRequestID:null,root=staged?await tx.get(rootKey):null;
    if(staged){
     if(await tx.get(V1+'request:'+p.rootRequestID)||await tx.get(V2+'request:'+p.rootRequestID))return json({error:'already_reserved'},409);
     if(p.stageIndex===0 ? root!=null : (!root||root.userHash!==p.userHash||root.fingerprint!==p.fingerprint||root.nextIndex!==p.stageIndex))return json({error:'stage_order_or_replay'},409);
    }
    if(!Object.hasOwn(PROFILES,p.profile)||p.amountMicroUSD!==PROFILES[p.profile]||!/^[a-f0-9]{64}$/.test(p.fingerprint??''))return json({error:'invalid_reservation'},400);
    // Enforce bounded staged concurrency with the atomic global exposure check.
    // A disconnected stage keeps its FULL hold; a stale legacy lock must not
    // permanently veto a new independently reserved stage. Legacy profiles retain
    // their original single-flight contract.
    if(!staged&&(await tx.get(V2+'inflight:'+p.userHash)||await tx.get(V1+'inflight:'+p.userHash)))return json({error:'request_in_progress'},429);
    if(!Number.isSafeInteger(current.reservedMicroUSD+p.amountMicroUSD))return json({error:'accounting_unavailable'},503);
    const active=(await rows(tx,V2+'request:')).filter(r=>r.state==='pending');
    if(active.length>=4)return json({error:'request_in_progress'},429);
    if(staged)await tx.put(rootKey,{userHash:p.userHash,fingerprint:p.fingerprint,nextIndex:p.stageIndex+1});
    await tx.put(V2+'adopted',true);
    await tx.put(k,{userHash:p.userHash,fingerprint:p.fingerprint,profile:p.profile,reservedMicroUSD:p.amountMicroUSD,state:'pending',...(staged?{rootRequestID:p.rootRequestID,stageIndex:p.stageIndex}:{})});if(!staged)await tx.put(V2+'inflight:'+p.userHash,p.requestID);
    // Append-only reconciliation audit. No reset/refund endpoint; v1 keys remain byte-for-byte untouched.
    await tx.put(V2+'audit:'+p.requestID,{legacyReconciliationEnabled:reconcileLegacy,legacyHistoricalReservedMicroUSD:current.legacyHistoricalReservedMicroUSD,legacyVerifiedUsageMicroUSD:current.legacyVerifiedUsageMicroUSD,legacyUncertainMicroUSD:current.legacyUncertainMicroUSD});
    return json({...await view(tx,reconcileLegacy),requestID:p.requestID,reservedMicroUSD:p.amountMicroUSD});
   }
   if(prior&&Object.hasOwn(NATIVE_PROFILES,prior.profile))return json({error:'native_accounting_required'},400);
   if(!prior||prior.userHash!==p.userHash||prior.state!=='pending')return json({error:'invalid_accounting_state'},409);
   if(path==='/cancel-undispatched-v2'){await tx.put(k,{...prior,state:'cancelled',undispatched:true,conservativeUsageMicroUSD:0});if(await tx.get(V2+'inflight:'+p.userHash)===p.requestID)await tx.put(V2+'inflight:'+p.userHash,null);return json({...await view(tx,reconcileLegacy),conservativeUsageMicroUSD:0});}
   if(path==='/complete-v2'&&knownProviderRejection({diagnostic:{providerStatus:p.providerRejectedStatus,providerCode:p.providerRejectedCode}})){await tx.put(k,{...prior,state:'rejected',providerStatus:p.providerRejectedStatus,providerCode:p.providerRejectedCode,conservativeUsageMicroUSD:0});if(await tx.get(V2+'inflight:'+p.userHash)===p.requestID)await tx.put(V2+'inflight:'+p.userHash,null);return json({...await view(tx,reconcileLegacy),requestReservedMicroUSD:prior.reservedMicroUSD,conservativeUsageMicroUSD:0});}
   let cost;
   try{if(path!=='/complete-v2')throw Error('uncertain');cost=usageCost(p.usage,prior.profile)}catch{
    await tx.put(k,{...prior,state:'uncertain'});await tx.put(V2+'halted',true);return json({error:'validation_halted'},503);
   }
   await tx.put(k,{...prior,state:'complete',usage:p.usage,conservativeUsageMicroUSD:cost});if(await tx.get(V2+'inflight:'+p.userHash)===p.requestID)await tx.put(V2+'inflight:'+p.userHash,null);
   return json({...await view(tx,reconcileLegacy),requestReservedMicroUSD:prior.reservedMicroUSD,conservativeUsageMicroUSD:cost});
  });
  // Optional diagnostics are a separate transaction AFTER verified settlement.
  // Failure can lose diagnostic evidence, never change charges or the successful answer.
  if(outcome.ok&&path==='/complete-v2'&&validLookupDiagnostic(p.publicDiagnostic)){
   try{await storage.transaction(async tx=>{
    const record=await tx.get(V2+'request:'+p.requestID);
    if(record?.state!=='complete'||record.userHash!==p.userHash||!Object.hasOwn(PUBLIC_PROFILES,record.profile))return;
    const history=await publicDiagnostics(tx);
    await tx.put(V2+'public-diagnostics',[...history.slice(-2),{requestID:p.requestID,...p.publicDiagnostic}]);
   })}catch{}
  }
  return outcome;
 }catch{return json({error:'accounting_unavailable'},503)}
}
