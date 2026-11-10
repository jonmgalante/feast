import test from 'node:test';
import assert from 'node:assert/strict';
import {NATIVE_RESEARCH,DIRECT_NATIVE_LIMITS,checkNativeFrameCapacity,encodeNativeFrame,decodeNativeFrame,validNativePayload,nativeContinuation,nativeRequestModel,nativeBody} from './native-research.mjs';
import {nativeConversationAnswer,decodeNativeResult,checkNativeReplyCapacity} from './native-conversation.mjs';
import {validConversationPayload} from './conversation.mjs';
import {validAgentPayload} from './agent-tools.mjs';
import {boundedResponse} from '../feast-proxy/openai.mjs';
import {ProductionLedger} from './production-ledger.mjs';
import {NATIVE_PROFILES,nativeUsageCost} from './native-accounting.mjs';
import {ANSWER_JOBS} from './answer-job-contract.mjs';
import {publicFetch} from './public-handler.mjs';
import {phoneHash,PHONE_OBJECT} from './phone-access.mjs';
import owner from '../feast-owner-validation/worker.mjs';
import {digest} from './broker.mjs';

// All transports, credentials, collection contents and ledger stores are fixtures.
const user='a'.repeat(64),at='2026-11-10T12:00:00.000Z',model='gpt-6.1-sol';
const direct={limits:DIRECT_NATIVE_LIMITS,allowCollectionQueryV2:true};
const bytes=v=>new TextEncoder().encode(typeof v==='string'?v:JSON.stringify(v)).byteLength;
const payload=()=>({version:10,mode:'conversationStep',requestID:crypto.randomUUID(),turnID:crypto.randomUUID(),step:0,text:'Read the relevant saved context.',webAllowed:true,context:{index:[],recent:[]},cities:[],task:null,findings:[],history:[],historyCount:0,continuation:null,result:null});
const result={status:'empty',complete:true,totalCount:0,records:[],findings:[],message:'not_found',localOnly:false};
const call=()=>({id:'read',type:'function_call',call_id:'read',name:'read_conversation',arguments:JSON.stringify({offset:0,limit:1})});
const reasoning=(id,content='')=>({id,type:'reasoning',summary:[],encrypted_content:content});
const message=()=>({id:'answer',type:'message',role:'assistant',phase:'final_answer',content:[{type:'output_text',text:'Only supported saved facts.',annotations:[]}]});
const receipt=(output=[message()],chosenModel=model)=>({model:chosenModel,status:'completed',usage:{input_tokens:98304,output_tokens:100},output});
const baseEnv={ENVIRONMENT:'production',OWNER_VALIDATION_ENABLED:'true',LIVE_AI:'true',ALLOW_RECONCILED_BUDGET:'true',ALLOW_PUBLIC_LOOKUP:'true',NATIVE_RESEARCH_ENABLED:'true',OPENAI_API_KEY:'fixture-not-a-key'};
class Storage {
 data=new Map();queue=Promise.resolve();
 transaction(fn){const run=this.queue.then(async()=>{const data=structuredClone(this.data);const result=await fn({get:async k=>data.get(k),put:async(k,v)=>data.set(k,structuredClone(v)),delete:async k=>data.delete(k),list:async({prefix='' }={})=>new Map([...data].filter(([k])=>k.startsWith(prefix)))});this.data=data;return result});this.queue=run.catch(()=>{});return run}
}
function setup(){const storage=new Storage(),access=new Storage(),env={...baseEnv};const ledger=new ProductionLedger({storage},env);env.PRODUCTION_STATE={idFromName:x=>x,get:id=>id===PHONE_OBJECT?new ProductionLedger({storage:access},env):ledger};return {env,storage,ledger,budget:async()=> (await ledger.fetch(new Request('https://ledger/status-v2'))).json()}}
function fixtureAccounting(){const calls={prepare:0,reserve:0,complete:0,rejected:0,uncertain:0,cancelUndispatched:0},bills=[];return {proofKind:'fixture_only',calls,bills,prepare:async p=>{calls.prepare++;return {revision:0,webAllowed:true,remainingWebActions:p.requestedWebActions}},reserve:async p=>{calls.reserve++;return {maxWebActions:p.maxWebActions}},complete:async(_r,b)=>{calls.complete++;bills.push(b);return {}},rejected:async()=>{calls.rejected++},uncertain:async()=>{calls.uncertain++},cancelUndispatched:async()=>{calls.cancelUndispatched++}}}
function padded(value,target,prefix='☕️😀"\\\n\u0000'){const copy={...value,padding:prefix};const n=target-bytes(copy);assert(n>=0);copy.padding+='a'.repeat(n);assert.equal(bytes(copy),target);return copy}
function paddedBody(value,target){const raw=JSON.stringify(value);assert(bytes(raw)<=target);return raw+' '.repeat(target-bytes(raw))}
async function fullFrame(p,target,{chosenModel=model,items=9}={}){
 const {frame}=await nativeContinuation(p,chosenModel,direct);
 frame.records=Array.from({length:items-1},(_,i)=>({observedAt:at,item:reasoning('r'+i,i===0?'☕️😀"\\\n\u0000':'')}));frame.records.push({observedAt:at,item:call()});
 let left=target-bytes(frame);assert(left>=0);
 for(const record of frame.records.slice(0,-1)){const n=Math.min(left,100000-record.item.encrypted_content.length);record.item.encrypted_content+='x'.repeat(n);left-=n}
 assert.equal(left,0);assert.equal(bytes(frame),target);return frame;
}
const resumed=(p,frame)=>({...p,step:1,continuation:encodeNativeFrame(frame,DIRECT_NATIVE_LIMITS),result:{callID:'read',output:result}});

