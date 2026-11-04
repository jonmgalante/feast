import {test,mock as nodeMock} from 'node:test';
import assert from 'node:assert/strict';
import worker,{BudgetLedger,digest,effectiveCredential} from './worker.mjs';
import {EVALUATION_CASES,EVALUATION_RUN,EVALUATION_TESTER,verifiedEvaluationStatus} from './evaluation.mjs';
const TESTER_TWO_REPLACEMENT_HASH=effectiveCredential({id:'feast-dev-tester-two',expiresAt:'2026-11-22T14:30:00Z'},'dev').sha256;
const token='b'.repeat(43),other='a'.repeat(43),prefix='evaluation:'+EVALUATION_RUN;
// Synthetic token maps to the approved hash only inside this offline test process.
const realDigest=crypto.subtle.digest.bind(crypto.subtle);
nodeMock.method(crypto.subtle,'digest',async(algorithm,data)=>new TextDecoder().decode(data)===token
 ? Uint8Array.from(TESTER_TWO_REPLACEMENT_HASH.match(/../g),x=>parseInt(x,16)).buffer
 : realDigest(algorithm,data));
function storage(){const values=new Map([['total',1200000],['user:feast-dev-tester-one',1200000]]);let queue=Promise.resolve(),writes=0;return {values,get writes(){return writes},transaction(fn){const next=queue.then(()=>fn({get:async k=>values.get(k),put:async(k,v)=>{writes++;values.set(k,v)}}));queue=next.catch(()=>{});return next}}}
async function setup(){const s=storage();return {s,env:{ENVIRONMENT:'dev',ENABLED:'true',LIVE_AI:'true',ALLOW_DISCOVERY:'true',ALLOW_DISCOVERY_EVALUATION:'true',OPENAI_API_KEY:'public-fake',CLIENT_TOKEN_HASHES_JSON:JSON.stringify([{id:'feast-dev-tester-one',sha256:await digest(other),expiresAt:'2099-01-01T00:00:00Z'},{id:EVALUATION_TESTER,sha256:await digest(token),expiresAt:'2099-01-01T00:00:00Z'}]),BUDGET:{idFromName:x=>x,get:()=>new BudgetLedger({storage:s})}}}}
const payload=c=>({version:3,requestID:crypto.randomUUID(),mode:'discovery',criteria:c.criteria});
const request=(p,auth=token,path='/v1/evaluation/answer')=>new Request('https://offline.invalid'+path,{method:'POST',headers:{Authorization:'Bearer '+auth,'Content-Type':'application/json'},body:JSON.stringify(p)});
const status=(e,auth=token)=>worker.fetch(new Request('https://offline.invalid/v1/evaluation/status',{headers:{Authorization:'Bearer '+auth}}),e);
function upstream(){let requests=0;const quotes=new Map();return {get requests(){return requests},send:async(_,options)=>{
 const body=JSON.parse(options.body);requests++;
 const structured=body.text?.format;
 if(!structured){
  const c=JSON.parse(body.input),url='https://public-example.org/'+c.region.toLowerCase();
  const date=new Date();if(c.intent==='upcoming_openings')date.setUTCDate(date.getUTCDate()+1);
  const iso=date.toISOString().slice(0,10),name='Public Fixture',quote=`${name} ${c.category} in ${c.region} ${c.intent==='upcoming_openings'?'will open':'opened'} on ${iso}.`;
  quotes.set(url,{c,date:iso,name,quote});
  return Response.json({model:'gpt-6-luna',status:'completed',usage:{input_tokens:1000,output_tokens:100},output:[{type:'web_search_call',status:'completed',action:{type:'search',sources:[{type:'url',url}]}},{type:'message',content:[{type:'output_text',text:quote,annotations:[{type:'url_citation',url,title:'Public fixture source',start_index:0,end_index:quote.length}]}]}]});
 }
 const input=JSON.parse(body.input),block=input.blocks[0],x=quotes.get(block.url);
 return Response.json({model:'gpt-6-luna',status:'completed',usage:{input_tokens:500,output_tokens:100},output:[{type:'message',content:[{type:'output_text',text:JSON.stringify({places:[{name:x.name,region:x.c.region,category:x.c.category,sourceURL:block.url,openingDate:x.date,openingKind:x.c.intent==='upcoming_openings'?'announced':'opened',evidence:x.quote}]})}]}]});
}}}
async function mock(send,fn){const original=globalThis.fetch;globalThis.fetch=send;try{return await fn()}finally{globalThis.fetch=original}}
test('status is authenticated dev-only tester-two-only, read-only and reflects actual seeded remaining allowance',async()=>{
 const {s,env}=await setup(),before=JSON.stringify([...s.values]);
 assert.equal((await status(env,'invalid')).status,401);assert.equal((await status(env,other)).status,403);
 assert.equal((await status({...env,ALLOW_DISCOVERY_EVALUATION:'false'})).status,503);
 assert.equal((await status({...env,ENVIRONMENT:'production'})).status,503);
 const value=await (await status(env)).json();assert.ok(verifiedEvaluationStatus(value));assert.equal(value.totalReservedMicroUSD,1200000);assert.equal(value.userReservedMicroUSD,0);assert.equal(value.availableAttempts,3);
 assert.equal(s.writes,0);assert.equal(JSON.stringify([...s.values]),before);
});
test('evaluation accepts only exact three public cases; no raw question/library/image or extra criteria reaches provider',async()=>{
 const {s,env}=await setup();let calls=0;
 await mock(async()=>{calls++;throw Error('must not call')},async()=>{
  for(const p of [{...payload(EVALUATION_CASES[0]),question:'PRIVATE'},{...payload(EVALUATION_CASES[0]),candidates:[]},{...payload(EVALUATION_CASES[0]),attachment:'PRIVATE'}, {...payload(EVALUATION_CASES[0]),criteria:{...EVALUATION_CASES[0].criteria,cuisine:'Italian'}}])assert.equal((await worker.fetch(request(p),env)).status,400);
 });assert.equal(calls,0);assert.equal(s.writes,0);
});
test('three cases compare same research with exactly six baseline calls, no candidate call; cap persists across recreation',async()=>{
 const {s,env}=await setup(),up=upstream();
 await mock(up.send,async()=>{
  for(const c of EVALUATION_CASES){const r=await worker.fetch(request(payload(c)),env);assert.equal(r.status,200);const body=await r.json();assert.equal(body.evaluation.baselineCalls,2);assert.equal(body.evaluation.candidateAdditionalCalls,0);assert.equal(body.evaluation.comparison.matchedCount,1);assert.equal(body.evaluation.stop,false);assert.ok(r.headers.get('Server-Timing').includes('research;dur='));}
  assert.equal(up.requests,6);assert.equal(s.values.get('total'),1800000);assert.equal(s.values.get('user:'+EVALUATION_TESTER),600000);
  const current=await (await status(env)).json();assert.equal(current.attemptedCount,3);assert.equal(current.availableAttempts,0);
  assert.equal((await worker.fetch(request(payload(EVALUATION_CASES[0])),env)).status,429);assert.equal(up.requests,6);
 });
});
test('normal path remains two calls and never writes evaluation keys or returns comparison',async()=>{
 const {s,env}=await setup(),up=upstream();await mock(up.send,async()=>{const r=await worker.fetch(request(payload(EVALUATION_CASES[0]),token,'/v1/answer'),{...env,ALLOW_DISCOVERY_EVALUATION:'false'});assert.equal(r.status,200);assert.equal((await r.json()).evaluation,undefined);assert.equal(up.requests,2);assert.equal([...s.values.keys()].some(x=>x.startsWith('evaluation:')),false)});
});
test('provider failure holds prior reservations and halts suite without retries or next case',async()=>{
 const {s,env}=await setup();let calls=0;await mock(async()=>{calls++;return new Response(null,{status:500})},async()=>{
  assert.equal((await worker.fetch(request(payload(EVALUATION_CASES[0])),env)).status,502);
  const current=await (await status(env)).json();assert.equal(current.halted,true);assert.equal(current.availableAttempts,0);assert.equal(s.values.get('total'),1400000);
  assert.equal((await worker.fetch(request(payload(EVALUATION_CASES[1])),env)).status,429);assert.equal(calls,1);
 });
});
test('insufficient original shared/user allowance reduces available count and prevents provider dispatch',async()=>{
 const {s,env}=await setup();s.values.set('total',4700000);s.values.set('user:'+EVALUATION_TESTER,2200000);
 assert.equal((await (await status(env)).json()).availableAttempts,1);
 s.values.set('total',4900000);let calls=0;await mock(async()=>{calls++;throw Error('no allowance')},async()=>{assert.equal((await worker.fetch(request(payload(EVALUATION_CASES[0])),env)).status,429)});assert.equal(calls,0);
});
test('pending/uncertain case blocks any next request and status never modifies counters',async()=>{
 const {s,env}=await setup(),p=payload(EVALUATION_CASES[0]);let release;const wait=new Promise(r=>release=r),up=upstream();
 await mock(async(...args)=>{await wait;return up.send(...args)},async()=>{
  const pending=worker.fetch(request(p),env);
  while(!s.values.has(prefix+':case:'+EVALUATION_CASES[0].id))await new Promise(r=>setTimeout(r,1));
  const writes=s.writes,current=await (await status(env)).json();assert.equal(current.availableAttempts,0);assert.equal(current.cases[0].state,'reserved');assert.equal(s.writes,writes);
  assert.equal((await worker.fetch(request(payload(EVALUATION_CASES[1])),env)).status,429);
  release();assert.equal((await pending).status,200);assert.equal(up.requests,2);
 });
});
test('old/malformed ledger cannot authorize a paid evaluation and live baseline cannot use mock mode',async()=>{
 const {s,env}=await setup();let calls=0;
 await mock(async()=>{calls++;throw Error('must not call')},async()=>{
  assert.equal((await worker.fetch(request(payload(EVALUATION_CASES[0])),{...env,LIVE_AI:'false',TEST_MODE:'true'})).status,503);
  const legacy={...env,BUDGET:{idFromName:x=>x,get:()=>({fetch:async()=>Response.json({reserved:true,protocol:2,reservationMicroUSD:50000})})}};
  assert.equal((await worker.fetch(request(payload(EVALUATION_CASES[0])),legacy)).status,503);
 });assert.equal(calls,0);assert.equal(s.writes,0);
});
test('concurrent duplicate case is admitted at most once with no extra candidate calls',async()=>{
 const {s,env}=await setup(),up=upstream();
 await mock(up.send,async()=>{
  const replies=await Promise.all([worker.fetch(request(payload(EVALUATION_CASES[0])),env),worker.fetch(request(payload(EVALUATION_CASES[0])),env)]);
  assert.equal(replies.filter(x=>x.status===200).length,1);assert.ok(replies.some(x=>[409,429].includes(x.status)));
  assert.equal(up.requests,2);assert.equal(s.values.get('total'),1400000);assert.equal(s.values.get(prefix+':count'),1);
 });
});
