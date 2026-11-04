// Isolated real SQLite/workerd upgrade test. No credentials or external network.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';import {join} from 'node:path';
import {stageID} from './stage-accounting.mjs';
const require=createRequire(new URL('../feast-proxy/package.json',import.meta.url));
const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const root=await mkdtemp(join(tmpdir(),'feast-stage-concurrency-'));
const oldPacket=process.env.FEAST_PRIOR_PACKET??'/tmp/feast-general-assistant-reviewed-v6';
const packet=process.env.FEAST_OWNER_PACKET??'/tmp/feast-provider-controlled-reviewed';
const userHash='a'.repeat(64),fingerprint='f'.repeat(64);
const payload=async()=>{const rootRequestID=crypto.randomUUID();return {requestID:await stageID(rootRequestID,0),rootRequestID,stageIndex:0,userHash,fingerprint,profile:'astraAgentStepV1',amountMicroUSD:1622016}};
const options=async path=>({modules:[{type:'ESModule',path:join(root,'worker.mjs'),contents:await readFile(join(path,'production/worker.js'),'utf8')}],modulesRoot:root,compatibilityDate:'2026-10-20',durableObjects:{STATE:{className:'ProductionLedger',useSQLite:true}},bindings:{ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true'},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},outboundService:()=>{throw Error('External network forbidden')}});
let mf;const send=async(path,body)=>{const ns=await mf.getDurableObjectNamespace('STATE');return ns.get(ns.idFromName('isolated')).fetch(new Request('https://ledger'+path,body?{method:'POST',body:JSON.stringify(body)}:undefined))};
try {
 mf=new Miniflare(convertV4MiniflareOptions(await options(oldPacket)));await mf.ready;
 const stopped=await payload();assert.equal((await send('/reserve-v2',stopped)).status,200);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(await options(packet)));await mf.ready;
 const requests=await Promise.all(Array.from({length:16},payload));
 const responses=await Promise.all(requests.map(p=>send('/reserve-v2',p)));
 assert.equal(responses.filter(r=>r.status===200).length,3);assert.equal(responses.filter(r=>r.status===429).length,13);
 let status=await(await send('/status-v2')).json();assert.equal(status.pendingMicroUSD,4*1622016);assert.equal(status.chargedMicroUSD,0);assert.equal(status.capMicroUSD,null);
 assert.equal((await send('/reserve-v2',stopped)).status,409);
 const winner=requests[responses.findIndex(r=>r.status===200)],usage=[{model:'gpt-6-astra',inputTokens:1000,outputTokens:100,webCalls:0}];
 assert.equal((await send('/complete-v2',{...winner,usage})).status,200);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(await options(packet)));await mf.ready;
 status=await(await send('/status-v2')).json();assert.equal(status.pendingMicroUSD,3*1622016);assert.equal(status.chargedMicroUSD,33000);assert.equal(status.reservedMicroUSD,status.pendingMicroUSD+33000);
 assert.equal((await send('/reserve-v2',stopped)).status,409);
 assert.equal((await send('/complete-v2',{...stopped,usage})).status,200);
 status=await(await send('/status-v2')).json();assert.equal(status.pendingMicroUSD,2*1622016);assert.equal(status.chargedMicroUSD,66000);
 console.log('PASS persisted SQLite upgrade: stopped full hold survives; same-user staged concurrency enforces simultaneous dispatch bounds without lifetime cap; old/new completion, replay and restart preserve all exposure. Zero external requests.');
} finally {if(mf)await mf.dispose();await rm(root,{recursive:true,force:true})}
