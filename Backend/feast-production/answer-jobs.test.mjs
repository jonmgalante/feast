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
async function setup({fast=false,provider}={}){
 const token='t'.repeat(43),invitation='i'.repeat(43),now=Date.now(),grant={id:crypto.randomUUID(),createdAt:now-1000,expiresAt:now+86400000,revoked:false,sha256:await phoneHash('invitation',invitation)};
 const env={ENVIRONMENT:'production',PHONE_ACCESS_ENABLED:'true',PHONE_INVITATIONS_JSON:JSON.stringify([grant]),OWNER_VALIDATION_ENABLED:'true',LIVE_AI:'true',ALLOW_RECONCILED_BUDGET:'true',ALLOW_PUBLIC_LOOKUP:'true',NATIVE_RESEARCH_ENABLED:'true',ASK_FEAST_RECOVERY_ENABLED:'true',OPENAI_API_KEY:'fixture-not-a-key'};
 const access=new Storage(),ledger=new Storage(),jobs=new Storage(),calls={paid:0,count:0,bodies:[]},waits=[];let clock=now,obj;
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
