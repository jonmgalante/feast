import {test} from 'node:test';
import assert from 'node:assert/strict';
import {providerBody,checkedAnswer,callOpenAI,MODEL,RESERVATION,TOTAL_CAP} from './openai.mjs';
const payload={text:'What fictional place?',mode:'collection',candidates:[{id:'p1',name:'Fictional Place',sourceIDs:['s1']}],sources:[{id:'s1',author:'Fixture',excerpt:'Fictional evidence'}]};
const answer={summary:'Fictional recommendation',candidateIDs:['p1'],paragraphs:[{id:'a1',spans:[{type:'place',value:'p1'},{type:'text',value:' fits the fictional evidence.'}],sourceIDs:['s1']}]};
const result=()=>({status:'completed',model:MODEL,usage:{input_tokens:1000,output_tokens:100},output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(answer)}]}]});
test('fixed provider request disables storage, tools, streaming and caps output',()=>{
 const b=JSON.parse(providerBody(payload));assert.equal(b.model,MODEL);assert.equal(b.store,false);assert.equal(b.stream,false);assert.equal(b.max_output_tokens,1000);assert.equal(b.reasoning.effort,'none');assert.equal(b.tools,undefined);assert.equal(b.text.format.strict,true);
 assert.throws(()=>providerBody({...payload,text:'x'.repeat(41000)}));assert.equal(TOTAL_CAP/RESERVATION,100);
});
test('only local identities and supported citations may be returned',()=>{
 assert.deepEqual(checkedAnswer(answer,payload),{version:1,...answer});
 for(const bad of [{...answer,candidateIDs:['foreign']},{...answer,paragraphs:[{...answer.paragraphs[0],sourceIDs:['foreign']}]},{...answer,paragraphs:[{...answer.paragraphs[0],spans:[{type:'place',value:'foreign'}]}]}])assert.throws(()=>checkedAnswer(bad,payload));
});
test('mocked Responses transport fixes endpoint/project and accounts conservatively',async()=>{
 let calls=0;const r=await callOpenAI(payload,{OPENAI_API_KEY:'synthetic-key'},async(url,options)=>{calls++;assert.equal(url,'https://api.openai.com/v1/responses');assert.equal(options.redirect,'manual');assert.equal(options.headers['OpenAI-Project'],'proj_si0dRO6qKPoVOas0he2frPLO');return Response.json(result());});
 assert.equal(calls,1);assert.equal(r.usage.estimatedMicroUSD,175);assert.ok(r.usage.estimatedMicroUSD<RESERVATION);
});
test('upstream rejection, timeout and missing key never retry',async()=>{
 let calls=0;await assert.rejects(()=>callOpenAI(payload,{OPENAI_API_KEY:'synthetic-key'},async()=>{calls++;return new Response('untrusted detail',{status:429})}),/upstream_429/);assert.equal(calls,1);
 await assert.rejects(()=>callOpenAI(payload,{},async()=>{throw Error('must not send')}),/missing_provider/);
 await assert.rejects(()=>callOpenAI(payload,{OPENAI_API_KEY:'synthetic-key'},async()=>{throw Error('timeout')}),/timeout/);
});
test('incomplete/refused, unexpected model and excessive or missing usage fail closed',async()=>{
 for(const invalid of [{...result(),status:'incomplete'},{...result(),model:'other-model'},{...result(),usage:{input_tokens:64001,output_tokens:1}},{...result(),usage:{input_tokens:1,output_tokens:1001}},{...result(),usage:null},{...result(),output:[]}])await assert.rejects(()=>callOpenAI(payload,{OPENAI_API_KEY:'synthetic-key'},async()=>Response.json(invalid)));
});
test('oversized upstream body is cancelled before parsing',async()=>{
 await assert.rejects(()=>callOpenAI(payload,{OPENAI_API_KEY:'synthetic-key'},async()=>new Response('x'.repeat(65537))),/upstream_limit/);
});

test('provider diagnostics expose only bounded error code, never message or raw body',async()=>{
 await assert.rejects(()=>callOpenAI(payload,{OPENAI_API_KEY:'synthetic-key'},async()=>Response.json({error:{code:'invalid_json_schema',message:'do not expose this diagnostic text'}},{status:400})),/upstream_400_invalid_json_schema/);
});

