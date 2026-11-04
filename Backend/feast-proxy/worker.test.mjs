import { test } from 'node:test';
import assert from 'node:assert/strict';
import worker, { BudgetLedger, digest } from './worker.mjs';
const token = 'a'.repeat(43), token2 = 'b'.repeat(43);
const payload = (id = crypto.randomUUID()) => ({ version: 1, synthetic: true, consent: true, requestID: id, mode: 'collection', text: 'Synthetic?', candidates: [{ id: 'fixture', name:'Synthetic fixture', sourceIDs:['source'] }], sources:[{id:'source',author:'Synthetic author',excerpt:'Fictional note'}] });
function ledger() {
  const data = new Map(); let queue = Promise.resolve();
  const storage = { transaction(fn) { const job = queue.then(() => fn({ get: async k => data.get(k), put: async (k,v) => data.set(k,v) })); queue = job.catch(() => {}); return job; } };
  return new BudgetLedger({ storage });
}
async function env() {
  const instance = ledger();
  return { ENABLED:'true', ENVIRONMENT:'dev', TEST_MODE:'true', CLIENT_TOKEN_HASHES_JSON:JSON.stringify([{id:'tester-one',sha256:await digest(token),expiresAt:'2026-11-22T14:30:00Z'},{id:'tester-two',sha256:await digest(token2),expiresAt:'2026-11-22T14:30:00Z'}]), BUDGET:{idFromName:x=>x,get:()=>instance} };
}
const req = (p, bearer=token) => new Request('https://test.invalid/v1/answer',{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${bearer}`},body:JSON.stringify(p)});
test('disabled, missing auth and production all fail closed',async()=>{
 const e=await env(); assert.equal((await worker.fetch(req(payload()),{...e,ENABLED:'false'})).status,503);
 assert.equal((await worker.fetch(req(payload(),'x'),e)).status,401);
 assert.equal((await worker.fetch(req(payload()),{...e,ENVIRONMENT:'production'})).status,503);
});
test('synthetic consent and byte bounds; no real payloads',async()=>{
 const e=await env(); for(const p of [{...payload(),synthetic:false},{...payload(),consent:false},{...payload(),mode:'discovery'},{...payload(),text:'x'.repeat(4001)}]) assert.equal((await worker.fetch(req(p),e)).status,400);
 assert.equal((await worker.fetch(req({...payload(),extra:'x'.repeat(33000)}),e)).status,400);
});
test('mock roundtrip and duplicate request cannot reserve twice',async()=>{
 const e=await env(), p=payload();const r=await worker.fetch(req(p),e);assert.equal(r.status,200);assert.deepEqual((await r.json()).candidateIDs,['fixture']);
 assert.equal((await worker.fetch(req(p),e)).status,409);
});
test('concurrent lifetime and per-user reservations never exceed caps',async()=>{
 const l=ledger();let tick=0;l.now=()=>tick++*60000;const send=user=>l.fetch(new Request('https://ledger/reserve',{method:'POST',body:JSON.stringify({user,id:crypto.randomUUID(),fingerprint:'c'.repeat(64)})}));
 const results=await Promise.all(Array.from({length:240},(_,i)=>send(i%2?'tester-one':'tester-two')));
 assert.equal(results.filter(x=>x.status===200).length,100); assert.equal(results.filter(x=>x.status===429).length,140);
});
test('ledger unavailable prevents output',async()=>{const e=await env();e.BUDGET.get=()=>{throw Error('offline')};assert.equal((await worker.fetch(req(payload()),e)).status,503)});

test('two-user allowlist rejects duplicate hashes and revoked tester',async()=>{
 const e=await env();const users=JSON.parse(e.CLIENT_TOKEN_HASHES_JSON);users[1].sha256=users[0].sha256;
 assert.equal((await worker.fetch(req(payload()),{...e,CLIENT_TOKEN_HASHES_JSON:JSON.stringify(users)})).status,401);
 users[1].sha256=await digest('c'.repeat(43));
 assert.equal((await worker.fetch(req(payload(),token2),{...e,CLIENT_TOKEN_HASHES_JSON:JSON.stringify(users)})).status,401);
});
test('single-user limit survives object recreation and duplicate changed payload is denied',async()=>{
 const l=ledger();let tick=0;l.now=()=>tick++*60000; const id=crypto.randomUUID();
 const send=(object,key=id,hash='c'.repeat(64))=>object.fetch(new Request('https://ledger/reserve',{method:'POST',body:JSON.stringify({user:'tester-one',id:key,fingerprint:hash})}));
 assert.equal((await send(l)).status,200);assert.equal((await send(l,id,'d'.repeat(64))).status,409);
 await Promise.all(Array.from({length:49},()=>send(l,crypto.randomUUID())));
 const recreated=new BudgetLedger({storage:l.storage});recreated.now=()=>tick++*60000;
 assert.equal((await send(recreated,crypto.randomUUID())).status,429);
});
test('malformed candidates fail validation without ledger work',async()=>{
 const e=await env();assert.equal((await worker.fetch(req({...payload(),candidates:[null]}),e)).status,400);
});

test('dev/prod configuration stays disabled and SQLite-only',async()=>{
 const {readFile}=await import('node:fs/promises');
 const config=JSON.parse(await readFile(new URL('./wrangler.jsonc',import.meta.url),'utf8'));
 for(const name of ['dev','production']) {
  const e=config.env[name];assert.equal(e.vars.ENABLED,'false');assert.equal(e.workers_dev,name==='dev');
  assert.deepEqual(e.migrations[0].new_sqlite_classes,['BudgetLedger']);
 }
 assert.equal(config.observability.enabled,false);
});

test('public health reports disabled model dispatch without exposing any secret',async()=>{
 const e=await env();e.ENABLED='false';e.OPENAI_API_KEY='not-a-real-key';
 const response=await worker.fetch(new Request('https://test.invalid/health'),e);
 assert.equal(response.status,200); const body=await response.json();assert.equal(body.liveAI,false);assert.equal(body.requestsEnabled,false);assert.equal(JSON.stringify(body).includes(e.OPENAI_API_KEY),false);
 assert.equal((await worker.fetch(req(payload()),e)).status,503);
 assert.equal((await worker.fetch(req(payload(),'invalid'),e)).status,401);
});
test('rate limit shares the transactional ledger and resets only its minute window',async()=>{
 const l=ledger();let minute=0;l.now=()=>minute*60000;
 const send=()=>l.fetch(new Request('https://ledger/reserve',{method:'POST',body:JSON.stringify({user:'tester-one',id:crypto.randomUUID(),fingerprint:'c'.repeat(64)})}));
 const results=await Promise.all(Array.from({length:8},send));assert.equal(results.filter(x=>x.status===200).length,6);
 minute=1;assert.equal((await send()).status,200);assert.equal(await l.storage.transaction(tx=>tx.get('total')),350000);
});
test('strict evidence contract rejects extra fields, malformed IDs and source forgery',async()=>{
 const e=await env(),p=payload();for(const value of [{...p,rawImage:'blocked'},{...p,requestID:'-'.repeat(36)},
  {...p,sources:[...p.sources,...p.sources]},{...p,candidates:[{...p.candidates[0],sourceIDs:['forged']}]},
  {...p,sources:[{...p.sources[0],excerpt:'x'.repeat(1501)}]}]) assert.equal((await worker.fetch(req(value),e)).status,400);
});

test('expired or missing tester expiry denies authentication before budget work',async()=>{
 const e=await env(),users=JSON.parse(e.CLIENT_TOKEN_HASHES_JSON);
 for(const expiry of ['2020-01-01T00:00:00Z',undefined,'invalid']) {users[0].expiresAt=expiry;assert.equal((await worker.fetch(req(payload()),{...e,CLIENT_TOKEN_HASHES_JSON:JSON.stringify(users)})).status,401);}
});
test('usage recording is idempotent and never releases lifetime reservation',async()=>{
 const l=ledger(),id=crypto.randomUUID(),user='tester-one';
 const send=(path,p)=>l.fetch(new Request('https://ledger/'+path,{method:'POST',body:JSON.stringify(p)}));
 assert.equal((await send('reserve',{user,id,fingerprint:'c'.repeat(64)})).status,200);
 const usage={input:1000,output:100,estimatedMicroUSD:175};
 for(let i=0;i<2;i++){const response=await send('settle',{user,id,usage});assert.equal(response.status,200);const receipt=await response.json();assert.deepEqual(receipt.budget,{reservedMicroUSD:50000,userReservedMicroUSD:50000,estimatedUsageMicroUSD:175});}
 assert.equal(await l.storage.transaction(tx=>tx.get('estimatedUsage')),175);
 assert.equal(await l.storage.transaction(tx=>tx.get('total')),50000);
 assert.equal((await send('settle',{user,id:crypto.randomUUID(),usage})).status,404);
 assert.equal((await send('settle',{user,id,usage:{estimatedMicroUSD:50001}})).status,400);
});

test('failed live upstream attempt holds reservation and duplicate does not dispatch again',async()=>{
 const e={...await env(),TEST_MODE:'false',LIVE_AI:'true',OPENAI_API_KEY:'synthetic-key'},p=payload();
 const original=globalThis.fetch;let calls=0;globalThis.fetch=async()=>{calls++;throw Error('mock timeout')};
 try {assert.equal((await worker.fetch(req(p),e)).status,502);assert.equal((await worker.fetch(req(p),e)).status,409);assert.equal(calls,1);
 assert.equal(await e.BUDGET.get().storage.transaction(tx=>tx.get('total')),50000);
 } finally {globalThis.fetch=original}
});
test('missing provider key prevents dispatch and reservation',async()=>{
 const e={...await env(),TEST_MODE:'false',LIVE_AI:'true'};assert.equal((await worker.fetch(req(payload()),e)).status,503);
 assert.equal(await e.BUDGET.get().storage.transaction(tx=>tx.get('total')),undefined);
});
