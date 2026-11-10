import test from 'node:test';import assert from 'node:assert/strict';
import {checkedNativeItem,nativeEvidence,nativeContinuation,nativeBody,nativeDigest,encodeNativeFrame} from './native-research.mjs';
import {nativeAccountingAdapter,NATIVE_ESTIMATE} from './native-accounting.mjs';
import {nativeConversationAnswer} from './native-conversation.mjs';import {ProductionLedger} from './production-ledger.mjs';import {boundedResponse} from '../feast-proxy/openai.mjs';
const at='2026-11-03T19:00:00Z';
const web=(id,start,count=41)=>({type:'web_search_call',id,status:'completed',action:{type:'search',query:'Compare public evidence',sources:Array.from({length:count},(_,i)=>({type:'url',url:'https://example.org/source-'+(start+i),title:'Public source '+(start+i)}))}});
const message=(urls=['https://example.org/source-81'],text='The verified opening date is supported; another date is disputed.')=>({type:'message',id:'answer',role:'assistant',status:'completed',phase:'final_answer',content:[{type:'output_text',text,annotations:urls.map(url=>({type:'url_citation',url,title:'Citation',start_index:0,end_index:3}))}]});
const records=items=>items.map(item=>({observedAt:at,item}));
const p=()=>({version:10,mode:'conversationStep',requestID:crypto.randomUUID(),turnID:crypto.randomUUID(),step:0,text:'Compare official public dates.',webAllowed:true,context:{index:[],recent:[]},cities:[],task:null,findings:[],history:[],historyCount:0,continuation:null,result:null});
function setup(){const data=new Map();let q=Promise.resolve();const storage={transaction(fn){const r=q.then(()=>fn({get:async k=>structuredClone(data.get(k)),put:async(k,v)=>data.set(k,structuredClone(v)),list:async({prefix})=>new Map([...data].filter(([k])=>k.startsWith(prefix)))}));q=r.catch(()=>{});return r}};const env={ENVIRONMENT:'production',OWNER_VALIDATION_ENABLED:'true',LIVE_AI:'true',ALLOW_RECONCILED_BUDGET:'true',ALLOW_PUBLIC_LOOKUP:'true',NATIVE_RESEARCH_ENABLED:'true',OPENAI_API_KEY:'offline-fixture'};const ledger=new ProductionLedger({storage},env);env.PRODUCTION_STATE={idFromName:x=>x,get:()=>ledger};return{env,ledger,data}}
test('multi-action overflow compacts only optional inventory, preserving late citations and opened pages exactly',async()=>{
 const items=[web('a',0),web('b',41),{id:'opened',type:'web_search_call',status:'completed',action:{type:'open_page',url:'https://example.org/official'}},message()];items.forEach(i=>checkedNativeItem(i,'Public query'));
 const metrics={};const e=await nativeEvidence(records(items),false,(k,v)=>metrics[k]=v);
 assert.equal(e.sources.length,80);assert.deepEqual(e.inventory,{totalUniqueSources:83,omittedConsultedSources:3,complete:false});
 assert(e.sources.some(s=>s.url==='https://example.org/source-81'&&s.roles.includes('cited')&&s.roles.includes('consulted')));assert(e.sources.some(s=>s.url==='https://example.org/official'&&s.roles.includes('provider_opened')));
 assert.equal(e.blocks[0].text,items[3].content[0].text);assert.equal(e.blocks[0].annotations[0].start,0);assert.equal(e.blocks[0].annotations[0].end,3);assert.equal(e.actions.length,3);assert.equal(metrics.evidenceSourcesOmitted,3);assert.equal(metrics.evidenceRequiredSources,2);
 for(const s of e.sources)assert.equal(s.id,await nativeDigest(s.url));
});
test('duplicates merge roles and counts without omissions or changed content',async()=>{
 const e=await nativeEvidence(records([web('a',0),web('b',0),message(['https://example.org/source-0'])]));assert.equal(e.sources.length,41);assert.deepEqual(e.inventory,{totalUniqueSources:41,omittedConsultedSources:0,complete:true});assert.deepEqual(e.sources[0].roles,['consulted','cited']);
});
test('all essential citations are preserved or capacity fails precisely; no silent essential truncation',async()=>{
 const urls=Array.from({length:81},(_,i)=>'https://example.org/cited-'+i),a=message(urls.slice(0,40)),b={...message(urls.slice(40)),id:'other'};
 const counters={};await assert.rejects(nativeEvidence(records([a,b]),false,(k,v)=>counters[k]=v),/native_required_sources_limit/);assert.equal(counters.evidenceRequiredSources,81);assert.equal(counters.evidenceSourcesSeen,81);
 const textBlocks=Array.from({length:5},(_,i)=>({...message(['https://example.org/cited'], 'x'.repeat(16000)),id:'long-'+i}));await assert.rejects(nativeEvidence(records(textBlocks)),/native_evidence_text_limit/);
});
test('compaction never launders malformed or oversized optional sources and retains all provider input unchanged',async()=>{
 for(const url of ['http://unsafe.invalid','https://user:password@example.org/','https://example.org/'+ 'x'.repeat(2048)]){const w=web('bad',0);w.action.sources[40].url=url;assert.throws(()=>checkedNativeItem(w,'Public query'),/sources_shape/)}
 const w=web('too-many',0,81);assert.throws(()=>checkedNativeItem(w,'Public query'),/sources_shape/);
 const items=[web('a',0),web('b',41),message()];const before=structuredClone(items);await nativeEvidence(records(items));assert.deepEqual(items,before);
 await assert.rejects(boundedResponse(Response.json({padding:'x'.repeat(1048576)})),/upstream_limit/);
});
test('private phase text and annotation metadata never enter projected evidence',async()=>{
 const privateResult={type:'function_call_output',call_id:'read',output:JSON.stringify({localOnly:true})};
 const e=await nativeEvidence(records([web('public',0),privateResult,message(['https://example.org/PRIVATE_SENTINEL'],'PRIVATE_SENTINEL')]));assert.equal(e.blocks.length,0);assert(!JSON.stringify(e).includes('PRIVATE_SENTINEL'));assert.equal(e.inventory.totalUniqueSources,41);
});
test('real ledger settles a compacted answer once and provider continuation retains every consulted URL',async()=>{
 const {env,ledger}=setup(),payload=p();let paid=0;const items=[web('a',0),web('b',41),message()];
 const send=async(url,o)=>{if(url.endsWith('input_tokens'))return Response.json({input_tokens:100});paid++;return Response.json({model:JSON.parse(o.body).model,status:'completed',usage:{input_tokens:1000,output_tokens:100},output:items})};
 const response=await nativeConversationAnswer(payload,'a'.repeat(64),env,send);const value=await response.json();assert.equal(response.status,200,JSON.stringify(value));assert.equal(paid,1);assert.equal(value.nativeEvidence.inventory.omittedConsultedSources,2);assert.equal(value.nativeEvidence.sources.length,80);assert.equal(value.budget.pendingMicroUSD,0);assert.equal(value.budget.chargedMicroUSD,28600);
 const frame=JSON.parse(atob(value.continuation));assert.equal(frame.records[0].item.action.sources.length,41);assert.equal(frame.records[1].item.action.sources.length,41);assert.equal(value.text,items[2].content[0].text);assert.equal(value.finalCitations[0].url,'https://example.org/source-81');
 const prior=await(await ledger.fetch(new Request('https://ledger/status-v2'))).json();const replay=await nativeConversationAnswer(payload,'a'.repeat(64),env,send);assert.equal(replay.status,503);assert.equal(paid,1);assert.equal((await(await ledger.fetch(new Request('https://ledger/status-v2'))).json()).chargedMicroUSD,prior.chargedMicroUSD);
 assert.equal(value.performance.counters.evidenceSourcesOmitted,2);assert(value.performance.stages.evidence);
});
test('essential overflow returns a precise error and content-free counts while known usage settles without new uncertainty',async()=>{
 const {env,ledger,data}=setup(),payload=p(),urls=Array.from({length:81},(_,i)=>'https://example.org/cited-'+i);let paid=0;
 const send=async url=>{if(url.endsWith('input_tokens'))return Response.json({input_tokens:100});paid++;return Response.json({model:'gpt-6.1-sol',status:'completed',usage:{input_tokens:1000,output_tokens:100},output:[message(urls.slice(0,40)),{...message(urls.slice(40)),id:'second'}]})};
 const old=nativeAccountingAdapter(env),request={userHash:'a'.repeat(64),root:crypto.randomUUID(),turnID:crypto.randomUUID(),step:0,fingerprint:'f'.repeat(64),priorDigest:null,privateLatched:false,requestedWebActions:12};
 const allocation=await old.prepare(request),hold=await old.reserve({...request,allocationRevision:allocation.revision,maxWebActions:allocation.remainingWebActions});await old.uncertain(hold);
 const response=await nativeConversationAnswer(payload,'a'.repeat(64),env,send),value=await response.json();assert.equal(response.status,503);assert.equal(value.error,'native_required_sources_limit');assert.equal(value.performance.counters.evidenceRequiredSources,81);assert(!JSON.stringify(value).includes('https://'));assert.equal(paid,1);
 const status=await(await ledger.fetch(new Request('https://ledger/status-v2'))).json();assert.equal(status.chargedMicroUSD,6600);assert.equal(status.pendingMicroUSD,NATIVE_ESTIMATE);
});

