import test from 'node:test';import assert from 'node:assert/strict';
import {AnswerJobs} from './answer-jobs.mjs';
import {ANSWER_JOBS,jobKey} from './answer-job-contract.mjs';
import {ProductionLedger} from './production-ledger.mjs';
import {phoneHash,PHONE_OBJECT} from './phone-access.mjs';
import {publicFetch} from './public-handler.mjs';
import {nativeConversationAnswer} from './native-conversation.mjs';

// Transactional fixture with rollback, sorted prefix scans, alarms, and snapshots
// at durable boundaries. External networking is never available in these tests.
class Storage {
 data=new Map();alarm=null;queue=Promise.resolve();onCommit=()=>{};
 transaction(fn){const p=this.queue.then(async()=>{const data=structuredClone(this.data);let alarm=this.alarm;const tx={get:async k=>structuredClone(data.get(k)),put:async(k,v)=>{assert(new TextEncoder().encode(JSON.stringify(v)).length<128*1024,'DO value limit');data.set(k,structuredClone(v))},delete:async k=>data.delete(k),list:async({prefix='',limit=Infinity}={})=>new Map([...data].filter(([k])=>k.startsWith(prefix)).sort(([a],[b])=>a.localeCompare(b)).slice(0,limit)),setAlarm:async n=>{alarm=n},getAlarm:async()=>alarm,deleteAlarm:async()=>{alarm=null}};const result=await fn(tx);this.data=data;this.alarm=alarm;this.onCommit();return result});this.queue=p.catch(()=>{});return p}
 setAlarm(n){return this.transaction(tx=>tx.setAlarm(n))}
}
const payload=()=>({version:10,mode:'conversationStep',requestID:crypto.randomUUID(),turnID:crypto.randomUUID(),step:0,text:'Read public context.',webAllowed:true,context:{index:[],recent:[]},cities:[],task:null,findings:[],history:[],historyCount:0,continuation:null,result:null});
const answer=body=>({status:'completed',model:body.model,usage:{input_tokens:1000,output_tokens:100},output:[{id:'answer',type:'message',role:'assistant',status:'completed',phase:'final_answer',content:[{type:'output_text',text:'A saved, supported answer.',annotations:[]}]}]});
async function setup({fast=false,provider,lifecycle=false}={}){
 const token='t'.repeat(43),invitation='i'.repeat(43),now=Date.now(),grant={id:crypto.randomUUID(),createdAt:now-1000,expiresAt:now+86400000,revoked:false,sha256:await phoneHash('invitation',invitation)};
 const env={ENVIRONMENT:'production',PHONE_ACCESS_ENABLED:'true',PHONE_INVITATIONS_JSON:JSON.stringify([grant]),OWNER_VALIDATION_ENABLED:'true',LIVE_AI:'true',ALLOW_RECONCILED_BUDGET:'true',ALLOW_PUBLIC_LOOKUP:'true',NATIVE_RESEARCH_ENABLED:'true',ASK_FEAST_RECOVERY_ENABLED:'true',OPENAI_API_KEY:'fixture-not-a-key'};
 const access=new Storage(),ledger=new Storage(),jobs=new Storage();
 if(lifecycle){env.EXECUTION_LIFECYCLE_ENABLED='true';const {executionInventory,applyExecutionMigration}=await import('./execution-migration.mjs');const initial=await executionInventory(ledger);await applyExecutionMigration(ledger,{version:1,revision:initial.revision,writersQuiesced:true,recovery:{version:1,kind:'never-enabled',namespace:'answer-jobs-v1',namespaceID:'a'.repeat(32),sourceRevision:'b'.repeat(40),quiescenceRevision:'c'.repeat(64),evidenceDigest:'d'.repeat(64)},legacy:[],halts:[]})}
 const calls={paid:0,count:0,bodies:[]},waits=[];let clock=now,obj;
 env.PRODUCTION_STATE={idFromName:x=>x,get:id=>new ProductionLedger({storage:id===PHONE_OBJECT?access:ledger},env)};
 const send=async(url,options)=>{const body=JSON.parse(options.body);if(url.endsWith('/input_tokens')){calls.count++;return Response.json({input_tokens:100})}assert.equal(url,'https://api.openai.com/v1/responses');calls.paid++;calls.bodies.push(body);return provider?provider(body):Response.json(answer(body))};
 const restart=()=>{obj=new AnswerJobs({storage:jobs},env,{send,now:()=>clock,foregroundWaitMs:fast?20000:0});return obj};restart();
 env.ANSWER_JOBS={idFromName:x=>x,get:()=>obj};
 let scheduled=false; jobs.onCommit=()=>{if(fast&&!scheduled&&jobs.alarm!==null&&jobs.alarm<=clock+1){scheduled=true;setTimeout(()=>{scheduled=false;waits.push(obj.alarm())},1)}};
 const headers={'Content-Type':'application/json',Authorization:'Bearer '+token,'X-Feast-Agent-Protocol':'10'};
 const activated=await publicFetch(new Request('https://feast.test/v1/access/activate',{method:'POST',headers,body:JSON.stringify({version:1,invitation,deviceID:crypto.randomUUID(),activationID:crypto.randomUUID(),credentialHash:await phoneHash('device',token)})}),env);assert.equal(activated.status,200);
 const invoke=(command,override={})=>publicFetch(new Request('https://feast.test/v1/answer-jobs',{method:'POST',headers:{...headers,...override},body:JSON.stringify(command)}),env);
 const submit=p=>invoke({version:1,op:'submit',request:p});
 const op=(op,p)=>invoke({version:1,op,requestID:p.requestID,step:p.step});
 const budget=async()=>{const r=await env.PRODUCTION_STATE.get('production-validation-v1').fetch(new Request('https://ledger/status-v2'));return r.json()};
 const snapshot=()=>({jobs:structuredClone(jobs.data),ledger:structuredClone(ledger.data),alarm:jobs.alarm});
 const restore=s=>{jobs.data=structuredClone(s.jobs);ledger.data=structuredClone(s.ledger);jobs.alarm=s.alarm;restart()};
 return {env,access,ledger,jobs,calls,headers,grant,token,invoke,submit,op,budget,restart,snapshot,restore,run:()=>obj.alarm(),waits,setTime:n=>{clock=n},now};
}
test('durable acceptance precedes acknowledgment; alarm completes after disconnect/restart, same key returns saved answer',async()=>{
 const f=await setup(),p=payload(),r=await f.submit(p);assert.equal(r.status,200);assert.equal((await r.json()).state,'queued');assert(f.jobs.alarm);assert.equal(f.calls.paid,0);
 f.restart();await f.run();let result=await(await f.op('status',p)).json();assert.equal(result.state,'completed');assert.equal(result.result.text,'A saved, supported answer.');assert.equal(result.result.model,'gpt-6.1-sol');assert(!('budget' in result.result));assert.equal(f.calls.paid,1);
 const repeated=await(await f.submit(structuredClone(p))).json();assert.deepEqual(repeated,result);assert.equal(f.calls.paid,1);assert.equal((await f.budget()).pendingMicroUSD,0);
 assert(!JSON.stringify([...f.jobs.data]).includes(f.token));assert(!JSON.stringify([...f.jobs.data]).includes('fixture-not-a-key'));
});
test('foreground fast path returns a completed answer without forced polling delay and provider body is unchanged',async()=>{
 const f=await setup({fast:true}),p=payload(),started=performance.now();const r=await(await f.submit(p)).json();assert.equal(r.state,'completed');assert(performance.now()-started<ANSWER_JOBS.retryMs);assert.equal(f.calls.paid,1);await Promise.all(f.waits);
 const other=await setup(),bodies=[];const userHash=await phoneHash('identity',other.grant.id);
 const direct=await nativeConversationAnswer(p,userHash,other.env,async(url,o)=>{const body=JSON.parse(o.body);if(url.endsWith('input_tokens'))return Response.json({input_tokens:100});bodies.push(body);return Response.json(answer(body))});assert.equal(direct.status,200);assert.deepEqual(f.calls.bodies,bodies);
});
test('canonical JSON ordering deduplicates, concurrent submits execute once, changed full payload is rejected',async()=>{
 const f=await setup(),p=payload(),reordered=Object.fromEntries(Object.entries(p).reverse());const r=await Promise.all([f.submit(p),f.submit(reordered)]);assert(r.every(x=>x.status===200));
 assert.equal((await f.submit({...p,text:'Changed question'})).status,409);await Promise.all([f.run(),f.run()]);assert.equal(f.calls.paid,1);
 assert.equal((await f.submit({...p,webAllowed:false})).status,409);
});
test('feature off rejects new submissions; current auth gates every retrieval and dispatch without leaking sponsor data',async()=>{
 const f=await setup(),p=payload();f.env.ASK_FEAST_RECOVERY_ENABLED='false';assert.equal((await f.submit(p)).status,503);let health=await(await publicFetch(new Request('https://feast.test/health'),f.env)).json();assert.equal(health.answerJobsVersion,undefined);
 f.env.ASK_FEAST_RECOVERY_ENABLED='true';health=await(await publicFetch(new Request('https://feast.test/health'),f.env)).json();assert.equal(health.answerJobsVersion,1);await f.submit(p);
 f.env.PHONE_INVITATIONS_JSON=JSON.stringify([{...f.grant,revoked:true}]);assert.equal((await f.op('status',p)).status,401);await f.run();assert.equal(f.calls.paid,0);
 f.env.PHONE_INVITATIONS_JSON=JSON.stringify([f.grant]);assert.equal((await(await f.op('status',p)).json()).state,'failed');assert.equal((await f.budget()).pendingMicroUSD,0);
 assert.equal((await f.invoke({version:1,op:'status',requestID:p.requestID,step:0},{Authorization:'Bearer '+'x'.repeat(43)})).status,401);
});
test('cancel before acceptance fences a delayed submit; Stop during dispatch suppresses result but settles paid usage',async()=>{
 let release,start;const began=new Promise(r=>start=r),gate=new Promise(r=>release=r);const f=await setup({provider:async body=>{start();await gate;return Response.json(answer(body))}}),p=payload();
 assert.equal((await(await f.op('cancel',p)).json()).state,'cancelled');assert.equal((await(await f.submit(p)).json()).state,'cancelled');await f.run();assert.equal(f.calls.paid,0);
 const q=payload();await f.submit(q);const running=f.run();await began;const cancel=await(await f.op('cancel',q)).json();assert.equal(cancel.state,'cancelled');release();await running;
 const r=await(await f.op('status',q)).json();assert.equal(r.state,'cancelled');assert.equal(r.result,undefined);assert.equal(f.calls.paid,1);assert.equal((await f.budget()).pendingMicroUSD,0);
 assert(![...f.jobs.data.keys()].some(k=>k.startsWith('content:'+jobKey(q.requestID,0))));
});
test('ack erases content and retains dedup tombstone; expiry and pruning never make the same root payable again',async()=>{
 const f=await setup(),p=payload();await f.submit(p);await f.run();assert.equal((await(await f.op('ack',p)).json()).state,'acknowledged');assert.equal((await(await f.submit(p)).json()).state,'acknowledged');
 assert(![...f.jobs.data.keys()].some(k=>k.startsWith('content:')));f.setTime(f.now+ANSWER_JOBS.tombstoneTTL+1);await f.run();assert.equal(f.jobs.data.size,0);
 await f.submit(p);await f.run();assert.equal((await(await f.op('status',p)).json()).state,'failed');assert.equal(f.calls.paid,1);
 const q=payload();await f.submit(q);f.setTime(f.now+ANSWER_JOBS.tombstoneTTL+ANSWER_JOBS.contentTTL+2);await f.run();assert.equal((await(await f.op('status',q)).json()).state,'expired');assert.equal(f.calls.paid,1);
});
test('unknown dispatch is terminal uncertain after restart and never retried, with exposure retained',async()=>{
 const f=await setup({provider:async()=>{throw Error('network outcome unknown')}}),p=payload();await f.submit(p);await f.run();assert.equal((await(await f.op('status',p)).json()).state,'uncertain');assert.equal(f.calls.paid,1);assert((await f.budget()).pendingMicroUSD>0);
 f.restart();await f.run();await f.submit(p);await f.run();assert.equal(f.calls.paid,1);
});
test('crash snapshots at reserved, dispatched, received and settlement boundaries never repeat a paid call',async()=>{
 const f=await setup(),p=payload(),snapshots=new Map();await f.submit(p);
 f.jobs.onCommit=()=>{const j=f.jobs.data.get('job:'+jobKey(p.requestID,0));if(j&&['reserved','dispatched','received','settling'].includes(j.phase)&&!snapshots.has(j.phase))snapshots.set(j.phase,f.snapshot())};
 await f.run();f.jobs.onCommit=()=>{};assert.equal(f.calls.paid,1);assert.deepEqual([...snapshots.keys()],['reserved','dispatched','received','settling']);
 for(const phase of ['dispatched','received','settling']){
  f.restore(snapshots.get(phase));const paid=f.calls.paid;await f.run();const status=await(await f.op('status',p)).json();assert.equal(status.state,phase==='dispatched'?'uncertain':'completed',phase);assert.equal(f.calls.paid,paid,phase);
  const budget=await f.budget();assert.equal(budget.pendingMicroUSD>0,phase==='dispatched',phase);
 }
 f.restore(snapshots.get('reserved'));await f.run();assert.equal((await(await f.op('status',p)).json()).state,'completed');assert.equal(f.calls.paid,2,'only the snapshot provably before dispatch may call the provider');
});
test('saved raw result can settle after feature rollback without credentials or any provider transport',async()=>{
 const f=await setup(),p=payload();let snapshot;await f.submit(p);f.jobs.onCommit=()=>{if(!snapshot&&f.jobs.data.get('job:'+jobKey(p.requestID,0))?.phase==='received')snapshot=f.snapshot()};await f.run();f.jobs.onCommit=()=>{};f.restore(snapshot);
 f.env.ASK_FEAST_RECOVERY_ENABLED='false';f.env.NATIVE_RESEARCH_ENABLED='false';f.env.LIVE_AI='false';delete f.env.OPENAI_API_KEY;await f.run();assert.equal(f.calls.paid,1);const r=await(await f.op('status',p)).json();assert.equal(r.state,'completed');assert.equal((await f.budget()).pendingMicroUSD,0);
});
test('lost reserve and settlement replies replay ledger RPCs idempotently without double counts',async()=>{
 const f=await setup(),p=payload(),original=f.env.PRODUCTION_STATE.get;let reserveLost=true,settlementLost=true;
 f.env.PRODUCTION_STATE.get=id=>{const target=original(id);return {fetch:async r=>{const reply=await target.fetch(r),path=new URL(r.url).pathname;if(path==='/native-reserve-v2'&&reply.ok&&reserveLost){reserveLost=false;throw Error('lost reserve reply')}if(path==='/native-complete-v2'&&reply.ok&&settlementLost){settlementLost=false;throw Error('lost settlement reply')}return reply}}};
 await f.submit(p);await assert.rejects(f.run(),/reservation_pending/);assert.equal(f.calls.paid,0);f.restart();await assert.rejects(f.run(),/settlement_pending/);assert.equal(f.calls.paid,1);const charged=(await f.budget()).chargedMicroUSD;assert(charged>0);
 f.restart();await f.run();assert.equal((await(await f.op('status',p)).json()).state,'completed');assert.equal(f.calls.paid,1);assert.equal((await f.budget()).chargedMicroUSD,charged);
 const turn=[...f.ledger.data.values()].find(x=>x?.responses!==undefined);assert.equal(turn.responses,1);assert.equal(turn.revision,2);
});
test('bounded chunk storage handles large native payloads and result retrieval does not accept protocol or actor substitution',async()=>{
 const f=await setup(),p=payload();p.context.recent=Array.from({length:10},()=> 'x'.repeat(100));
 assert.equal((await f.invoke({version:1,op:'submit',request:p},{'X-Feast-Agent-Protocol':'9'})).status,400);
 assert.equal((await f.invoke({version:1,op:'submit',request:p,userHash:'f'.repeat(64)})).status,400);
 const obj=f.restart();await obj.storage.transaction(tx=>obj.blob(tx,'fixture','large',{value:'☕'.repeat(100000)}));assert.equal((await obj.storage.transaction(tx=>obj.readBlob(tx,'fixture','large'))).value.length,100000);
});
test('expiry erases private content even with ledger rollback/outage; only compact known accounting evidence survives',async()=>{
 const f=await setup(),p=payload();let received;await f.submit(p);f.jobs.onCommit=()=>{if(!received&&f.jobs.data.get('job:'+jobKey(p.requestID,0))?.phase==='received')received=f.snapshot()};await f.run();f.jobs.onCommit=()=>{};
 f.setTime(f.now+ANSWER_JOBS.contentTTL+1);
 // Duplicate submit must not retrieve an expired result even before an alarm.
 const replay=await(await f.submit(p)).json();assert.equal(replay.state,'expired');assert.equal(replay.result,undefined);f.env.ALLOW_RECONCILED_BUDGET='false';await f.run();assert(![...f.jobs.data.keys()].some(k=>k.startsWith('content:')));
 assert.equal(f.jobs.data.get('job:'+jobKey(p.requestID,0)).needsFence,true);
 // A receipt not yet settled becomes a compact bill BEFORE unavailable RPCs.
 f.restore(received);await assert.rejects(f.run(),/accounting_v2_disabled/);assert(![...f.jobs.data.keys()].some(k=>k.startsWith('content:')));
 const retained=f.jobs.data.get('job:'+jobKey(p.requestID,0));assert.equal(retained.phase,'settling');assert.equal(retained.settlement.kind,'complete');assert.equal(retained.settlement.value.inputTokens,1000);assert(!JSON.stringify(retained).includes(p.text));
 f.env.ALLOW_RECONCILED_BUDGET='true';await f.run();assert.equal(f.calls.paid,1);assert.equal((await f.budget()).pendingMicroUSD,0);assert.equal((await(await f.op('status',p)).json()).state,'expired');
});
test('late credential revocation while foreground waits denies delivery, and no subsequent provider dispatch occurs',async()=>{
 let release,start;const began=new Promise(r=>start=r),gate=new Promise(r=>release=r);const f=await setup({fast:true,provider:async body=>{start();await gate;return Response.json(answer(body))}}),p=payload();
 const pending=f.submit(p);await began;f.env.PHONE_INVITATIONS_JSON=JSON.stringify([{...f.grant,revoked:true}]);release();assert.equal((await pending).status,401);await Promise.all(f.waits);assert.equal(f.calls.paid,1);assert.equal((await f.budget()).pendingMicroUSD,0);
});
test('foreground completion during an in-flight stale read cannot lose its wake-up',async()=>{
 const f=await setup(),p=payload();await f.submit(p);const obj=f.restart(),key=jobKey(p.requestID,p.step),read=obj.read.bind(obj);obj.foregroundWaitMs=5000;
 let intercepted=false;obj.read=async k=>{const stale=await read(k);if(!intercepted){intercepted=true;await obj.finish(k,'failed','fixture_completion')}return stale};
 let completed=false;const waiting=obj.waitFor(key).then(()=>{completed=true});
 try{
  // All fixture reads/writes finish before the next event-loop turn. The old
  // read-before-subscribe ordering misses notify() and stays asleep here.
  await new Promise(resolve=>setImmediate(resolve));assert.equal(completed,true,'completed job waited for the foreground timeout');
 }finally{obj.notify(key);await waiting}
 assert.equal(obj.waiters.size,0);assert.equal(f.calls.paid,0);
 obj.read=async()=>{throw Error('fixture_read_failure')};await assert.rejects(obj.waitFor(key),/fixture_read_failure/);assert.equal(obj.waiters.size,0);
});
test('fully elapsed long-polls renew promptly while early pending responses retain backoff',async()=>{
 const f=await setup(),p=payload(),obj=f.restart();obj.foregroundWaitMs=20;
 let started=performance.now();const submitted=await(await f.submit(p)).json();assert.equal(submitted.state,'queued');assert.equal(submitted.retryAfterMs,100);assert(performance.now()-started>=15);assert.equal(f.calls.paid,0);
 started=performance.now();const polled=await(await f.op('status',p)).json();assert.equal(polled.retryAfterMs,100);assert(performance.now()-started>=15);assert.equal(obj.waiters.size,0);
 obj.foregroundWaitMs=5000;const early=f.op('status',p),key=jobKey(p.requestID,p.step);
 while(!obj.waiters.has(key))await new Promise(resolve=>setImmediate(resolve));obj.notify(key);
 assert.equal((await(await early).json()).retryAfterMs,1500);assert.equal(obj.waiters.size,0);
 await f.run();const completed=await(await f.op('status',p)).json();assert.equal(completed.state,'completed');assert.equal(completed.retryAfterMs,undefined);assert.equal(f.calls.paid,1);
});

