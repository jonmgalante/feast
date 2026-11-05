import test from 'node:test';import assert from 'node:assert/strict';
import worker,{publicFetch} from './public-handler.mjs';import {ProductionLedger} from './production-ledger.mjs';
import {phoneHash,phoneGrants,phoneAccessFetch,PHONE_OBJECT} from './phone-access.mjs';
// Static fake test strings only. No live credentials, network, or saved data.
const invite='i'.repeat(43),token='t'.repeat(43),id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`,now=1000000;
function storage(){const data=new Map();let queue=Promise.resolve();return {data,transaction(fn){const job=queue.then(async()=>{const next=structuredClone(data);const result=await fn({get:async k=>next.get(k),put:async(k,v)=>next.set(k,structuredClone(v)),list:async({prefix})=>new Map([...next].filter(([k])=>k.startsWith(prefix)))});data.clear();for(const [k,v] of next)data.set(k,v);return result});queue=job.catch(()=>{});return job}}}
const req=(path,p,headers={})=>new Request('https://feast.test'+path,p?{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(p)}:{headers});
async function setup(){const s=storage(),grant={id:id(1),createdAt:now-100,expiresAt:now+1000,revoked:false,sha256:await phoneHash('invitation',invite)},env={PHONE_ACCESS_ENABLED:'true',PHONE_INVITATIONS_JSON:JSON.stringify([grant]),ENVIRONMENT:'production',OWNER_VALIDATION_ENABLED:'true',LIVE_AI:'true',ALLOW_RECONCILED_BUDGET:'true',ALLOW_PUBLIC_LOOKUP:'true',NATIVE_RESEARCH_ENABLED:'true'};
 const p={version:1,invitation:invite,credentialHash:await phoneHash('device',token),deviceID:id(2),activationID:id(3)};
 const call=(path,p,at=now)=>phoneAccessFetch(s,req('/phone-access/'+path,p),env,at);
 env.PRODUCTION_STATE={idFromName:name=>{assert.equal(name,PHONE_OBJECT);return name},get:()=>({fetch:r=>phoneAccessFetch(s,r,env,now)})};return {s,grant,env,p,call};}
test('activation is single-use, exact lost-reply recovery survives restart and expiry, and stores hashes only',async()=>{const {s,p,call,env}=await setup();const first=await call('activate',p);assert.equal(first.status,200);const receipt=await first.json();assert.equal((await call('activate',{...p,activationID:id(4)})).status,403);assert.deepEqual(await(await phoneAccessFetch(s,req('/phone-access/activate',p),env,now+100000)).json(),receipt);assert.equal((await call('authenticate',{credentialHash:p.credentialHash},now+100000)).status,200);const encoded=JSON.stringify([...s.data]);assert(!encoded.includes(invite));assert(!encoded.includes(token));assert([...s.data.keys()].every(k=>k.startsWith('phone-access-v1:')))});
test('simultaneous code claims authorize exactly one device without partial state',async()=>{const {p,call,s}=await setup();const rs=await Promise.all([call('activate',p),call('activate',{...p,deviceID:id(4),activationID:id(5),credentialHash:'a'.repeat(64)})]);assert.deepEqual(rs.map(r=>r.status).sort(),[200,403]);assert.equal(s.data.size,4)});
test('expired, unknown, revoked, future and malformed grants fail without enrollment or provider calls',async()=>{for(const change of [{expiresAt:now},{revoked:true},{createdAt:now+10,expiresAt:now+20}]){const {p,call,env,grant,s}=await setup();env.PHONE_INVITATIONS_JSON=JSON.stringify([{...grant,...change}]);assert.equal((await call('activate',p)).status,403);assert.equal(s.data.size,0)}const {p,call,env,grant}=await setup();assert.equal((await call('activate',{...p,invitation:'z'.repeat(43)})).status,403);for(const list of [[grant,grant],[{...grant,role:'owner'}],[{...grant,expiresAt:now+31*86400000}]]){env.PHONE_INVITATIONS_JSON=JSON.stringify(list);assert.equal(phoneGrants(env),null)}});
test('revocation denies an existing device immediately and does not erase its receipt or other ledger records',async()=>{const {p,call,env,grant,s}=await setup();s.data.set('historic-ledger-hold',{amount:6800288,state:'uncertain'});assert.equal((await call('activate',p)).status,200);const before=structuredClone(s.data);env.PHONE_INVITATIONS_JSON=JSON.stringify([{...grant,revoked:true}]);assert.equal((await call('authenticate',{credentialHash:p.credentialHash})).status,401);assert.equal((await call('activate',p)).status,403);assert.deepEqual(s.data,before)});
test('changing invitation material cannot reassign an already claimed identity',async()=>{const {p,call,env,grant}=await setup();await call('activate',p);env.PHONE_INVITATIONS_JSON=JSON.stringify([{...grant,sha256:await phoneHash('invitation','x'.repeat(43))}]);assert.equal((await call('activate',{...p,invitation:'x'.repeat(43)})).status,403);assert.equal((await call('authenticate',{credentialHash:p.credentialHash})).status,401)});
test('public routing leaves default closed, exposes only own receipt, and denies admin/global ledger/pilot access',async()=>{const {env,p}=await setup();assert.equal((await worker.fetch(req('/v1/access/activate',p),{PHONE_ACCESS_ENABLED:'false'})).status,503);assert.equal((await worker.fetch(req('/v1/access/activate',p),env)).status,200);const headers={Authorization:'Bearer '+token};const own=await worker.fetch(req('/v1/access/status',null,headers),env);assert.equal(own.status,200);assert(!Object.keys(await own.json()).some(k=>/Hash|budget|charged|pending/i.test(k)));for(const path of ['/v1/status','/admin','/phone-access/activate'])assert.equal((await worker.fetch(req(path,null,headers),env)).status,404);assert.equal((await worker.fetch(req('/v1/access/status'),env)).status,401);assert.equal((await worker.fetch(req('/v1/answer',{version:11,mode:'researchPilot'},{...headers,'X-Feast-Agent-Protocol':'11'}),env)).status,400)});
test('body bound and malformed JSON fail closed; activated health advertises the unchanged model/tool capabilities',async()=>{const {env}=await setup();assert.equal((await worker.fetch(new Request('https://feast.test/v1/access/activate',{method:'POST',headers:{'Content-Type':'application/json'},body:'x'.repeat(2049)}),env)).status,503);const health=await(await worker.fetch(req('/health'),env)).json();assert.equal(health.model,'gpt-6.1-sol');assert.equal(health.validationCapMicroUSD,null);assert.equal(health.nativeResearchEnabled,true);assert.deepEqual(health.agentProtocolVersions,[8,9,10])});
test('existing Durable Object class routes access separately with no accounting migration',async()=>{const {s,env,p}=await setup();const ledger=new ProductionLedger({storage:s},env);const currentGrant=JSON.parse(env.PHONE_INVITATIONS_JSON)[0],time=Date.now();env.PHONE_INVITATIONS_JSON=JSON.stringify([{...currentGrant,createdAt:time-1000,expiresAt:time+10000}]);assert.equal((await ledger.fetch(req('/phone-access/activate',p))).status,200);assert([...s.data.keys()].every(k=>k.startsWith('phone-access-v1:')))});
test('activated phone uses the existing Sol conversation/accounting pipeline; owner holds stay and sponsor totals stay private',async()=>{
 const {s,env,p}=await setup(),accounting=storage();env.OPENAI_API_KEY='offline-placeholder';
 accounting.data.set('unrelated-held-receipt',{state:'uncertain',amount:6800288});
 const ledger=new ProductionLedger({storage:accounting},env);
 env.PRODUCTION_STATE={idFromName:x=>x,get:name=>name===PHONE_OBJECT?{fetch:r=>phoneAccessFetch(s,r,env,now)}:name==='production-validation-v1'?ledger:assert.fail('unexpected namespace')};
 await worker.fetch(req('/v1/access/activate',p),env);
 const payload={version:10,mode:'conversationStep',requestID:id(20),turnID:id(21),step:0,text:'Explain public city history.',webAllowed:true,context:{index:[],recent:[]},cities:[],task:null,findings:[],history:[],historyCount:0,continuation:null,result:null};
 let calls=0;const send=async(url,o)=>{assert.equal(JSON.parse(o.body).model,'gpt-6.1-sol');if(url.endsWith('/input_tokens'))return Response.json({input_tokens:100});assert.equal(url,'https://api.openai.com/v1/responses');calls++;return Response.json({model:'gpt-6.1-sol',status:'completed',usage:{input_tokens:1000,output_tokens:100},output:[{type:'message',id:'m',role:'assistant',phase:'final_answer',content:[{type:'output_text',text:'A general explanation.',annotations:[]}]}]})};
 const r=await publicFetch(req('/v1/answer',payload,{Authorization:'Bearer '+token,'X-Feast-Agent-Protocol':'10'}),env,send);assert.equal(r.status,200,JSON.stringify(await r.clone().json()));const body=await r.json();assert.equal(body.model,'gpt-6.1-sol');assert.equal(body.budget,undefined);assert.equal(calls,1);
 assert.deepEqual(accounting.data.get('unrelated-held-receipt'),{state:'uncertain',amount:6800288});assert([...accounting.data.values()].some(v=>v?.profile==='solNativeUsageV1'&&v.state==='complete'));
 assert([...s.data.keys()].every(k=>k.startsWith('phone-access-v1:')));
});
test('client/server hash contract is stable and stored grant identity cannot be substituted',async()=>{
 const {p,call,s}=await setup();
 assert.equal(await phoneHash('device',token),'c396c4020946c806167512d4b6078935565d30e573dc3a2356be36c984e122ea');
 await call('activate',p);const key='phone-access-v1:grant:'+id(1),before=s.data.get(key);
 s.data.set(key,{...before,grantID:id(99)});
 assert.equal((await call('authenticate',{credentialHash:p.credentialHash})).status,401);
 assert.equal((await call('activate',p)).status,403);
});
test('revoked and malformed credentials, protocol mismatches and unregistered credentials cannot reach provider dispatch',async()=>{
 const {env,p,grant}=await setup();await worker.fetch(req('/v1/access/activate',p),env);
 let calls=0;const send=()=>{calls++;throw Error('Provider must not be called')};
 for(const authorization of ['', 'Bearer wrong', 'Basic '+token, 'Bearer '+token+'x', 'Bearer '+'o'.repeat(43)]){
  const r=await publicFetch(req('/v1/answer',{version:10,mode:'conversationStep'},{Authorization:authorization,'X-Feast-Agent-Protocol':'10'}),env,send);
  assert.equal(r.status,401);
 }
 for(const [header,version,mode] of [['9',10,'conversationStep'],['10',10,'researchPilot'],['8',8,'webSearch']]){
  assert.equal((await publicFetch(req('/v1/answer',{version,mode},{Authorization:'Bearer '+token,'X-Feast-Agent-Protocol':header}),env,send)).status,400);
 }
 env.PHONE_INVITATIONS_JSON=JSON.stringify([{...grant,revoked:true}]);
 assert.equal((await publicFetch(req('/v1/answer',{version:10,mode:'conversationStep'},{Authorization:'Bearer '+token,'X-Feast-Agent-Protocol':'10'}),env,send)).status,401);
 assert.equal(calls,0);
});
test('malformed scalar types cannot consume invitations or substitute stored identities',async()=>{
 const {env,p,grant,call,s}=await setup();
 for(const field of ['deviceID','activationID','credentialHash','invitation'])for(const bad of [[p[field]],{value:p[field]},42,null]){
  assert.equal((await call('activate',{...p,[field]:bad})).status,400);assert.equal(s.data.size,0);
 }
 for(const field of ['id','sha256'])for(const bad of [[grant[field]],{value:grant[field]},42,null]){
  env.PHONE_INVITATIONS_JSON=JSON.stringify([{...grant,[field]:bad}]);assert.equal(phoneGrants(env),null);
 }
 env.PHONE_INVITATIONS_JSON=JSON.stringify([grant]);await call('activate',p);
 assert.equal((await call('authenticate',{credentialHash:[p.credentialHash]})).status,401);
 const key='phone-access-v1:grant:'+grant.id,record=structuredClone(s.data.get(key));
 for(const field of ['grantID','deviceID','activationID','credentialHash','invitationHash']){
  s.data.set(key,{...record,[field]:[record[field]]});assert.equal((await call('authenticate',{credentialHash:p.credentialHash})).status,503);
 }
});
test('native-off phone rollback supports only the existing bounded public v7 lookup, with accounting and sponsor redaction',async()=>{
 const {s,env,p}=await setup(),accounting=storage();env.NATIVE_RESEARCH_ENABLED='false';env.OPENAI_API_KEY='offline-placeholder';
 const ledger=new ProductionLedger({storage:accounting},env);
 env.PRODUCTION_STATE={idFromName:x=>x,get:name=>name===PHONE_OBJECT?{fetch:r=>phoneAccessFetch(s,r,env,now)}:name==='production-validation-v1'?ledger:assert.fail('unexpected namespace')};
 await worker.fetch(req('/v1/access/activate',p),env);
 const headers={Authorization:'Bearer '+token},payload={version:7,mode:'publicLookup',requestID:id(30),business:{name:'Public Cafe',city:'London'},fields:['website']};
 const source='https://public-cafe.example/',quote='Public Cafe in London publishes its official website at '+source;
 let generations=0,counts=0;const send=async(url,o)=>{
  const body=JSON.parse(o.body);assert.equal(body.model,'gpt-6.1-sol');assert.equal(body.reasoning.effort,'medium');
  if(url.endsWith('/input_tokens')){counts++;return Response.json({input_tokens:1000})}
  generations++;let output;
  if(generations===1){assert.deepEqual(JSON.parse(body.input),{business:payload.business,fields:payload.fields});output=[{type:'web_search_call',status:'completed',action:{type:'search',sources:[{type:'url',url:source}]}},{type:'message',content:[{type:'output_text',text:quote,annotations:[{type:'url_citation',url:source,title:'Website',start_index:0,end_index:quote.length}]}]}]}
  else {output=[{type:'message',content:[{type:'output_text',text:JSON.stringify({decisions:[{field:'website',decision:'supported',targetName:'Public Cafe',targetCity:'London',value:source,sourceURL:source,blockID:'e0',quote}]})}]}]}
  return Response.json({model:'gpt-6.1-sol',status:'completed',usage:{input_tokens:1000,output_tokens:100},output});
 };
 const health=await(await worker.fetch(req('/health'),env)).json();assert.equal(health.nativeResearchEnabled,false);assert.equal(health.publicBusinessLookupEnabled,true);
 for(const bad of [{...payload,context:{index:[]}},{...payload,requestID:[payload.requestID]},{...payload,version:6},{...payload,mode:'libraryIntent'},{...payload,fields:['notes']}])assert.equal((await publicFetch(req('/v1/answer',bad,headers),env,send)).status,400);
 assert.equal((await publicFetch(req('/v1/answer',payload,{...headers,'X-Feast-Agent-Protocol':'7'}),env,send)).status,400);
 assert.equal(generations,0);assert.equal(counts,0);
 const result=await publicFetch(req('/v1/answer',payload,headers),env,send);assert.equal(result.status,200,JSON.stringify(await result.clone().json()));
 const body=await result.json();assert.equal(body.state,'found');assert.equal(body.findings[0].value,source);assert.equal(body.budget,undefined);assert.equal(generations,2);assert.equal(counts,2);
 assert.equal((await publicFetch(req('/v1/answer',payload,headers),env,send)).status,409);assert.equal(generations,2);
 env.ALLOW_PUBLIC_LOOKUP='false';assert.equal((await publicFetch(req('/v1/answer',{...payload,requestID:id(31)},headers),env,send)).status,503);assert.equal(generations,2);
});
test('each invited device keeps its own retry identity and cannot fence another device attempt',async()=>{
 const {s,env,p,grant}=await setup(),accounting=storage(),secondToken='u'.repeat(43),secondInvite='j'.repeat(43);
 env.OPENAI_API_KEY='offline-placeholder';
 const secondGrant={...grant,id:id(40),sha256:await phoneHash('invitation',secondInvite)};
 env.PHONE_INVITATIONS_JSON=JSON.stringify([grant,secondGrant]);const ledger=new ProductionLedger({storage:accounting},env);
 env.PRODUCTION_STATE={idFromName:x=>x,get:name=>name===PHONE_OBJECT?{fetch:r=>phoneAccessFetch(s,r,env,now)}:ledger};
 await worker.fetch(req('/v1/access/activate',p),env);
 await worker.fetch(req('/v1/access/activate',{...p,invitation:secondInvite,deviceID:id(41),activationID:id(42),credentialHash:await phoneHash('device',secondToken)}),env);
 const root=id(43),actor=await phoneHash('identity',grant.id);accounting.data.set('production-validation-v2:stage-root:'+root,{userHash:actor});
 const fence={version:9,mode:'retryFence',roots:[root]},send=()=>assert.fail('No provider call in retry fencing');
 assert.equal((await publicFetch(req('/v1/answer',fence,{Authorization:'Bearer '+secondToken,'X-Feast-Agent-Protocol':'9'}),env,send)).status,403);
 assert.equal(accounting.data.has('production-validation-v2:closed-root:'+root),false);
 assert.equal((await publicFetch(req('/v1/answer',fence,{Authorization:'Bearer '+token,'X-Feast-Agent-Protocol':'9'}),env,send)).status,200);
});
