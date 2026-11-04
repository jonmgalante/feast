import {test} from 'node:test';
import assert from 'node:assert/strict';
import {validDiscovery,searchBody,citedBlocks,checkedOpenings,webCost,callDiscovery,WEB_RESERVATION} from './discovery.mjs';
import worker,{BudgetLedger,digest} from './worker.mjs';
const now=new Date('2026-10-24T12:00:00Z');
const criteria={category:'cafe',region:'Manhattan',intent:'recent_openings',windowDays:90};
const payload=()=>({version:3,requestID:crypto.randomUUID(),mode:'discovery',criteria});
const url='https://public-example.org/harbor';
const quote='Harbor Coffee cafe in Manhattan opened on 2026-10-20.';
const blocks=[{url,title:'Public opening announcement',text:quote}];
const place={name:'Harbor Coffee',region:'Manhattan',category:'cafe',sourceURL:url,openingDate:'2026-10-20',openingKind:'opened',evidence:quote};
function provider(output,usage={input_tokens:1000,output_tokens:100}){return {status:'completed',model:'gpt-6-luna',usage,output}}
const first=()=>provider([{type:'web_search_call',status:'completed',action:{type:'search',sources:[{type:'url',url}]}},{type:'message',content:[{type:'output_text',text:quote,annotations:[{type:'url_citation',url,title:blocks[0].title,start_index:0,end_index:quote.length}]}]}]);
const second=()=>provider([{type:'message',content:[{type:'output_text',text:JSON.stringify({places:[place]})}]}]);
test('public search accepts enum criteria only, never raw question/history/library fields',()=>{
 assert.equal(validDiscovery(payload()),true);
 for(const key of ['text','question','notes','status','history','candidates','attachment'])assert.equal(validDiscovery({...payload(),[key]:'PRIVATE'}),false);
 for(const patch of [{region:'PRIVATE HOME'},{category:'my favorite'},{windowDays:10000},{intent:'arbitrary'}])assert.equal(validDiscovery({...payload(),criteria:{...criteria,...patch}}),false);
 const body=searchBody(payload(),now);assert.equal(body.store,false);assert.equal(body.max_tool_calls,1);assert.equal(body.max_output_tokens,1800);assert.equal(body.previous_response_id,undefined);assert.equal(body.tools[0].type,'web_search');
});
test('opening event dates, location, category and cited quotation are all required',()=>{
 assert.equal(checkedOpenings({places:[place]},blocks,criteria,now).length,1);
 assert.equal(checkedOpenings({places:[place]},blocks,{...criteria,cuisine:'Italian'},now).length,0);
 for(const patch of [{sourceURL:'https://uncited.org/x'},{openingDate:'2025-10-20'},{openingDate:'2026-10-25'},{openingDate:'2026-02-31'},{openingKind:'announced'},{region:'London'},{category:'bar'},{evidence:'Published 2026-10-20.'}])assert.equal(checkedOpenings({places:[{...place,...patch}]},blocks,criteria,now).length,0);
 assert.equal(checkedOpenings({places:[place]},[{...blocks[0],text:'Harbor Coffee London restaurant opened on 2026-10-20.'}],criteria,now).length,0);
 const published='Published 2026-10-20. Harbor Coffee cafe in Manhattan opened last year.';
 assert.equal(checkedOpenings({places:[{...place,evidence:published}]},[{...blocks[0],text:published}],criteria,now).length,0);
 const future='Harbor Coffee cafe in Manhattan will open on 2026-11-20.';
 assert.equal(checkedOpenings({places:[{...place,openingDate:'2026-11-20',openingKind:'announced',evidence:future}]},[{...blocks[0],text:future}],{...criteria,intent:'upcoming_openings',windowDays:180},now).length,1);
});
test('only actual URL annotations produce clickable citation blocks; private/malformed URLs rejected',()=>{
 assert.equal(citedBlocks(first()).length,1);
 for(const bad of ['http://public-example.org','file:///secret','https://127.0.0.1/a','https://user:secret@public-example.org/a','https://host.local/a']){
  const f=first();f.output[1].content[0].annotations[0].url=bad;assert.equal(citedBlocks(f).length,0);
 }
 const f=first();f.output[1].content[0].annotations[0].end_index=10000;assert.equal(citedBlocks(f).length,0);
});
test('web reservation conservatively covers two full model stages and one bounded tool charge',()=>{
 const a=first(),b=second();a.usage={input_tokens:1050000,output_tokens:1800};b.usage={input_tokens:64000,output_tokens:1200};
 const cost=webCost(a,b);assert.equal(cost.estimatedMicroUSD,150750);assert.ok(cost.estimatedMicroUSD<WEB_RESERVATION);assert.equal(cost.webCalls,1);
 a.output.unshift({type:'web_search_call',status:'completed'});assert.throws(()=>webCost(a,b),/web_calls/);
});
test('mocked current discovery performs one bounded research and one tools-off extraction; useful linked answer',async()=>{
 const sent=[];const result=await callDiscovery(payload(),{OPENAI_API_KEY:'public-fake'},async(endpoint,options)=>{
  assert.equal(endpoint,'https://api.openai.com/v1/responses');assert.equal(options.redirect,'manual');const body=JSON.parse(options.body);sent.push(body);return Response.json(sent.length===1?first():second());
 },now);
 assert.equal(sent.length,2);assert.equal(sent[1].tools,undefined);assert.equal(result.answer.paragraphs[0].citations[0].url,url);assert.ok(result.answer.summary.includes('opened on 2026-10-20'));assert.equal(result.usage.webCalls,1);
});
test('uncited/undated evidence produces concise no-match, never an invented place; failures never retry',async()=>{
 const f=first();f.output[1].content[0].annotations=[];
 // Explicit extraction empty result with no citation blocks.
 let calls=0;const empty=second();empty.output[0].content[0].text=JSON.stringify({places:[]});
 const r=await callDiscovery(payload(),{OPENAI_API_KEY:'public-fake'},async()=>Response.json(++calls===1?f:empty),now);
 assert.equal(r.answer.places.length,0);assert.equal(r.answer.paragraphs[0].citations.length,0);
 calls=0;await assert.rejects(()=>callDiscovery(payload(),{OPENAI_API_KEY:'public-fake'},async()=>{calls++;return new Response(null,{status:403})},now),/web_upstream_403/);assert.equal(calls,1);
});
test('web gate fails closed before ledger/provider and shares original auth',async()=>{
 const token='a'.repeat(43),env={ENABLED:'true',ENVIRONMENT:'dev',LIVE_AI:'true',CLIENT_TOKEN_HASHES_JSON:JSON.stringify([{id:'one',sha256:await digest(token),expiresAt:'2026-11-22T14:30:00Z'},{id:'two',sha256:await digest('b'.repeat(43)),expiresAt:'2026-11-22T14:30:00Z'}]),BUDGET:{get(){throw Error('must not reserve')}}};
 const request=new Request('https://test.invalid/v1/answer',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(payload())});
 assert.equal((await worker.fetch(request,env)).status,503);
});
test('mixed text/web reservations retain the same lifetime counters across recreation and reject usage over own hold',async()=>{
 const map=new Map();let queue=Promise.resolve();const storage={transaction(fn){const p=queue.then(()=>fn({get:async k=>map.get(k),put:async(k,v)=>map.set(k,v)}));queue=p.catch(()=>{});return p}};
 let l=new BudgetLedger({storage});let tick=0;l.now=()=>tick++*60000;
 const reserve=(id,amount)=>l.fetch(new Request('https://ledger/reserve',{method:'POST',body:JSON.stringify({user:'one',id,fingerprint:'a'.repeat(64),amount})}));
 const textID=crypto.randomUUID();assert.equal((await reserve(textID,50000)).status,200);
 assert.equal((await l.fetch(new Request('https://ledger/settle',{method:'POST',body:JSON.stringify({user:'one',id:textID,usage:{estimatedMicroUSD:100000}})}))).status,400);
 for(let i=0;i<12;i++)assert.equal((await reserve(crypto.randomUUID(),200000)).status,200);
 l=new BudgetLedger({storage});l.now=()=>tick++*60000;
 assert.equal((await reserve(crypto.randomUUID(),200000)).status,429);assert.equal(map.get('total'),2450000);assert.equal(map.get('user:one'),2450000);
});