test('cancel without a local job rejects another protocol owner before persisting a tombstone, including recovery OFF',async()=>{
 const f=await setup(),p=payload();f.env.ASK_FEAST_RECOVERY_ENABLED='false';
 f.ledger.data.set('production-validation-v2:stage-root:'+p.requestID.toUpperCase(),{userHash:'b'.repeat(64),fingerprint:'f'.repeat(64),nextIndex:1});
 const before=structuredClone(f.ledger.data),r=await f.op('cancel',p);assert.equal(r.status,403);
 assert.equal(f.jobs.data.size,0);assert.deepEqual(f.ledger.data,before);assert.equal(f.calls.paid,0);
});

test('cancel at local job capacity does not create unbounded ledger fences',async()=>{
 const f=await setup(),p=payload();
 for(let i=0;i<ANSWER_JOBS.maxJobs;i++)f.jobs.data.set('job:capacity-'+i,{state:'cancelled'});
 const before=structuredClone(f.ledger.data);assert.equal((await f.op('cancel',p)).status,429);
 assert.deepEqual(f.ledger.data,before);assert.equal(f.jobs.data.size,ANSWER_JOBS.maxJobs);
});

test('slow unknown-root ownership claim cannot block an existing owned local Stop or status',async()=>{
 const f=await setup(),owned=payload(),unknown=payload();await f.submit(owned);
 const original=f.env.PRODUCTION_STATE.get;let release,started;
 const gate=new Promise(r=>release=r),began=new Promise(r=>started=r);
 f.env.PRODUCTION_STATE.get=id=>{const target=original(id);return {fetch:async request=>{
  if(new URL(request.url).pathname==='/native-close-v2'&&(await request.clone().json()).root===unknown.requestID){started();await gate}
  return target.fetch(request);
 }}};
 const pending=f.op('cancel',unknown);await began;
 let stopped=false;const local=f.op('cancel',owned).then(r=>{stopped=true;return r});
 try{
  for(let i=0;i<15&&!stopped;i++)await new Promise(r=>setImmediate(r));
  assert.equal(stopped,true,'unrelated ledger latency must not hold the local job transaction');
  assert.equal((await(await local).json()).state,'cancelled');
  assert.equal((await(await f.op('status',owned)).json()).state,'cancelled');assert.equal(f.calls.paid,0);
 }finally{release();await pending}
});

