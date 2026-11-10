// Isolated workerd/SQLite integration. No credentials or live provider requests.
// The test subclass disables foreground waiting and delays the first alarm so
// acceptance can be followed by a complete runtime restart before dispatch.
import assert from 'node:assert/strict';import {createRequire} from 'node:module';
import {mkdtemp,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join,resolve} from 'node:path';
import {phoneHash} from './phone-access.mjs';
const require=createRequire(new URL('../feast-proxy/package.json',import.meta.url));
const {build}=require('esbuild'),{Miniflare,convertV4MiniflareOptions}=require('miniflare');
const root=await mkdtemp(join(tmpdir(),'feast-answer-jobs-runtime-'));
const bundle=await build({stdin:{contents:`export {default} from './public-handler.mjs'; export {ProductionLedger} from './production-ledger.mjs'; import {AnswerJobs} from './answer-jobs.mjs'; export class AlarmOnlyAnswerJobs extends AnswerJobs { constructor(state,env){super(state,env,env.TEST_DELAY_ALARM==='true'?{now:()=>Date.now()+2000,foregroundWaitMs:0}:{})} }`,resolveDir:resolve('Backend/feast-production'),sourcefile:'alarm-only-fixture.mjs'},bundle:true,write:false,format:'esm',platform:'browser',external:['cloudflare:workers'],logLevel:'silent'});
const invitation='i'.repeat(43),token='t'.repeat(43),now=Date.now(),grant={id:crypto.randomUUID(),createdAt:now-1000,expiresAt:now+86400000,revoked:false,sha256:await phoneHash('invitation',invitation)};
let paid=0,counts=0;
const options={modulesRoot:root,modules:[{type:'ESModule',path:join(root,'worker.mjs'),contents:bundle.outputFiles[0].text}],compatibilityDate:'2026-10-20',
 bindings:{TEST_DELAY_ALARM:'true',PHONE_ACCESS_ENABLED:'true',PHONE_INVITATIONS_JSON:JSON.stringify([grant]),ENVIRONMENT:'production',OWNER_VALIDATION_ENABLED:'true',LIVE_AI:'true',ALLOW_RECONCILED_BUDGET:'true',ALLOW_PUBLIC_LOOKUP:'true',NATIVE_RESEARCH_ENABLED:'true',ASK_FEAST_RECOVERY_ENABLED:'true',OPENAI_API_KEY:'fixture-not-a-key'},
 durableObjects:{PRODUCTION_STATE:{className:'ProductionLedger',useSQLite:true},ANSWER_JOBS:{className:'AlarmOnlyAnswerJobs',useSQLite:true}},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},
 outboundService:async request=>{
  const url=new URL(request.url);assert.equal(url.origin,'https://api.openai.com','external network forbidden');
  if(url.pathname==='/v1/responses/input_tokens'){counts++;return Response.json({input_tokens:100})}
  assert.equal(url.pathname,'/v1/responses');paid++;const body=await request.json();assert.equal(body.model,'gpt-6.1-sol');assert.equal(body.store,false);
  return Response.json({status:'completed',model:body.model,usage:{input_tokens:1000,output_tokens:100},output:[{id:'offline',type:'message',role:'assistant',content:[{type:'output_text',text:'A durable offline fixture answer.',annotations:[]}]}]});
 }};
let mf;const headers={'Content-Type':'application/json',Authorization:'Bearer '+token,'X-Feast-Agent-Protocol':'10'};
const post=(path,p)=>mf.dispatchFetch('https://feast.test'+path,{method:'POST',headers,body:JSON.stringify(p)});
const p={version:10,mode:'conversationStep',requestID:crypto.randomUUID(),turnID:crypto.randomUUID(),step:0,text:'Read fixture context.',webAllowed:true,context:{index:[],recent:[]},cities:[],task:null,findings:[],history:[],historyCount:0,continuation:null,result:null};
const status=()=>post('/v1/answer-jobs',{version:1,op:'status',requestID:p.requestID,step:0});
try{
 mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await post('/v1/access/activate',{version:1,invitation,deviceID:crypto.randomUUID(),activationID:crypto.randomUUID(),credentialHash:await phoneHash('device',token)})).status,200);
 const submitted=await(await post('/v1/answer-jobs',{version:1,op:'submit',request:p})).json();assert.equal(submitted.state,'queued');assert.equal(paid,0);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 let completed;for(let i=0;i<100;i++){completed=await(await status()).json();if(completed.state==='completed')break;await new Promise(r=>setTimeout(r,100))}
 assert.equal(completed.state,'completed',JSON.stringify({completed,paid,counts}));assert.equal(completed.result.text,'A durable offline fixture answer.');assert.equal(completed.result.budget,undefined);assert.equal(paid,1);assert.equal(counts,1);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.deepEqual(await(await post('/v1/answer-jobs',{version:1,op:'submit',request:p})).json(),completed);assert.equal(paid,1);
 assert.equal((await post('/v1/answer-jobs',{version:1,op:'submit',request:{...p,text:'Different content'}})).status,409);
 const acknowledged=await(await post('/v1/answer-jobs',{version:1,op:'ack',requestID:p.requestID,step:0})).json();assert.equal(acknowledged.state,'acknowledged');assert.equal(acknowledged.result,undefined);
 await mf.dispose();options.bindings.TEST_DELAY_ALARM='false';mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 const fast={...p,requestID:crypto.randomUUID(),turnID:crypto.randomUUID()},started=performance.now();
 const fastResult=await(await post('/v1/answer-jobs',{version:1,op:'submit',request:fast})).json();assert.equal(fastResult.state,'completed');assert(performance.now()-started<1500,'foreground must not impose a polling interval');assert.equal(paid,2);
 const cancelled={...p,requestID:crypto.randomUUID(),turnID:crypto.randomUUID()};
 const stop=await(await post('/v1/answer-jobs',{version:1,op:'cancel',requestID:cancelled.requestID,step:0})).json();assert.equal(stop.state,'cancelled');
 assert.equal((await(await post('/v1/answer-jobs',{version:1,op:'submit',request:cancelled})).json()).state,'cancelled');assert.equal(paid,2);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await(await post('/v1/answer-jobs',{version:1,op:'status',requestID:cancelled.requestID,step:0})).json()).state,'cancelled');assert.equal(paid,2);
 console.log('PASS real offline SQLite/workerd: atomic accepted job/alarm survives runtime restart before dispatch; exactly one mocked provider call; durable result retrieval/replay, mismatch rejection, sponsor redaction, acknowledgment, and ownership-claimed cancel-before-submit across restart. Zero live provider calls.');
}finally{if(mf)await mf.dispose();await rm(root,{recursive:true,force:true})}
