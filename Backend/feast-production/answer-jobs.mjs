import {ANSWER_JOBS as LIMIT,answerJobsEnabled,jobUUID,jobHash,jobStep,jobKey,jobDigest,canonicalJSON} from './answer-job-contract.mjs';
import {validNativePayload,nativeRequestModel,nativeContinuation,NATIVE_RESEARCH} from './native-research.mjs';
import {nativeConversationAnswer,decodeNativeResult,verifiedNativeUsage} from './native-conversation.mjs';
import {nativeAccountingAdapter} from './native-accounting.mjs';
import {phoneStore,accessJSON} from './phone-access.mjs';
import {boundedResponse} from '../feast-proxy/openai.mjs';
import {providerFailure,knownProviderRejection} from './provider-errors.mjs';
const META='job:',BLOB='content:';
const json=(v,status=200)=>Response.json(v,{status,headers:{'Cache-Control':'no-store'}});
const terminal=s=>['completed','failed','uncertain','cancelled','expired','acknowledged'].includes(s);
const safeError=e=>/^[a-z_]{1,100}$/.test(e?.message??'')?e.message:'answer_job_unavailable';
const stopped=j=>j.cancelled||j.expired||j.acknowledged;
const undispatched=message=>Object.assign(Error(message),{providerNotDispatched:true});
const sameKeys=(v,keys)=>v&&typeof v==='object'&&!Array.isArray(v)&&Object.keys(v).sort().join(',')===keys.slice().sort().join(',');

