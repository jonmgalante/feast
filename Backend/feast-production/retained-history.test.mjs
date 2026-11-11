import test from 'node:test';
import assert from 'node:assert/strict';
import {conversationTools,checkedConversationCall,validConversationResult} from './conversation.mjs';
import {DIRECT_NATIVE_LIMITS,validNativePayload,nativeContinuation,nativeBody,encodeNativeFrame} from './native-research.mjs';
const options={limits:DIRECT_NATIVE_LIMITS,allowCollectionQueryV2:true,allowRetainedHistory:true};
const payload=()=>({version:10,mode:'conversationStep',requestID:crypto.randomUUID(),turnID:crypto.randomUUID(),step:0,text:'Retrieve the end of the earlier answer.',webAllowed:false,context:{index:[],recent:[],collectionAccess:'permitted_details_v1',totalCount:0},cities:[],task:null,findings:[],history:[],historyCount:2,continuation:null,result:null});
const call=(args)=>({type:'function_call',call_id:'history',name:'read_conversation',arguments:JSON.stringify(args)});
test('retained history paging is explicit and separately negotiated; old tools remain unchanged',async()=>{
 const p={...payload(),retainedHistoryVersion:1};
 assert.equal(validNativePayload(p),false);
 assert.equal(validNativePayload(p,{...options,allowRetainedHistory:false}),false);
 assert.equal(validNativePayload(p,options),true);
 assert.equal(validNativePayload({...p,retainedHistoryVersion:2},options),false);
 assert.equal(validNativePayload({...p,context:{index:[],recent:[]}},options),false);
 const old=conversationTools(true,true).find(t=>t.name==='read_conversation');assert.equal(old.parameters.properties.textOffset,undefined);
 const fresh=conversationTools(true,true,true).find(t=>t.name==='read_conversation');assert(fresh.parameters.required.includes('textOffset'));
 const state=await nativeContinuation(p,'gpt-6.1-sol',options);assert(nativeBody(p,state).tools.find(t=>t.name==='read_conversation').parameters.properties.textOffset);
 const legacy=payload(),legacyState=await nativeContinuation(legacy,'gpt-6.1-sol',options);assert.equal(nativeBody(legacy,legacyState).tools.find(t=>t.name==='read_conversation').parameters.properties.textOffset,undefined);
});
test('paged reads preserve bounded wire results and reject unnegotiated offsets, invalid ranges and multi-message text offsets',()=>{
 for(const args of [{offset:1,limit:1,textOffset:1800},{offset:0,limit:12,textOffset:null},{offset:0,limit:1}])assert.doesNotThrow(()=>checkedConversationCall(call(args),'Read earlier context',true,true,true));
 for(const args of [{offset:1,limit:1,textOffset:1800},{offset:0,limit:1,textOffset:null}])assert.throws(()=>checkedConversationCall(call(args),'Read earlier context',true,true),/conversation_history_range/);
 for(const args of [{offset:0,limit:2,textOffset:1},{offset:200,limit:1,textOffset:0},{offset:0,limit:1,textOffset:-1},{offset:0,limit:1,textOffset:8388609},{offset:0,limit:1,textOffset:1.5}])assert.throws(()=>checkedConversationCall(call(args),'Read earlier context',true,true,true),/conversation_history_range/);
 const result={status:'success',complete:true,totalCount:2,records:[],findings:[],message:'ok',localOnly:false,history:[{role:'assistant',text:'x'.repeat(2000)}]};
 assert(validConversationResult(result,true));assert(!validConversationResult({...result,history:[{role:'assistant',text:'x'.repeat(2001)}]},true));
});
test('retained-history capability is bound to the original continuation identity',async()=>{
 const p={...payload(),retainedHistoryVersion:1},state=await nativeContinuation(p,'gpt-6.1-sol',options);
 state.frame.records.push({observedAt:'2026-11-11T00:00:00Z',item:call({offset:1,limit:1,textOffset:1800})});
 const next={...p,step:1,continuation:encodeNativeFrame(state.frame,DIRECT_NATIVE_LIMITS),result:{callID:'history',output:{status:'success',complete:true,totalCount:2,records:[],findings:[],message:'ok',localOnly:false,history:[{role:'assistant',text:'The retained tail.'}]}}};
 await nativeContinuation(next,'gpt-6.1-sol',options);
 const {retainedHistoryVersion,...unmarked}=next;await assert.rejects(nativeContinuation(unmarked,'gpt-6.1-sol',options),/native_context_identity/);
});
