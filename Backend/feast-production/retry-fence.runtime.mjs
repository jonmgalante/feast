// Isolated real SQLite/workerd upgrade test. No credentials or external network.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';import {join} from 'node:path';
import {stageID} from './stage-accounting.mjs';
const require=createRequire(new URL('../feast-proxy/package.json',import.meta.url));
const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const root=await mkdtemp(join(tmpdir(),'feast-stage-concurrency-'));
const oldPacket=process.env.FEAST_PRIOR_PACKET??'/tmp/feast-provider-controlled-release';
const packet=process.env.FEAST_OWNER_PACKET??'/tmp/feast-retry-reviewed';
const userHash='a'.repeat(64),fingerprint='f'.repeat(64);
const payload=async()=>{const rootRequestID=crypto.randomUUID();return {requestID:await stageID(rootRequestID,0),rootRequestID,stageIndex:0,userHash,fingerprint,profile:'astraAgentStepV1',amountMicroUSD:1622016}};
const options=async path=>({modules:[{type:'ESModule',path:join(root,'worker.mjs'),contents:await readFile(join(path,'production/worker.js'),'utf8')}],modulesRoot:root,compatibilityDate:'2026-10-20',durableObjects:{STATE:{className:'ProductionLedger',useSQLite:true}},bindings:{ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true'},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},outboundService:()=>{throw Error('External network forbidden')}});
let mf;const send=async(path,body)=>{const ns=await mf.getDurableObjectNamespace('STATE');return ns.get(ns.idFromName('isolated')).fetch(new Request('https://ledger'+path,body?{method:'POST',body:JSON.stringify(body)}:undefined))};
try {
 mf=new Miniflare(convertV4MiniflareOptions(await options(oldPacket)));await mf.ready;
 const original=await payload();assert.equal((await send('/reserve-v2',original)).status,200);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(await options(packet)));await mf.ready;
 const absent=await payload(),fence={roots:[absent.rootRequestID,original.rootRequestID],userHash};
 assert.equal((await send('/fence-v2',fence)).status,409);
 const before=await(await send('/status-v2')).json();assert.equal(before.pendingMicroUSD,1622016);
 const usage=[{model:'gpt-6-astra',inputTokens:1000,outputTokens:100,webCalls:0}];
 assert.equal((await send('/complete-v2',{...original,usage})).status,200);
 assert.equal((await send('/fence-v2',fence)).status,200);
 assert.equal((await send('/reserve-v2',absent)).status,409);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(await options(packet)));await mf.ready;
 const after=await(await send('/status-v2')).json();assert.equal(after.chargedMicroUSD,33000);assert.equal(after.pendingMicroUSD,0);
 assert.equal((await send('/reserve-v2',absent)).status,409);
 const fresh=await payload();assert.equal((await send('/reserve-v2',fresh)).status,200);
 console.log('PASS real SQLite retry fence upgrade: pending blocked, settled roots fenced, absent roots prevent late dispatch, restart preserves charges/tombstones, new attempt admitted. Zero provider calls.');
} finally {if(mf)await mf.dispose();await rm(root,{recursive:true,force:true})}