test('lost cancellation claim acknowledgment is bounded, blocks delayed submit and resolves after restart without dispatch',async()=>{
 const f=await setup(),p=payload(),original=f.env.PRODUCTION_STATE.get;let lost=true;
 f.env.PRODUCTION_STATE.get=id=>{const target=original(id);return {fetch:async request=>{
  const r=await target.fetch(request);if(new URL(request.url).pathname==='/native-close-v2'&&r.ok&&lost){lost=false;throw Error('lost close acknowledgment')}return r;
 }}};
 assert.equal((await f.op('cancel',p)).status,503);
 assert(f.jobs.data.has('cancel-claim:'+jobKey(p.requestID,0)));assert(!f.jobs.data.has('job:'+jobKey(p.requestID,0)));
 assert.equal((await f.submit(p)).status,409);assert(f.jobs.alarm!==null);
 f.restart();await f.run();assert.equal((await(await f.op('status',p)).json()).state,'cancelled');
 assert(!f.jobs.data.has('cancel-claim:'+jobKey(p.requestID,0)));assert.equal((await(await f.submit(p)).json()).state,'cancelled');
 assert.equal(f.calls.paid,0);assert.equal(f.calls.count,0);assert.equal((await f.budget()).pendingMicroUSD,0);
});

test('unconfirmed cancellation claims share the normal job capacity and never grant provider execution',async()=>{
 const f=await setup(),p=payload();
 for(let i=0;i<ANSWER_JOBS.maxJobs;i++)f.jobs.data.set('cancel-claim:capacity-'+i,{userHash:'a'.repeat(64)});
 const before=structuredClone(f.ledger.data);assert.equal((await f.submit(p)).status,429);assert.equal((await f.op('cancel',p)).status,429);
 assert.deepEqual(f.ledger.data,before);assert.equal(f.jobs.data.size,ANSWER_JOBS.maxJobs);assert.equal(f.calls.paid,0);
});

