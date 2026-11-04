import {test} from 'node:test';import assert from 'node:assert/strict';
import {STAGE_HOLDS,STAGE_POLICY,stageCost} from './stage-policy.mjs';
import {StageAccounting,stageID} from './stage-accounting.mjs';
import {ProductionLedger} from './production-ledger.mjs';
function storage(){const m=new Map();let queue=Promise.resolve();return {m,transaction(fn){const work=queue.then(()=>fn({get:async k=>m.get(k),put:async(k,v)=>m.set(k,v),list:async({prefix,limit})=>new Map([...m].filter(([k])=>k.startsWith(prefix)).slice(0,limit))}));queue=work.catch(()=>{});return work}}}
function setup(s=storage()){const ledger=new ProductionLedger({storage:s},{ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true'});return {s,ledger,invoke:(route,body)=>ledger.fetch(new Request('https://ledger'+route+'-v2',{method:'POST',body:JSON.stringify(body)}))}}
const usage=(webCalls=0)=>({model:'gpt-6-astra',inputTokens:1000,outputTokens:100,webCalls});
const runner=(invoke,root=crypto.randomUUID(),user='a'.repeat(64))=>new StageAccounting({root,userHash:user,fingerprint:'f'.repeat(64),invoke});
const status=async ledger=>(await ledger.fetch(new Request('https://ledger/status-v2'))).json();
test('exact stage upper bounds preserve model, research context/output and extraction output',()=>{
 assert.deepEqual(STAGE_HOLDS,{solAgentStepV1:324404,solResearchStageV1:1344658,solExtractionStageV1:216269,astraAgentStepV1:1622016,astraResearchStageV1:6679288,astraExtractionStageV1:1081344});
 for(const [name,p] of Object.entries(STAGE_POLICY)){assert.equal(stageCost([{model:p.model,inputTokens:p.maxInput,outputTokens:p.maxOutput,webCalls:p.webCalls}],name),STAGE_HOLDS[name]);for(const bad of [{inputTokens:p.maxInput+1},{outputTokens:p.maxOutput+1},{model:'gpt-6-luna'},{webCalls:p.webCalls+1}])assert.throws(()=>stageCost([{model:p.model,inputTokens:p.maxInput,outputTokens:p.maxOutput,webCalls:p.webCalls,...bad}],name))}
});
test('stages settle before next reservation without resetting old data; durable restart recalculates costs',async()=>{
 const {s,ledger,invoke}=setup();s.m.set('production-validation-v1:total',0);const old=[...s.m];const r=runner(invoke);await r.begin('astraResearchStageV1');await r.complete(usage(1));const first=await status(ledger);assert.equal(first.pendingMicroUSD,0);await r.begin('astraExtractionStageV1');await r.complete(usage());const after=await status(new ProductionLedger({storage:s},{ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true'}));assert.equal(after.chargedMicroUSD,77000);assert.equal(after.historicalReservedMicroUSD,7760632);assert.equal(after.remainingMicroUSD,null);assert.equal(after.capMicroUSD,null);for(const [k,v] of old)assert.deepEqual(s.m.get(k),v)
});
test('atomic reservations prevent concurrent over-cap dispatch and preserve uncertain hold',async()=>{
 const {ledger,invoke}=setup();const attempts=['a','b','c','d','e','f'].map(x=>runner(invoke,crypto.randomUUID(),x.repeat(64)));const outcomes=await Promise.allSettled(attempts.map(x=>x.begin('astraResearchStageV1')));assert.equal(outcomes.filter(x=>x.status==='fulfilled').length,4);const won=attempts[outcomes.findIndex(x=>x.status==='fulfilled')];await won.uncertain();const value=await status(ledger);assert.equal(value.pendingMicroUSD,26717152);assert.equal(value.halted,true);await assert.rejects(runner(invoke).begin('astraAgentStepV1'))
});
test('same root cannot replay; independent same-user stages retain holds and survive stale pre-upgrade lock',async()=>{
 const {s,invoke,ledger}=setup(),root=crypto.randomUUID(),a=runner(invoke,root);await a.begin('astraAgentStepV1');
 const oldID=await stageID(root,0),oldKey='production-validation-v2:request:'+oldID,oldRecord=structuredClone(s.m.get(oldKey));
 s.m.set('production-validation-v2:inflight:'+'a'.repeat(64),oldID);
 const b=runner(invoke);await b.begin('astraAgentStepV1');assert.equal((await status(ledger)).pendingMicroUSD,3244032);
 await b.complete(usage());assert.deepEqual(s.m.get(oldKey),oldRecord);assert.equal(s.m.get('production-validation-v2:inflight:'+'a'.repeat(64)),oldID);
 await a.complete(usage());assert.equal((await status(ledger)).pendingMicroUSD,0);assert.equal(s.m.get('production-validation-v2:inflight:'+'a'.repeat(64)),null);
 await assert.rejects(runner(invoke,root).begin('astraAgentStepV1'));assert.equal(await stageID(root,0),await stageID(root,0));assert.notEqual(await stageID(root,0),await stageID(root,1))
});
test('same-user concurrent staged reservations count every hold and enforce bounded simultaneous dispatch',async()=>{
 const {ledger,invoke}=setup(),requests=Array.from({length:24},()=>runner(invoke));
 const outcomes=await Promise.allSettled(requests.map(x=>x.begin('astraAgentStepV1')));
 assert.equal(outcomes.filter(x=>x.status==='fulfilled').length,4);
 let value=await status(ledger);assert.equal(value.pendingMicroUSD,4*1622016);assert.equal(value.remainingMicroUSD,null);
 const first=outcomes.findIndex(x=>x.status==='fulfilled');await requests[first].complete(usage());value=await status(ledger);assert.equal(value.pendingMicroUSD,3*1622016);assert.equal(value.chargedMicroUSD,33000);
 assert.equal(value.reservedMicroUSD,value.pendingMicroUSD+value.chargedMicroUSD)
});
test('lost settlement response stops without uncertain/repeated accounting mutation',async()=>{
 const {invoke,ledger}=setup();let complete=0,uncertain=0;const r=runner(async(route,p)=>{if(route==='/complete'){complete++;await invoke(route,p);throw Error('lost reply')}if(route==='/uncertain')uncertain++;return invoke(route,p)});await r.begin('astraAgentStepV1');await assert.rejects(r.complete(usage()));await r.uncertain();assert.equal(complete,1);assert.equal(uncertain,0);const v=await status(ledger);assert.equal(v.chargedMicroUSD,33000);assert.equal(v.pendingMicroUSD,0);await assert.rejects(r.begin('astraAgentStepV1'))
});
test('same-instance concurrent begin acquires synchronous ownership before identity await',async()=>{const {invoke,ledger}=setup();let reserves=0;const r=runner(async(route,p)=>{if(route==='/reserve')reserves++;return invoke(route,p)});const out=await Promise.allSettled([r.begin('astraAgentStepV1'),r.begin('astraAgentStepV1')]);assert.equal(out.filter(x=>x.status==='fulfilled').length,1);assert.equal(reserves,1);await r.complete(usage());assert.equal((await status(ledger)).pendingMicroUSD,0)});
test('logical root already used under either old ledger version cannot replay after upgrade',async()=>{for(const legacy of [true,false]){const {s,invoke,ledger}=setup(),root=crypto.randomUUID();if(legacy){s.m.set('production-validation-v1:total',2500000);s.m.set('production-validation-v1:request:'+root,{userHash:'a'.repeat(64),reservedMicroUSD:2500000,state:'complete',inputTokens:1000,outputTokens:100,calls:1,conservativeUsageMicroUSD:33000})}else{const x={requestID:root,userHash:'a'.repeat(64),fingerprint:'f'.repeat(64),profile:'publicAstraV1',amountMicroUSD:8000000};assert.equal((await invoke('/reserve',x)).status,200);assert.equal((await invoke('/complete',{...x,usage:[usage(1)]})).status,200)}const before=await status(ledger),saved=JSON.stringify([...s.m]);await assert.rejects(runner(invoke,root).begin('astraResearchStageV1'));const after=await status(ledger);assert.deepEqual(after,before);assert.equal(JSON.stringify([...s.m]),saved)}});
test('a staged logical root cannot replay through an older request profile after rollback',async()=>{const {invoke,ledger}=setup(),root=crypto.randomUUID(),r=runner(invoke,root);await r.begin('astraAgentStepV1');await r.complete(usage());const before=await status(ledger);assert.equal((await invoke('/reserve',{requestID:root,userHash:'a'.repeat(64),fingerprint:'f'.repeat(64),profile:'saved',amountMicroUSD:2500000})).status,409);assert.deepEqual(await status(ledger),before)});

test('historical spend above former cap and unknown holds remain intact while new stages can run',async()=>{
 const {s,ledger,invoke}=setup();
 for(let i=0;i<40;i++)s.m.set('production-validation-v2:request:'+crypto.randomUUID(),{profile:'saved',reservedMicroUSD:2500000,userHash:'a'.repeat(64),state:'complete',usage:[{model:'gpt-6-astra',inputTokens:8192,outputTokens:8192,webCalls:0}],conservativeUsageMicroUSD:usageCostFixture()});
 function usageCostFixture(){return Math.ceil((8192*20+8192*100)*1.1)}
 const unknownKey='production-validation-v2:request:'+crypto.randomUUID(),unknown={profile:'astraAgentStepV1',reservedMicroUSD:1622016,userHash:'a'.repeat(64),state:'uncertain'};s.m.set(unknownKey,unknown);
 const before=await status(ledger);assert.ok(before.chargedMicroUSD>30000000);assert.equal(before.capMicroUSD,null);assert.equal(before.remainingMicroUSD,null);
 const r=runner(invoke);await r.begin('astraResearchStageV1');await r.complete(usage(1));const after=await status(ledger);assert.equal(after.chargedMicroUSD,before.chargedMicroUSD+44000);assert.equal(after.pendingMicroUSD,1622016);assert.deepEqual(s.m.get(unknownKey),unknown);
});

test('retry fence closes absent/settled roots without resetting accounting and blocks late dispatch case-insensitively',async()=>{
 const {ledger,invoke}=setup(),root=crypto.randomUUID().toUpperCase(),r=runner(invoke,root);await r.begin('astraAgentStepV1');await r.complete(usage());const absent=crypto.randomUUID(),before=await status(ledger);
 const fence=roots=>ledger.fetch(new Request('https://ledger/fence-v2',{method:'POST',body:JSON.stringify({roots,userHash:'a'.repeat(64)})}));
 assert.equal((await fence([root.toLowerCase(),absent])).status,200);assert.deepEqual(await status(ledger),before);
 await assert.rejects(r.begin('astraAgentStepV1'));await assert.rejects(runner(invoke,absent.toUpperCase()).begin('astraAgentStepV1'));
 const fresh=runner(invoke);await fresh.begin('astraAgentStepV1');await fresh.complete(usage());assert.equal((await status(ledger)).chargedMicroUSD,66000);
 assert.equal((await fence([root,absent])).status,200);
});
test('retry fence is atomic, user scoped and never releases pending or unknown holds',async()=>{
 for(const uncertain of [false,true]){const {s,ledger,invoke}=setup(),root=crypto.randomUUID(),r=runner(invoke,root);await r.begin('astraAgentStepV1');if(uncertain)await r.uncertain();const before=JSON.stringify([...s.m]),absent=crypto.randomUUID();
 const fence=(roots,userHash='a'.repeat(64))=>ledger.fetch(new Request('https://ledger/fence-v2',{method:'POST',body:JSON.stringify({roots,userHash})}));
 assert.equal((await fence([absent,root])).status,409);assert.equal(JSON.stringify([...s.m]),before);assert.equal((await fence([root],'b'.repeat(64))).status,403);assert.equal(JSON.stringify([...s.m]),before);
 }
});

test('Sol stages are additive; pre-migration pending Astra settles under immutable historical rules',async()=>{
 const {s,ledger,invoke}=setup();const astra=runner(invoke);await astra.begin('astraAgentStepV1');
 const sol=runner(invoke,crypto.randomUUID(),'b'.repeat(64));await sol.begin('solAgentStepV1');
 await sol.complete({model:'gpt-6.1-sol',inputTokens:1000,outputTokens:100,webCalls:0});
 let value=await status(ledger);assert.equal(value.pendingMicroUSD,1622016);assert.equal(value.chargedMicroUSD,6600);
 await astra.complete(usage());value=await status(new ProductionLedger({storage:s},{ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true'}));
 assert.equal(value.chargedMicroUSD,39600);assert.equal(value.pendingMicroUSD,0);assert.equal(value.capMicroUSD,null);
 assert.throws(()=>stageCost([{model:'gpt-6-astra',inputTokens:1000,outputTokens:100,webCalls:0}],'solAgentStepV1'));
 assert.throws(()=>stageCost([{model:'gpt-6.1-sol',inputTokens:1000,outputTokens:100,webCalls:0}],'astraAgentStepV1'));
});
