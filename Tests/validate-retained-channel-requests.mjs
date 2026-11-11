import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {validConversationPayload} from '../Backend/feast-production/conversation.mjs';
import {validNativePayload, DIRECT_NATIVE_LIMITS} from '../Backend/feast-production/native-research.mjs';
const captured=JSON.parse(readFileSync(process.argv[2], 'utf8'));
assert(captured.length>0);
for (const body of captured) {
 const durable=body.op==='submit', p=durable?body.request:body;
 if(durable){assert.deepEqual(Object.keys(body).sort(),['op','request','version']);assert.equal(body.version,1);}
 const valid=p.version===9?validConversationPayload(p):validNativePayload(p,durable?{allowRetainedHistory:true}:{limits:DIRECT_NATIVE_LIMITS,allowCollectionQueryV2:true,allowRetainedHistory:true});
 assert.equal(valid,true,`backend rejected actual ${durable?'durable':'direct'} app request: step=${p.step}, history=${p.history.length}, count=${p.historyCount}`);
 if(p.result?.output.history) assert.equal(p.result.output.totalCount,p.historyCount,'read_conversation and initial history must use one index domain');
}
console.log(`PASS real backend validators accept ${captured.length} actual synthetic app request bodies`);
