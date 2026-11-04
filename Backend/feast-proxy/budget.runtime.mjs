// Local workerd/SQLite test only. No Cloudflare account or provider connection.
import assert from 'node:assert/strict';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {digest} from './worker.mjs';
const root=await mkdtemp(join(tmpdir(),'feast-budget-runtime-'));
const token='a'.repeat(43),token2='b'.repeat(43);
const hashes=JSON.stringify([{id:'tester-one',sha256:await digest(token),expiresAt:'2026-11-22T14:30:00Z'},{id:'tester-two',sha256:await digest(token2),expiresAt:'2026-11-22T14:30:00Z'}]);
const workerCode=await readFile(new URL('worker.mjs',import.meta.url),'utf8');
const modules=[{type:'ESModule',path:join(root,'worker.mjs'),contents:'let testClock=0;\n'+workerCode.replace('Date.now()) / 60000','testClock++*60000) / 60000')},{type:'ESModule',path:join(root,'openai.mjs'),contents:await readFile(new URL('openai.mjs',import.meta.url),'utf8')},{type:'ESModule',path:join(root,'discovery.mjs'),contents:await readFile(new URL('discovery.mjs',import.meta.url),'utf8')}];
for(const name of ['library-intent.mjs','evaluation.mjs','discovery-local-candidate.mjs'])modules.push({type:'ESModule',path:join(root,name),contents:await readFile(new URL(name,import.meta.url),'utf8')});
const options={modules,modulesRoot:root,compatibilityDate:'2026-10-20',durableObjects:{BUDGET:{className:'BudgetLedger',useSQLite:true}},resourcePersistencePath:join(root,'sqlite'),telemetry:{enabled:false},bindings:{ENVIRONMENT:'dev',ENABLED:'true',TEST_MODE:'true',CLIENT_TOKEN_HASHES_JSON:hashes},outboundService:()=>{throw Error('External network forbidden in runtime test')}};
let mf;
const send=(i)=>mf.dispatchFetch('https://test.invalid/v1/answer',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+(i%2?token:token2)},body:JSON.stringify({version:1,synthetic:true,consent:true,requestID:crypto.randomUUID(),mode:'collection',text:'Fictional?',candidates:[],sources:[]})});
try{
 mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 const first=await Promise.all(Array.from({length:80},(_,i)=>send(i)));assert.equal(first.filter(r=>r.status===200).length,80);
 await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions(options));await mf.ready;
 const second=await Promise.all(Array.from({length:80},(_,i)=>send(i)));assert.equal(second.filter(r=>r.status===200).length,20);assert.equal(second.filter(r=>r.status===429).length,60);
 console.log('PASS actual local workerd SQLite: 80 reservations survive runtime restart; concurrent requests admit exactly 20 remaining; lifetime $5 exhausted; external network forbidden.');
}finally{if(mf)await mf.dispose();await rm(root,{recursive:true,force:true});}
