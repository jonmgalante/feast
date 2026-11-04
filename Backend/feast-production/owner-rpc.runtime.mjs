// Isolated local workerd only. Fake credential, mocked provider; no account or simulator access.
import assert from 'node:assert/strict';import {createRequire} from 'node:module';import {readFile,mkdtemp,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join,resolve} from 'node:path';import {digest} from './broker.mjs';
const require=createRequire(new URL('../feast-proxy/package.json',import.meta.url));const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const packet=process.env.FEAST_OWNER_PACKET??'/tmp/feast-owner-validation-reviewed-v2';
const root=await mkdtemp(join(tmpdir(),'feast-owner-rpc-')),token='x'.repeat(43),now=Date.now(),record={id:'owner-original-iphone17',sha256:await digest(token),createdAt:new Date(now-1000).toISOString(),expiresAt:new Date(now+3600000).toISOString()};
const plan={operation:'list',scope:'library',city:'London',cuisine:null,status:null,placeType:null,name:null,positions:[],fields:[],neighborhood:null,groupBy:null,names:null};let providerCalls=0,countCalls=0;
const options={resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},workers:[
 {name:'owner',modulesRoot:root,compatibilityDate:'2026-10-20',modules:[{type:'ESModule',path:join(root,'owner.mjs'),contents:await readFile(resolve(packet,'owner/worker.js'),'utf8')}],bindings:{ENABLED:'true',LIVE_AI:'true',OWNER_TOKEN_HASHES_JSON:JSON.stringify([record])},serviceBindings:{PRODUCTION:{name:'production',entrypoint:'OwnerValidationRPC'}},outboundService:()=>{throw Error('Owner external network forbidden')}},
 {name:'production',modulesRoot:root,compatibilityDate:'2026-10-20',modules:[{type:'ESModule',path:join(root,'production.mjs'),contents:await readFile(resolve(packet,'production/worker.js'),'utf8')}],bindings:{ENVIRONMENT:'production',OWNER_VALIDATION_ENABLED:'true',LIVE_AI:'true',OPENAI_API_KEY:'offline-placeholder'},durableObjects:{PRODUCTION_STATE:{className:'ProductionLedger',useSQLite:true}},outboundService:async request=>{const url=new URL(request.url);assert.equal(url.origin,'https://api.openai.com');assert.equal(request.method,'POST');if(url.pathname==='/v1/responses/input_tokens'){countCalls++;return Response.json({input_tokens:1000})}assert.equal(url.pathname,'/v1/responses');providerCalls++;return Response.json({status:'completed',model:'gpt-6-astra',usage:{input_tokens:1000,output_tokens:100},output:[{type:'function_call',name:'read_saved_places',call_id:'offline-call',arguments:JSON.stringify(plan)}]})}}
]};let mf;
try{
 mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 const headers={Authorization:'Bearer '+token,'Content-Type':'application/json'};
 assert.equal((await mf.dispatchFetch('https://owner/v1/status')).status,401);
 const status=await(await mf.dispatchFetch('https://owner/v1/status',{headers})).json();assert.equal(status.remainingMicroUSD,20000000);assert.equal(providerCalls,0);
 const production=await mf.getWorker('production');assert.equal((await production.fetch('https://production/v1/answer',{method:'POST',headers,body:'{}'})).status,503);
 const p={version:6,mode:'libraryIntent',requestID:crypto.randomUUID(),text:'What is saved in London?',context:{index:[],recent:[]}},send=()=>mf.dispatchFetch('https://owner/v1/answer',{method:'POST',headers,body:JSON.stringify(p)});
 const response=await send();assert.equal(response.status,200);assert.deepEqual((await response.json()).plan,plan);assert.equal(providerCalls,1);assert.equal(countCalls,1);assert.equal((await send()).status,409);assert.equal(providerCalls,1);
 assert.equal((await(await mf.dispatchFetch('https://owner/v1/status',{headers})).json()).reservedMicroUSD,2500000);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await(await mf.dispatchFetch('https://owner/v1/status',{headers})).json()).reservedMicroUSD,2500000);assert.equal((await send()).status,409);assert.equal(providerCalls,1);
 console.log('PASS local workerd private named RPC + SQLite: auth, status without reservation, public route rejection, one mocked dispatch, duplicate blocking and persistent hold across restart. Zero external network.');
}finally{if(mf)await mf.dispose();await rm(root,{recursive:true,force:true})}
