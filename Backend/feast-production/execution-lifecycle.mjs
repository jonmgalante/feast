import {validateRecoveryDisposition} from './answer-jobs-preflight.mjs';
import {attemptOwnership} from './attempt-ownership.mjs';
// Additive execution metadata. Canonical holds remain the accounting authority.
// No provider transport, namespace replacement, balance reset or inferred usage.
import {jobDigest,jobHash,jobUUID,jobStep} from './answer-job-contract.mjs';
export const V2='production-validation-v2:',EXECUTION=V2+'execution:v1:',LEGACY_EXECUTION=V2+'legacy-execution:v1:';
// A 90s provider request plus bounded body/decode and ledger margin. This is a
// capacity deadline, never evidence of cancellation or an upstream billing cap.
export const EXECUTION_WINDOW_MS=300000;
const integer=x=>Number.isSafeInteger(x)&&x>=0;
const INTENT_KEYS=new Set(['requestID','userHash','fingerprint','profile','amountMicroUSD','rootRequestID','stageIndex','bodyDigest','root','turnID','step','model','priorDigest','privateLatched','requestedWebActions','allocationRevision','webAllowed','maxWebActions','maxOutput','recoveryKey','executionProtocol']);
export const executionEnabled=env=>env.EXECUTION_LIFECYCLE_ENABLED==='true';
export async function entries(tx,prefix){const out=[];let startAfter;for(;;){const page=await tx.list({prefix,limit:1000,...(startAfter?{startAfter}:{})});if(!(page instanceof Map))throw Error('accounting_incomplete');if(!page.size)return out;const last=[...page.keys()].at(-1);if(startAfter&&last<=startAfter)throw Error('accounting_incomplete');out.push(...page);if(page.size<1000)return out;startAfter=last}}
export async function readExecution(tx,id,record){
 const x=await tx.get(EXECUTION+id);if(!x){if(record?.executionVersion!==undefined)throw Error('execution_missing');return null}
 if(!x||x.version!==1||x.requestID!==id||!jobUUID(id)||!['native','stage','direct'].includes(x.protocol)||!jobHash(x.userHash)||!jobUUID(x.root)||!jobStep(x.stageIndex)||!(x.turnID===null||jobUUID(x.turnID))||typeof x.profile!=='string'||!integer(x.originalHoldMicroUSD)||!jobHash(x.reservationDigest)||!Array.isArray(x.intentKeys)||!x.intentKeys.length||new Set(x.intentKeys).size!==x.intentKeys.length||x.intentKeys.some(k=>!INTENT_KEYS.has(k))||!jobHash(x.bodyDigest)||!jobHash(x.allocationDigest)||!integer(x.reservedAt)||!integer(x.deadlineAt)||x.deadlineAt!==x.reservedAt+(x.protocol==='direct'?2:1)*EXECUTION_WINDOW_MS||!integer(x.revision)||x.revision<1||!['reserved','claimed','uncertain','settled'].includes(x.phase)||!(x.claimedAt===null||integer(x.claimedAt))||!(x.settlementDigest===null||jobHash(x.settlementDigest))||![null,'deadline','uncertain','cancelled','rejected','stopped'].includes(x.terminalReason))throw Error('execution_corrupt');
 if(!record||record.executionVersion!==1||record.userHash!==x.userHash||record.profile!==x.profile||record.reservedMicroUSD!==x.originalHoldMicroUSD||record.rootRequestID!==x.root||record.stageIndex!==x.stageIndex||(record.nativeTurnID??null)!==x.turnID||x.protocol==='native'!==!!x.turnID)throw Error('execution_record_conflict');
 if(x.phase==='reserved'&&(record.state!=='pending'||x.claimedAt!==null)||x.phase==='claimed'&&(record.state!=='pending'||x.claimedAt===null)||x.phase==='uncertain'&&record.state!=='uncertain'||x.phase==='settled'&&(!['complete','rejected','cancelled'].includes(record.state)||!x.settlementDigest)||x.phase!=='settled'&&x.settlementDigest!==null)throw Error('execution_state_conflict');
 if(x.protocol==='direct'&&(!Array.isArray(x.claims)||x.claims.length>3||x.claims.some((c,i)=>c.index!==i||!jobHash(c.providerBodyDigest)||!jobHash(c.priorUsageDigest)||!integer(c.claimedAt))||x.claims.length===0&&x.claimedAt!==null||x.claims.length>0&&x.claimedAt===null))throw Error('execution_child_claim_corrupt');
 if(x.protocol==='direct'&&['reserved','claimed'].includes(x.phase)&&await tx.get(V2+'direct-inflight:v1:'+x.userHash)!==x.requestID)throw Error('execution_direct_lock_conflict');
 if(x.protocol==='native'){const root=await tx.get(V2+'native-root:'+x.root),turn=await tx.get(V2+'native-turn:'+x.userHash+':'+x.turnID);if(!root||root.userHash!==x.userHash||root.turnID!==x.turnID||root.fingerprint!==record.fingerprint||!integer(root.nextStep)||root.nextStep<=x.stageIndex||root.model!==(x.profile==='astraNativeUsageV1'?'gpt-6-astra':'gpt-6.1-sol')||!turn||!integer(turn.responses)||turn.responses>12||!integer(turn.webActions)||turn.webActions>12||!integer(turn.revision)||typeof turn.privateLatched!=='boolean')throw Error('execution_native_association')}
 if(x.protocol==='stage'){const root=await tx.get(V2+'stage-root:'+x.root);if(!root||root.userHash!==x.userHash||root.fingerprint!==record.fingerprint||!integer(root.nextIndex)||root.nextIndex<=x.stageIndex)throw Error('execution_stage_association')}
 return x;
}
export async function validateExecutions(tx){
 if(tx.accountingIndex){await tx.accountingIndex.validate();return}
 if((await entries(tx,EXECUTION)).length||(await entries(tx,LEGACY_EXECUTION)).length||(await entries(tx,V2+'halt-ack:')).length||await tx.get(V2+'execution-cutover:v1'))await requireExecutionCutover(tx);
 for(const [key,record] of await entries(tx,V2+'request:'))if(record?.executionVersion!==undefined)await readExecution(tx,key.slice((V2+'request:').length),record);
 for(const [key] of await entries(tx,EXECUTION)){const id=key.slice(EXECUTION.length);await readExecution(tx,id,await tx.get(V2+'request:'+id))}
 const migrationItems=new Map();
 for(const [key,m] of await entries(tx,LEGACY_EXECUTION)){
  const r=await tx.get(m?.recordKey);if(!m||!await tx.get(V2+'migration-receipt:'+m.receiptDigest)||m.version!==1||!['attributed-uncertain','retain-active'].includes(m.classification)||!jobHash(m.recordDigest)||!jobHash(m.receiptDigest)||!r||m.recordKey!==key.slice(LEGACY_EXECUTION.length))throw Error('legacy_execution_corrupt');
  // Settlement is permitted to replace a classified pending record, not its
  // owner/root/profile/hold. The classification never proves zero usage.
  let items=migrationItems.get(m.receiptDigest);if(!items){const plan=await readMigrationPlan(tx,m.receiptDigest);items=new Map(plan.legacy.map(item=>[item.key,item]));if(items.size!==plan.legacy.length)throw Error('legacy_execution_receipt_conflict');migrationItems.set(m.receiptDigest,items)}const item=items.get(m.recordKey);if(!item||item.recordDigest!==m.recordDigest||item.classification!==m.classification)throw Error('legacy_execution_receipt_conflict');
  if(r.userHash!==m.userHash||(r.rootRequestID??m.requestID)!==m.root||(r.profile??null)!==m.profile||r.reservedMicroUSD!==m.hold)throw Error('legacy_execution_conflict');
 }
}
export async function activeExecutionCount(tx){if(tx.accountingIndex)return tx.accountingIndex.activeCount();let active=0;for(const [key,r] of await entries(tx,V2+'request:'))if(r.state==='pending'){const m=await tx.get(LEGACY_EXECUTION+key);if(m?.classification!=='attributed-uncertain')active++}return active}
export async function createExecution(tx,{requestID,protocol,record,intent,allocation,now}){
 if(!jobHash(intent.bodyDigest)||!integer(now)||Object.keys(intent).some(k=>!INTENT_KEYS.has(k)))throw Error('execution_intent_required');
 const x={version:1,requestID,protocol,userHash:record.userHash,root:record.rootRequestID,stageIndex:record.stageIndex,turnID:record.nativeTurnID??null,profile:record.profile,originalHoldMicroUSD:record.reservedMicroUSD,reservationDigest:await jobDigest(intent),intentKeys:Object.keys(intent).sort(),bodyDigest:intent.bodyDigest,allocationDigest:await jobDigest(allocation),reservedAt:now,deadlineAt:now+(protocol==='direct'?2:1)*EXECUTION_WINDOW_MS,...(protocol==='direct'?{claims:[]}:{}),phase:'reserved',claimedAt:null,settlementDigest:null,terminalReason:null,revision:1};
 await tx.put(EXECUTION+requestID,x);await tx.put(V2+'execution-adopted:v1',true);const previous=await tx.getAlarm();if(previous===null||previous>x.deadlineAt)await tx.setAlarm(x.deadlineAt);return x;
}
export async function closeExecution(tx,x,reason){
 if(!(await attemptOwnership(tx,x.root,x.userHash)).owned)throw Error('execution_owner_conflict');
 await tx.put(V2+'closed-root:'+x.root.toLowerCase(),{userHash:x.userHash});
 if(x.protocol==='native'){
  const key=V2+'native-root:'+x.root,root=await tx.get(key);if(!root||root.userHash!==x.userHash||root.turnID!==x.turnID)throw Error('execution_root_conflict');
  await tx.put(key,{...root,state:'closed'});
  const turnKey=V2+'native-turn:'+x.userHash+':'+x.turnID,turn=await tx.get(turnKey);if(!turn)throw Error('execution_turn_missing');if(['uncertain','deadline'].includes(x.terminalReason??reason))await tx.put(turnKey,{...turn,closed:true});
 }
 return {...x,terminalReason:x.terminalReason??reason};
}
export async function uncertainExecution(tx,x,record,reason='uncertain'){
 if(x.phase==='settled'||x.phase==='uncertain')return x;
 x=await closeExecution(tx,x,reason);x={...x,phase:'uncertain',revision:x.revision+1};await tx.put(V2+'request:'+x.requestID,{...record,state:'uncertain'});await tx.put(EXECUTION+x.requestID,x);if(x.protocol==='direct'&&await tx.get(V2+'direct-inflight:v1:'+x.userHash)===x.requestID)await tx.put(V2+'direct-inflight:v1:'+x.userHash,null);return x;
}
export async function expireExecution(tx,x,record,now){return x&&['reserved','claimed'].includes(x.phase)&&now>=x.deadlineAt?uncertainExecution(tx,x,record,'deadline'):x}
export async function executionIdentityMatches(x,intent){return intent.executionDigest===x.reservationDigest&&x.intentKeys.every(k=>Object.hasOwn(intent,k))&&await jobDigest(Object.fromEntries(x.intentKeys.map(k=>[k,intent[k]])))===x.reservationDigest}
export async function readMigrationPlan(tx,digest){const receipt=await tx.get(V2+'migration-receipt:'+digest);if(!receipt||receipt.version!==1||receipt.planDigest!==digest||!integer(receipt.planChunks)||receipt.planChunks<1)throw Error('migration_receipt_corrupt');const chunks=await entries(tx,V2+'migration-plan:'+digest+':');if(chunks.length!==receipt.planChunks||chunks.some(([k,v],i)=>k!==V2+'migration-plan:'+digest+':'+String(i).padStart(6,'0')||typeof v!=='string'||v.length>24000))throw Error('migration_receipt_corrupt');const plan=JSON.parse(chunks.map(([,v])=>v).join(''));if(await jobDigest(plan)!==digest||plan.revision!==receipt.reviewedRevision)throw Error('migration_receipt_corrupt');await validateRecoveryDisposition(plan.recovery);return plan}
export async function requireExecutionCutover(tx){if(tx.accountingIndex){await tx.accountingIndex.validate();return}const cutover=await tx.get(V2+'execution-cutover:v1');const receipt=cutover&&await tx.get(V2+'migration-receipt:'+cutover.receiptDigest);if(!cutover||cutover.version!==1||!jobHash(cutover.receiptDigest)||!receipt||receipt.reviewedRevision!==cutover.reviewedRevision||!await readMigrationPlan(tx,cutover.receiptDigest))throw Error('execution_migration_required')}
export async function claimExecution(tx,x,record,intent,now){
 x=await expireExecution(tx,x,record,now);
 if(!x||!await executionIdentityMatches(x,intent)||x.userHash!==intent.userHash||x.bodyDigest!==intent.bodyDigest||x.phase!=='reserved'||x.claimedAt!==null||await tx.get(V2+'closed-root:'+x.root.toLowerCase()))return null;
 const next={...x,phase:'claimed',claimedAt:now,revision:x.revision+1};await tx.put(EXECUTION+x.requestID,next);return {executionVersion:1,requestID:x.requestID,dispatchGranted:true,deadlineAt:x.deadlineAt};
}
export async function executionAlarm(storage,now=Date.now()){
 return storage.transaction(async tx=>{
  await validateExecutions(tx);let earliest=Infinity;
  const ids=tx.accountingIndex?await tx.accountingIndex.activeIDs():(await entries(tx,EXECUTION)).map(([key])=>key.slice(EXECUTION.length));
  for(const id of ids){
   const record=await tx.get(V2+'request:'+id);let x=await readExecution(tx,id,record);x=await expireExecution(tx,x,record,now);if(['reserved','claimed'].includes(x.phase))earliest=Math.min(earliest,x.deadlineAt);
  }
  if(earliest===Infinity)await tx.deleteAlarm();else await tx.setAlarm(earliest);
 });
}
export async function recordGlobalHalt(tx,prefix,reason){
 const key=prefix+'halt-generation',prior=await tx.get(key);if(prior!==undefined&&(!integer(prior.generation)||prior.generation<1))throw Error('halt_generation_corrupt');
 await tx.put(prefix+'halted',true);await tx.put(key,{version:1,generation:(prior?.generation??0)+1,reason});
}
export async function effectiveHalt(tx,prefix){
 const halted=(await tx.get(prefix+'halted'))??false;if(typeof halted!=='boolean')throw Error('accounting_corrupt');if(!halted)return false;
 const generation=await tx.get(prefix+'halt-generation');if(generation!==undefined&&(!integer(generation.generation)||generation.generation<1||generation.version!==1))throw Error('halt_generation_corrupt');
 const ack=await tx.get(V2+'halt-ack:'+prefix);if(!ack)return true;
 if(tx.accountingIndex){if(!await tx.accountingIndex.verifiedAck(prefix,ack))throw Error('halt_ack_corrupt');return ack.generation!==(generation?.generation??'legacy-unversioned')}
 const receipt=await tx.get(V2+'migration-receipt:'+ack.receiptDigest),plan=receipt&&await readMigrationPlan(tx,ack.receiptDigest);
 if(!jobHash(ack.receiptDigest)||!receipt||!plan.halts.some(h=>h.key===prefix+'halted'&&h.generation===ack.generation&&h.classification==='attributed-uncertainty'))throw Error('halt_ack_corrupt');
 return ack.generation!==(generation?.generation??'legacy-unversioned');
}
