// Actual local workerd + SQLite + mocked OpenAI. Never deployed bindings.
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
import {digest} from './worker.mjs';
const root=await mkdtemp(join(tmpdir(),'feast-discovery-runtime-'));
const token='a'.repeat(43),date=new Date().toISOString().slice(0,10),url='https://public-example.org/runtime';
const quote=`Public Runtime Coffee cafe in Manhattan opened on ${date}.`;
const users=JSON.stringify([{id:'one',sha256:await digest(token),expiresAt:'2099-01-01T00:00:00Z'},{id:'two',sha256:await digest('b'.repeat(43)),expiresAt:'2099-01-01T00:00:00Z'}]);
const modules=await Promise.all(['worker.mjs','library-intent.mjs','openai.mjs','discovery.mjs','evaluation.mjs','discovery-local-candidate.mjs'].map(async name=>({type:'ESModule',path:join(root,name),contents:await readFile(new URL(name,import.meta.url),'utf8')})));
let calls=0;
const options={modules,modulesRoot:root,compatibilityDate:'2026-10-20',durableObjects:{BUDGET:{className:'BudgetLedger',useSQLite:true}},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},bindings:{ENVIRONMENT:'dev',ENABLED:'true',LIVE_AI:'true',TEST_MODE:'false',ALLOW_DISCOVERY:'true',OPENAI_API_KEY:'public-fake-not-a-key',CLIENT_TOKEN_HASHES_JSON:users},outboundService:async request=>{
 assert.equal(request.url,'https://api.openai.com/v1/responses');assert.equal(request.headers.get('Authorization'),'Bearer public-fake-not-a-key');
 const body=await request.json();calls++;
 if(body.tools){assert.equal(body.max_tool_calls,1);return Response.json({status:'completed',model:'gpt-6-luna',usage:{input_tokens:1000,output_tokens:100},output:[{type:'web_search_call',status:'completed',action:{type:'search',sources:[{type:'url',url}]}},{type:'message',content:[{type:'output_text',text:quote,annotations:[{type:'url_citation',url,title:'Public runtime fixture',start_index:0,end_index:quote.length}]}]}]})}
 return Response.json({status:'completed',model:'gpt-6-luna',usage:{input_tokens:500,output_tokens:100},output:[{type:'message',content:[{type:'output_text',text:JSON.stringify({places:[{name:'Public Runtime Coffee',region:'Manhattan',category:'cafe',cuisine:null,sourceURL:url,openingDate:date,openingKind:'opened',evidence:quote}]})}]}]});
}};
const p={version:3,requestID:crypto.randomUUID(),mode:'discovery',criteria:{category:'cafe',region:'Manhattan',intent:'recent_openings',windowDays:30,period:'calendar_month'}};
const send=mf=>mf.dispatchFetch('https://offline.invalid/v1/answer',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(p)});
let mf;
try{
 mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 const r=await send(mf),body=await r.json();assert.equal(r.status,200,JSON.stringify(body));assert.equal(body.version,2);assert.equal(body.budget.reservedMicroUSD,200000);assert.equal(body.budget.userReservedMicroUSD,200000);assert.equal(body.usage.webCalls,1);assert.equal(body.paragraphs[0].citations[0].url,url);assert.equal(calls,2);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await send(mf)).status,409);assert.equal(calls,2);
 console.log('PASS actual local workerd: discovery verifies committed $0.20 proof, returns cited mock opening, settles usage, and rejects duplicate after SQLite restart without another upstream attempt. Fake key; no external API or deployed namespace.');
}finally{if(mf)await mf.dispose();await rm(root,{recursive:true,force:true});}
