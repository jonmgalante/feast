// Actual local workerd + SQLite with fake credential and mocked provider only.
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {digest} from './worker.mjs';
const root=await mkdtemp(join(tmpdir(),'feast-library-runtime-')),token='a'.repeat(43);
const users=JSON.stringify([{id:'fixture-one',sha256:await digest(token),expiresAt:'2099-01-01T00:00:00Z'},{id:'fixture-two',sha256:await digest('b'.repeat(43)),expiresAt:'2099-01-01T00:00:00Z'}]);
const modules=await Promise.all(['worker.mjs','library-intent.mjs','openai.mjs','discovery.mjs','evaluation.mjs','discovery-local-candidate.mjs'].map(async name=>({type:'ESModule',path:join(root,name),contents:await readFile(new URL(name,import.meta.url),'utf8')})));
const plan={operation:'list',scope:'library',city:'London',cuisine:null,status:null,placeType:null,name:null,positions:[],fields:[]};let calls=0;
const mf=new Miniflare(convertV4MiniflareOptions({modules,modulesRoot:root,compatibilityDate:'2026-10-20',durableObjects:{BUDGET:{className:'BudgetLedger',useSQLite:true}},telemetry:{enabled:false},bindings:{ENVIRONMENT:'dev',ENABLED:'true',LIVE_AI:'true',TEST_MODE:'false',ALLOW_SAVED_METADATA:'true',ALLOW_LIBRARY_TOOLS:'true',OPENAI_API_KEY:'offline-fake',CLIENT_TOKEN_HASHES_JSON:users},outboundService:async request=>{
 assert.equal(request.url,'https://api.openai.com/v1/responses');const body=await request.json();calls++;assert.deepEqual(body.input,[{role:'user',content:'Show saved places in London'}]);assert.equal(body.tools[0].name,'read_saved_places');
 return Response.json({status:'completed',model:'gpt-6-luna',usage:{input_tokens:1000,output_tokens:100},output:[{type:'function_call',name:'read_saved_places',arguments:JSON.stringify(plan)}]});
}}));
try{
 await mf.ready;const payload={version:4,mode:'libraryIntent',requestID:crypto.randomUUID(),text:'Show saved places in London'};
 const send=()=>mf.dispatchFetch('https://test.invalid/v1/answer',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify(payload)});
 const response=await send(),body=await response.json();assert.equal(response.status,200,JSON.stringify(body));assert.deepEqual(body.plan,plan);assert.equal(body.budget.reservedMicroUSD,50000);assert.equal(body.budget.userReservedMicroUSD,50000);assert.equal(calls,1);
 assert.equal((await send()).status,409);assert.equal(calls,1);
 console.log('PASS actual local workerd+SQLite read-plan flow: one mocked model call, original $0.05 hold, stable user identity, duplicate blocked, no private records transmitted.');
}finally{await mf.dispose();await rm(root,{recursive:true,force:true})}
