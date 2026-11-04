import {test} from 'node:test';
import assert from 'node:assert/strict';
import worker,{validPayload,digest} from './worker.mjs';
import {providerBody,callOpenAI,checkedAnswer} from './openai.mjs';
const id='11111111-1111-4111-8111-111111111111';
const source='metadata-'+id;
function payload(){return {version:2,synthetic:false,consent:true,requestID:crypto.randomUUID(),mode:'collection',text:'Japanese fixture',candidates:[{id,name:'Public fixture',sourceIDs:[source]}],sources:[{id:source,author:'Saved place metadata',excerpt:JSON.stringify({name:'Public fixture',cuisines:'Japanese'})}]};}
const jpeg=Buffer.from([255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,218,0,8,1,1,0,0,63,0,0,255,217]).toString('base64');
function imagePayload(){const p=payload();p.attachment={mime:'image/jpeg',selected:true,base64:jpeg};p.sources.push({id:'selected-screenshot',author:'Selected screenshot',excerpt:'Image deliberately attached to this question.'});return p;}
test('version2 whitelists metadata only; missing address/rating remain absent',()=>{
 const p=payload();assert.equal(validPayload(p),true);
 for(const key of ['note','personalNote','tags','status','website','photos']){const bad=payload();bad.sources[0].excerpt=JSON.stringify({name:'Public fixture',[key]:'PRIVATE'});assert.equal(validPayload(bad),false)}
 const bad=payload();bad.sources[0].author='Private collaborator';assert.equal(validPayload(bad),false);
});
test('malformed, foreign and duplicate saved identities and unconsented data are rejected',()=>{
 for(const bad of [{...payload(),synthetic:true},{...payload(),consent:false},{...payload(),mode:'importText'},{...payload(),note:'PRIVATE'}, {...payload(),candidates:[{id:'not-uuid',name:'x',sourceIDs:[]}]}])assert.equal(validPayload(bad),false);
 const p=payload();p.sources.push(p.sources[0]);assert.equal(validPayload(p),false);
});
test('only deliberately selected bounded inline JPEGs are accepted',()=>{
 assert.equal(validPayload(imagePayload()),true);
 for(const patch of [{selected:false},{mime:'image/png'},{base64:'https://outside.invalid/private.jpg'},{base64:Buffer.from([255,216,255,217]).toString('base64')},{base64:'A'.repeat(262145)}]){const p=imagePayload();Object.assign(p.attachment,patch);assert.equal(validPayload(p),false)}
});
test('metadata and screenshot gates reject before any ledger/provider operation',async()=>{
 const token='a'.repeat(43),users=JSON.stringify([{id:'one',sha256:await digest(token),expiresAt:'2026-11-22T14:30:00Z'},{id:'two',sha256:await digest('b'.repeat(43)),expiresAt:'2026-11-22T14:30:00Z'}]);
 const env={ENVIRONMENT:'dev',ENABLED:'true',LIVE_AI:'true',OPENAI_API_KEY:'fake',CLIENT_TOKEN_HASHES_JSON:users,BUDGET:{get(){throw Error('must not reach budget')}}};
 const send=(p,e)=>worker.fetch(new Request('https://test.invalid/v1/answer',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify(p)}),e);
 assert.equal((await send(payload(),env)).status,503);assert.equal((await send(imagePayload(),{...env,ALLOW_SAVED_METADATA:'true'})).status,503);
});
test('provider separates image pixels from metadata; image observations cannot create saved identities',()=>{
 const p=imagePayload(),body=JSON.parse(providerBody(p));assert.equal(body.input[0].content[1].type,'input_image');assert.equal(body.input[0].content[1].detail,'low');assert.ok(body.input[0].content[1].image_url.startsWith('data:image/jpeg;base64,'));assert.equal(body.store,false);
 assert.ok(!body.instructions.includes('supplied fictional candidates'));
 const answer={summary:'Selected image',candidateIDs:[],paragraphs:[{id:'image',spans:[{type:'text',value:'An attached fixture image.'}],sourceIDs:['selected-screenshot']}]};
 assert.equal(checkedAnswer(answer,p).version,1);assert.throws(()=>checkedAnswer({...answer,candidateIDs:['invented-place']},p));
});
test('multimodal token preflight fails closed before generation on unavailable or oversized count',async()=>{
 for(const count of [64001,null]){let calls=0;await assert.rejects(()=>callOpenAI(imagePayload(),{OPENAI_API_KEY:'fake'},async url=>{calls++;assert.ok(url.endsWith('/responses/input_tokens'));return Response.json({input_tokens:count})}),/image_count_exceeds_limit/);assert.equal(calls,1)}
 let calls=0;await assert.rejects(()=>callOpenAI(imagePayload(),{OPENAI_API_KEY:'fake'},async()=>{calls++;return new Response(null,{status:403})}),/image_count_unavailable/);assert.equal(calls,1);
});
test('bounded screenshot count precedes one generation and uses existing pricing/accounting',async()=>{
 let calls=0;const result=await callOpenAI(imagePayload(),{OPENAI_API_KEY:'fake'},async url=>{
  calls++;if(calls===1){assert.ok(url.endsWith('/input_tokens'));return Response.json({input_tokens:1000})}
  assert.ok(url.endsWith('/responses'));return Response.json({status:'completed',model:'gpt-6-luna',usage:{input_tokens:1000,output_tokens:100},output:[{type:'message',content:[{type:'output_text',text:JSON.stringify({summary:'Generated fixture',candidateIDs:[],paragraphs:[{id:'image',spans:[{type:'text',value:'Fixture image.'}],sourceIDs:['selected-screenshot']}]})}]}]});
 });assert.equal(calls,2);assert.equal(result.usage.estimatedMicroUSD,175);
});

test('verification gate keeps native picker hidden until useful image extraction passes',async()=>{
 const health=await worker.fetch(new Request('https://test.invalid/health'),{ALLOW_SELECTED_SCREENSHOT:'verification'});
 assert.equal((await health.json()).selectedScreenshotEnabled,false);
});
