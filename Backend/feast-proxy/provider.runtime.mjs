// Actual local workerd transport, mocked OpenAI. No real key or external connection.
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {digest} from './worker.mjs';
const root=await mkdtemp(join(tmpdir(),'feast-provider-runtime-'));
const token='a'.repeat(43),token2='b'.repeat(43);
const users=JSON.stringify([{id:'tester-one',sha256:await digest(token),expiresAt:'2026-11-22T14:30:00Z'},{id:'tester-two',sha256:await digest(token2),expiresAt:'2026-11-22T14:30:00Z'}]);
const answer={summary:'Fictional runtime result',candidateIDs:['fixture'],paragraphs:[{id:'answer',spans:[{type:'place',value:'fixture'}],sourceIDs:['source']}]};
let providerCalls=0;
const modules=await Promise.all(['worker.mjs','library-intent.mjs','openai.mjs','discovery.mjs','evaluation.mjs','discovery-local-candidate.mjs'].map(async name=>({type:'ESModule',path:join(root,name),contents:(await readFile(new URL(name,import.meta.url),'utf8')).replace('reservation_held\',reason},502)','reservation_held\',reason,diagnostic:String(error)},502)')})));
const mf=new Miniflare(convertV4MiniflareOptions({modules,modulesRoot:root,compatibilityDate:'2026-10-20',durableObjects:{BUDGET:{className:'BudgetLedger',useSQLite:true}},telemetry:{enabled:false},bindings:{ENVIRONMENT:'dev',ENABLED:'true',LIVE_AI:'true',TEST_MODE:'false',OPENAI_API_KEY:'fake-runtime-key',CLIENT_TOKEN_HASHES_JSON:users},outboundService:async request=>{
 assert.equal(request.url,'https://api.openai.com/v1/responses');assert.equal(request.headers.get('Authorization'),'Bearer fake-runtime-key');providerCalls++;
 return Response.json({status:'completed',model:'gpt-6-luna',usage:{input_tokens:1000,output_tokens:100},output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(answer)}]}]});
}}));
try{
 await mf.ready;const response=await mf.dispatchFetch('https://test.invalid/v1/answer',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify({version:1,synthetic:true,consent:true,requestID:crypto.randomUUID(),mode:'collection',text:'Fictional?',candidates:[{id:'fixture',name:'Fictional Fixture',sourceIDs:['source']}],sources:[{id:'source',author:'Fictional',excerpt:'Synthetic note'}]})});
 const body=await response.json();assert.equal(response.status,200,JSON.stringify(body));assert.equal(providerCalls,1);assert.equal(body.model,'gpt-6-luna');assert.equal(body.budget.reservedMicroUSD,50000);assert.equal(body.budget.estimatedUsageMicroUSD,175);console.log('PASS local workerd live-adapter path dispatches once to mocked OpenAI and records a five-cent reservation plus usage. No real network or credentials.');
}finally{await mf.dispose();await rm(root,{recursive:true,force:true});}