test('managed recovery: Stop/revoke after ledger claim but before provider send retains exposure without stuck cancel settlement',async()=>{
 for(const mode of ['stop','revoke']){const f=await setup({lifecycle:true}),p=payload();await f.submit(p);const original=f.env.PRODUCTION_STATE.get;let intercepted=false;f.env.PRODUCTION_STATE.get=id=>{const target=original(id);if(id!== 'production-validation-v1')return target;return {fetch:async request=>{const response=await target.fetch(request);if(!intercepted&&new URL(request.url).pathname==='/native-claim-v2'&&response.ok){intercepted=true;if(mode==='stop')await f.op('cancel',p);else f.env.PHONE_INVITATIONS_JSON=JSON.stringify([{...f.grant,revoked:true}])}return response}}};await f.run();assert(intercepted);assert.equal(f.calls.paid,0);const job=f.jobs.data.get('job:'+jobKey(p.requestID,0));assert.equal(job.phase,'done');assert.equal(job.state,'uncertain');assert.equal((await f.budget()).pendingMicroUSD,1400288);f.restart();await f.run();assert.equal(f.calls.paid,0)}
});
test('managed recovery: claim committed before job phase persistence is never redispatched after restart',async()=>{
 const f=await setup({lifecycle:true}),p=payload();let snapshot;await f.submit(p);f.ledger.onCommit=()=>{const x=[...f.ledger.data].find(([k,v])=>k.startsWith('production-validation-v2:execution:v1:')&&v.phase==='claimed');if(x&&!snapshot)snapshot=f.snapshot()};await f.run();assert(snapshot);assert.equal(snapshot.jobs.get('job:'+jobKey(p.requestID,0)).phase,'claiming');const paid=f.calls.paid;f.ledger.onCommit=()=>{};f.restore(snapshot);await f.run();assert.equal(f.calls.paid,paid);assert.equal(f.jobs.data.get('job:'+jobKey(p.requestID,0)).phase,'done');assert.equal((await f.budget()).pendingMicroUSD,1400288);
});
test('managed recovery: OFF between reservation and claim cannot dispatch and later OFF receipt settlement still works',async()=>{
 const f=await setup({lifecycle:true}),p=payload();await f.submit(p);const original=f.env.PRODUCTION_STATE.get;let paused=false;f.env.PRODUCTION_STATE.get=id=>{const target=original(id);return id==='production-validation-v1'?{fetch:async request=>{const r=await target.fetch(request);if(!paused&&new URL(request.url).pathname==='/native-reserve-v2'&&r.ok){paused=true;f.env.EXECUTION_LIFECYCLE_ENABLED='false'}return r}}:target};await f.run();assert(paused);assert.equal(f.calls.paid,0);assert.equal(f.jobs.data.get('job:'+jobKey(p.requestID,0)).phase,'done');assert.equal((await f.budget()).pendingMicroUSD,1400288);
 const g=await setup({lifecycle:true}),q=payload();let received;await g.submit(q);g.jobs.onCommit=()=>{if(!received&&g.jobs.data.get('job:'+jobKey(q.requestID,0))?.phase==='received')received=g.snapshot()};await g.run();const count=g.calls.paid;g.jobs.onCommit=()=>{};g.restore(received);g.env.EXECUTION_LIFECYCLE_ENABLED='false';g.env.ALLOW_RECONCILED_BUDGET='false';await g.run();assert.equal(g.calls.paid,count);assert.equal(g.jobs.data.get('job:'+jobKey(q.requestID,0)).phase,'done');assert.equal((await g.budget()).pendingMicroUSD,0);
});
test('managed recovery: lost reservation ACK recovers once, lost claim ACK never sends',async()=>{
 for(const lost of ['reserve','claim']){const f=await setup({lifecycle:true}),p=payload();await f.submit(p);const original=f.env.PRODUCTION_STATE.get;let dropped=false;f.env.PRODUCTION_STATE.get=id=>{const target=original(id);return id==='production-validation-v1'?{fetch:async request=>{const r=await target.fetch(request);if(!dropped&&new URL(request.url).pathname==='/native-'+lost+'-v2'&&r.ok){dropped=true;throw Error('fixture_lost_ack')}return r}}:target};try{await f.run()}catch{}f.restart();await f.run();assert(dropped);assert.equal(f.calls.paid,lost==='reserve'?1:0);assert.equal(f.jobs.data.get('job:'+jobKey(p.requestID,0)).phase,'done');assert.equal((await f.budget()).pendingMicroUSD,lost==='reserve'?0:1400288)}
});
test('legacy cached reserved job cannot bypass managed cutover with a legacy adapter dispatch grant',async()=>{
 const f=await setup(),p=payload();await f.submit(p);let reserved;f.jobs.onCommit=()=>{if(!reserved&&f.jobs.data.get('job:'+jobKey(p.requestID,0))?.phase==='reserved')reserved=f.snapshot()};await f.run();f.jobs.onCommit=()=>{};f.restore(reserved);const {executionInventory,applyExecutionMigration}=await import('./execution-migration.mjs'),inv=await executionInventory(f.ledger);await applyExecutionMigration(f.ledger,{version:1,revision:inv.revision,writersQuiesced:true,recovery:{version:1,kind:'never-enabled',namespace:'answer-jobs-v1',namespaceID:'a'.repeat(32),sourceRevision:'b'.repeat(40),quiescenceRevision:'c'.repeat(64),evidenceDigest:'d'.repeat(64)},legacy:inv.records.filter(r=>r.state==='pending').map(r=>({key:r.key,recordDigest:r.digest,classification:'attributed-uncertain'})),halts:[]});f.env.EXECUTION_LIFECYCLE_ENABLED='true';const paid=f.calls.paid;await f.run();assert.equal(f.calls.paid,paid);assert.equal(f.jobs.data.get('job:'+jobKey(p.requestID,0)).phase,'done');
});
test('managed reserved recovery resumes original bytes across midnight but rejects changed payload identity',async()=>{
 for(const drift of ['midnight','prompt']){const f=await setup({lifecycle:true}),p=payload();await f.submit(p);let reserved;f.jobs.onCommit=()=>{if(!reserved&&f.jobs.data.get('job:'+jobKey(p.requestID,0))?.phase==='reserved')reserved=f.snapshot()};await f.run();f.jobs.onCommit=()=>{};f.restore(reserved);const paid=f.calls.paid;const RealDate=globalThis.Date;
 try{if(drift==='midnight')globalThis.Date=class extends RealDate{constructor(...args){super(...(args.length?args:[RealDate.now()+86400000]))}static now(){return RealDate.now()}};
 else{const obj=f.restart();await obj.storage.transaction(tx=>obj.blob(tx,jobKey(p.requestID,0),'payload',{...p,text:p.text+' Updated reconstructed prompt inputs.'}))}
 await f.run();assert.equal(f.calls.paid,paid+(drift==='midnight'?1:0));const j=f.jobs.data.get('job:'+jobKey(p.requestID,0));assert.equal(j.phase,'done');assert.equal(j.state,drift==='midnight'?'completed':'uncertain');assert.equal((await f.budget()).pendingMicroUSD,drift==='midnight'?0:1400288);if(drift==='midnight')assert.deepEqual(f.calls.bodies.at(-1),f.calls.bodies[0],'original accepted bytes survive reconstructed prompt changes');
 }finally{globalThis.Date=RealDate}
 }
});
test('managed count-only restart keys cached token count to exact body; unchanged reconstruction reuses it',async()=>{
 for(const drift of [false,true]){const f=await setup({lifecycle:true}),p=payload();await f.submit(p);let counted;f.jobs.onCommit=()=>{const j=f.jobs.data.get('job:'+jobKey(p.requestID,0));if(!counted&&j?.count&&!j.reserveIntent)counted=f.snapshot()};await f.run();f.jobs.onCommit=()=>{};f.restore(counted);const paid=f.calls.paid,counts=f.calls.count,RealDate=globalThis.Date;
 try{if(drift)globalThis.Date=class extends RealDate{constructor(...args){super(...(args.length?args:[RealDate.now()+86400000]))}static now(){return RealDate.now()}};await f.run();assert.equal(f.calls.paid,paid+1);assert.equal(f.calls.count,counts,'stored exact count material survives midnight');assert.equal(f.jobs.data.get('job:'+jobKey(p.requestID,0)).state,'completed')}finally{globalThis.Date=RealDate}
 }
});
test('historical body-bound reserved job missing only count digest safely recounts without rebinding generation bytes',async()=>{
 const f=await setup({lifecycle:true}),p=payload();await f.submit(p);let reserved;f.jobs.onCommit=()=>{if(!reserved&&f.jobs.data.get('job:'+jobKey(p.requestID,0))?.phase==='reserved')reserved=f.snapshot()};await f.run();f.jobs.onCommit=()=>{};f.restore(reserved);const obj=f.restart(),key=jobKey(p.requestID,0),counts=f.calls.count,paid=f.calls.paid;
 await obj.mutate(key,async(j,tx)=>{delete j.countBodyDigest;delete j.dispatchMaterial;await obj.blob(tx,key,'dispatch-provider',undefined);await obj.blob(tx,key,'dispatch-count',undefined)});await f.run();assert.equal(f.calls.count,counts+1);assert.equal(f.calls.paid,paid+1);assert.deepEqual(f.calls.bodies.at(-1),f.calls.bodies[0]);assert.equal(f.jobs.data.get('job:'+key).state,'completed');
});
test('missing/corrupt exact material never sends, retains exposure, and TTL erases remaining dispatch content',async()=>{
 for(const corrupt of [false,true]){const f=await setup({lifecycle:true}),p=payload();await f.submit(p);let reserved;f.jobs.onCommit=()=>{if(!reserved&&f.jobs.data.get('job:'+jobKey(p.requestID,0))?.phase==='reserved')reserved=f.snapshot()};await f.run();f.jobs.onCommit=()=>{};f.restore(reserved);const paid=f.calls.paid,key=[...f.jobs.data.keys()].find(k=>k.includes(':dispatch-provider:'));if(corrupt)f.jobs.data.set(key,f.jobs.data.get(key)+'x');else f.jobs.data.delete(key);await f.run();assert.equal(f.calls.paid,paid);assert.equal((await f.budget()).pendingMicroUSD,1400288);assert.equal(f.jobs.data.get('job:'+jobKey(p.requestID,0)).state,'uncertain');f.setTime(f.now+ANSWER_JOBS.contentTTL+1);await f.run();assert(![...f.jobs.data.keys()].some(k=>k.startsWith('content:')))}
});
test('pristine OFF body-bound legacy cached reservation missing count digest re-counts and resumes unchanged',async()=>{
 const f=await setup(),p=payload();await f.submit(p);let reserved;f.jobs.onCommit=()=>{if(!reserved&&f.jobs.data.get('job:'+jobKey(p.requestID,0))?.phase==='reserved')reserved=f.snapshot()};await f.run();f.jobs.onCommit=()=>{};f.restore(reserved);const obj=f.restart(),key=jobKey(p.requestID,0),paid=f.calls.paid,counts=f.calls.count;
 await obj.mutate(key,async(j,tx)=>{delete j.countBodyDigest;delete j.dispatchMaterial;await obj.blob(tx,key,'dispatch-provider',undefined);await obj.blob(tx,key,'dispatch-count',undefined)});await f.run();assert.equal(f.calls.paid,paid+1);assert.equal(f.calls.count,counts+1);assert.deepEqual(f.calls.bodies.at(-1),f.calls.bodies[0]);assert.equal(f.jobs.data.get('job:'+key).state,'completed');
});
test('versioned exact material ignores a new prompt template but still binds original allocation and payload',async()=>{
 const f=await setup({lifecycle:true}),p=payload();await f.submit(p);let reserved;f.jobs.onCommit=()=>{if(!reserved&&f.jobs.data.get('job:'+jobKey(p.requestID,0))?.phase==='reserved')reserved=f.snapshot()};await f.run();f.jobs.onCommit=()=>{};f.restore(reserved);const obj=f.restart(),j=await obj.read(jobKey(p.requestID,0)),r=j.reserveIntent,newTemplate={...f.calls.bodies[0],instructions:'A materially different future prompt template.'},candidate={providerBody:JSON.stringify(newTemplate),countBody:JSON.stringify({model:j.model,input:'future version count input'}),model:j.model,fingerprint:r.fingerprint,allocation:{revision:r.allocationRevision,privateLatched:r.privateLatched,webAllowed:r.webAllowed,maxWebActions:r.maxWebActions,maxOutput:r.maxOutput}};
 const material=await obj.dispatchMaterial(j.key,p,candidate);assert.equal(material.providerBody,JSON.stringify(f.calls.bodies[0]));assert.notEqual(material.providerBody,candidate.providerBody);await assert.rejects(obj.dispatchMaterial(j.key,{...p,text:'Different owner payload'},candidate),/payload_conflict/);await f.run();assert.deepEqual(f.calls.bodies.at(-1),f.calls.bodies[0]);assert.equal(f.jobs.data.get('job:'+j.key).state,'completed');
});
test('dispatch material byte limit is atomic before reserve or claim, and accepted chunks remain under DO value limits',async()=>{
 const f=await setup({lifecycle:true}),p=payload();await f.submit(p);const obj=f.restart(),key=jobKey(p.requestID,0),before=structuredClone(f.jobs.data),ledger=structuredClone(f.ledger.data),material={providerBody:JSON.stringify({model:'gpt-6.1-sol',input:'x'.repeat(4*ANSWER_JOBS.maxPayloadBytes)}),countBody:JSON.stringify({model:'gpt-6.1-sol',input:[]}),model:'gpt-6.1-sol',fingerprint:'f'.repeat(64),allocation:{revision:0}};
 await assert.rejects(obj.dispatchMaterial(key,p,material),/material_limit/);assert.deepEqual(f.jobs.data,before);assert.deepEqual(f.ledger.data,ledger);assert.equal(f.calls.paid,0);assert.equal(f.calls.count,0);
 const prefix=JSON.stringify({model:'gpt-6.1-sol',input:''}),bounded={...material,providerBody:JSON.stringify({model:'gpt-6.1-sol',input:'x'.repeat(4*ANSWER_JOBS.maxPayloadBytes-new TextEncoder().encode(prefix).length)})};await obj.dispatchMaterial(key,p,bounded);assert([...f.jobs.data.keys()].some(k=>k.includes(':dispatch-provider:')));await f.op('cancel',p);await f.run();assert(![...f.jobs.data.keys()].some(k=>k.startsWith('content:'+key)));assert.equal(f.calls.paid,0);
});
test('actual 3c078b0 reserved/lost-ACK jobs pause intact while a received receipt settles without dispatch',async()=>{
 const {mkdtemp,rm}=await import('node:fs/promises'),{tmpdir}=await import('node:os'),{join}=await import('node:path'),{pathToFileURL}=await import('node:url'),{execFileSync}=await import('node:child_process');const dir=await mkdtemp(join(tmpdir(),'feast-preproof-baseline-'));
 try{const archive=execFileSync('git',['archive','3c078b0','Backend/feast-production','Backend/feast-proxy'],{maxBuffer:32*1024*1024});execFileSync('tar',['-x','-C',dir],{input:archive});const {AnswerJobs:OldJobs}=await import(pathToFileURL(join(dir,'Backend/feast-production/answer-jobs.mjs'))),{ProductionLedger:OldLedger}=await import(pathToFileURL(join(dir,'Backend/feast-production/production-ledger.mjs')));const f=await setup(),p=payload(),key=jobKey(p.requestID,0),currentLedger=f.env.PRODUCTION_STATE.get,snapshots=new Map();let oldPaid=0;
 f.env.PRODUCTION_STATE.get=id=>id===PHONE_OBJECT?currentLedger(id):new OldLedger({storage:f.ledger},f.env);const old=new OldJobs({storage:f.jobs},f.env,{foregroundWaitMs:0,now:()=>f.now,send:async(url,o)=>{if(url.endsWith('/input_tokens'))return Response.json({input_tokens:100});oldPaid++;return Response.json(answer(JSON.parse(o.body)))}});f.env.ANSWER_JOBS.get=()=>old;await f.submit(p);
 f.jobs.onCommit=()=>{const phase=f.jobs.data.get('job:'+key)?.phase;if(['reserved','received'].includes(phase)&&!snapshots.has(phase))snapshots.set(phase,f.snapshot())};f.ledger.onCommit=()=>{if(f.jobs.data.get('job:'+key)?.phase==='reserving'&&[...f.ledger.data.values()].some(r=>r?.state==='pending')&&!snapshots.has('reserving'))snapshots.set('reserving',f.snapshot())};await old.alarm();assert.equal(oldPaid,1);assert.deepEqual([...snapshots.keys()],['reserving','reserved','received']);f.jobs.onCommit=f.ledger.onCommit=()=>{};f.env.PRODUCTION_STATE.get=currentLedger;
 for(const phase of ['reserving','reserved','received']){const original=snapshots.get(phase),historical=original.jobs.get('job:'+key);assert.equal(historical.reserveIntent.bodyDigest,undefined);assert.equal(historical.reservation?.bodyDigest,undefined);assert.equal(historical.dispatchMaterial,undefined);f.restore(original);const before=await f.budget();await f.run();assert.equal(f.calls.paid,0);
 if(phase==='received'){assert.equal(f.jobs.data.get('job:'+key).state,'completed');assert.equal((await f.budget()).pendingMicroUSD,0);continue}
 assert.equal((await f.budget()).pendingMicroUSD,before.pendingMicroUSD);assert(before.pendingMicroUSD>0);const paused=f.jobs.data.get('job:'+key);assert.equal(paused.phase,phase);assert.equal(paused.compatibilityBlocked,'legacy-preproof-v1');const {compatibilityBlocked,...unchanged}=paused;assert.deepEqual(unchanged,historical);assert.deepEqual(f.ledger.data,original.ledger);assert([...f.jobs.data.keys()].some(k=>k.startsWith('content:')));assert.equal(f.jobs.alarm,historical.expiresAt);await f.run();assert.equal(f.jobs.alarm,historical.expiresAt);
 const pausedSnapshot=f.snapshot(),current=f.restart();for(let i=0;i<5;i++){const status=await current.fetch(new Request('https://jobs/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({command:{version:1,op:'status',requestID:p.requestID,step:0},userHash:historical.userHash,credentialHash:historical.credentialHash})}));assert.equal((await status.json()).state,historical.state);assert.equal(f.jobs.alarm,historical.expiresAt)}
 const cancelled=await current.fetch(new Request('https://jobs/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({command:{version:1,op:'cancel',requestID:p.requestID,step:0},userHash:historical.userHash,credentialHash:historical.credentialHash})}));assert.equal(cancelled.status,200);await f.run();assert(![...f.jobs.data.keys()].some(k=>k.startsWith('content:')));assert.equal(f.calls.paid,0);
 f.restore(pausedSnapshot);f.setTime(f.now+ANSWER_JOBS.contentTTL+1);await f.run();assert(![...f.jobs.data.keys()].some(k=>k.startsWith('content:')));assert.equal(f.calls.paid,0);f.setTime(f.now);
 // Before managed cutover only: the unchanged legacy row remains readable by
 // its actual original processor. This does not authorize a binary rollback.
 f.restore(pausedSnapshot);f.env.PRODUCTION_STATE.get=id=>id===PHONE_OBJECT?currentLedger(id):new OldLedger({storage:f.ledger},f.env);const compatible=new OldJobs({storage:f.jobs},f.env,{foregroundWaitMs:0,now:()=>f.now,send:async(url,o)=>{if(url.endsWith('/input_tokens'))return Response.json({input_tokens:100});oldPaid++;return Response.json(answer(JSON.parse(o.body)))}});const paidBefore=oldPaid;await compatible.alarm();assert.equal(oldPaid,paidBefore+1);assert.equal(f.jobs.data.get('job:'+key).state,'completed');f.env.PRODUCTION_STATE.get=currentLedger;

 }
 }finally{await rm(dir,{recursive:true,force:true})}
});
test('Stop or expiry during native preparation cannot persist new dispatch material after retirement',async()=>{
 for(const mode of ['stop','expire']){const f=await setup({lifecycle:true}),p=payload();await f.submit(p);const get=f.env.PRODUCTION_STATE.get;let release,started;const gate=new Promise(r=>release=r),began=new Promise(r=>started=r);f.env.PRODUCTION_STATE.get=id=>{const target=get(id);return id===PHONE_OBJECT?target:{fetch:async request=>{const response=await target.fetch(request);if(new URL(request.url).pathname==='/native-prepare-v2'){started();await gate}return response}}};const work=f.run();await began;if(mode==='stop')await f.op('cancel',p);else{f.setTime(f.now+ANSWER_JOBS.contentTTL+1);await f.op('status',p)}let wrote=false;f.jobs.onCommit=()=>{if([...f.jobs.data.keys()].some(k=>k.includes(':dispatch-provider:')))wrote=true};release();await work;assert.equal(wrote,false);assert.equal(f.calls.count,0);assert.equal(f.calls.paid,0);assert.equal((await f.budget()).pendingMicroUSD,0);assert(![...f.jobs.data.keys()].some(k=>k.startsWith('content:')))}
});
