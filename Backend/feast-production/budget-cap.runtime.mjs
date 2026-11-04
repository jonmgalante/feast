// OFFLINE ONLY. Existing/new reviewed bundles against the SAME isolated SQLite namespace.
// No credentials, provider calls or deployment. Never deploy this test entrypoint.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {stageID} from './stage-accounting.mjs';
const require=createRequire(new URL('../feast-proxy/package.json',import.meta.url));
const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const oldPacket=process.env.FEAST_OLD_CAP_PACKET??'/tmp/feast-general-assistant-reviewed-v7';
const newPacket=process.env.FEAST_NEW_CAP_PACKET??'/tmp/feast-cap30-reviewed';
const root=await mkdtemp(join(tmpdir(),'feast-cap-upgrade-'));
const scripts=await Promise.all([oldPacket,newPacket].map(p=>readFile(resolve(p,'production/worker.js'),'utf8')));
const options=contents=>({resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},workers:[{name:'production',modulesRoot:root,compatibilityDate:'2026-10-20',modules:[{type:'ESModule',path:join(root,'production.mjs'),contents}],bindings:{ENVIRONMENT:'production',ENABLED:'false',ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true'},durableObjects:{PRODUCTION_STATE:{className:'ProductionLedger',useSQLite:true}},outboundService:()=>{throw Error('External network forbidden')}}]});
const req=(path,p)=>new Request('https://ledger'+path,p?{method:'POST',body:JSON.stringify(p)}:undefined);
const proposal=user=>({requestID:crypto.randomUUID(),userHash:user.repeat(64),fingerprint:'f'.repeat(64),profile:'saved',amountMicroUSD:2500000});
let mf,ledger;
async function open(index){mf=new Miniflare(convertV4MiniflareOptions(options(scripts[index])));await mf.ready;const ns=await mf.getDurableObjectNamespace('PRODUCTION_STATE','production');ledger=ns.get(ns.idFromName('production-validation-v1'));}
const status=async()=>{const r=await ledger.fetch(req('/status-v2'));assert.equal(r.status,200);return r.json()};
try {
 await open(0);const completed=proposal('a');assert.equal((await ledger.fetch(req('/reserve-v2',completed))).status,200);assert.equal((await ledger.fetch(req('/complete-v2',{...completed,usage:[{model:'gpt-6-astra',inputTokens:1000,outputTokens:100,webCalls:0}]}))).status,200);
 const pending=['0','1','2','3','4','5'].map(proposal);for(const p of pending)assert.equal((await ledger.fetch(req('/reserve-v2',p))).status,200);
 const before=await status();assert.equal(before.capMicroUSD,20000000);assert.equal(before.chargedMicroUSD,33000);assert.equal(before.pendingMicroUSD,15000000);
 await mf.dispose();await open(1);const after=await status();assert.equal(after.capMicroUSD,30000000);assert.equal(after.remainingMicroUSD,before.remainingMicroUSD+10000000);
 for(const key of Object.keys(before).filter(k=>!['capMicroUSD','remainingMicroUSD'].includes(k)))assert.deepEqual(after[key],before[key],key);
 for(const p of [completed,...pending])assert.equal((await ledger.fetch(req('/reserve-v2',p))).status,409);
 const rootID=crypto.randomUUID(),research={requestID:await stageID(rootID,0),rootRequestID:rootID,stageIndex:0,userHash:'e'.repeat(64),fingerprint:'f'.repeat(64),profile:'astraResearchStageV1',amountMicroUSD:6679288};
 assert.equal((await ledger.fetch(req('/reserve-v2',research))).status,200);const reserved=await status();assert.equal(reserved.chargedMicroUSD,33000);assert.equal(reserved.pendingMicroUSD,15000000+6679288);
 await mf.dispose();await open(0);assert.equal((await ledger.fetch(req('/status-v2'))).status,503); // Old lower-cap rollback refuses excess exposure; never resets it.
 await mf.dispose();await open(1);assert.deepEqual(await status(),reserved);
 assert.equal((await ledger.fetch(req('/uncertain-v2',research))).status,503);const uncertain=await status();assert.equal(uncertain.pendingMicroUSD,reserved.pendingMicroUSD);assert.equal(uncertain.halted,true);
 await mf.dispose();await open(1);assert.deepEqual(await status(),uncertain);assert.equal((await ledger.fetch(req('/reserve-v2',proposal('f')))).status,503);
 console.log('PASS real isolated SQLite $20→$30 code upgrade retains completed costs/pending records/replay history, admits unchanged research hold; lower-cap rollback fails closed, uncertainty survives restart. Zero provider/external calls.');
}finally {if(mf)await mf.dispose();await rm(root,{recursive:true,force:true});}