test('provider redirect is never followed or retried',async()=>{
 let calls=0;await assert.rejects(()=>callOpenAI(payload,{OPENAI_API_KEY:'fake'},async()=>{calls++;return new Response(null,{status:302,headers:{Location:'https://forbidden.invalid'}})}),/upstream_redirect_blocked/);assert.equal(calls,1);
});

test('grounded limitations may cite supplied metadata without recommending a place',()=>{
 const limitation={summary:'Cuisine is known; cocktails and location are not supplied.',candidateIDs:[],paragraphs:[{id:'limitation',spans:[{type:'text',value:'The metadata records cuisine but not cocktails or neighborhood.'}],sourceIDs:['s1']}]};
 assert.equal(checkedAnswer(limitation,payload).candidateIDs.length,0);
 assert.throws(()=>checkedAnswer({...limitation,paragraphs:[{...limitation.paragraphs[0],sourceIDs:['not-supplied']}]},payload),/invalid_answer_sources/);
});
test('request-specific schema prevents invented IDs and handles no-match questions',()=>{
 const schema=JSON.parse(providerBody(payload)).text.format.schema;
 assert.deepEqual(schema.properties.candidateIDs.items.enum,['p1']);
 const spans=schema.properties.paragraphs.items.properties.spans.items.anyOf;
 assert.deepEqual(spans[1].properties.value.enum,['p1']);
 assert.deepEqual(schema.properties.paragraphs.items.properties.sourceIDs.items.enum,['s1']);
 const empty=JSON.parse(providerBody({...payload,candidates:[],sources:[]})).text.format.schema;
 assert.equal(empty.properties.candidateIDs.maxItems,0);
 assert.equal(empty.properties.paragraphs.items.properties.sourceIDs.maxItems,0);
 assert.equal(empty.properties.paragraphs.items.properties.spans.items.properties.type.enum[0],'text');
 assert.equal(checkedAnswer({summary:'No matching saved details.',candidateIDs:[],paragraphs:[{id:'none',spans:[{type:'text',value:'I cannot establish cocktails or a remembered visit from these details.'}],sourceIDs:[]}]},{...payload,candidates:[],sources:[]}).version,1);
});


test('memory answer canonicalizes known place mentions missing redundant selection/citation',()=>{
 const realistic={...payload,text:'Which Japanese place with good cocktails in the UES might I remember?'};
 for(const missing of [
  {...answer,candidateIDs:[]},
  {...answer,paragraphs:[{...answer.paragraphs[0],sourceIDs:[]}]},
  {...answer,candidateIDs:[],paragraphs:[{...answer.paragraphs[0],sourceIDs:[]}]}
 ]){
  const checked=checkedAnswer(missing,realistic);
  assert.deepEqual(checked.candidateIDs,['p1']);
  assert.deepEqual(checked.paragraphs[0].sourceIDs,['s1']);
  assert.equal(checked.paragraphs[0].spans[0].value,'p1');
 }
});
test('place canonicalization never accepts unknown, case-changed or null IDs or foreign citations',()=>{
 for(const value of ['P1','unknown','',null]){
  assert.throws(()=>checkedAnswer({...answer,candidateIDs:[],paragraphs:[{...answer.paragraphs[0],spans:[{type:'place',value}]}]},payload),/invalid_answer_(place|span)/);
 }
 assert.throws(()=>checkedAnswer({...answer,candidateIDs:[],paragraphs:[{...answer.paragraphs[0],sourceIDs:['foreign']}]},payload),/invalid_answer_sources/);
 assert.throws(()=>checkedAnswer(answer,{...payload,candidates:[{...payload.candidates[0],sourceIDs:['foreign']}]}),/invalid_answer_place/);
 const noMatch={summary:'No matching metadata establishes cocktails or a neighborhood.',candidateIDs:[],paragraphs:[{id:'no-match',spans:[{type:'text',value:'I cannot identify a remembered place from these saved details. Do you remember its name or cuisine?'}],sourceIDs:[]}]};
 assert.deepEqual(checkedAnswer(noMatch,{...payload,candidates:[],sources:[]}),{version:1,...noMatch});
});
