// Real workerd/SQLite storage. The only fixture routes live in this generated
// test bundle, never in the production worker. No outbound network is allowed.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const require=createRequire(new URL('../feast-proxy/package.json',import.meta.url));
const {build}=require('esbuild'),{Miniflare,convertV4MiniflareOptions}=require('miniflare');
const indexed=process.env.FEAST_INDEX_TEST==='true',historyCount=Number(process.env.FEAST_INDEX_HISTORY??1000),recordPadding=Number(process.env.FEAST_INDEX_PADDING??0);if(!Number.isSafeInteger(historyCount)||historyCount<0)throw Error('fixture_history_count');
const root=await mkdtemp(join(tmpdir(),'feast-execution-runtime-'));
const bundle=await build({stdin:{contents:`
 import {ProductionLedger} from './production-ledger.mjs';
 import {executionInventory,applyExecutionMigration} from './execution-migration.mjs';
 import {prepareAccountingIndexPlan,beginAccountingIndex,advanceAccountingIndex,activateAccountingIndex,accountingIndexStatus,auditAccountingIndex,rawAccountingStorage,INDEX} from './accounting-index.mjs';
 export class FixtureLedger extends ProductionLedger {
  constructor(state,env){super(state,env,{now:()=>Date.now()+Number(env.FIXTURE_OFFSET)})}
  async fetch(request){const path=new URL(request.url).pathname;
   if(path==='/fixture/bootstrap'){if(this.env.FIXTURE_INDEX==='true')await this.storage.transaction(async tx=>{for(let i=0;i<Number(this.env.FIXTURE_HISTORY);i++)await tx.put('production-validation-v2:request:'+crypto.randomUUID(),{profile:'saved',userHash:'a'.repeat(64),reservedMicroUSD:2500000,state:'complete',usage:[{model:'gpt-6-astra',inputTokens:1000,outputTokens:100,webCalls:0}],conservativeUsageMicroUSD:33000,...Number(this.env.FIXTURE_PADDING)?{retainedUnknownField:'x'.repeat(Number(this.env.FIXTURE_PADDING))}:{}})});const i=await executionInventory(this.storage),receipt=await applyExecutionMigration(this.storage,{version:1,revision:i.revision,writersQuiesced:true,recovery:{version:1,kind:'never-enabled',namespace:'answer-jobs-v1',namespaceID:'a'.repeat(32),sourceRevision:'b'.repeat(40),quiescenceRevision:'c'.repeat(64),evidenceDigest:'d'.repeat(64)},legacy:[],halts:[]});return Response.json(receipt)}
   if(path==='/fixture/index-plan')return Response.json(await prepareAccountingIndexPlan(this.storage,{writersQuiesced:true,evidenceDigest:'e'.repeat(64),sourceRevision:'0'.repeat(40)}));
   if(path==='/fixture/index-begin')return Response.json(await beginAccountingIndex(this.storage,await request.json()));
   if(path==='/fixture/index-step')return Response.json(await advanceAccountingIndex(this.storage,await request.json()));
   if(path==='/fixture/index-status')return Response.json(await accountingIndexStatus(this.storage));
   if(path==='/fixture/index-activate')return Response.json(await activateAccountingIndex(this.storage,(await request.json()).token));
   if(path==='/fixture/index-activation-failure'){const raw=rawAccountingStorage(this.storage),wrapped=new Proxy(raw,{get(t,k){if(k==='transaction')return fn=>t.transaction(tx=>fn(new Proxy(tx,{get(x,p){if(p==='put')return async(key,value)=>{if(key===INDEX+'state')throw Error('fixture_disk_failure');return x.put(key,value)};const v=Reflect.get(x,p);return typeof v==='function'?v.bind(x):v}})));const value=Reflect.get(t,k);return typeof value==='function'?value.bind(t):value}});try{await activateAccountingIndex(wrapped,(await request.json()).token);return Response.json({error:'did_not_fail'},500)}catch{return Response.json({expectedFailure:true})}}
   if(path==='/fixture/audit')return Response.json(await auditAccountingIndex(this.storage));
   if(path==='/fixture/alarm'){await this.alarm();return Response.json({ok:true})}
   return super.fetch(request);
  }
 }
 export default {fetch(request,env){return env.PRODUCTION_STATE.get(env.PRODUCTION_STATE.idFromName('production-validation-v1')).fetch(request)}};
`,resolveDir:resolve('Backend/feast-production'),sourcefile:'execution-fixture-only.mjs'},bundle:true,write:false,format:'esm',platform:'browser',external:['cloudflare:workers'],logLevel:'silent'});
const options={modulesRoot:root,modules:[{type:'ESModule',path:join(root,'worker.mjs'),contents:bundle.outputFiles[0].text}],compatibilityDate:'2026-10-20',bindings:{FIXTURE_INDEX:indexed?'true':'false',FIXTURE_HISTORY:String(historyCount),FIXTURE_PADDING:String(recordPadding),ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true',EXECUTION_LIFECYCLE_ENABLED:'true',FIXTURE_OFFSET:'0'},durableObjects:{PRODUCTION_STATE:{className:'FixtureLedger',useSQLite:true}},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},outboundService:()=>{throw Error('LIVE NETWORK FORBIDDEN')}};
let mf;const invoke=(path,p)=>mf.dispatchFetch('https://fixture'+path,p?{method:'POST',body:JSON.stringify(p)}:undefined);
const p=()=>({userHash:'a'.repeat(64),root:crypto.randomUUID(),turnID:crypto.randomUUID(),step:0,fingerprint:'f'.repeat(64),priorDigest:null,privateLatched:false,requestedWebActions:12,bodyDigest:'b'.repeat(64),model:'gpt-6-astra'});
const reserve=async base=>{const allocation=await(await invoke('/native-prepare-v2',base)).json(),intent={...base,allocationRevision:allocation.revision,maxWebActions:allocation.remainingWebActions},response=await invoke('/native-reserve-v2',intent);assert.equal(response.status,200);return {intent,r:{...intent,...await response.json()}}};
try{
 mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;assert.equal((await invoke('/fixture/bootstrap')).status,200);
 if(indexed){const plan=await(await invoke('/fixture/index-plan')).json();let step=await(await invoke('/fixture/index-begin',plan)).json(),steps=0,maxWall=0,maxRead=0,maxWrite=0,maxOps=0;while(step.phase!=='ready'){const request={token:step.token,step:step.step},started=performance.now(),response=await invoke('/fixture/index-step',request);assert.equal(response.status,200);step=await response.json();maxWall=Math.max(maxWall,performance.now()-started);maxRead=Math.max(maxRead,step.work.reads);maxWrite=Math.max(maxWrite,step.work.writes);maxOps=Math.max(maxOps,step.work.operations);assert(step.work.reads<=16*1024*1024&&step.work.writes<=16*1024*1024&&step.work.operations<=10000);if(steps===0)assert.deepEqual(await(await invoke('/fixture/index-step',request)).json(),step);if(steps===10){await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;const restored=await(await invoke('/fixture/index-begin',plan)).json();assert.equal(restored.step,step.step);assert.equal(restored.token,step.token)}steps++;assert(steps<100000)}assert.equal((await invoke('/fixture/index-activation-failure',{token:step.token})).status,200);assert.equal((await(await invoke('/fixture/index-status')).json()).phase,'ready');assert.equal((await invoke('/fixture/index-activate',{token:step.token})).status,200);assert.equal((await(await invoke('/fixture/index-status')).json()).phase,'active');assert(maxWall<5000,'per-step local wall ceiling');console.log(JSON.stringify({history:historyCount,recordPadding,steps,maxStepWallMs:Math.ceil(maxWall),maxStepReadBytes:maxRead,maxStepWriteBytes:maxWrite,maxStepOperations:maxOps}));}
 const reservations=[];for(let i=0;i<4;i++)reservations.push(await reserve(p()));
 const [{intent,r}]=reservations;assert.equal((await invoke('/native-claim-v2',r)).status,200);
 // Dispose immediately after ignoring the committed claim response.
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await invoke('/native-reserve-v2',intent)).status,200);assert.equal((await invoke('/native-claim-v2',r)).status,409);
 await mf.dispose();options.bindings.FIXTURE_OFFSET='600000';options.bindings.EXECUTION_LIFECYCLE_ENABLED='false';mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await invoke('/fixture/alarm')).status,200);assert.equal((await invoke('/fixture/alarm')).status,200);
 let status=await(await invoke('/status-v2')).json();assert.equal(status.pendingMicroUSD,4*6800288);assert.equal(status.halted,false);
 const bill={...r,usage:{model:'gpt-6-astra',inputTokens:1000,outputTokens:100,webCalls:0},frameDigest:'e'.repeat(64),closed:false};assert.equal((await invoke('/native-complete-v2',bill)).status,200);assert.equal((await invoke('/native-complete-v2',bill)).status,200);
 assert.equal((await invoke('/native-prepare-v2',{...p(),turnID:r.turnID})).status,503);
 await mf.dispose();options.bindings.EXECUTION_LIFECYCLE_ENABLED='true';mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 const blocked=await invoke('/native-prepare-v2',{...p(),turnID:r.turnID});assert.equal(blocked.status,409);await reserve(p());status=await(await invoke('/status-v2')).json();assert.equal(status.chargedMicroUSD,33000+(indexed?historyCount*33000:0));assert.equal(status.pendingMicroUSD,4*6800288);
 if(indexed)assert.equal((await invoke('/fixture/audit')).status,200);
 console.log((indexed?'Indexed'+historyCount+'-history: ':'')+'PASS real offline SQLite/workerd: atomic reservation/alarm, exact reservation replay, lost claim ACK across restart, four deadline holds retained/slots released, duplicate alarm, OFF late settlement, permanent uncertain-turn fence. Zero outbound calls.');
}finally{if(mf)await mf.dispose();await rm(root,{recursive:true,force:true})}
