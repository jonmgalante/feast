import test,{after} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {ProductionLedger} from './production-ledger.mjs';
import {executionInventory,applyExecutionMigration} from './execution-migration.mjs';
import {INDEX,indexedStorage,prepareAccountingIndexPlan,buildAccountingIndex,beginAccountingIndex,auditAccountingIndex} from './accounting-index.mjs';
import {attemptOwnershipBatch} from './attempt-ownership.mjs';
import {PROFILES,accountingView} from './reconciled-accounting.mjs';
import {PUBLIC_PROFILES} from './public-policy.mjs';
import {STAGE_HOLDS} from './stage-policy.mjs';
import {NATIVE_ESTIMATE} from './native-accounting.mjs';
const V1='production-validation-v1:',V2='production-validation-v2:',user='a'.repeat(64),fingerprint='f'.repeat(64);
const dir=await mkdtemp(join(tmpdir(),'feast-legacy-id-producers-'));
after(()=>rm(dir,{recursive:true,force:true}));
async function archive(revision,name){const target=join(dir,name);await mkdir(target);const bytes=execFileSync('git',['archive',revision,'Backend/feast-production','Backend/feast-proxy'],{maxBuffer:32*1024*1024});execFileSync('tar',['-x','-C',target],{input:bytes});return target}
const oldPath=await archive('41229acfabb080559904c41a07f1db25f0b082f6','producer');
const {ProductionLedger:OldLedger}=await import(pathToFileURL(join(oldPath,'Backend/feast-production/production-ledger.mjs')));
const oldIndexPath=await archive('79d658373745c31c6f24769ecd142ead47146160','prior-index');
const oldIndex=await import(pathToFileURL(join(oldIndexPath,'Backend/feast-production/accounting-index.mjs')));
class Store{
 data=new Map();alarm=null;queue=Promise.resolve();
 transaction(fn){const work=this.queue.then(async()=>{const data=structuredClone(this.data);let alarm=this.alarm;const tx={get:async k=>structuredClone(data.get(k)),put:async(k,v)=>data.set(k,structuredClone(v)),delete:async k=>data.delete(k),list:async({prefix='',startAfter,limit=1000}={})=>new Map([...data].filter(([k])=>k.startsWith(prefix)&&(!startAfter||k>startAfter)).sort(([a],[b])=>a<b?-1:a>b?1:0).slice(0,limit)),getAlarm:async()=>alarm,setAlarm:async n=>{alarm=n},deleteAlarm:async()=>{alarm=null}};const result=await fn(tx);this.data=data;this.alarm=alarm;return result});this.queue=work.catch(()=>{});return work}
}
const request=(route,p)=>new Request('https://offline-ledger'+route,p===undefined?undefined:{method:'POST',body:JSON.stringify(p)});
const env={ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true',EXECUTION_LIFECYCLE_ENABLED:'true'};
const recovery={version:1,kind:'never-enabled',namespace:'answer-jobs-v1',namespaceID:'a'.repeat(32),sourceRevision:'b'.repeat(40),quiescenceRevision:'c'.repeat(64),evidenceDigest:'d'.repeat(64)};
const evidence={writersQuiesced:true,evidenceDigest:'e'.repeat(64),sourceRevision:'0'.repeat(40)};
const route=(version,kind)=>'/'+kind+(version===2?'-v2':'');
const prefix=v=>v===1?V1:V2;
const payload=(id,profile='saved',owner=user)=>({requestID:id,userHash:owner,fingerprint,profile,amountMicroUSD:PROFILES[profile]});
function bill(profile='saved',n=0){const policy=PUBLIC_PROFILES[profile],model=profile==='public'?'gpt-6-luna':policy?.model??'gpt-6-astra';return {calls:1,inputTokens:1000+n*37,outputTokens:100+n*19,usage:[{model,inputTokens:1000+n*37,outputTokens:100+n*19,webCalls:profile==='saved'?0:1}]}}
async function produce(storage,version,id,{outcome='complete',profile='saved',owner=user,n=0}={}){const ledger=new OldLedger({storage},version===2?{ALLOW_RECONCILED_BUDGET:'true',ALLOW_LEGACY_RECONCILIATION:'true'}:{}),p=payload(id,profile,owner);assert.equal((await ledger.fetch(request(route(version,'reserve'),p))).status,200);if(outcome!=='pending'){const r=await ledger.fetch(request(route(version,outcome==='uncertain'?'uncertain':outcome==='cancelled'?'cancel-undispatched':'complete'),{...p,...bill(profile,n),...(outcome==='rejected'?{providerRejectedStatus:429,providerRejectedCode:'insufficient_quota'}:{})}));assert.equal(r.status,outcome==='uncertain'?503:200)}return {ledger,p,key:prefix(version)+'request:'+id}}
async function migrate(storage,classification='attributed-uncertain'){const inventory=await executionInventory(storage),unknown=inventory.records.filter(r=>['pending','uncertain'].includes(r.state));return applyExecutionMigration(storage,{version:1,revision:inventory.revision,writersQuiesced:true,recovery,legacy:unknown.map(r=>({key:r.key,recordDigest:r.digest,classification})),halts:inventory.halts.map(h=>({...h,classification:'attributed-uncertainty',records:unknown.map(r=>r.key),evidenceDigest:'e'.repeat(64)}))})}
async function index(storage){return buildAccountingIndex(storage,await prepareAccountingIndexPlan(storage,evidence))}
function unchanged(storage,before){for(const [key,value] of before)assert.deepEqual(storage.data.get(key),value,key)}
const ownerPath=id=>[...id.toLowerCase()].map(c=>c.charCodeAt(0).toString(16).padStart(2,'0')).join('');

test('authentic old case/hyphen physical IDs retain four rows, separate bills/replays and owner counts2/1/1',async()=>{
 for(const version of [1,2])for(const ids of [
  ['aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA','a'.repeat(32)+'----','----'+'a'.repeat(32)],
  [version===1?'z'.repeat(36):'a'.repeat(36),version===1?'Z'.repeat(36):'A'.repeat(36),(version===1?'z':'a').repeat(35)+'-','-'+(version===1?'z':'a').repeat(35)]
 ]){
  const storage=new Store(),produced=[];for(let n=0;n<ids.length;n++)produced.push(await produce(storage,version,ids[n],{n}));
  const before=structuredClone(storage.data),charged=produced.reduce((n,r)=>n+storage.data.get(r.key).conservativeUsageMicroUSD,0);
  await migrate(storage);await index(storage);unchanged(storage,before);
  const audit=await auditAccountingIndex(storage);assert.equal(audit.budget.historicalReservedMicroUSD,10000000);assert.equal(audit.budget.chargedMicroUSD,charged);assert.equal(audit.budget.pendingMicroUSD,0);
  const scope=storage.data.get(INDEX+'state').treeScope,nodes=[...storage.data].filter(([k])=>k.startsWith(INDEX+'tree:'+scope+':root:')).map(([,v])=>v);
  for(const [id,count] of [[ids[0],2],[ids[2],1],[ids[3],1]]){const leaf=nodes.find(n=>n.type==='leaf'&&n.path===ownerPath(id));assert(leaf);assert.equal(leaf.value.records,count);assert.equal(leaf.value.links,count)}
  const records=[...storage.data].filter(([k,v])=>k.startsWith(INDEX+'tree:'+scope+':record:')&&v.type==='leaf'&&produced.some(r=>r.key===v.value.key));assert.equal(records.length,4);
  const current=new ProductionLedger({storage},env),snapshot=structuredClone(storage.data);
  for(const {p} of produced)assert.equal((await current.fetch(request(route(version,'complete'),{...p,...bill()}))).status,409);
  assert.deepEqual(storage.data,snapshot,'exact physical replay must not alter any index or original row');
  const owned=await indexedStorage(storage).transaction(tx=>attemptOwnershipBatch(tx,ids,user));assert([...owned.values()].every(x=>x.owned));
 }
});

test('cross-namespace different-owner case aliases remain conflicting without overwriting either old reservation',async()=>{
 const storage=new Store(),id='a'.repeat(36);await produce(storage,1,id.toUpperCase());await produce(storage,2,id,{outcome:'pending',owner:'b'.repeat(64)});const before=structuredClone(storage.data);
 const budget=await storage.transaction(tx=>accountingView(tx,true));assert.equal(budget.chargedMicroUSD,33000);assert.equal(budget.pendingMicroUSD,2500000);
 for(const owner of [user,'b'.repeat(64)])assert.equal((await storage.transaction(tx=>attemptOwnershipBatch(tx,[id],owner))).get(id).owned,false);
 await assert.rejects(migrate(storage),/migration_owner_conflict/);assert.deepEqual(storage.data,before);
});

test('authentic non-UUID pending/uncertain/zero-charge rows retain every hold and original inflight byte',async()=>{
 for(const version of [1,2])for(const outcome of ['pending','uncertain','rejected',...(version===2?['cancelled']:[])]){
  const storage=new Store(),r=await produce(storage,version,'a'.repeat(36),{outcome}),before=structuredClone(storage.data);
  await migrate(storage);await index(storage);unchanged(storage,before);
  const budget=(await auditAccountingIndex(storage)).budget;assert.equal(budget.historicalReservedMicroUSD,2500000);assert.equal(budget.pendingMicroUSD,['pending','uncertain'].includes(outcome)?2500000:0);assert.equal(budget.chargedMicroUSD,0);
  if(['pending','uncertain'].includes(outcome))assert.equal(storage.data.get(V2+'closed-root:'+r.p.requestID).userHash,user);
 }
});

test('retained-active non-UUID reservations can settle a known bill once through indexed legacy routes',async()=>{
 for(const version of [1,2]){const storage=new Store(),r=await produce(storage,version,'a'.repeat(36),{outcome:'pending'});await migrate(storage,'retain-active');await index(storage);const ledger=new ProductionLedger({storage},env),p={...payload(crypto.randomUUID()),executionProtocol:'direct',bodyDigest:fingerprint};assert.equal((await ledger.fetch(request('/reserve-v2',p))).status,429);assert.equal((await ledger.fetch(request(route(version,'complete'),{...r.p,...bill()}))).status,200);const before=structuredClone(storage.data);assert.equal((await ledger.fetch(request(route(version,'complete'),{...r.p,...bill()}))).status,409);assert.deepEqual(storage.data,before);const budget=(await auditAccountingIndex(storage)).budget;assert.equal(budget.chargedMicroUSD,33000);assert.equal(budget.pendingMicroUSD,0);assert.equal(budget.historicalReservedMicroUSD,2500000)}
});

test('all actual historical direct profiles preserve original usage rates and physical non-UUID keys',async()=>{
 for(const profile of ['saved','public',...Object.keys(PUBLIC_PROFILES)]){const storage=new Store(),r=await produce(storage,2,'a'.repeat(36),{profile}),before=structuredClone(storage.data),expected=storage.data.get(r.key).conservativeUsageMicroUSD;await migrate(storage);await index(storage);unchanged(storage,before);const budget=(await auditAccountingIndex(storage)).budget;assert.equal(budget.chargedMicroUSD,expected);assert.equal(budget.historicalReservedMicroUSD,PROFILES[profile])}
});

test('non-UUID recognition cannot relabel partial managed metadata or native/stage profiles as legacy direct',async()=>{
 const cases=[...['executionVersion','rootRequestID','nativeTurnID','stageIndex'].flatMap(key=>[r=>{r[key]=null},r=>{r[key]=undefined}]),r=>{delete r.fingerprint},r=>{delete r.userHash},r=>{r.fingerprint='bad'},r=>{r.profile='astraNativeUsageV1';r.reservedMicroUSD=NATIVE_ESTIMATE},r=>{r.profile='astraAgentStepV1';r.reservedMicroUSD=STAGE_HOLDS.astraAgentStepV1}];
 for(const mutate of cases){const storage=new Store(),r=await produce(storage,2,'a'.repeat(36));mutate(storage.data.get(r.key));const before=structuredClone(storage.data);await assert.rejects(executionInventory(storage));assert.deepEqual(storage.data,before)}
 for(const invalid of ['g'.repeat(36),'a'.repeat(35),'a'.repeat(37),'a'.repeat(35)+'_']){const storage=new Store(),r=await produce(storage,2,'a'.repeat(36));storage.data.set(V2+'request:'+invalid,storage.data.get(r.key));storage.data.delete(r.key);await assert.rejects(executionInventory(storage))}
});

test('new managed native/staged/direct admission stays UUID-strict after compatible historical indexing',async()=>{
 const storage=new Store();await produce(storage,1,'z'.repeat(36));await migrate(storage);await index(storage);const ledger=new ProductionLedger({storage},env),before=structuredClone(storage.data),id='a'.repeat(36);
 for(const [route,p] of [['/native-prepare-v2',{root:id,turnID:crypto.randomUUID(),step:0,userHash:user}],['/reserve-v2',{...payload(id),executionProtocol:'direct',bodyDigest:fingerprint}],['/reserve-v2',{...payload(crypto.randomUUID(),'astraAgentStepV1'),rootRequestID:id,stageIndex:0,bodyDigest:fingerprint}]])assert.notEqual((await ledger.fetch(request(route,p))).status,200);
 assert.deepEqual(storage.data,before);
});

test('old UUID-stripping proof plans cannot be reinterpreted by the revised legacy identity policy',async()=>{
 const storage=new Store();await produce(storage,1,crypto.randomUUID());await migrate(storage);const oldPlan=await oldIndex.prepareAccountingIndexPlan(storage,evidence),before=structuredClone(storage.data);await assert.rejects(beginAccountingIndex(storage,oldPlan),/plan_invalid|policy_changed/);assert.deepEqual(storage.data,before);const current=await prepareAccountingIndexPlan(storage,evidence);assert.notEqual(current.sourcePolicyVersion,oldPlan.sourcePolicyVersion);assert.notEqual(current.policyHash,oldPlan.policyHash);await buildAccountingIndex(storage,current);assert.equal((await auditAccountingIndex(storage)).valid,true);
});

test('historical direct grammar extremes and standalone original retry fences remain readable',async()=>{
 for(const version of [1,2])for(const id of ['-'.repeat(36),'0'.repeat(36)]){const storage=new Store();await produce(storage,version,id);const before=structuredClone(storage.data);await migrate(storage);await index(storage);unchanged(storage,before);assert.equal((await auditAccountingIndex(storage)).budget.chargedMicroUSD,33000)}
 const storage=new Store(),old=new OldLedger({storage},{ALLOW_RECONCILED_BUDGET:'true'}),roots=['a'.repeat(36),'a'.repeat(32)+'----','----'+'a'.repeat(32)];assert.equal((await old.fetch(request('/fence-v2',{userHash:user,roots}))).status,200);const before=structuredClone(storage.data);await migrate(storage);await index(storage);unchanged(storage,before);assert.equal((await auditAccountingIndex(storage)).budget.historicalReservedMicroUSD,0);
});

test('V1 recognition also requires absent profile/linkage and authentic owner/fingerprint fields',async()=>{
 for(const change of [r=>{r.profile='saved'},r=>{r.profile=undefined},r=>{delete r.fingerprint},r=>{delete r.userHash},...['executionVersion','rootRequestID','nativeTurnID','stageIndex'].flatMap(key=>[r=>{r[key]=null},r=>{r[key]=undefined}])]){const storage=new Store(),r=await produce(storage,1,'z'.repeat(36));change(storage.data.get(r.key));const before=structuredClone(storage.data);await assert.rejects(executionInventory(storage));assert.deepEqual(storage.data,before)}
});

test('a non-authoritative old-policy stage cannot resume and only a fully prepared new plan can supersede it',async()=>{
 const storage=new Store();await produce(storage,1,crypto.randomUUID());await migrate(storage);const oldPlan=await oldIndex.prepareAccountingIndexPlan(storage,evidence),prior=await oldIndex.beginAccountingIndex(storage,oldPlan),before=structuredClone(storage.data),api=await import('./accounting-index.mjs');await assert.rejects(api.advanceAccountingIndex(storage,{token:prior.token,step:prior.step}),/policy_changed/);assert.deepEqual(storage.data,before);assert.equal((await api.accountingIndexStatus(storage)).phase,'stale');const plan=await prepareAccountingIndexPlan(storage,evidence);await buildAccountingIndex(storage,plan);assert.equal((await auditAccountingIndex(storage)).valid,true);assert.deepEqual(storage.data.get(INDEX+'staging:'+prior.token),before.get(INDEX+'staging:'+prior.token));
});

test('classified legacy metadata is bound to its exact physical request key and original native-turn absence',async()=>{
 for(const version of [1,2])for(const field of ['physical','turn']){const storage=new Store(),r=await produce(storage,version,'a'.repeat(36),{outcome:'pending'});await migrate(storage);const metadata=storage.data.get(V2+'legacy-execution:v1:'+r.key);if(field==='physical'){metadata.requestID='b'.repeat(36);metadata.root=metadata.requestID}else metadata.turnID=crypto.randomUUID();const before=structuredClone(storage.data);await assert.rejects(prepareAccountingIndexPlan(storage,evidence),/legacy_execution_conflict/);assert.deepEqual(storage.data,before)}
});

test('attributed old non-UUID inflight pointers do not strand a new compatible request or lose old exposure',async()=>{
 for(const version of [1,2])for(const outcome of ['pending','uncertain']){const storage=new Store(),old=await produce(storage,version,'a'.repeat(36),{outcome}),original=structuredClone(storage.data);await migrate(storage);await index(storage);const ledger=new ProductionLedger({storage},env),p={...payload(crypto.randomUUID()),executionProtocol:'direct',bodyDigest:fingerprint},response=await ledger.fetch(request('/reserve-v2',p));assert.equal(response.status,200);assert.equal((await response.json()).dispatchGranted,false);unchanged(storage,original);assert.equal(storage.data.get(prefix(version)+'inflight:'+user),old.p.requestID);const audit=await auditAccountingIndex(storage);assert.equal(audit.budget.pendingMicroUSD,5000000);assert.equal(audit.budget.halted,false)}
});