test('general public recommendations require cited category/geography but cannot smuggle opening claims',()=>{
 const c={...criteria,intent:'recommendations'};
 assert.equal(validDiscovery({...payload(),criteria:c}),true);
 const evidence='Harbor Coffee is a cafe serving coffee in Manhattan.';
 const generic={...place,openingDate:'',openingKind:'not_applicable',evidence};
 assert.equal(checkedOpenings({places:[generic]},[{...blocks[0],text:evidence}],c,now).length,1);
 assert.equal(checkedOpenings({places:[place]},blocks,c,now).length,0);
 assert.equal(checkedOpenings({places:[generic]},[{...blocks[0],text:evidence}],criteria,now).length,0);
});

test('announced or uncertain targets never become confirmed opened events',()=>{
 for(const evidence of ['Harbor Coffee cafe in Manhattan may open on 2026-10-20.','Harbor Coffee cafe in Manhattan will open on 2026-10-20.','Harbor Coffee cafe in Manhattan was expected to have opened on 2026-10-20.']){
  assert.equal(checkedOpenings({places:[{...place,evidence}]},[{...blocks[0],text:evidence}],criteria,now).length,0);
 }
});


test('this month uses the calendar opening-event month, not a rolling window or article date',()=>{
 const september='Harbor Coffee cafe in Manhattan opened on 2026-09-30.';
 const x={...place,openingDate:'2026-09-30',evidence:september};
 assert.equal(checkedOpenings({places:[x]},[{...blocks[0],text:september}],criteria,now).length,1);
 assert.equal(checkedOpenings({places:[x]},[{...blocks[0],text:september}],{...criteria,period:'calendar_month'},now).length,0);
 assert.equal(validDiscovery({...payload(),criteria:{...criteria,period:'calendar_month'}}),true);
 assert.equal(validDiscovery({...payload(),criteria:{...criteria,period:'PRIVATE'}}),false);
});
