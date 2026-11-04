// Fixed, read-only backend pilot. No normal user payload or collection is accepted.
import {PILOT_WORKLOADS,PILOT_ORDER,pilotBody,pilotBill,MODEL_PILOT_KIND,SOL_ONLY_KIND,checkedPilotDiagnostic} from './pilot-policy.mjs';
import {pilotClient} from './pilot-accounting.mjs';
import {conversationAnswer} from './conversation.mjs';import {nativeConversationAnswer} from './native-conversation.mjs';
import {stageID} from './stage-accounting.mjs';import {boundedResponse} from '../feast-proxy/openai.mjs';import {knownProviderRejection} from './provider-errors.mjs';
const json=(v,status=200)=>Response.json(v,{status,headers:{'Cache-Control':'no-store'}});
const uuid=x=>/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(x??'');
function shape(p){return p&&Object.keys(p).sort().join(',')==='arm,mode,runID,version,workloadID'&&p.version===11&&['researchPilot','researchPilotStatus','researchPilotStop'].includes(p.mode)&&uuid(p.runID)&&Object.hasOwn(PILOT_WORKLOADS,p.workloadID)&&['legacy','candidate'].includes(p.arm)}
export function pilotTransport(send,invoke,lease){return async(url,options)=>{
 let config;try{config=pilotBody(url,options,lease.model??'gpt-6-astra')}catch(e){throw Object.assign(e,{providerNotDispatched:true})}
 if(config.countOnly)return send(url,options);
 const id=crypto.randomUUID(),fields={...lease,id};
 try{await invoke('reserve',{...fields,webAllowance:config.webAllowance})}catch(e){throw Object.assign(e,{providerNotDispatched:true})}
 const started=performance.now();let settlementAttempted=false,diagnostic={};
 try{
  // The supplied transport is fetch or a single-attempt test transport. No retries.
  const response=await send(url,options);diagnostic.httpStatus=response.status;const requestID=response.headers.get('x-request-id');if(requestID&&/^[A-Za-z0-9_-]{1,200}$/.test(requestID))diagnostic.requestID=requestID;
  const v=await boundedResponse(response.clone());for(const [key,value]of Object.entries({responseID:v.id,responseStatus:v.status,providerCode:v.error?.code??v.error?.type,inputTokens:v.usage?.input_tokens,outputTokens:v.usage?.output_tokens})){if(checkedPilotDiagnostic({[key]:value}))diagnostic[key]=value}if(Array.isArray(v.output)){diagnostic.webCompleted=v.output.filter(i=>i.type==='web_search_call'&&i.status==='completed').length;diagnostic.webIncomplete=v.output.filter(i=>i.type==='web_search_call'&&i.status!=='completed').length}let bill;
  if(!response.ok){const diagnostic={providerStatus:response.status,providerCode:v.error?.code??v.error?.type};if(!knownProviderRejection({diagnostic}))throw Error('pilot_usage_unknown');bill={cost:0,webCalls:0,inputTokens:0,outputTokens:0}}
  else bill=pilotBill(v,lease.model??'gpt-6-astra');
  if(bill.webCalls>config.webAllowance)throw Error('pilot_usage_unknown');
  settlementAttempted=true;await invoke('settle',{...fields,...bill,diagnostic,elapsedMS:Math.round(performance.now()-started)});return response;
 }catch(e){if(!settlementAttempted)try{await invoke('uncertain',{...fields,diagnostic:checkedPilotDiagnostic(diagnostic)??{}})}catch{}throw e}
};}
export async function researchPilot(p,userHash,env,send=fetch){
 if(shape(p))p={...p,runID:p.runID.toLowerCase()};
 if(!shape(p)||(p.mode==='researchPilot'&&(env.RESEARCH_PILOT_ENABLED!=='true'||p.runID!==env.RESEARCH_PILOT_RUN_ID?.toLowerCase()))||env.ENVIRONMENT!=='production'||env.OWNER_VALIDATION_ENABLED!=='true'||env.LIVE_AI!=='true'||env.ALLOW_PUBLIC_LOOKUP!=='true'||env.ALLOW_RECONCILED_BUDGET!=='true'||!/^[a-f0-9]{64}$/.test(userHash??''))return json({error:'pilot_disabled'},503);
 let invoke,lease;
 try{
  invoke=pilotClient(env,userHash,p.runID);
  if(p.mode==='researchPilotStatus')return json(await invoke('status'));
  if(p.mode==='researchPilotStop')return json(await invoke('stop'));
  const caseID=p.workloadID+':'+p.arm;
  if(env.RESEARCH_PILOT_KIND===SOL_ONLY_KIND&&['museums:candidate','menus:legacy'].includes(caseID)){await invoke('control',{caseID});return json({version:11,runID:p.runID,workloadID:p.workloadID,arm:p.arm,skipped:true,providerCalls:0,comparisonKind:SOL_ONLY_KIND,path:'control'})}
  lease=await invoke('case-begin',{caseID});
  const guarded=pilotTransport(send,invoke,lease),root=await stageID(p.runID,PILOT_ORDER.indexOf(caseID));
  const text=PILOT_WORKLOADS[p.workloadID];let continuation=null,result=null,sources=[],measurements=[];
  const start=performance.now();
  for(let step=0;step<12;step++){
   if(Date.now()>lease.deadline)throw Error('pilot_deadline');
   const payload={version:p.arm==='candidate'?10:9,mode:'conversationStep',requestID:root,step,text,context:{index:[],recent:[]},cities:[],task:null,findings:[],history:[],historyCount:0,continuation,result,...(p.arm==='candidate'?{webAllowed:true,turnID:root}:{})};
   const comparison=[MODEL_PILOT_KIND,SOL_ONLY_KIND].includes(lease.kind),comparisonKind=lease.kind;
   if(comparison)Object.assign(payload,{version:10,webAllowed:true,turnID:root});
   const response=comparison?await nativeConversationAnswer(payload,userHash,{...env,NATIVE_RESEARCH_ENABLED:'true'},guarded,{pilotExecutionModel:lease.model}):p.arm==='candidate'?await nativeConversationAnswer(payload,userHash,{...env,NATIVE_RESEARCH_ENABLED:'true'},guarded,{pilotExecutionModel:lease.model??'gpt-6-astra'}):await conversationAnswer(payload,userHash,env,guarded,'gpt-6-astra');
   const value=await response.json();if(!response.ok)throw Error(value.error??'pilot_answer_failed');
   measurements.push(value.performance);continuation=value.continuation;
   if(value.kind==='answer'){
    await invoke('case-finish',{...lease,success:true});lease=null;
    return json({version:11,runID:p.runID,workloadID:p.workloadID,arm:p.arm,text:value.text,citations:comparison||p.arm==='candidate'?value.finalCitations:sources,citationKind:comparison||p.arm==='candidate'?'final_text':'research_pool',...comparison?{comparisonKind,model:value.model,path:'native'}:{},elapsedMS:Math.round(performance.now()-start),measurements});
   }
   const call=value.call;if(!call)throw Error('pilot_call_missing');let output={status:'empty',complete:true,totalCount:0,records:[],findings:[],message:'not_found',localOnly:false};
   if(!comparison&&call.name==='search_web'&&p.arm==='legacy'){
    const query=JSON.parse(call.arguments).query;
    const response=await conversationAnswer({version:9,mode:'webSearch',requestID:crypto.randomUUID(),query},userHash,env,guarded,'gpt-6-astra');
    const web=await response.json();if(!response.ok)throw Error(web.error??'pilot_search_failed');measurements.push(web.performance);
    for(const source of web.citations)if(!sources.some(s=>s.url===source.url))sources.push(source);
    output={...output,status:'success',message:'ok',web:{text:web.text,citations:web.citations}};
   }else if(call.name==='read_conversation')output.history=[];
   else if(!['query_collection','research_businesses'].includes(call.name))output={...output,status:'unavailable',complete:false,message:'unavailable'};
   // No Maps network, authorization calls or collection writes exist in this runner.
   result={callID:call.callID,output};
  }
  throw Error('pilot_response_limit');
 }catch(e){if(invoke&&lease)try{await invoke('case-finish',{...lease,success:false})}catch{}return json({error:/^[a-z_]+$/.test(e.message)?e.message:'pilot_failed'},503)}
}
