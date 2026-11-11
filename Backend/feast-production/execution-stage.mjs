import {V2,EXECUTION,executionIdentityMatches,requireExecutionCutover,executionEnabled,readExecution,createExecution,activeExecutionCount,claimExecution,expireExecution,uncertainExecution,closeExecution} from './execution-lifecycle.mjs';
import {jobDigest,jobHash,jobUUID,jobStep} from './answer-job-contract.mjs';
import {attemptOwnership} from './attempt-ownership.mjs';
import {stageID} from './stage-accounting.mjs';
import {STAGE_POLICY,STAGE_HOLDS} from './stage-policy.mjs';
import {knownProviderRejection} from './provider-errors.mjs';
const json=(x,status=200)=>Response.json(x,{status});
export async function executionStageFetch(storage,path,p,env,now,view,usageCost){
 if(!['/reserve-v2','/claim-v2','/complete-v2','/uncertain-v2','/cancel-undispatched-v2'].includes(path))return null;
 return storage.transaction(async tx=>{
  const key=V2+'request:'+p.requestID;let record=await tx.get(key),x=await readExecution(tx,p.requestID,record);
  if(x&&x.protocol!=='stage')return null;
  if(!x&&!(executionEnabled(env)&&path==='/reserve-v2'&&Object.hasOwn(STAGE_POLICY,p.profile)))return path==='/claim-v2'?json({error:'execution_claim_missing'},409):null;
  const current=await view(tx);
  if(path==='/reserve-v2'){
   if(!jobUUID(p.rootRequestID)||!jobStep(p.stageIndex)||!jobHash(p.fingerprint)||!jobHash(p.bodyDigest)||p.amountMicroUSD!==STAGE_HOLDS[p.profile]||await stageID(p.rootRequestID,p.stageIndex)!==p.requestID)return json({error:'execution_intent_required'},400);
   if(x){if(x.reservationDigest!==await jobDigest(p))return json({error:'execution_reservation_conflict'},409);return json({...current,requestID:p.requestID,reservedMicroUSD:x.originalHoldMicroUSD,executionVersion:1,dispatchGranted:false,executionDigest:x.reservationDigest,deadlineAt:x.deadlineAt})}
   await requireExecutionCutover(tx);
   if(current.halted)return json({error:'validation_halted'},503);
   if(record||await tx.get('production-validation-v1:request:'+p.requestID))return json({error:'already_reserved'},409);
   const ownership=await attemptOwnership(tx,p.rootRequestID,p.userHash);
   if(!ownership.owned)return json({error:'execution_identity'},403);
   if(await tx.get(V2+'closed-root:'+p.rootRequestID.toLowerCase()))return json({error:'attempt_closed'},409);
   const rootKey=V2+'stage-root:'+p.rootRequestID,root=await tx.get(rootKey);
   if(p.stageIndex===0?(root||ownership.accounting.length):(!root||root.userHash!==p.userHash||root.fingerprint!==p.fingerprint||root.nextIndex!==p.stageIndex))return json({error:'stage_order_or_replay'},409);
   if(p.stageIndex>0){const previous=await tx.get(V2+'request:'+await stageID(p.rootRequestID,p.stageIndex-1));if(!previous||previous.state!=='complete')return json({error:'stage_unsettled'},409)}
   if(await activeExecutionCount(tx)>=4)return json({error:'request_in_progress'},429);
   if(!Number.isSafeInteger(current.reservedMicroUSD+p.amountMicroUSD))return json({error:'accounting_unavailable'},503);
   record={userHash:p.userHash,fingerprint:p.fingerprint,profile:p.profile,reservedMicroUSD:p.amountMicroUSD,state:'pending',rootRequestID:p.rootRequestID,stageIndex:p.stageIndex,executionVersion:1};
   await tx.put(key,record);await tx.put(rootKey,{userHash:p.userHash,fingerprint:p.fingerprint,nextIndex:p.stageIndex+1});
   x=await createExecution(tx,{requestID:p.requestID,protocol:'stage',record,intent:p,allocation:{profile:p.profile,amountMicroUSD:p.amountMicroUSD},now});
   await tx.put(V2+'adopted',true);
   await tx.put(V2+'audit:'+p.requestID,{legacyReconciliationEnabled:current.legacyReconciliationEnabled,legacyHistoricalReservedMicroUSD:current.legacyHistoricalReservedMicroUSD,legacyVerifiedUsageMicroUSD:current.legacyVerifiedUsageMicroUSD,legacyUncertainMicroUSD:current.legacyUncertainMicroUSD});
   return json({...await view(tx),requestID:p.requestID,reservedMicroUSD:p.amountMicroUSD,executionVersion:1,dispatchGranted:false,executionDigest:x.reservationDigest,deadlineAt:x.deadlineAt});
  }
  if(x.userHash!==p.userHash)return json({error:'execution_identity'},403);
  if(!await executionIdentityMatches(x,p)||p.bodyDigest!==x.bodyDigest||p.rootRequestID!==x.root||p.stageIndex!==x.stageIndex||p.profile!==x.profile)return json({error:'execution_identity_required'},409);
  if(path==='/claim-v2'){
   if(!executionEnabled(env)||current.halted)return json({error:'validation_halted'},503);
   if(p.rootRequestID!==x.root||p.stageIndex!==x.stageIndex||p.profile!==x.profile||p.fingerprint!==record.fingerprint)return json({error:'execution_claim_identity'},409);
   const grant=await claimExecution(tx,x,record,p,now);return grant?json(grant):json({error:'execution_dispatch_claim_denied'},409);
  }
  const settlement=await jobDigest({path,usage:p.usage??null,providerRejectedStatus:p.providerRejectedStatus??null,providerRejectedCode:p.providerRejectedCode??null});
  if(x.settlementDigest){if(x.settlementDigest!==settlement)return json({error:'execution_settlement_conflict'},409);return json({...current,requestReservedMicroUSD:x.originalHoldMicroUSD,conservativeUsageMicroUSD:record.conservativeUsageMicroUSD})}
  x=await expireExecution(tx,x,record,now);record=await tx.get(key);
  if(path==='/uncertain-v2'){await uncertainExecution(tx,x,record);return json({...await view(tx),requestReservedMicroUSD:x.originalHoldMicroUSD})}
  let cost=0,state,fields={};
  if(path==='/cancel-undispatched-v2'){
   if(x.claimedAt!==null)return json({error:'execution_dispatch_claim_exists'},409);state='cancelled';fields={undispatched:true};
  }else{
   if(x.claimedAt===null)return json({error:'execution_dispatch_claim_missing'},409);
   const diagnostic={providerStatus:p.providerRejectedStatus,providerCode:p.providerRejectedCode};
   if(knownProviderRejection({diagnostic})){state='rejected';fields=diagnostic}
   else{try{cost=usageCost(p.usage,record.profile)}catch{await uncertainExecution(tx,x,record);return json({error:'execution_usage_unverified'},409)}state='complete';fields={usage:p.usage}}
  }
  if(state!=='complete'||x.terminalReason||await tx.get(V2+'closed-root:'+x.root.toLowerCase()))x=await closeExecution(tx,x,state==='cancelled'?'cancelled':state==='rejected'?'rejected':'stopped');
  await tx.put(key,{...record,state,...fields,conservativeUsageMicroUSD:cost});await tx.put(EXECUTION+x.requestID,{...x,phase:'settled',settlementDigest:settlement,revision:x.revision+1});
  if(await tx.get(V2+'inflight:'+p.userHash)===p.requestID)await tx.put(V2+'inflight:'+p.userHash,null);
  return json({...await view(tx),requestReservedMicroUSD:x.originalHoldMicroUSD,conservativeUsageMicroUSD:cost});
 });
}
