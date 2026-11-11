// Compatibility envelope for the original saved-place broker. One historical
// aggregate hold; an independently one-shot claim for every provider body.
import {V2,EXECUTION,LEGACY_EXECUTION,executionEnabled,executionIdentityMatches,requireExecutionCutover,readExecution,createExecution,activeExecutionCount,expireExecution,uncertainExecution,closeExecution} from './execution-lifecycle.mjs';
import {jobDigest,jobHash,jobUUID} from './answer-job-contract.mjs';
import {attemptOwnership} from './attempt-ownership.mjs';
import {knownProviderRejection} from './provider-errors.mjs';
const json=(x,status=200)=>Response.json(x,{status});
async function activeInflight(tx,prefix,userHash){const id=await tx.get(prefix+'inflight:'+userHash);if(!id)return false;const compatibility=await tx.get(LEGACY_EXECUTION+prefix+'request:'+id);return !(compatibility?.classification==='attributed-uncertain'&&compatibility.userHash===userHash)}
export async function executionDirectFetch(storage,path,p,env,now,view,usageCost){
 if(!['/reserve-v2','/claim-v2','/complete-v2','/uncertain-v2','/cancel-undispatched-v2'].includes(path))return null;
 return storage.transaction(async tx=>{
  const key=V2+'request:'+p.requestID;let record=await tx.get(key),x=await readExecution(tx,p.requestID,record);
  if(x&&x.protocol!=='direct')return null;
  if(!x&&!(path==='/reserve-v2'&&executionEnabled(env)&&p.profile==='saved'))return null;
  const current=await view(tx);
  if(path==='/reserve-v2'){
   if(x){if(x.reservationDigest!==await jobDigest(p))return json({error:'execution_reservation_conflict'},409);return json({...current,requestID:p.requestID,reservedMicroUSD:x.originalHoldMicroUSD,executionVersion:1,executionDigest:x.reservationDigest,dispatchGranted:false,childClaims:true})}
   await requireExecutionCutover(tx);
   if(!jobUUID(p.requestID)||!jobHash(p.fingerprint)||p.bodyDigest!==p.fingerprint||p.executionProtocol!=='direct'||p.amountMicroUSD!==2500000)return json({error:'execution_intent_required'},400);
   if(current.halted)return json({error:'validation_halted'},503);
   const ownership=await attemptOwnership(tx,p.requestID,p.userHash);
   if(!ownership.owned)return json({error:'execution_identity'},403);
   if(record||ownership.accounting.length||await tx.get(V2+'stage-root:'+p.requestID)||await tx.get(V2+'native-root:'+p.requestID.toLowerCase()))return json({error:'already_reserved'},409);
   if(await tx.get(V2+'closed-root:'+p.requestID.toLowerCase()))return json({error:'attempt_closed'},409);
   if(await tx.get(V2+'direct-inflight:v1:'+p.userHash)||await activeInflight(tx,V2,p.userHash)||await activeInflight(tx,'production-validation-v1:',p.userHash)||await activeExecutionCount(tx)>=4)return json({error:'request_in_progress'},429);
   if(!Number.isSafeInteger(current.reservedMicroUSD+p.amountMicroUSD))return json({error:'accounting_unavailable'},503);
   record={userHash:p.userHash,fingerprint:p.fingerprint,profile:'saved',reservedMicroUSD:2500000,state:'pending',rootRequestID:p.requestID,stageIndex:0,executionVersion:1};await tx.put(key,record);
   x=await createExecution(tx,{requestID:p.requestID,protocol:'direct',record,intent:p,allocation:{maxCalls:3,maxOutputTotal:16384,hold:2500000},now});
   await tx.put(V2+'direct-inflight:v1:'+p.userHash,p.requestID);await tx.put(V2+'adopted',true);
   return json({...await view(tx),requestID:p.requestID,reservedMicroUSD:2500000,executionVersion:1,executionDigest:x.reservationDigest,dispatchGranted:false,childClaims:true});
  }
  if(x.userHash!==p.userHash)return json({error:'execution_identity'},403);
  if(!await executionIdentityMatches(x,p))return json({error:'execution_identity_required'},409);
  x=await expireExecution(tx,x,record,now);record=await tx.get(key);
  if(path==='/claim-v2'){
   if(!executionEnabled(env)||current.halted)return json({error:'execution_admission_disabled'},503);
   if(!['reserved','claimed'].includes(x.phase)||await tx.get(V2+'closed-root:'+x.root.toLowerCase())||p.callIndex!==x.claims.length||p.callIndex>=3||!jobHash(p.providerBodyDigest)||!Array.isArray(p.priorUsage)||p.priorUsage.length!==p.callIndex)return json({error:'execution_child_claim_denied'},409);
   try{if(p.priorUsage.length)usageCost(p.priorUsage,'saved')}catch{return json({error:'execution_prior_usage_unverified'},409)}
   for(const claim of x.claims)if(await jobDigest(p.priorUsage.slice(0,claim.index))!==claim.priorUsageDigest)return json({error:'execution_prior_usage_conflict'},409);
   const claim={index:p.callIndex,providerBodyDigest:p.providerBodyDigest,priorUsageDigest:await jobDigest(p.priorUsage),claimedAt:now};
   await tx.put(EXECUTION+x.requestID,{...x,phase:'claimed',claimedAt:x.claimedAt??now,claims:[...x.claims,claim],revision:x.revision+1});
   return json({executionVersion:1,requestID:x.requestID,callIndex:p.callIndex,dispatchGranted:true});
  }
  const settlement=await jobDigest({path,usage:p.usage??null,providerRejectedStatus:p.providerRejectedStatus??null,providerRejectedCode:p.providerRejectedCode??null});
  if(x.settlementDigest){if(x.settlementDigest!==settlement)return json({error:'execution_settlement_conflict'},409);return json({...current,requestReservedMicroUSD:x.originalHoldMicroUSD,conservativeUsageMicroUSD:record.conservativeUsageMicroUSD})}
  if(path==='/uncertain-v2'){await uncertainExecution(tx,x,record);return json({...await view(tx),requestReservedMicroUSD:x.originalHoldMicroUSD})}
  let state,cost=0,fields={};const diagnostic={providerStatus:p.providerRejectedStatus,providerCode:p.providerRejectedCode},rejected=knownProviderRejection({diagnostic}),usage=p.usage??[];
  if(path==='/cancel-undispatched-v2'){
   if(x.claims.length)return json({error:'execution_dispatch_claim_exists'},409);state='cancelled';fields={undispatched:true};
  }else{
   if(!Array.isArray(usage)||!x.claims.length||usage.length!==x.claims.length-(rejected?1:0))return json({error:'execution_usage_unverified'},409);
   for(const claim of x.claims)if(await jobDigest(usage.slice(0,claim.index))!==claim.priorUsageDigest)return json({error:'execution_prior_usage_conflict'},409);
   if(usage.length){try{cost=usageCost(usage,'saved')}catch{await uncertainExecution(tx,x,record);return json({error:'execution_usage_unverified'},409)}state='complete';fields={usage,...(rejected?diagnostic:{})}}
   else{state='rejected';fields=diagnostic}
  }
  if(state!=='complete'||rejected||x.terminalReason||await tx.get(V2+'closed-root:'+x.root.toLowerCase()))x=await closeExecution(tx,x,state==='cancelled'?'cancelled':rejected?'rejected':'stopped');
  await tx.put(key,{...record,state,...fields,conservativeUsageMicroUSD:cost});await tx.put(EXECUTION+x.requestID,{...x,phase:'settled',settlementDigest:settlement,revision:x.revision+1});
  if(await tx.get(V2+'direct-inflight:v1:'+p.userHash)===p.requestID)await tx.put(V2+'direct-inflight:v1:'+p.userHash,null);
  return json({...await view(tx),requestReservedMicroUSD:x.originalHoldMicroUSD,conservativeUsageMicroUSD:cost});
 });
}
