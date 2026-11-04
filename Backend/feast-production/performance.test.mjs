import test from 'node:test';
import assert from 'node:assert/strict';
import {PerformanceMeasurements} from './performance.mjs';
test('timing is content-free, bounded and request-local, including failures',async()=>{
 let time=0;const a=new PerformanceMeasurements(()=>time),b=new PerformanceMeasurements(()=>time);
 assert.equal(await a.measure('provider',async()=>{time+=23;return 7}),7);
 await assert.rejects(a.measure('inputCount',async()=>{time+=2;throw Error('PRIVATE must never enter metrics')}));
 a.record('PRIVATE',0);a.count('PRIVATE',33);a.count('inputTokens',-1);a.count('outputTokens',NaN);
 a.usage({usage:{input_tokens:100,output_tokens:5,input_tokens_details:{cached_tokens:40},output_tokens_details:{reasoning_tokens:3},secret:'PRIVATE'}});
 const v=a.snapshot();assert.deepEqual(v,{version:1,stages:{provider:{milliseconds:23,calls:1},inputCount:{milliseconds:2,calls:1}},counters:{inputTokens:100,outputTokens:5,cachedInputTokens:40,reasoningTokens:3}});
 assert.deepEqual(b.snapshot(),{version:1,stages:{},counters:{}});assert(!JSON.stringify(v).includes('PRIVATE'));
 v.stages.provider.calls=999;assert.equal(a.snapshot().stages.provider.calls,1);
 for(let i=0;i<200;i++)a.record('ledger',time);
 assert.equal(a.snapshot().stages.ledger.calls,64);
});
test('measurement preserves dependency ordering and thrown error identity',async()=>{
 let now=0;const m=new PerformanceMeasurements(()=>now),order=[],error=Error('failure');
 await assert.rejects(m.measure('ledger',async()=>{order.push('begin');now++;await Promise.resolve();order.push('end');throw error}),e=>e===error);
 assert.deepEqual(order,['begin','end']);assert.equal(m.snapshot().stages.ledger.calls,1);
});
