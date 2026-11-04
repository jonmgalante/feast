import test from 'node:test';import assert from 'node:assert/strict';
import {ACTIVE_MODEL,ACTIVE_EFFORT,ACTIVE_PROFILES,modelFrame,continuationModel} from './active-model.mjs';
import {MODEL_POLICY} from './model-policy.mjs';import {NATIVE_RESEARCH} from './native-research.mjs';import {PUBLIC_POLICY,ASTRA_PUBLIC_POLICY} from './public-policy.mjs';import {usageCost} from './reconciled-accounting.mjs';import {pilotBody} from './pilot-policy.mjs';
test('role boundaries preserve compatibility Astra and disabled native pilot, while normal roles use Sol medium',()=>{
 assert.equal(ACTIVE_MODEL,'gpt-6.1-sol');assert.equal(ACTIVE_EFFORT,'medium');assert.equal(ACTIVE_PROFILES.agent,'solAgentStepV1');assert.equal(PUBLIC_POLICY.model,ACTIVE_MODEL);assert.equal(PUBLIC_POLICY.effort,'medium');assert.equal(MODEL_POLICY.model,'gpt-6-astra');assert.equal(NATIVE_RESEARCH.model,'gpt-6-astra');
 assert.throws(()=>pilotBody('https://api.openai.com/v1/responses/input_tokens',{method:'POST',body:JSON.stringify({model:ACTIVE_MODEL,reasoning:{effort:'medium'}})}),/pilot_model/);
});
test('model-tagged continuation rejects arbitrary providers or fields and legacy arrays pin Astra',()=>{
 assert.equal(modelFrame([]).model,'gpt-6-astra');assert.equal(continuationModel({step:0},null),ACTIVE_MODEL);
 assert.equal(modelFrame({version:1,model:ACTIVE_MODEL,items:[]}).model,ACTIVE_MODEL);
 for(const value of [{version:1,model:'gpt-6-luna',items:[]},{version:2,model:ACTIVE_MODEL,items:[]},{version:1,model:ACTIVE_MODEL,items:[],extra:true}])assert.throws(()=>modelFrame(value));
});
test('public Astra and Sol retain independent immutable accounting policies and no mixed settlement',()=>{
 const old=[{model:'gpt-6-astra',inputTokens:262144,outputTokens:8192,webCalls:1},{model:'gpt-6-astra',inputTokens:8192,outputTokens:8192,webCalls:0}];
 assert.equal(ASTRA_PUBLIC_POLICY.holdMicroUSD,8000000);assert.equal(usageCost(old,'publicAstraV1'),7760632);
 const sol=old.map(x=>({...x,model:ACTIVE_MODEL}));assert.equal(usageCost(sol,'publicSolV1'),1560927);assert.throws(()=>usageCost(sol,'publicAstraV1'));assert.throws(()=>usageCost(old,'publicSolV1'));
});
test('behavioral rollback retains Sol frame and public profile readers while selecting Astra for fresh calls',async()=>{
 const fs=await import('node:fs/promises');
 const source=await fs.readFile(new URL('./active-model.mjs',import.meta.url),'utf8');
 const url='data:text/javascript,'+encodeURIComponent(source.replace("ACTIVE_MODEL='gpt-6.1-sol'","ACTIVE_MODEL='gpt-6-astra'"));
 const rollback=await import(url);assert.equal(rollback.ACTIVE_MODEL,'gpt-6-astra');assert.equal(rollback.ACTIVE_PROFILES.agent,'astraAgentStepV1');
 assert.equal(rollback.modelFrame({version:1,model:'gpt-6.1-sol',items:[]}).model,'gpt-6.1-sol');assert.equal(rollback.agentProfile('gpt-6.1-sol'),'solAgentStepV1');
 const publicSource=await fs.readFile(new URL('./public-policy.mjs',import.meta.url),'utf8');
 const policy=await import('data:text/javascript,'+encodeURIComponent(publicSource.replace("'./active-model.mjs'",JSON.stringify(url))));
 assert.equal(policy.PUBLIC_POLICY.model,'gpt-6-astra');assert.equal(policy.PUBLIC_PROFILES.publicSolV1.model,'gpt-6.1-sol');assert.equal(policy.PUBLIC_PROFILES.publicAstraV1.holdMicroUSD,8000000);
});