// A hashed device credential is sufficient to recheck current grants, but is not
// accepted as a public bearer credential and is never logged or returned.
async function authenticate(env,credentialHash,userHash){
 if(!jobHash(credentialHash)||!jobHash(userHash))return false;
 const r=await phoneStore(env).fetch(new Request('https://access/phone-access/authenticate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({credentialHash})}));
 if(r.status===401)return false;if(!r.ok)throw Error('access_unavailable');
 return (await r.json()).userHash===userHash;
}
export async function answerJobsRequest(command,actor,credentialHash,env){
 if(!env.ANSWER_JOBS||command?.op==='submit'&&!answerJobsEnabled(env))return json({error:'answer_jobs_disabled'},503);
 return env.ANSWER_JOBS.get(env.ANSWER_JOBS.idFromName('answer-jobs-v1:'+actor.userHash)).fetch(new Request('https://jobs/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({command,userHash:actor.userHash,credentialHash})}));
}

// One object per authenticated grant. No public client can select the object or
// supply an actor hash. All mutations use storage transactions; provider work
// runs outside transactions, behind a persisted dispatch fence.
export class AnswerJobs {
 constructor(state,env,dependencies={}){this.state=state;this.storage=state.storage;this.env=env;this.send=dependencies.send??((...args)=>fetch(...args));this.now=dependencies.now??Date.now;this.foregroundWaitMs=dependencies.foregroundWaitMs??LIMIT.foregroundWaitMs;this.running=null;this.waiters=new Map()}
 async blob(tx,key,name,value){
  const prefix=BLOB+key+':'+name+':',old=await tx.list({prefix});
  for(const k of old.keys())await tx.delete(k);
  if(value===undefined)return;
  const text=JSON.stringify(value);if(new TextEncoder().encode(text).length>LIMIT.maxBlobBytes)throw Error('answer_job_content_limit');
  // A DO value is limited to 128 KiB. UTF-16 chunks stay below that even for
  // worst-case JSON escaping, and the transaction prevents partial readers.
  for(let i=0;i<text.length;i+=LIMIT.chunkUnits)await tx.put(prefix+String(i/LIMIT.chunkUnits).padStart(3,'0'),text.slice(i,i+LIMIT.chunkUnits));
 }
 async readBlob(tx,key,name){const parts=await tx.list({prefix:BLOB+key+':'+name+':'});return parts.size?JSON.parse([...parts.values()].join('')):undefined}
 async eraseContent(tx,key){for(const k of (await tx.list({prefix:BLOB+key+':'})).keys())await tx.delete(k)}
 async mutate(key,fn){return this.storage.transaction(async tx=>{const j=await tx.get(META+key);if(!j)throw Error('answer_job_missing');await fn(j,tx);await tx.put(META+key,j);return j})}
 async read(key){return this.storage.transaction(tx=>tx.get(META+key))}
 async wake(tx,at){const previous=await tx.getAlarm();if(previous===null||previous>at)await tx.setAlarm(at)}
 async list(){return this.storage.transaction(async tx=>[...(await tx.list({prefix:META,limit:LIMIT.maxJobs+1})).values()])}
 async view(j,longPollTimedOut=false){
  if(this.now()>=j.expiresAt&&!j.expired){
   await this.mutate(j.key,async(x,tx)=>{x.expired=true;x.needsFence=true;await this.wake(tx,this.now()+1)});
   j=await this.retireContent(j.key);this.notify(j.key);
  }
  const state=j.cancelled?'cancelled':j.expired?'expired':j.acknowledged?'acknowledged':j.state;
  const out={version:1,requestID:j.requestID,step:j.step,state,expiresAt:j.expiresAt};
  if(state==='completed')out.result=await this.storage.transaction(tx=>this.readBlob(tx,j.key,'reply'));
  if(['failed','uncertain'].includes(state))out.error=j.error??(state==='uncertain'?'answer_job_uncertain':'answer_job_failed');
  if(!terminal(state))out.retryAfterMs=longPollTimedOut?LIMIT.longPollRetryMs:LIMIT.retryMs;
  return json(out);
 }
 async fetch(request){
  try{
   if(request.method!=='POST'||new URL(request.url).pathname!=='/command')return json({error:'not_found'},404);
   const p=await accessJSON(request,LIMIT.maxPayloadBytes+2048),c=p?.command;
   if(!sameKeys(p,['command','userHash','credentialHash'])||!await authenticate(this.env,p.credentialHash,p.userHash))return json({error:'unauthorized'},401);
   if(!c||c.version!==1||!['submit','status','cancel','ack'].includes(c.op))return json({error:'invalid_answer_job'},400);
   if(c.op==='submit'){
    if(!answerJobsEnabled(this.env))return json({error:'answer_jobs_disabled'},503);
    if(!sameKeys(c,['version','op','request'])||!validNativePayload(c.request)||new TextEncoder().encode(JSON.stringify(c.request)).length>LIMIT.maxPayloadBytes)return json({error:'invalid_answer_job'},400);
    const payload=c.request,model=nativeRequestModel(payload);await nativeContinuation(payload,model);
    const key=jobKey(payload.requestID,payload.step),digest=await jobDigest(payload),now=this.now();
    const accepted=await this.storage.transaction(async tx=>{
     const prior=await tx.get(META+key);
     if(prior){if(prior.userHash!==p.userHash)return json({error:'unauthorized'},401);if(prior.digest&&prior.digest!==digest)return json({error:'answer_job_conflict'},409);return prior}
     const jobs=[...(await tx.list({prefix:META,limit:LIMIT.maxJobs+1})).values()];
     if(jobs.length>=LIMIT.maxJobs||jobs.filter(j=>j.hasContent).length>=LIMIT.maxContentJobs||jobs.filter(j=>!terminal(j.state)&&!stopped(j)).length>=LIMIT.maxActive)return json({error:'answer_job_capacity'},429);
     const j={key,requestID:payload.requestID,step:payload.step,turnID:payload.turnID,userHash:p.userHash,credentialHash:p.credentialHash,digest,recoveryKey:await jobDigest({userHash:p.userHash,key,digest}),model,state:'queued',phase:'accepted',createdAt:now,expiresAt:now+LIMIT.contentTTL,purgeAt:now+LIMIT.tombstoneTTL,hasContent:true};
     await this.blob(tx,key,'payload',payload);await tx.put(META+key,j);
     // Acceptance and its independent wake-up commit atomically BEFORE the
     // acknowledgment. A lost HTTP response cannot lose or duplicate this job.
     await this.wake(tx,now+1);return j;
    });
    if(accepted instanceof Response)return accepted;
    // Foreground requests only wait for the independently scheduled alarm.
    // Paid work never belongs to an HTTP lifetime or a waitUntil extension.
    const longPollTimedOut=await this.waitFor(accepted.key);
    if(!await authenticate(this.env,p.credentialHash,p.userHash))return json({error:'unauthorized'},401);
    return this.view(await this.read(accepted.key),longPollTimedOut);
   }
   if(!sameKeys(c,['version','op','requestID','step'])||!jobUUID(c.requestID)||!jobStep(c.step))return json({error:'invalid_answer_job'},400);
   const key=jobKey(c.requestID,c.step),now=this.now();
   let j=await this.storage.transaction(async tx=>{
    let j=await tx.get(META+key);
    if(!j){
     if(c.op!=='cancel')return null;
     if((await tx.list({prefix:META,limit:LIMIT.maxJobs+1})).size>=LIMIT.maxJobs)return json({error:'answer_job_capacity'},429);
     // Stop may arrive before a delayed submit. Retain a tombstone so that the
     // delayed submit cannot start work the user already cancelled.
     j={key,requestID:c.requestID,turnID:c.requestID,step:c.step,userHash:p.userHash,credentialHash:p.credentialHash,digest:null,state:'cancelled',phase:'done',cancelled:true,createdAt:now,expiresAt:now+LIMIT.contentTTL,purgeAt:now+LIMIT.tombstoneTTL,needsFence:true};
    }
    if(j.userHash!==p.userHash)return json({error:'unauthorized'},401);
    if(now>=j.expiresAt){j.expired=true;j.needsFence=true}
    if(c.op==='cancel'){j.cancelled=true;j.needsFence=true}
    if(c.op==='ack'){
     if(!terminal(j.state)&&!stopped(j))return json({error:'answer_job_not_complete'},409);
     j.acknowledged=true;
    }
    if(stopped(j)&&j.phase==='done'){await this.eraseContent(tx,key);j.hasContent=false}
    await tx.put(META+key,j);await this.wake(tx,now+1);return j;
   });
   if(j instanceof Response)return j;if(!j)return json({error:'answer_job_not_found'},404);
   if(c.op==='cancel'||c.op==='ack')this.notify(key);
   const longPollTimedOut=c.op==='status'?await this.waitFor(key):false;
   if(!await authenticate(this.env,p.credentialHash,p.userHash))return json({error:'unauthorized'},401);
   return this.view(await this.read(key),longPollTimedOut);
  }catch{return json({error:'answer_job_unavailable'},503)}
 }
 notify(key){for(const wake of this.waiters.get(key)??[])wake();this.waiters.delete(key)}
 async waitFor(key){
  if(this.foregroundWaitMs<=0)return false;
  let wake,timer;const changed=new Promise(resolve=>{wake=()=>resolve(false)});
  const waiters=this.waiters.get(key)??new Set();waiters.add(wake);this.waiters.set(key,waiters);
  try{
   // Subscribe before any await: an alarm may complete while the state read is
   // in flight, so even a stale nonterminal read must not lose its wake-up.
   const j=await this.read(key);if(!j||terminal(j.state)||stopped(j))return false;
   // Only a fully elapsed long-poll earns the short renewal delay. Early
   // notifications/runner failures retain backoff and cannot create a hot loop.
   return await Promise.race([changed,...this.running?[this.running.then(()=>false,()=>false)]:[],new Promise(resolve=>{timer=setTimeout(()=>resolve(true),this.foregroundWaitMs)})]);
  }finally{
   clearTimeout(timer);waiters.delete(wake);
   // notify() removes this set. Do not erase a newer subscriber set created
   // under the same job key before this waiter's finally block runs.
   if(!waiters.size&&this.waiters.get(key)===waiters)this.waiters.delete(key);
  }
 }
 async alarm(){await this.drain()}
 async close(j){
  const ledger=this.env.PRODUCTION_STATE.get(this.env.PRODUCTION_STATE.idFromName('production-validation-v1'));
  const r=await ledger.fetch(new Request('https://ledger/native-close-v2',{method:'POST',body:JSON.stringify({userHash:j.userHash,root:j.requestID,turnID:j.turnID,step:j.step})}));
  if(!r.ok)throw Error('answer_job_fence_unavailable');
 }
 async schedule(){
  await this.storage.transaction(async tx=>{
   const jobs=[...(await tx.list({prefix:META,limit:LIMIT.maxJobs+1})).values()],now=this.now();
   if(!jobs.length){await tx.deleteAlarm();return}
   const next=Math.min(...jobs.map(j=>j.phase!=='done'||j.needsFence?now+LIMIT.retryMs:Math.min(j.expired||j.acknowledged||j.cancelled?Infinity:j.expiresAt,j.purgeAt)));
   await tx.setAlarm(Math.max(now+1,next));
  });
 }
 async sweep(){
  for(let j of await this.list()){
   if(this.now()>=j.expiresAt&&!j.expired)j=await this.mutate(j.key,async x=>{x.expired=true;x.needsFence=true});
   if(this.now()>=j.purgeAt&&!j.fenced)j=await this.mutate(j.key,async x=>{x.needsFence=true});
   // Content expiry is independent of the accounting service. Do not retain a
   // private prompt/result because fencing or settlement is temporarily down.
   if(stopped(j))j=await this.retireContent(j.key);
   if(j.needsFence){try{await this.close(j);j=await this.mutate(j.key,async x=>{x.needsFence=false;x.fenced=true})}catch{/* Keep only the compact fence and accounting intent for retry. */}}
   if(this.now()>=j.purgeAt&&j.fenced&&j.phase==='done')await this.storage.transaction(async tx=>{await this.eraseContent(tx,j.key);await tx.delete(META+j.key)});
  }
 }
 async retireContent(key){
  return this.mutate(key,async(j,tx)=>{
   if(j.phase==='received'&&!j.settlement){
    const receipt=await this.readBlob(tx,key,'provider');let kind='uncertain',value=null;
    try{
     const r=new Response(receipt.text,{status:receipt.status,headers:{'Content-Type':'application/json'}});
     if(!r.ok){const error=await providerFailure(r,'provider');if(knownProviderRejection(error)){kind='rejected';value=error.diagnostic}}
     else{const bill=verifiedNativeUsage(JSON.parse(receipt.text),j.model,j.reservation.maxWebActions);if(bill){kind='complete';value={...bill,frameDigest:null,closed:true}}}
    }catch{/* Unknown receipt keeps its existing exposure; never fabricate usage. */}
    j.settlement={kind,value};j.phase='settling';j.replyReady=false;
   }
   if(!j.reservation&&!j.reserveIntent){j.phase='done';j.state=j.cancelled?'cancelled':j.acknowledged?'acknowledged':'expired'}
   await this.eraseContent(tx,key);j.hasContent=false;
  });
 }
 async drain(){
  if(this.running)return this.running;
  this.running=(async()=>{
   // A crash during a provider request must wake later even when an alarm is
   // the caller. Recovered dispatched work is NEVER blindly resubmitted.
   await this.storage.setAlarm(this.now()+LIMIT.watchdogMs);
   try{await this.sweep();for(const j of (await this.list()).filter(x=>x.phase!=='done').sort((a,b)=>a.createdAt-b.createdAt).slice(0,LIMIT.maxActive))await this.run(j.key)}
   finally{await this.schedule()}
  })();
  try{return await this.running}finally{this.running=null}
 }
 async settle(key,kind,value){
  let j=await this.mutate(key,async x=>{
   const settlement={kind,value:value??null};
   if(x.settlement&&canonicalJSON(x.settlement)!==canonicalJSON(settlement))throw Error('answer_job_settlement_conflict');
   x.settlement=settlement;x.phase='settling';
  });
  if(j.settled)return {};
  const a=nativeAccountingAdapter(this.env,j.model),budget=await a[kind](j.reservation,value);
  await this.mutate(key,async x=>{x.settled=true});return budget;
 }
 async finish(key,state,error){
  const result=await this.mutate(key,async(j,tx)=>{
   if(j.settlement&&!j.settled)throw Error('answer_job_settlement_pending');
   j.state=state;j.phase='done';if(error)j.error=error;
   // Keep only the delivered reply and compact dedup/accounting metadata.
   await this.blob(tx,key,'payload',undefined);await this.blob(tx,key,'provider',undefined);
   delete j.count;delete j.allocation;delete j.reservation;delete j.reserveIntent;delete j.settlement;
   if(stopped(j)||state!=='completed'){await this.blob(tx,key,'reply',undefined);j.hasContent=false}
  });this.notify(key);return result;
 }
 async run(key){
  let j=await this.read(key);if(!j||j.phase==='done')return;
  // A reservation RPC can commit even if its response is lost. Recover that
  // exact reservation before deciding whether there is anything to settle.
  if(j.reserveIntent&&!j.reservation){
   try{const reservation=await nativeAccountingAdapter(this.env,j.model).reserve(j.reserveIntent);j=await this.mutate(key,async x=>{x.reservation=reservation;x.phase='reserved'})}
   catch(error){if(error.accountingStatus>=400&&error.accountingStatus<500){await this.mutate(key,async x=>{delete x.reserveIntent});return this.finish(key,'failed',safeError(error))}throw error}
  }
  if(j.settlement){await this.settle(key,j.settlement.kind,j.settlement.value);return this.finish(key,j.settlement.kind==='uncertain'?'uncertain':j.replyReady?'completed':'failed',j.error)}
  if(j.phase==='dispatched'){
   // The provider may have charged, but no durable receipt exists. Preserve
   // exposure and stop. Neither a restart nor a status request retries it.
   await this.settle(key,'uncertain');return this.finish(key,'uncertain','answer_job_uncertain');
  }
  if(stopped(j)&&!j.reservation)return this.finish(key,j.cancelled?'cancelled':'expired');
  if(stopped(j)&&j.phase!=='received'){
   await this.settle(key,'cancelUndispatched');return this.finish(key,j.cancelled?'cancelled':'expired');
  }
  const payload=await this.storage.transaction(tx=>this.readBlob(tx,key,'payload'));
  if(!payload)throw Error('answer_job_missing_payload');
  if(j.phase==='received')return this.resumeReceipt(j,payload);
  if(!answerJobsEnabled(this.env)||!await authenticate(this.env,j.credentialHash,j.userHash)){
   if(j.reservation)await this.settle(key,'cancelUndispatched');
   return this.finish(key,'failed','answer_job_access_changed');
  }
  await this.mutate(key,async x=>{x.state='running';if(x.phase==='accepted')x.phase='preparing'});
  const base=nativeAccountingAdapter(this.env,j.model),accounting={policy:base.policy};
  accounting.prepare=async p=>{
   const current=await this.read(key);if(current.allocation)return current.allocation;
   const allocation=await base.prepare(p);await this.mutate(key,async x=>{x.allocation=allocation});return allocation;
  };
  accounting.reserve=async p=>{
   const current=await this.read(key);if(current.reservation)return current.reservation;
   if(stopped(current))throw undispatched('answer_job_cancelled');
   const intent={...p,recoveryKey:current.recoveryKey};await this.mutate(key,async x=>{x.reserveIntent=intent;x.phase='reserving'});
   let reservation;
   try{reservation=await base.reserve(intent)}catch(error){if(error.accountingStatus>=400&&error.accountingStatus<500)await this.mutate(key,async x=>{delete x.reserveIntent});throw error}
   await this.mutate(key,async x=>{x.reservation=reservation;x.phase='reserved'});return reservation;
  };
  for(const method of ['complete','rejected','cancelUndispatched','uncertain'])accounting[method]=(_r,value)=>this.settle(key,method,value);
  const send=async(url,options)=>{
   let current=await this.read(key);
   if(url.endsWith('/input_tokens')){
    if(current.count)return Response.json(current.count);
    if(stopped(current))throw undispatched('answer_job_cancelled');
    const r=await this.send(url,options);if(!r.ok)return r;
    const raw=await boundedResponse(r),count={input_tokens:raw.input_tokens};await this.mutate(key,async x=>{x.count=count});return Response.json(count);
   }
   if(url!=='https://api.openai.com/v1/responses')throw undispatched('answer_job_provider_route');
   const cached=await this.storage.transaction(tx=>this.readBlob(tx,key,'provider'));
   if(cached)return new Response(cached.text,{status:cached.status,headers:{'Content-Type':'application/json'}});
   if(stopped(current)||!answerJobsEnabled(this.env)||!await authenticate(this.env,current.credentialHash,current.userHash))throw undispatched('answer_job_access_changed');
   await this.mutate(key,async x=>{if(stopped(x)||x.phase==='dispatched')throw undispatched('answer_job_cancelled');x.phase='dispatched'});
   const response=await this.send(url,options);
   // Preserve exactly the bounded response that the native decoder sees before
   // accounting, parsing, acknowledgment or result delivery can occur.
   const reader=response.body?.getReader();if(!reader)throw Error('upstream');let size=0,chunks=[];
   for(;;){const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>65536){await reader.cancel();throw Error('upstream_limit')}chunks.push(part.value)}
   const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length}
   const receipt={status:response.status,text:new TextDecoder().decode(bytes)};
   await this.mutate(key,async(x,tx)=>{await this.blob(tx,key,'provider',receipt);x.phase='received';x.observedAt=new Date(this.now()).toISOString()});
   return new Response(receipt.text,{status:receipt.status,headers:{'Content-Type':'application/json'}});
  };
  const recovery={
   ready:(reply,bill)=>this.ready(key,reply,bill),
   failed:async error=>{await this.mutate(key,async x=>{x.error=safeError(error)})}
  };
  const response=await nativeConversationAnswer(payload,j.userHash,this.env,send,{accounting,recovery,initialModel:j.model,observedAt:j.observedAt});
  j=await this.read(key);
  if(j.reserveIntent&&!j.reservation)throw Error('answer_job_reservation_pending');
  if(j.settlement&&!j.settled)throw Error('answer_job_settlement_pending');
  if(response.ok&&j.replyReady){
   const final=await response.json();delete final.budget;
   await this.mutate(key,async(x,tx)=>{if(!stopped(x))await this.blob(tx,key,'reply',final)});
   return this.finish(key,'completed');
  }
  if(j.settlement?.kind==='uncertain')return this.finish(key,'uncertain',j.error??'answer_job_uncertain');
  return this.finish(key,'failed',j.error??'answer_job_failed');
 }
 async ready(key,reply,bill){
  if(new TextEncoder().encode(JSON.stringify(reply)).length>NATIVE_RESEARCH.maxReplyBytes)throw Error('native_reply_limit');
  await this.mutate(key,async(x,tx)=>{if(!stopped(x))await this.blob(tx,key,'reply',reply);x.replyReady=!stopped(x);x.settlement={kind:'complete',value:bill};x.phase='settling'});
 }
 async resumeReceipt(j,payload){
  // Pure processing of a saved receipt, including after revocation/rollback.
  // This method has NO provider transport and cannot create another charge.
  let verifiedBill=null;
  try{
   const receipt=await this.storage.transaction(tx=>this.readBlob(tx,j.key,'provider'));
   if(!receipt)throw Error('answer_job_missing_receipt');
   const response=new Response(receipt.text,{status:receipt.status,headers:{'Content-Type':'application/json'}});
   if(!response.ok)throw await providerFailure(response,'provider');
   const state=await nativeContinuation(payload,j.model);
   state.privateLatched ||= j.allocation.privateLatched===true;
   state.webAllowed=j.reservation.webAllowed;state.allowedWebActions=j.reservation.maxWebActions;
   const {reply,bill}=await decodeNativeResult(payload,state,JSON.parse(receipt.text),{observedAt:j.observedAt,onVerifiedUsage:bill=>{verifiedBill=bill}});
   await this.ready(j.key,reply,bill);await this.settle(j.key,'complete',bill);
   return this.finish(j.key,'completed');
  }catch(error){
   const current=await this.read(j.key);if(current.settlement)throw error;
   await this.mutate(j.key,async x=>{x.error=safeError(error)});
   if(verifiedBill)await this.settle(j.key,'complete',{...verifiedBill,frameDigest:null,closed:true});
   else if(knownProviderRejection(error))await this.settle(j.key,'rejected',error.diagnostic);
   else await this.settle(j.key,'uncertain');
   return this.finish(j.key,verifiedBill||knownProviderRejection(error)?'failed':'uncertain',safeError(error));
  }
 }
}