test('existing client 60-block capacity is enforced without dropping essential annotated blocks',async()=>{
 const items=Array.from({length:4},(_,i)=>({...message(['https://example.org/source-0'],'A'),id:'block-'+i}));
 for(const [i,item]of items.entries()){item.content=Array.from({length:i===3?1:20},()=>({type:'output_text',text:'Fact',annotations:[{type:'url_citation',url:'https://example.org/source-0',title:'Source',start_index:0,end_index:1}]}));checkedNativeItem(item,'Public query')}
 const metrics={};await assert.rejects(nativeEvidence(records(items),false,(k,v)=>metrics[k]=v),/native_evidence_block_limit/);assert.equal(metrics.evidenceBlocks,61);
 items.pop();const e=await nativeEvidence(records(items));assert.equal(e.blocks.length,60);assert.equal(e.sources.length,1);
});
test('combined continuation/projection fits expanded direct budget while pilot retains historical known-settlement failure',async()=>{
 for(const pilot of [false,true]){
 const {env,ledger}=setup(),payload=p();let paid=0,next=payload;
 const options=pilot?{pilotExecutionModel:'gpt-6.1-sol'}:{};if(pilot)Object.assign(env,{RESEARCH_PILOT_ENABLED:'true',RESEARCH_PILOT_KIND:'sol-astra-v2'});
 const send=async(url,o)=>{
  if(url.endsWith('input_tokens'))return Response.json({input_tokens:100});const n=paid++;
  const urls=Array.from({length:20},(_,i)=>'https://example.org/'+('x'.repeat(1960))+'?item='+String(n*20+i));
  const output=[{id:'web-'+n,type:'web_search_call',status:'completed',action:{type:'search',query:'Public fixtures',sources:urls.map(url=>({type:'url',url,title:'Public source'}))}},message([urls[0]],'x'.repeat(5000))];output[1].id='message-'+n;
  if(n<3){output[1].phase='commentary';output.push({type:'function_call',id:'function-'+n,call_id:'read-'+n,name:'read_conversation',arguments:JSON.stringify({offset:0,limit:1})})}
  return Response.json({model:JSON.parse(o.body).model,status:'completed',usage:{input_tokens:1000,output_tokens:1000},output});
 };
 let final;
 for(let step=0;step<4;step++){
  const response=await nativeConversationAnswer(next,'a'.repeat(64),env,send,options),value=await response.json();
  if(!response.ok){final=value;break}
  if(step===3){final=value;assert.equal(pilot,false);assert.equal(value.kind,'answer');assert(new TextEncoder().encode(JSON.stringify(value)).byteLength>400000);break}
  next={...payload,step:step+1,continuation:value.continuation,result:{callID:'read-'+step,output:{status:'empty',complete:true,totalCount:0,records:[],findings:[],message:'not_found',localOnly:false}}};
 }
 assert.equal(final?.error,pilot?'native_reply_limit':undefined);assert.equal(paid,4);
 const status=await(await ledger.fetch(new Request('https://ledger/status-v2'))).json();assert.equal(status.pendingMicroUSD,0);assert.equal(status.chargedMicroUSD,149600);
 }
});
test('oversized unverifiable provider output keeps exposure held and blocks a fresh attempt on the same human turn',async()=>{
 const {env,ledger}=setup(),payload=p();let paid=0;const send=async url=>{if(url.endsWith('input_tokens'))return Response.json({input_tokens:100});paid++;return Response.json({padding:'x'.repeat(1048576)})};
 const first=await nativeConversationAnswer(payload,'a'.repeat(64),env,send);assert.equal(first.status,502);assert.equal((await first.json()).error,'native_provider_response_limit');
 const status=await(await ledger.fetch(new Request('https://ledger/status-v2'))).json();assert.equal(status.chargedMicroUSD,0);assert.equal(status.pendingMicroUSD,1400288);
 const retry=await nativeConversationAnswer({...payload,requestID:crypto.randomUUID()},'a'.repeat(64),env,send);assert.equal(retry.status,503);assert.equal(paid,1);
});
