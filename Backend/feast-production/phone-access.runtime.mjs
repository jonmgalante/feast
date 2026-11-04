// Offline workerd/SQLite integration. Fixed fake tokens; all outbound network forbidden.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';import {mkdtemp,rm} from 'node:fs/promises';import {join,resolve} from 'node:path';import {tmpdir} from 'node:os';
import {phoneHash} from './phone-access.mjs';
const require=createRequire(new URL('../feast-proxy/package.json',import.meta.url));
const {build}=require('esbuild'),{Miniflare,convertV4MiniflareOptions}=require('miniflare');
const root=await mkdtemp(join(tmpdir(),'feast-phone-runtime-')),id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const invitation='i'.repeat(43),token='t'.repeat(43),time=Date.now(),grant={id:id(1),createdAt:time-1000,expiresAt:time+3600000,revoked:false,sha256:await phoneHash('invitation',invitation)};
const bundle=await build({entryPoints:[resolve('Backend/feast-production/worker.mjs')],bundle:true,write:false,format:'esm',platform:'browser',external:['cloudflare:workers'],logLevel:'silent'});
const options={modulesRoot:root,modules:[{type:'ESModule',path:join(root,'worker.mjs'),contents:bundle.outputFiles[0].text}],compatibilityDate:'2026-10-20',
 bindings:{PHONE_ACCESS_ENABLED:'true',PHONE_INVITATIONS_JSON:JSON.stringify([grant]),ENVIRONMENT:'production',OWNER_VALIDATION_ENABLED:'true',LIVE_AI:'true',ALLOW_RECONCILED_BUDGET:'false'},
 durableObjects:{PRODUCTION_STATE:{className:'ProductionLedger',useSQLite:true}},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},outboundService:()=>{throw Error('External network forbidden')}};
const p={version:1,invitation,deviceID:id(2),activationID:id(3),credentialHash:await phoneHash('device',token)};
let mf;const activate=payload=>mf.dispatchFetch('https://feast.test/v1/access/activate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
const access=()=>mf.dispatchFetch('https://feast.test/v1/access/status',{headers:{Authorization:'Bearer '+token}});
async function ledger(path,payload){const ns=await mf.getDurableObjectNamespace('PRODUCTION_STATE');return ns.get(ns.idFromName('production-validation-v1')).fetch(new Request('https://ledger'+path,payload?{method:'POST',body:JSON.stringify(payload)}:undefined))}
try{
 mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await ledger('/reserve',{requestID:id(40),userHash:'a'.repeat(64),fingerprint:'b'.repeat(64),amountMicroUSD:2500000})).status,200);
 const before=await(await ledger('/status')).json();assert.equal(before.remainingMicroUSD,null);
 const claims=await Promise.all([activate(p),activate({...p,deviceID:id(4),activationID:id(5)})]);assert.deepEqual(claims.map(r=>r.status).sort(),[200,403]);
 const winner=claims[0].status===200?p:{...p,deviceID:id(4),activationID:id(5)};
 assert.equal((await access()).status,200);assert.deepEqual(await(await ledger('/status')).json(),before);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await activate(winner)).status,200);assert.equal((await access()).status,200);assert.deepEqual(await(await ledger('/status')).json(),before);
 await mf.dispose();options.bindings.PHONE_INVITATIONS_JSON=JSON.stringify([{...grant,revoked:true}]);mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 assert.equal((await access()).status,401);assert.equal((await activate(winner)).status,403);assert.deepEqual(await(await ledger('/status')).json(),before);
 console.log('PASS real offline workerd/SQLite: atomic one-device activation, exact retry and access survive restart, revocation denies access, separate accounting hold unchanged; zero provider calls.');
}finally{if(mf)await mf.dispose();await rm(root,{recursive:true,force:true})}