// These values are fixed route constants, never request-selectable profiles.
test('direct capacities expand only intended transport bounds; historical and accounting limits stay pinned',()=>{
 assert.deepEqual(DIRECT_NATIVE_LIMITS,{maxInitialInput:98304,maxRawContinuationBytes:786432,maxContinuationBytes:1048576,maxRequestBytes:2097152,maxReplyBytes:2097152,maxProviderResponseBytes:1048576});
 assert.equal(NATIVE_RESEARCH.maxInitialInput,32768);assert.equal(NATIVE_RESEARCH.maxRawContinuationBytes,262500);assert.equal(NATIVE_RESEARCH.maxContinuationBytes,350000);assert.equal(NATIVE_RESEARCH.maxReplyBytes,400000);assert.equal(NATIVE_RESEARCH.maxProviderResponseBytes,65536);
 assert.equal(NATIVE_RESEARCH.maxOutput,8192);assert.equal(NATIVE_RESEARCH.maxItems,60);assert.equal(NATIVE_RESEARCH.maxResponses,12);assert.equal(NATIVE_RESEARCH.maxWebActions,12);assert.equal(NATIVE_RESEARCH.effort,'medium');
 assert.equal(NATIVE_PROFILES.solNativeUsageV1.estimate,1400288);assert.equal(NATIVE_PROFILES.astraNativeUsageV1.estimate,6800288);assert.equal(ANSWER_JOBS.maxPayloadBytes,512000);assert.equal(ANSWER_JOBS.maxBlobBytes,600000);
});
test('raw UTF-8/JSON escaping and encoded continuation accept exact limits and reject +1',()=>{
 for(const limits of [NATIVE_RESEARCH,DIRECT_NATIVE_LIMITS]){
  const frame=padded({records:[]},limits.maxRawContinuationBytes);const encoded=encodeNativeFrame(frame,limits);assert.equal(encoded.length,limits.maxContinuationBytes);assert.deepEqual(decodeNativeFrame(encoded,limits),frame);
  assert.throws(()=>encodeNativeFrame({...frame,padding:frame.padding+'a'},limits),/native_context_limit/);
  assert.throws(()=>decodeNativeFrame(encoded+'a',limits),/native_context_limit/);
  const custom={...limits,maxContinuationBytes:limits.maxContinuationBytes+4};const over=btoa(String.fromCharCode(...new TextEncoder().encode('null')))+'A'.repeat(4);assert.throws(()=>decodeNativeFrame(over,custom),/native_context_shape/);
  const bytesOver=Buffer.from(JSON.stringify({...frame,padding:frame.padding+'a'})).toString('base64');assert.throws(()=>decodeNativeFrame(bytesOver,custom),/native_context_limit/);
 }
 assert.throws(()=>encodeNativeFrame({records:Array.from({length:61},()=>({}))},DIRECT_NATIVE_LIMITS),/native_context_limit/);
 checkNativeFrameCapacity({records:Array.from({length:60},()=>({}))},DIRECT_NATIVE_LIMITS);
});
test('nested v8/v9 validators stay at 350k; only direct native validation admits 1MiB continuation',()=>{
 const p={...payload(),step:1,continuation:'a'.repeat(1048576),result:{callID:'read',output:result}};
 assert.equal(validNativePayload(p,direct),true);assert.equal(validNativePayload({...p,continuation:p.continuation+'a'},direct),false);assert.equal(validNativePayload(p),false);
 const {webAllowed,turnID,...old}=p;assert.equal(validConversationPayload({...old,version:9}),false);
 const {history,historyCount,...agent}=old;assert.equal(validAgentPayload({...agent,version:8,mode:'agentStep'}),false);
 const small={...old,version:9,continuation:'a'.repeat(350000)};assert.equal(validConversationPayload(small),true);assert.equal(validConversationPayload({...small,continuation:small.continuation+'a'}),false);
 assert.equal(validNativePayload({...payload(),capacityProfile:'large'},direct),false);
});
test('post-result append exact raw bound survives; +1 stops before input count or any ledger/generation',async()=>{
 for(const chosenModel of ['gpt-6-astra',model]){
  const p=payload(),seed=await fullFrame(p,5000,{chosenModel});
  const appended={observedAt:at,item:{type:'function_call_output',call_id:'read',output:JSON.stringify(result)}};
  const extra=bytes({...seed,records:[...seed.records,appended]})-bytes(seed);
  for(const over of [0,1]){
   const frame=await fullFrame(p,786432-extra+over,{chosenModel}),next=resumed(p,frame),accounting=fixtureAccounting();let counts=0,paid=0;
   const send=async url=>{if(url.endsWith('/input_tokens')){counts++;return Response.json({input_tokens:98304})}paid++;return Response.json(receipt([],chosenModel))};
   assert.equal(nativeRequestModel(next,undefined,direct),chosenModel);
   const response=await nativeConversationAnswer(next,user,baseEnv,send,{accounting,testOnly:true}),value=await response.json();
   assert.equal(response.status,over?413:200,JSON.stringify(value));assert.equal(counts,over?0:1);assert.equal(paid,over?0:1);assert.equal(accounting.calls.prepare,over?0:1);assert.equal(accounting.calls.reserve,over?0:1);
   if(over){assert.equal(value.error,'native_context_limit');assert.equal(accounting.calls.uncertain,0)}else {assert.equal(Buffer.from(value.continuation,'base64').length,786432);assert.equal(value.continuation.length,1048576)}
  }
 }
});
test('60-item frame becomes overfull after tool result and stops before any count/reservation/generation',async()=>{
 const p=payload(),frame=await fullFrame(p,15000,{items:60}),next=resumed(p,frame),accounting=fixtureAccounting();let sends=0;
 const response=await nativeConversationAnswer(next,user,baseEnv,async()=>{sends++;throw Error('must not call')},{accounting,testOnly:true});
 assert.equal(response.status,413);assert.equal((await response.json()).error,'native_context_limit');assert.equal(sends,0);assert.equal(accounting.calls.prepare,0);assert.equal(accounting.calls.reserve,0);
});
test('exact input cap generates once, +1 and malformed counts never reserve or generate; pilot/recovery keep 32768',async()=>{
 for(const [options,limit,overflowStatus]of [[{},98304,413],[{recovery:{ready:async()=>{},failed:async()=>{}}},32768,503],[{pilotExecutionModel:model},32768,503]]){
  for(const count of [limit,limit+1]){
   const accounting=fixtureAccounting();let paid=0;const env={...baseEnv,RESEARCH_PILOT_ENABLED:'true',RESEARCH_PILOT_KIND:'sol-astra-v2'};
   const response=await nativeConversationAnswer(payload(),user,env,async(url,o)=>{if(url.endsWith('/input_tokens'))return Response.json({input_tokens:count});paid++;const body=JSON.parse(o.body);assert.equal(body.max_output_tokens,8192);assert.equal(body.reasoning.effort,'medium');assert.equal(body.max_tool_calls,12);return Response.json(receipt())},{...options,accounting,testOnly:true});
   assert.equal(response.status,count===limit?200:overflowStatus);assert.equal(paid,count===limit?1:0);assert.equal(accounting.calls.reserve,paid);
  }
 }
 const accounting=fixtureAccounting(),response=await nativeConversationAnswer(payload(),user,baseEnv,async()=>Response.json({input_tokens:'98304'}),{accounting,testOnly:true});assert.equal(response.status,503);assert.equal((await response.json()).error,'native_input_unverified');assert.equal(accounting.calls.reserve,0);
});
test('provider decoder has explicit inclusive 1MiB override, cancellation, and unchanged default 64KiB',async()=>{
 for(const cap of [65536,1048576]){
  const value=padded({ok:true},cap),response=new Response(JSON.stringify(value));assert.deepEqual(await boundedResponse(response,cap),value);
  let cancelled=false;const body=new ReadableStream({start(c){c.enqueue(new TextEncoder().encode(JSON.stringify({...value,padding:value.padding+'a'})))},cancel(){cancelled=true}});
  await assert.rejects(boundedResponse(new Response(body),cap),/upstream_limit/);assert.equal(cancelled,true);
 }
 await assert.rejects(boundedResponse(new Response(JSON.stringify(padded({ok:true},65537)))),/upstream_limit/);
});
test('only direct generation decodes expanded receipts; count responses, pilot and recovery stay 64KiB',async()=>{
 for(const [options,code,status]of [[{},null,200],[{recovery:{ready:async()=>{},failed:async()=>{}}},'upstream_limit',503],[{pilotExecutionModel:model},'upstream_limit',503]]){
  const accounting=fixtureAccounting(),env={...baseEnv,RESEARCH_PILOT_ENABLED:'true',RESEARCH_PILOT_KIND:'sol-astra-v2'},body=JSON.stringify(padded(receipt(),1048576));
  const response=await nativeConversationAnswer(payload(),user,env,async url=>url.endsWith('/input_tokens')?Response.json({input_tokens:100}):new Response(body),{...options,accounting,testOnly:true});
  const value=await response.json();assert.equal(response.status,status);assert.equal(value.error??null,code);assert.equal(accounting.calls.uncertain,status===503?1:0);
 }
 const accounting=fixtureAccounting();let sends=0;const response=await nativeConversationAnswer(payload(),user,baseEnv,async()=>{sends++;return new Response(JSON.stringify(padded({input_tokens:100},65537)))},{accounting,testOnly:true});assert.equal(response.status,503);assert.equal((await response.json()).error,'upstream_limit');assert.equal(sends,1);assert.equal(accounting.calls.reserve,0);
});
test('provider overflow remains uncertain on real ledger and same-turn retry cannot dispatch',async()=>{
 const f=setup(),p=payload();let paid=0;
 const send=async url=>{if(url.endsWith('/input_tokens'))return Response.json({input_tokens:100});paid++;return new Response(JSON.stringify(padded(receipt(),1048577)))};
 const response=await nativeConversationAnswer(p,user,f.env,send),value=await response.json();assert.equal(response.status,502);assert.equal(value.error,'native_provider_response_limit');assert.equal(paid,1);
 const budget=await f.budget();assert.equal(budget.chargedMicroUSD,0);assert.equal(budget.pendingMicroUSD,1400288);assert([...f.storage.data.values()].some(x=>x?.state==='uncertain'));
 const retry=await nativeConversationAnswer({...p,requestID:crypto.randomUUID()},user,f.env,send);assert.equal(retry.status,503);assert.equal(paid,1);assert.equal((await f.budget()).pendingMicroUSD,1400288);
});
test('known usage is settled even when post-generation raw/item limits reject content, not falsely zeroed',async()=>{
 for(const output of [Array.from({length:61},(_,i)=>reasoning('r'+i)),[...Array.from({length:8},(_,i)=>reasoning('r'+i,'x'.repeat(99000))),message()]]){
  const f=setup(),value=receipt(output),response=await nativeConversationAnswer(payload(),user,f.env,async url=>url.endsWith('/input_tokens')?Response.json({input_tokens:100}):Response.json(value));
  assert.equal(response.status,413);const budget=await f.budget();assert.equal(budget.pendingMicroUSD,0);assert.equal(budget.chargedMicroUSD,nativeUsageCost([{model,inputTokens:98304,outputTokens:100,webCalls:0}],'solNativeUsageV1'));
 }
 const f=setup(),response=await nativeConversationAnswer(payload(),user,f.env,async url=>url.endsWith('/input_tokens')?Response.json({input_tokens:100}):Response.json({error:{code:'insufficient_quota'}},{status:429}));assert.equal(response.status,503);assert.equal((await response.json()).error,'provider_billing_limit');assert.equal((await f.budget()).chargedMicroUSD,0);assert.equal((await f.budget()).pendingMicroUSD,0);
});
test('pure recovery decoder retains historic raw frame limit while direct uses explicit fixed limit',async()=>{
 const p=payload(),state=await nativeContinuation(p,model),value=receipt([...Array.from({length:3},(_,i)=>reasoning('r'+i,'x'.repeat(90000))),message()]);state.allowedWebActions=12;
 let known=false;await assert.rejects(decodeNativeResult(p,state,value,{onVerifiedUsage:()=>{known=true}}),/native_context_limit/);assert.equal(known,true);
 const directReply=await decodeNativeResult(p,state,value,{limits:DIRECT_NATIVE_LIMITS});assert(directReply.reply.continuation.length>350000);
});
test('reply JSON bytes accept exact limits and reject +1 including escaping and Unicode',()=>{
 for(const limits of [NATIVE_RESEARCH,DIRECT_NATIVE_LIMITS]){const reply=padded({version:10,text:'☕️ "quoted" \\ line\n'},limits.maxReplyBytes);checkNativeReplyCapacity(reply,limits);assert.throws(()=>checkNativeReplyCapacity({...reply,padding:reply.padding+'a'},limits),/native_reply_limit/)}
});
test('oversized final reply settles known bill once and returns capacity error without uncertainty',async()=>{
 const accounting=fixtureAccounting(),complete=accounting.complete;accounting.complete=async(r,b)=>{await complete(r,b);return {padding:'x'.repeat(2097152)}};
 const response=await nativeConversationAnswer(payload(),user,baseEnv,async url=>url.endsWith('/input_tokens')?Response.json({input_tokens:100}):Response.json(receipt()),{accounting,testOnly:true});assert.equal(response.status,413);assert.equal((await response.json()).error,'native_reply_limit');assert.equal(accounting.calls.complete,1);assert.equal(accounting.calls.uncertain,0);assert.equal(accounting.bills[0].inputTokens,98304);
});
test('collection feature marker is direct-only, fingerprint-bound and absent fingerprints remain compatible',async()=>{
 const p=payload(),marked={...p,collectionQueryVersion:2};assert.equal(validNativePayload(marked),false);assert.equal(validNativePayload(marked,direct),true);assert.equal(validNativePayload({...p,collectionQueryVersion:3},direct),false);
 const old=await nativeContinuation(p,model),now=await nativeContinuation(p,model,direct);assert.equal(old.fingerprint,now.fingerprint);
 const updated=await nativeContinuation(marked,model,direct);assert.notEqual(updated.fingerprint,old.fingerprint);
 updated.frame.records=[{observedAt:at,item:call()}];const next=resumed(marked,updated.frame);assert.equal(nativeRequestModel(next,undefined,direct),model);await nativeContinuation(next,model,direct);const {collectionQueryVersion,...without}=next;await assert.rejects(nativeContinuation(without,model,direct),/native_context_identity/);
 const accounting=fixtureAccounting();for(const options of [{recovery:{failed:async()=>{}}},{pilotExecutionModel:model}]){const r=await nativeConversationAnswer(marked,user,{...baseEnv,RESEARCH_PILOT_ENABLED:'true',RESEARCH_PILOT_KIND:'sol-astra-v2'},()=>assert.fail('no provider calls'),{...options,accounting,testOnly:true});assert.equal(r.status,503)}assert.equal(accounting.calls.prepare,0);
});
async function publicFixture(){const f=setup(),token='t'.repeat(43),invitation='i'.repeat(43),now=Date.now();Object.assign(f.env,{PHONE_ACCESS_ENABLED:'true',PHONE_INVITATIONS_JSON:JSON.stringify([{id:crypto.randomUUID(),createdAt:now-1000,expiresAt:now+3600000,revoked:false,sha256:await phoneHash('invitation',invitation)}])});const headers={'Content-Type':'application/json',Authorization:'Bearer '+token};const activate=await publicFetch(new Request('https://feast.test/v1/access/activate',{method:'POST',headers,body:JSON.stringify({version:1,invitation,deviceID:crypto.randomUUID(),activationID:crypto.randomUUID(),credentialHash:await phoneHash('device',token)})}),f.env);assert.equal(activate.status,200);return {...f,headers}}
test('public direct v10 ingress accepts exact 2MiB and rejects +1 before dispatch; older/jobs limits do not expand',async()=>{
 const f=await publicFixture();let paid=0;const send=async url=>{if(url.endsWith('/input_tokens'))return Response.json({input_tokens:100});paid++;return Response.json(receipt())};
 const request=(path,protocol,body)=>new Request('https://feast.test'+path,{method:'POST',headers:{...f.headers,...protocol===null?{}:{'X-Feast-Agent-Protocol':protocol}},body});
 for(const size of [2097152,2097153]){const response=await publicFetch(request('/v1/answer','10',paddedBody(payload(),size)),f.env,send),value=await response.json();assert.equal(response.status,size===2097152?200:413);if(size===2097152)assert.equal(value.budget,undefined);else assert.equal(value.error,'request_limit')}assert.equal(paid,1);
 for(const protocol of ['8','9','11']){const response=await publicFetch(request('/v1/answer',protocol,paddedBody({version:Number(protocol),mode:'invalid'},512001)),f.env,()=>assert.fail('no generation'));assert.equal(response.status,503);assert.equal((await response.json()).error,'access_unavailable')}
 const jobs=await publicFetch(request('/v1/answer-jobs','10',paddedBody({version:1,op:'status'},514049)),f.env,()=>assert.fail('no generation'));assert.equal(jobs.status,503);assert.equal((await jobs.json()).error,'access_unavailable');
 const headerless=await publicFetch(request('/v1/answer',null,paddedBody({version:7},4097)),f.env,()=>assert.fail('no generation'));assert.equal(headerless.status,503);
 const health=await(await publicFetch(new Request('https://feast.test/health'),f.env)).json();assert.equal(health.collectionQueryVersion,2);assert.equal(health.model,model);assert.equal((await(await publicFetch(new Request('https://feast.test/health'),{...f.env,NATIVE_RESEARCH_ENABLED:'false'})).json()).collectionQueryVersion,undefined);
});
test('owner ingress widens protocol10 only, forwards capacity diagnostics, and preserves 8/9/pilot/headerless bounds',async()=>{
 const token='o'.repeat(43),now=Date.now();let calls=0;const env={ENABLED:'true',LIVE_AI:'true',NATIVE_RESEARCH_ENABLED:'true',RESEARCH_PILOT_ENABLED:'true',ALLOW_PUBLIC_LOOKUP:'true',ALLOW_RECONCILED_BUDGET:'true',OWNER_TOKEN_HASHES_JSON:JSON.stringify([{id:'owner-original-iphone17',sha256:await digest(token),createdAt:new Date(now-1000).toISOString(),expiresAt:new Date(now+3600000).toISOString()}]),PRODUCTION:{answer:async()=>{calls++;return {status:413,body:{error:'native_input_limit'}}}}};
 const request=(protocol,value,size)=>new Request('https://owner.test/v1/answer',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',...protocol===null?{}:{'X-Feast-Agent-Protocol':protocol}},body:paddedBody(value,size)});
 const accepted=await owner.fetch(request('10',{version:10,mode:'conversationStep'},2097152),env);assert.equal(accepted.status,413);assert.equal((await accepted.json()).error,'native_input_limit');assert.equal(calls,1);
 const over=await owner.fetch(request('10',{version:10,mode:'conversationStep'},2097153),env);assert.equal((await over.json()).error,'request_limit');assert.equal(calls,1);
 for(const [protocol,value,limit]of [['8',{version:8,mode:'agentStep'},512000],['9',{version:9,mode:'conversationStep'},512000],['11',{version:11,mode:'researchPilot'},512000],[null,{version:7,mode:'publicLookup'},50000]]){await owner.fetch(request(protocol,value,limit),env);const prior=calls,r=await owner.fetch(request(protocol,value,limit+1),env);assert.equal(r.status,413);assert.equal((await r.json()).error,'request_limit');assert.equal(calls,prior)}
 const health=await(await owner.fetch(new Request('https://owner.test/health'),env)).json();assert.equal(health.collectionQueryVersion,2);assert.equal(health.model,model);
});
test('native RPC request bound rejects serialized +1 bytes before accounting or counting',async()=>{
 const accounting=fixtureAccounting(),p=padded(payload(),2097153);const response=await nativeConversationAnswer(p,user,baseEnv,()=>assert.fail('no transport'),{accounting,testOnly:true});assert.equal(response.status,413);assert.equal((await response.json()).error,'native_request_limit');assert.equal(accounting.calls.prepare,0);
});
test('marked native query schema, receipt and resumption preserve fieldPresence and requested-null projection end to end',async()=>{
 const f=setup(),p={...payload(),collectionQueryVersion:2};p.context={...p.context,collectionAccess:'permitted_details_v1',totalCount:1,indexComplete:false};
 const query={operation:'list',scope:'library',city:null,cuisine:null,status:null,placeType:null,name:null,positions:[],fields:['instagram'],neighborhood:null,groupBy:null,names:null,offset:null,limit:null,searchText:null,tag:null,snapshot:null,fieldPresence:{field:'instagram',presence:'missing'}};
 const queryCall={id:'query',type:'function_call',call_id:'query',name:'query_collection',arguments:JSON.stringify({entity:'place',query,selectionIDs:null})};let paid=0;
 const send=async(url,o)=>{if(url.endsWith('/input_tokens'))return Response.json({input_tokens:100});paid++;const body=JSON.parse(o.body),schema=body.tools.find(t=>t.name==='query_collection').parameters.properties.query;assert(schema.properties.fieldPresence);assert.match(body.instructions,/omitted field is unrequested or unavailable/);if(paid===2){const toolOutput=JSON.parse(body.input.find(i=>i.type==='function_call_output').output);assert.equal(toolOutput.records[0].instagram,null);assert.equal(Object.hasOwn(toolOutput.records[0],'note'),false);const oldCall=JSON.parse(body.input.find(i=>i.type==='function_call').arguments);assert.deepEqual(oldCall.query.fieldPresence,query.fieldPresence)}return Response.json(receipt(paid===1?[queryCall]:[message()]))};
 const first=await nativeConversationAnswer(p,user,f.env,send),value=await first.json();assert.equal(first.status,200,JSON.stringify(value));assert.equal(value.kind,'tool');assert.deepEqual(JSON.parse(value.call.arguments).query.fieldPresence,query.fieldPresence);
 const projected={status:'success',complete:true,totalCount:1,records:[{id:crypto.randomUUID(),name:'Public Café',city:'New York',cuisines:[],kind:'place',instagram:null}],findings:[],message:'ok',localOnly:false};
 const next={...p,step:1,continuation:value.continuation,result:{callID:'query',output:projected}}, {collectionQueryVersion,...unmarked}=next;
 const denied=await nativeConversationAnswer(unmarked,user,f.env,()=>assert.fail('no dispatch after marker removal'));assert.equal(denied.status,503);assert.equal((await denied.json()).error,'native_context_identity');
 const last=await nativeConversationAnswer(next,user,f.env,send);assert.equal(last.status,200,JSON.stringify(await last.clone().json()));assert.equal((await last.json()).kind,'answer');assert.equal(paid,2);assert.equal((await f.budget()).pendingMicroUSD,0);
 const old={...p};delete old.collectionQueryVersion;const oldBody=nativeBody(old,await nativeContinuation(old,model,direct));assert.equal(oldBody.tools.find(t=>t.name==='query_collection').parameters.properties.query.properties.fieldPresence,undefined);
});
