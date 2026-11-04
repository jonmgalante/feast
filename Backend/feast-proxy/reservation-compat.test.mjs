// All provider attempts intercepted; fake credentials only. No real network or ledger.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import worker,{BudgetLedger,digest} from './worker.mjs';
const token='a'.repeat(43),now=new Date('2026-10-24T12:00:00Z');
const oldCode=execFileSync('git',['show','fd506ec:Backend/feast-proxy/worker.mjs'],{encoding:'utf8'}).replace("from './openai.mjs'",'from '+JSON.stringify(pathToFileURL(new URL('openai.mjs',import.meta.url).pathname).href));
const legacy=await import('data:text/javascript;base64,'+Buffer.from(oldCode).toString('base64'));
function store(){const values=new Map();let queue=Promise.resolve();return {values,storage:{transaction(fn){const p=queue.then(()=>fn({get:async k=>values.get(k),put:async(k,v)=>values.set(k,v)}));queue=p.catch(()=>{});return p}}}}
async function env(ledger){return {ENVIRONMENT:'dev',ENABLED:'true',LIVE_AI:'true',ALLOW_DISCOVERY:'true',OPENAI_API_KEY:'public-fake',CLIENT_TOKEN_HASHES_JSON:JSON.stringify([{id:'one',sha256:await digest(token),expiresAt:'2099-01-01T00:00:00Z'},{id:'two',sha256:await digest('b'.repeat(43)),expiresAt:'2099-01-01T00:00:00Z'}]),BUDGET:{idFromName:x=>x,get:()=>ledger}}}
const payload=()=>({version:3,requestID:crypto.randomUUID(),mode:'discovery',criteria:{category:'cafe',region:'Manhattan',intent:'recent_openings',windowDays:30,period:'calendar_month'}});
const request=p=>new Request('https://offline.invalid/v1/answer',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(p)});
async function intercepted(fn){const original=globalThis.fetch;let attempts=0;globalThis.fetch=async()=>{attempts++;throw Error('Network blocked by compatibility test')};try{return await fn(()=>attempts)}finally{globalThis.fetch=original}}

test('new discovery Worker + real previous ledger fails before upstream and retains old hold without reset',()=>intercepted(async calls=>{
 const state=store(),ledger=new legacy.BudgetLedger({storage:state.storage}),e=await env(ledger),p=payload();
 const r=await worker.fetch(request(p),e);assert.equal(r.status,503);assert.equal((await r.json()).error,'budget_reservation_unverified');assert.equal(calls(),0);
 assert.equal(state.values.get('total'),50000);assert.equal(state.values.get('user:one'),50000);
 assert.equal((await worker.fetch(request(p),e)).status,409);assert.equal(state.values.get('total'),50000);assert.equal(calls(),0);
}));
test('new/new commits $0.20 proof before any upstream attempt',()=>intercepted(async calls=>{
 const state=store(),ledger=new BudgetLedger({storage:state.storage}),e=await env(ledger),p=payload();
 const r=await worker.fetch(request(p),e);assert.equal(r.status,502);assert.equal(calls(),1);assert.equal(state.values.get('total'),200000);
 const stored=state.values.get('request:one:'+p.requestID);assert.equal(stored.reserved,200000);
}));
test('missing/malformed/too-small/stale proof cannot dispatch and is not retried',()=>intercepted(async calls=>{
 for(const variant of ['invalid-json','empty','legacy','small','string','wrong-protocol','wrong-request','not-reserved']){
  let requests=0;const p=payload();const proof={reserved:true,protocol:2,reservationMicroUSD:200000,requestID:p.requestID};
  if(variant==='small')proof.reservationMicroUSD=50000;
  if(variant==='string')proof.reservationMicroUSD='200000';
  if(variant==='wrong-protocol')proof.protocol=1;
  if(variant==='wrong-request')proof.requestID=crypto.randomUUID();
  if(variant==='not-reserved')proof.reserved=false;
  const ledger={fetch:async()=>{requests++;return variant==='invalid-json'?new Response('{'):Response.json(variant==='empty'?{}:variant==='legacy'?{reserved:true}:proof)}};
  const r=await worker.fetch(request(p),await env(ledger));assert.equal(r.status,503,variant);assert.equal(requests,1,variant);assert.equal(calls(),0,variant);
 }
}));
test('old text Worker + new ledger remains compatible with $0.05 default and usage settlement',()=>intercepted(async calls=>{
 const state=store(),ledger=new BudgetLedger({storage:state.storage}),e=await env(ledger);e.LIVE_AI='false';e.TEST_MODE='true';
 const p={version:1,synthetic:true,consent:true,requestID:crypto.randomUUID(),mode:'collection',text:'Public fixture',candidates:[],sources:[]};
 assert.equal((await legacy.default.fetch(request(p),e)).status,200);assert.equal(state.values.get('total'),50000);assert.equal(calls(),0);
 const r=await ledger.fetch(new Request('https://ledger/settle',{method:'POST',body:JSON.stringify({user:'one',id:p.requestID,usage:{estimatedMicroUSD:175}})}));
 assert.equal(r.status,200);const receipt=await r.json();assert.equal(receipt.budget.reservedMicroUSD,50000);assert.equal(receipt.budget.estimatedUsageMicroUSD,175);
}));
test('new text Worker + previous ledger stays compatible without requiring a web proof',()=>intercepted(async calls=>{
 const state=store(),ledger=new legacy.BudgetLedger({storage:state.storage}),e=await env(ledger);e.LIVE_AI='false';e.TEST_MODE='true';
 const p={version:1,synthetic:true,consent:true,requestID:crypto.randomUUID(),mode:'collection',text:'Public fixture',candidates:[],sources:[]};
 assert.equal((await worker.fetch(request(p),e)).status,200);assert.equal(state.values.get('total'),50000);assert.equal(calls(),0);
}));
test('ledger returns proof only after transaction commits; duplicate proof is not reusable',async()=>{
 const state=store(),ledger=new BudgetLedger({storage:state.storage}),id=crypto.randomUUID();
 const req=()=>new Request('https://ledger/reserve',{method:'POST',body:JSON.stringify({user:'one',id,fingerprint:'a'.repeat(64),amount:200000})});
 const r=await ledger.fetch(req()),p=await r.json();assert.equal(r.status,200);assert.deepEqual(p,{reserved:true,protocol:2,reservationMicroUSD:200000,requestID:id});
 assert.equal(state.values.get('total'),200000);const duplicate=await ledger.fetch(req());assert.equal(duplicate.status,409);assert.equal((await duplicate.json()).reserved,false);assert.equal(state.values.get('total'),200000);
});
