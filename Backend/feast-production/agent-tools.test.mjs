import test from 'node:test';
import assert from 'node:assert/strict';
import {agentTools,checkedAgentCall,validAgentResult} from './agent-tools.mjs';
import {checkedContinuation} from './agent-broker.mjs';
const id='a43c2763-734c-48fa-b40a-693d9b711cdc';
const question='Find their Instagrams, then save them.';
const intent={goal:'mixed',sourcePolicy:'public_if_missing',fields:['instagram'],selectionIDs:[id],permissions:[{entity:'place',operations:['update'],fields:['instagram'],targetIDs:[id],instructionQuote:'save them'}]};
const call=(name,args,callID='call_1')=>({type:'function_call',name,arguments:JSON.stringify(args),call_id:callID});
const result={status:'success',complete:true,totalCount:1,records:[{id,name:'Alinea',city:'Chicago',cuisines:[],kind:'place'}],findings:[],message:'ok',localOnly:false};
const encoded=items=>Buffer.from(JSON.stringify(items)).toString('base64');
test('model tools use the same research contract for one or multiple exact records',()=>{for(const targets of [[id],[id,'1e7ba809-6a46-4d89-80fe-6c0af05aae61']])assert.equal(checkedAgentCall(call('research_businesses',{targetIDs:targets,fields:['instagram'],sourcePolicy:'public_if_missing'}),question).name,'research_businesses');assert.deepEqual(agentTools(true).map(x=>x.name),['interpret_request']);assert.ok(!agentTools().some(x=>x.name==='interpret_request'))});
test('root interpretation distinguishes research from permission to change and requires current instruction evidence',()=>{assert.equal(checkedAgentCall(call('interpret_request',intent),question).name,'interpret_request');assert.throws(()=>checkedAgentCall(call('interpret_request',{...intent,goal:'research'}),question));assert.throws(()=>checkedAgentCall(call('interpret_request',{...intent,permissions:[{...intent.permissions[0],instructionQuote:'delete everything'}]}),question))});
test('cloud result projection refuses private fields and hidden private result membership',()=>{assert.ok(validAgentResult(result));assert.equal(validAgentResult({...result,records:[{...result.records[0],note:'private'}]}),false);assert.equal(validAgentResult({...result,localOnly:true}),false);assert.ok(validAgentResult({...result,localOnly:true,records:[],totalCount:0,message:'private_result'}))});
test('continuation preserves call IDs and reasoning while enforcing one ordered output per call',()=>{const first=call('interpret_request',intent),p={step:1,text:question,continuation:encoded([first]),result:{callID:'call_1',output:result}};assert.equal(checkedContinuation(p).at(-1).call_id,'call_1');const output={type:'function_call_output',call_id:'call_1',output:JSON.stringify(result)},second=call('research_businesses',{targetIDs:[id],fields:['instagram'],sourcePolicy:'public_if_missing'},'call_2');assert.equal(checkedContinuation({...p,step:2,continuation:encoded([first,output,second]),result:{callID:'call_2',output:result}}).length,4);for(const items of [[first,output,output,second],[first,second,output],[second],[first,output,call('interpret_request',intent,'call_2')]])assert.throws(()=>checkedContinuation({...p,step:2,continuation:encoded(items),result:{callID:'call_2',output:result}}))});

test('mutation tools accept full bounded record sets while research retains per-call batch cap',()=>{const targets=Array.from({length:200},(_,i)=>`00000000-0000-4000-8000-${String(i).padStart(12,'0')}`);const change={entity:'place',operation:'append',targetIDs:targets,cityID:null,sectionID:null,mapMatchID:null,changes:[{field:'tags',value:null,values:['Test'],findingID:null}],instructionQuote:'save them'};assert.equal(checkedAgentCall(call('propose_changes',change),question).name,'propose_changes');assert.throws(()=>checkedAgentCall(call('propose_changes',{...change,targetIDs:[...targets,id]}),question));assert.throws(()=>checkedAgentCall(call('research_businesses',{targetIDs:targets.slice(0,7),fields:['instagram'],sourcePolicy:'public_if_missing'}),question));assert.equal(agentTools().find(t=>t.name==='propose_changes').parameters.properties.targetIDs.maxItems,200)});

test('exact large aggregates can omit local membership while record and mutation transport bounds remain fixed',()=>{
 assert.ok(validAgentResult({...result,totalCount:1205,records:[]}));
 assert.ok(validAgentResult({...result,totalCount:10001,records:[]}));
 assert.equal(validAgentResult({...result,totalCount:Number.MAX_SAFE_INTEGER+1,records:[]}),false);
 assert.equal(validAgentResult({...result,records:Array.from({length:201},(_,i)=>({...result.records[0],id:`00000000-0000-4000-8000-${String(i).padStart(12,'0')}`}))}),false);
 assert.equal(validAgentResult({...result,totalCount:1205,records:[],localOnly:true}),false);
});
