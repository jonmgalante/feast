// Local runtime fixture only; NEVER deploy this test entrypoint. No credentials or external requests.
import assert from 'node:assert/strict';import {createRequire} from 'node:module';import {readFile,mkdtemp,rm} from 'node:fs/promises';import {tmpdir} from 'node:os';import {join} from 'node:path';
const require=createRequire(new URL('../feast-proxy/package.json',import.meta.url));const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const root=await mkdtemp(join(tmpdir(),'feast-production-ledger-runtime-'));
const packet=process.env.FEAST_CAP_PACKET??'/tmp/feast-cap20-reviewed';
const entry=await readFile(join(packet,'production/worker.js'),'utf8');
const options={modules:[{type:'ESModule',path:join(root,'worker.mjs'),contents:entry}],modulesRoot:root,compatibilityDate:'2026-10-20',durableObjects:{STATE:{className:'ProductionLedger',useSQLite:true}},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},outboundService:()=>{throw Error('External network forbidden')}};
const p=i=>({requestID:crypto.randomUUID(),userHash:i.toString(16).repeat(64),amountMicroUSD:2500000,fingerprint:'f'.repeat(64)});
let mf;const send=async(path,payload)=>{const ns=await mf.getDurableObjectNamespace('STATE');return ns.get(ns.idFromName('production-validation-v1')).fetch(new Request('https://local.invalid'+path,payload?{method:'POST',body:JSON.stringify(payload)}:undefined))};
try{
 mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;const first=p(1);
 assert.equal((await send('/reserve',first)).status,200);assert.equal((await send('/reserve',p(2))).status,200);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await send('/reserve',first)).status,409);
 const rest=await Promise.all([3,4,5,6,7,8,9,10].map(i=>send('/reserve',p(i))));assert.equal(rest.filter(x=>x.status===200).length,6);assert.equal(rest.filter(x=>x.status===429).length,2);
 const status=await(await send('/status')).json();assert.equal(status.capMicroUSD,20000000);assert.equal(status.reservedMicroUSD,20000000);assert.equal(status.remainingMicroUSD,0);
 console.log('PASS real local workerd/SQLite: separate production $20 lifetime reservations survive restart; duplicate never repeats; concurrent clients admit only remaining six holds. Zero external requests, no dev namespace/counters touched.');
}finally{if(mf)await mf.dispose();await rm(root,{recursive:true,force:true})}
