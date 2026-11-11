import {historicalRequestID,historicalRootID} from './historical-accounting-identity.mjs';
import {validateRecoveryDisposition} from './answer-jobs-preflight.mjs';
import {rawAccountingStorage,bumpAccountingWriterRevision} from './accounting-index.mjs';
// Offline storage migration only. No HTTP route and no production credentials.
import {accountingView} from './reconciled-accounting.mjs';
import {V2,LEGACY_EXECUTION,entries,validateExecutions,readMigrationPlan} from './execution-lifecycle.mjs';
import {jobDigest,jobHash,jobUUID,jobStep} from './answer-job-contract.mjs';
import {attemptOwnershipBatch} from './attempt-ownership.mjs';
import {stageID} from './stage-accounting.mjs';
const V1='production-validation-v1:';
const unsettled=r=>['pending','uncertain'].includes(r.state);
async function inventory(tx){
 const budget=await accountingView(tx,true),all=[...await entries(tx,V1),...await entries(tx,V2)].sort(([a],[b])=>a<b?-1:a>b?1:0),records=[],halts=[];
 for(const [key,r] of all){
  if(key.startsWith(V1+'request:')||key.startsWith(V2+'request:')){if(!historicalRequestID(key,r)||r.userHash!==undefined&&!jobHash(r.userHash)||r.rootRequestID!==undefined&&!jobUUID(r.rootRequestID)||r.nativeTurnID!==undefined&&!jobUUID(r.nativeTurnID))throw Error('migration_record_identity');records.push({key,digest:await jobDigest(r),state:r.state,profile:r.profile??'legacySavedV1',hold:r.reservedMicroUSD,userHash:r.userHash??null,root:r.rootRequestID??key.slice(key.lastIndexOf(':')+1),turnID:r.nativeTurnID??null,stageIndex:r.stageIndex??null,executionVersion:r.executionVersion??null});}
 }
 for(const prefix of [V1,V2])if(await tx.get(prefix+'halted')===true){const generation=await tx.get(prefix+'halt-generation');halts.push({key:prefix+'halted',generation:generation?.generation??'legacy-unversioned'})}
 return {version:1,revision:await jobDigest(all),budget,records,halts,metadata:all.filter(([key])=>!key.includes(':request:')).map(([key,value])=>({key})),validationFailures:[]};
}
export async function executionInventory(storage){return rawAccountingStorage(storage).transaction(inventory)}
export async function applyExecutionMigration(storage,plan){
 storage=rawAccountingStorage(storage);
 if(!plan||plan.version!==1||!jobHash(plan.revision)||plan.writersQuiesced!==true||!Array.isArray(plan.legacy)||!Array.isArray(plan.halts))throw Error('migration_plan_invalid');
 await validateRecoveryDisposition(plan.recovery);
 const receiptDigest=await jobDigest(plan);
 return storage.transaction(async tx=>{
  const previous=await tx.get(V2+'migration-receipt:'+receiptDigest);
  if(previous){if(!await readMigrationPlan(tx,receiptDigest)||previous.planDigest!==receiptDigest||previous.reviewedRevision!==plan.revision)throw Error('migration_receipt_conflict');await validateExecutions(tx);return previous}
  if(await tx.get('production-validation-v2:accounting-index:v1:pending')||await tx.get('production-validation-v2:accounting-index:v1:state'))throw Error('migration_during_index_cutover');
  const current=await inventory(tx);if(current.revision!==plan.revision)throw Error('migration_revision_conflict');
  if(await tx.get(V2+'execution-cutover:v1'))throw Error('migration_already_applied');
  const needed=current.records.filter(r=>r.executionVersion===null&&unsettled(r));
  if(plan.legacy.length!==needed.length||new Set(plan.legacy.map(x=>x.key)).size!==plan.legacy.length)throw Error('migration_legacy_classification_required');
  const neededByKey=new Map(needed.map(r=>[r.key,r])),owners=new Map();for(const r of needed){if(!jobHash(r.userHash)||!historicalRootID(r.root))throw Error('migration_unattributed_record');const root=r.root.toLowerCase();if(owners.has(root)&&owners.get(root)!==r.userHash)throw Error('migration_owner_conflict');owners.set(root,r.userHash)}const ownership=await attemptOwnershipBatch(tx,[...owners.keys()],owners),classifications=new Map(plan.legacy.map(x=>[x.key,x]));
  for(const item of plan.legacy){
   const r=neededByKey.get(item.key);if(!r||r.digest!==item.recordDigest||!['attributed-uncertain','retain-active'].includes(item.classification))throw Error('migration_legacy_conflict');
   if(!jobHash(r.userHash)||!historicalRootID(r.root))throw Error('migration_unattributed_record');
   if(r.stageIndex!==null&&(!jobStep(r.stageIndex)||await stageID(r.root,r.stageIndex)!==r.key.slice(r.key.lastIndexOf(':')+1)))throw Error('migration_stage_identity');
   if(r.stageIndex!==null&&r.turnID===null){const root=await tx.get(V2+'stage-root:'+r.root),record=await tx.get(r.key);if(!root||root.userHash!==r.userHash||root.fingerprint!==record.fingerprint||!Number.isSafeInteger(root.nextIndex)||root.nextIndex<=r.stageIndex)throw Error('migration_stage_association')}
   if(r.turnID!==null){
    if(!jobUUID(r.turnID))throw Error('migration_turn_identity');
    const root=await tx.get(V2+'native-root:'+r.root),turn=await tx.get(V2+'native-turn:'+r.userHash+':'+r.turnID);
    if(!root||root.userHash!==r.userHash||root.turnID!==r.turnID||!turn||!Number.isSafeInteger(turn.responses)||!Number.isSafeInteger(turn.revision)||typeof turn.privateLatched!=='boolean')throw Error('migration_native_association');
   }
   if(!ownership.get(r.root.toLowerCase())?.owned)throw Error('migration_owner_conflict');
  }
  if(plan.halts.length!==current.halts.length||new Set(plan.halts.map(x=>x.key)).size!==plan.halts.length)throw Error('migration_halt_classification_required');
  for(const h of plan.halts){
   if(!current.halts.some(x=>x.key===h.key&&x.generation===h.generation)||!['unexplained','attributed-uncertainty'].includes(h.classification))throw Error('migration_halt_conflict');
   // Explicit evidence identifiers are reviewed facts, not an inference from the
   // mere existence of a pending row. Every named row must retain its full hold.
   if(h.classification==='attributed-uncertainty'&&(!jobHash(h.evidenceDigest)||!Array.isArray(h.records)||!h.records.length||new Set(h.records).size!==h.records.length||h.records.some(key=>classifications.get(key)?.classification!=='attributed-uncertain')))throw Error('migration_halt_evidence_required');
  }
  for(const item of plan.legacy){
   const r=neededByKey.get(item.key),canonical=await tx.get(r.key),requestID=r.key.slice(r.key.lastIndexOf(':')+1);
   await tx.put(LEGACY_EXECUTION+r.key,{version:1,recordKey:r.key,requestID,recordDigest:r.digest,receiptDigest,classification:item.classification,userHash:r.userHash,root:r.root,turnID:r.turnID,profile:canonical.profile??null,hold:r.hold});
   if(item.classification==='attributed-uncertain'){
    await tx.put(V2+'closed-root:'+r.root.toLowerCase(),{userHash:r.userHash});
    if(r.turnID){const key=V2+'native-turn:'+r.userHash+':'+r.turnID.toLowerCase(),turn=await tx.get(key);if(!turn)throw Error('migration_turn_missing');await tx.put(key,{...turn,closed:true})}
   }
  }
  const encodedPlan=JSON.stringify(plan),planChunks=Math.ceil(encodedPlan.length/24000);
  for(let i=0;i<planChunks;i++)await tx.put(V2+'migration-plan:'+receiptDigest+':'+String(i).padStart(6,'0'),encodedPlan.slice(i*24000,(i+1)*24000));
  const receipt={version:1,planChunks,planDigest:receiptDigest,reviewedRevision:plan.revision,records:plan.legacy.length,halts:plan.halts.length,canonicalBytesUnchanged:true};
  await tx.put(V2+'migration-receipt:'+receiptDigest,receipt);
  for(const h of plan.halts)if(h.classification==='attributed-uncertainty')await tx.put(V2+'halt-ack:'+h.key.slice(0,-6),{generation:h.generation,receiptDigest});
  await tx.put(V2+'execution-cutover:v1',{version:1,receiptDigest,reviewedRevision:plan.revision});
  await bumpAccountingWriterRevision(tx);await validateExecutions(tx);return receipt;
 });
}
