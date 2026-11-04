import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {callDiscovery,WEB_RESERVATION,citedBlocks,checkedOpenings} from './discovery.mjs';
import {localExtractionCandidate} from './discovery-local-candidate.mjs';
const url='https://public-example.org/opening',quote='Public Coffee cafe in Manhattan opened on 2026-10-20.';
const criteria={category:'cafe',region:'Manhattan',intent:'recent_openings',windowDays:30};
const result=(output)=>({status:'completed',model:'gpt-6-luna',usage:{input_tokens:1000,output_tokens:100},output});
function research(text=quote){return result([{type:'web_search_call',status:'completed',action:{type:'search',sources:[{type:'url',url}]}},{type:'message',content:[{type:'output_text',text,annotations:[{type:'url_citation',url,title:'Public source',start_index:0,end_index:text.length}]}]}])}
const now=new Date('2026-10-25');
test('timing instrumentation records enum durations only and retains two sequential bounded calls',async()=>{
 let requests=0,tick=0;
 const response=await callDiscovery({version:3,requestID:crypto.randomUUID(),mode:'discovery',criteria},{OPENAI_API_KEY:'fake'},async(_,o)=>{
  const body=JSON.parse(o.body);assert.equal(body.model,'gpt-6-luna');assert.equal(body.stream,false);assert.equal(body.reasoning.effort,'none');requests++;
  if(requests===1){assert.equal(body.max_tool_calls,1);return Response.json(research())}
  assert.equal(body.tools,undefined);
  return Response.json(result([{type:'message',content:[{type:'output_text',text:JSON.stringify({places:[{name:'Public Coffee',region:'Manhattan',category:'cafe',sourceURL:url,openingDate:'2026-10-20',openingKind:'opened',evidence:quote}]})}]}]));
 },now,()=>tick+=10);
 assert.equal(requests,2);assert.equal(response.answer.places.length,1);
 assert.deepEqual(Object.keys(response.timings).sort(),['extraction','overall','research','validation']);
 assert.ok(Object.values(response.timings).every(x=>Number.isFinite(x)&&x>=0));
 assert.equal(JSON.stringify(response.timings).includes('Public'),false);assert.ok(response.usage.estimatedMicroUSD<WEB_RESERVATION);
});
test('disabled local extraction uses identical source/date/relevance/cost guards, no model fallback',()=>{
 const good=localExtractionCandidate(research(),criteria,now);assert.equal(good.places.length,1);assert.equal(good.usage.webCalls,1);
 for(const text of ['Public Coffee cafe in Manhattan opened last year. Published 2026-10-20.','Public Coffee cafe in Manhattan opened on 2026-10-20. Published 2026-10-22.','Public Coffee restaurant in London opened on 2026-10-20.','Public Coffee cafe in Manhattan may have opened on 2026-10-20.'])assert.equal(localExtractionCandidate(research(text),criteria,now).places.length,0);
 const uncited=research();uncited.output[1].content[0].annotations=[];assert.equal(localExtractionCandidate(uncited,criteria,now).places.length,0);
 const incomplete=research();incomplete.status='incomplete';assert.throws(()=>localExtractionCandidate(incomplete,criteria,now));
 assert.equal(localExtractionCandidate(research(),{...criteria,intent:'recommendations'},now).unsupported,true);
});
test('local candidate is not imported by normal discovery and keeps original lifetime allowance',async()=>{
 for(const name of ['discovery.mjs'])assert.equal((await readFile(new URL(name,import.meta.url),'utf8')).includes('discovery-local-candidate'),false);
 assert.equal(WEB_RESERVATION,200000);
});

test('positive natural-language evidence exposes conservative local-candidate recall gaps',()=>{
 const texts=[
  'Public Coffee cafe in Manhattan opened on October 20, 2026.',
  'In Manhattan, Public Coffee cafe opened on 2026-10-20.',
  'Public Coffee cafe in Manhattan opened on 2026-10-20. Updated on 2026-10-22.'
 ];
 for(const text of texts){
  const first=research(text),blocks=citedBlocks(first);
  const accepted=checkedOpenings({places:[{name:'Public Coffee',region:'Manhattan',category:'cafe',sourceURL:url,openingDate:'2026-10-20',openingKind:'opened',evidence:text}]},blocks,criteria,now);
  assert.equal(accepted.length,1,'existing grounding accepts this positive quoted opening');
  assert.equal(localExtractionCandidate(first,criteria,now).places.filter(x=>x.name==='Public Coffee').length,0,'narrow parser loses or misidentifies otherwise supported evidence');
 }
});
