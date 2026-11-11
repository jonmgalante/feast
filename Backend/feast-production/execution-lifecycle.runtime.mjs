// Real workerd/SQLite storage. The only fixture routes live in this generated
// test bundle, never in the production worker. No outbound network is allowed.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const require=createRequire(new URL('../feast-proxy/package.json',import.meta.url));
const {build}=require('esbuild'),{Miniflare,convertV4MiniflareOptions}=require('miniflare');
const root=await mkdtemp(join(tmpdir(),'feast-execution-runtime-'));
const bundle=await build({stdin:{contents:`
 import {ProductionLedger} from './production-ledger.mjs';
 import {executionInventory,applyExecutionMigration} from './execution-migration.mjs';
 export class FixtureLedger extends ProductionLedger {
  constructor(state,env){super(state,env,{now:()=>Date.now()+Number(env.FIXTURE_OFFSET)})}
  async fetch(request){const path=new URL(request.url).pathname;
   if(path==='/fixture/bootstrap'){const i=await executionInventory(this.storage);return Response.json(await applyExecutionMigration(this.storage,{version:1,revision:i.revision,writersQuiesced:true,recovery:{version:1,kind:'never-enabled',namespace:'answer-jobs-v1',namespaceID:'a'.repeat(32),sourceRevision:'b'.repeat(40),quiescenceRevision:'c'.repeat(64),evidenceDigest:'d'.repeat(64)},legacy:[],halts:[]}))}
   if(path==='/fixture/alarm'){await this.alarm();return Response.json({ok:true})}
   return super.fetch(request);
  }
 }
 export default {fetch(request,env){return env.PRODUCTION_STATE.get(env.PRODUCTION_STATE.idFromName('production-validation-v1')).fetch(request)}};
`,resolveDir:resolve('Backend/feast-production'),sourcefile:'execution-fixture-only.mjs'},bundle:true,write:false,format:'esm',platform:'browser',external:['cloudflare:workers'],logLevel:'silent'});
const options={modulesRoot:root,modules:[{type:'ESModule',path:join(root,'worker.mjs'),contents:bundle.outputFiles[0].text}],compatibilityDate:'2026-10-20',bindings:{ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true',EXECUTION_LIFECYCLE_ENABLED:'true',FIXTURE_OFFSET:'0'},durableObjects:{PRODUCTION_STATE:{className:'FixtureLedger',useSQLite:true}},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},outboundService:()=>{throw Error('LIVE NETWORK FORBIDDEN')}};
let mf;const invoke=(path,p)=>mf.dispatchFetch('https://fixture'+path,p?{method:'POST',body:JSON.stringify(p)}:undefined);
const p=()=>({userHash:'a'.repeat(64),root:crypto.randomUUID(),turnID:crypto.randomUUID(),step:0,fingerprint:'f'.repeat(64),priorDigest:null,privateLatched:false,requestedWebActions:12,bodyDigest:'b'.repeat(64),model:'gpt-6-astra'});
const reserve=async base=>{const allocation=await(await invoke('/native-prepare-v2',base)).json(),intent={...base,allocationRevision:allocation.revision,maxWebActions:allocation.remainingWebActions},response=await invoke('/native-reserve-v2',intent);assert.equal(response.status,200);return {intent,r:{...intent,...await response.json()}}};
try{
 mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;assert.equal((await invoke('/fixture/bootstrap')).status,200);
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
 const blocked=await invoke('/native-prepare-v2',{...p(),turnID:r.turnID});assert.equal(blocked.status,409);await reserve(p());status=await(await invoke('/status-v2')).json();assert.equal(status.chargedMicroUSD,33000);assert.equal(status.pendingMicroUSD,4*6800288);
 console.log('PASS real offline SQLite/workerd: atomic reservation/alarm, exact reservation replay, lost claim ACK across restart, four deadline holds retained/slots released, duplicate alarm, OFF late settlement, permanent uncertain-turn fence. Zero outbound calls.');
}finally{if(mf)await mf.dispose();await rm(root,{recursive:true,force:true})}
