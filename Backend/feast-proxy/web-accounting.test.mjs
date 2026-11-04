// Schema fixtures, not copies of the unavailable live provider response.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {checkedWebCalls,webCallSummary,webCost,callDiscovery,WEB_RESERVATION} from './discovery.mjs';
import worker,{BudgetLedger,digest} from './worker.mjs';
const url='https://public-example.org/current',text='Public Coffee cafe in Manhattan opened on 2026-10-20.';
const call=(id='ws_public',status='completed',action={type:'search',queries:['public cafe Manhattan'],sources:[{type:'url',url}]})=>({id,type:'web_search_call',status,action});
const result=(output)=>({id:'resp_public_fixture',status:'completed',model:'gpt-6-luna',usage:{input_tokens:1000,output_tokens:100},output});
const message={id:'msg_public',type:'message',status:'completed',role:'assistant',content:[{type:'output_text',text,annotations:[{type:'url_citation',url,title:'Public source',start_index:0,end_index:text.length}]}]};
const payload=()=>({version:3,requestID:crypto.randomUUID(),mode:'discovery',criteria:{category:'cafe',region:'Manhattan',intent:'recent_openings',windowDays:30}});
test('current documented completed search schema including IDs, queries/sources and message metadata passes',()=>{
 const first=result([call(),message]);assert.equal(checkedWebCalls(first),1);assert.equal(webCost(first,result([])).webCalls,1);

});
test('missing, excess, incomplete and malformed tool metadata have distinct fail-closed reasons',()=>{
 for(const [output,reason] of [[[], 'missing'],[null,'shape'],[[call('a'),call('b'),call('c')],'limit']])assert.throws(()=>checkedWebCalls(result(output)),new RegExp('web_calls_'+reason));
 for(const status of ['failed','in_progress','searching','incomplete','cancelled',undefined,'unknown'])assert.throws(()=>checkedWebCalls(result([{...call(),status}])),/web_calls_status/);
});
test('invalid research never triggers the second paid extraction request',async()=>{
 for(const output of [[message],[call('a','failed'),message],[call('a'),call('b'),call('c'),message],null]){
  let requests=0;await assert.rejects(()=>callDiscovery(payload(),{OPENAI_API_KEY:'public-fake'},async()=>{requests++;return Response.json(result(output))},new Date('2026-10-24')),/web_calls_(missing|status|limit|shape)/);
  assert.equal(requests,1);
 }
});
test('diagnostics contain only bounded enum/count metadata, never model text, URLs, queries or unknown values',()=>{
 const summary=webCallSummary(result([{type:'PRIVATE_TYPE',content:'PRIVATE_TEXT'},call('PRIVATE_ID','PRIVATE_STATUS',{type:'PRIVATE_ACTION',query:'PRIVATE_QUERY',sources:[{url:'https://private.invalid'}]}),message]));
 assert.equal(summary.webCallCount,1);assert.deepEqual(summary.calls,[{status:'other',action:'other'}]);assert.equal(JSON.stringify(summary).includes('PRIVATE'),false);assert.equal(JSON.stringify(summary).includes(url),false);
});
test('failed public tool attempt holds full original reservation and exposes safe metadata without retry',async()=>{
 const map=new Map(),ledger=new BudgetLedger({storage:{transaction:async f=>f({get:async k=>map.get(k),put:async(k,v)=>map.set(k,v)})}});
 const token='a'.repeat(43),e={ENVIRONMENT:'dev',ENABLED:'true',LIVE_AI:'true',ALLOW_DISCOVERY:'true',OPENAI_API_KEY:'public-fake',CLIENT_TOKEN_HASHES_JSON:JSON.stringify([{id:'one',sha256:await digest(token),expiresAt:'2099-01-01T00:00:00Z'},{id:'two',sha256:await digest('b'.repeat(43)),expiresAt:'2099-01-01T00:00:00Z'}]),BUDGET:{idFromName:x=>x,get:()=>ledger}};
 const original=globalThis.fetch;let requests=0;globalThis.fetch=async()=>{requests++;return Response.json(result([call('public','failed'),message]))};
 try{
  const p=payload(),req=()=>new Request('https://offline.invalid/v1/answer',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify(p)});
  const r=await worker.fetch(req(),e),body=await r.json();assert.equal(r.status,502);assert.equal(body.reason,'web_calls_status');assert.equal(body.diagnostic.webCallCount,1);assert.equal(requests,1);
  assert.equal(map.get('total'),200000);assert.equal(map.get('user:one'),200000);assert.equal(map.get('estimatedUsage'),undefined);
  assert.equal((await worker.fetch(req(),e)).status,409);assert.equal(requests,1);assert.equal(map.get('total'),200000);
 }finally{globalThis.fetch=original}
});
test('observed two completed searches plus trailing searching open_page counts processed calls under legacy bound only',()=>{
 const observed=result([call('a'),message,call('b'),call('c','searching',{type:'open_page',url:'https://unprocessed.example/page'})]);
 assert.equal(checkedWebCalls(observed,2),2);
 assert.throws(()=>checkedWebCalls(observed),/web_calls_limit/); // new provider bound is ONE, never silently raised
 assert.equal(checkedWebCalls(result([call(),message,call('pending','searching',{type:'open_page',url})])),1);
 for(const status of ['incomplete','in_progress'])assert.throws(()=>checkedWebCalls({...observed,status},2),/web_calls_status/);
 assert.throws(()=>checkedWebCalls(result([call(),call('pending','searching',{type:'open_page',url})]),2),/web_calls_status/);
 assert.throws(()=>checkedWebCalls(result([call(),call('pending','failed',{type:'open_page',url})])),/web_calls_status/);
 assert.throws(()=>checkedWebCalls(result([call(),call('pending','searching',{type:'open_page',url}),call('later')])),/web_calls_limit/);
});
test('only sources from completed searches can become extraction evidence',async()=>{
 const {citedBlocks,searchBody}=await import('./discovery.mjs');
 const first=result([call('pending','searching',{type:'open_page',url}),message]);
 assert.equal(citedBlocks(first).length,0);
 first.output.unshift(call());assert.equal(citedBlocks(first).length,1);
 first.output[0].action.sources=[];assert.equal(citedBlocks(first).length,0);
 assert.equal(searchBody(payload()).max_tool_calls,1);
 assert.equal(searchBody(payload()).parallel_tool_calls,false);
});
test('completed research with ignored follow-up produces grounded answer without another research request',async()=>{
 let requests=0;
 const first=result([call(),message,call('pending','searching',{type:'open_page',url:'https://unprocessed.example/page'})]);
 const second=result([{type:'message',content:[{type:'output_text',text:JSON.stringify({places:[{name:'Public Coffee',region:'Manhattan',category:'cafe',sourceURL:url,openingDate:'2026-10-20',openingKind:'opened',evidence:text}]})}]}]);
 const answer=await callDiscovery(payload(),{OPENAI_API_KEY:'fake'},async()=>Response.json(++requests===1?first:second),new Date('2026-10-24'));
 assert.equal(requests,2);assert.equal(answer.answer.places.length,1);assert.equal(answer.usage.webCalls,1);
});
