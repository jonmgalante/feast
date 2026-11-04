// Actual local workerd + SQLite + mocked OpenAI. Never deployed bindings.
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {digest} from './worker.mjs';
const root=await mkdtemp(join(tmpdir(),'feast-evaluation-runtime-'));
const token='a'.repeat(43),date=new Date().toISOString().slice(0,10),url='https://public-example.org/runtime';
const quote=`Public Runtime Coffee cafe in Manhattan opened on ${date}.`;
const users=JSON.stringify([{id:'feast-dev-tester-two',sha256:await digest(token),expiresAt:'2099-01-01T00:00:00Z'},{id:'feast-dev-tester-one',sha256:await digest('b'.repeat(43)),expiresAt:'2099-01-01T00:00:00Z'}]);
// Test module only maps replacement to this runtime's fake token; deployed source is unchanged.
const modules=await Promise.all(['worker.mjs','library-intent.mjs','openai.mjs','discovery.mjs','evaluation.mjs','discovery-local-candidate.mjs'].map(async name=>({type:'ESModule',path:join(root,name),contents:name==='worker.mjs' ? (await readFile(new URL(name,import.meta.url),'utf8')).replace(/const TESTER_TWO_REPLACEMENT_HASH = '[a-f0-9]{64}';/, `const TESTER_TWO_REPLACEMENT_HASH = '${await digest(token)}';`) : await readFile(new URL(name,import.meta.url),'utf8')})));
let calls=0;
const options={modules,modulesRoot:root,compatibilityDate:'2026-10-20',durableObjects:{BUDGET:{className:'BudgetLedger',useSQLite:true}},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},bindings:{ENVIRONMENT:'dev',ENABLED:'true',LIVE_AI:'true',TEST_MODE:'false',ALLOW_DISCOVERY:'true',ALLOW_DISCOVERY_EVALUATION:'true',OPENAI_API_KEY:'public-fake-not-a-key',CLIENT_TOKEN_HASHES_JSON:users},outboundService:async request=>{
 assert.equal(request.url,'https://api.openai.com/v1/responses');assert.equal(request.headers.get('Authorization'),'Bearer public-fake-not-a-key');
 const body=await request.json();calls++;
 if(body.tools){assert.equal(body.max_tool_calls,1);return Response.json({status:'completed',model:'gpt-6-luna',usage:{input_tokens:1000,output_tokens:100},output:[{type:'web_search_call',status:'completed',action:{type:'search',sources:[{type:'url',url}]}},{type:'message',content:[{type:'output_text',text:quote,annotations:[{type:'url_citation',url,title:'Public runtime fixture',start_index:0,end_index:quote.length}]}]}]})}
 return Response.json({status:'completed',model:'gpt-6-luna',usage:{input_tokens:500,output_tokens:100},output:[{type:'message',content:[{type:'output_text',text:JSON.stringify({places:[{name:'Public Runtime Coffee',region:'Manhattan',category:'cafe',cuisine:null,sourceURL:url,openingDate:date,openingKind:'opened',evidence:quote}]})}]}]});
}};
const p={version:3,requestID:crypto.randomUUID(),mode:'discovery',criteria:{category:'cafe',region:'Manhattan',intent:'recent_openings',windowDays:30,period:'calendar_month'}};
const send=mf=>mf.dispatchFetch('https://offline.invalid/v1/evaluation/answer',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(p)});
let mf;
try{
 mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 const read=async()=> (await mf.dispatchFetch('https://offline.invalid/v1/evaluation/status',{headers:{Authorization:'Bearer '+token}})).json();
 const prior=await mf.dispatchFetch('https://offline.invalid/v1/answer',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({...p,requestID:crypto.randomUUID()})});
 assert.equal(prior.status,200);assert.equal(calls,2);
 const before=await read();assert.equal(before.totalReservedMicroUSD,200000);assert.equal(before.availableAttempts,3);assert.deepEqual(await read(),before);assert.equal(calls,2);
 const r=await send(mf),body=await r.json();assert.equal(r.status,200,JSON.stringify(body));assert.equal(body.evaluation.candidateAdditionalCalls,0);assert.equal(body.evaluation.comparison.matchedCount,1);assert.equal(body.budget.reservedMicroUSD,400000);assert.equal(calls,4);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await send(mf)).status,409);assert.equal(calls,4);
 const resumed=await read();assert.equal(resumed.attemptedCount,1);assert.equal(resumed.totalReservedMicroUSD,400000);
 // Direct internal ledger probes are test-only, to stress the persisted suite reservation cap without extra provider calls.
 const namespace=await mf.getDurableObjectNamespace('BUDGET'),ledger=namespace.get(namespace.idFromName('shared-lifetime-v1'));
 const reserve=caseID=>ledger.fetch('https://ledger/evaluation-reserve',{method:'POST',body:JSON.stringify({user:'feast-dev-tester-two',id:crypto.randomUUID(),fingerprint:'a'.repeat(64),amount:200000,runID:'local-extraction-20261025-v1',caseID})});
 assert.equal((await reserve('philadelphia-bakery-today')).status,200);assert.equal((await reserve('london-bakery-upcoming30')).status,200);
 assert.equal((await reserve('london-bakery-upcoming30')).status,409);
 const final=await read();assert.equal(final.attemptedCount,3);assert.equal(final.availableAttempts,0);assert.equal(final.totalReservedMicroUSD,800000);assert.equal(calls,4);
 console.log('PASS isolated workerd/SQLite: status is read-only; prior ordinary hold survives; one comparison uses exactly two mocked baseline calls and zero candidate calls; same-case replay denied across restart; $0.60 suite reservation cap persists. Fake credentials, no external network.');

}finally{if(mf)await mf.dispose();await rm(root,{recursive:true,force:true});}
