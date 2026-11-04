import {ACTIVE_MODEL,modelFrame,continuationModel,agentProfile} from './active-model.mjs';
import {providerFailure,knownProviderRejection} from './provider-errors.mjs';
import {agentTools,agentInstructions,checkedAgentCall,validAgentPayload,validAgentResult} from './agent-tools.mjs';
import {StageAccounting,StageRefusal} from './stage-accounting.mjs';
import {STAGE_POLICY} from './stage-policy.mjs';
import {productionInputCountBody} from './model-policy.mjs';
import {boundedResponse} from '../feast-proxy/openai.mjs';
const json=(value,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store'}});
const digest=async x=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(x)))].map(x=>x.toString(16).padStart(2,'0')).join('');
const encode=x=>{const bytes=new TextEncoder().encode(JSON.stringify(x));let binary='';for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(binary)};
function decode(x){try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(atob(x),c=>c.charCodeAt(0))))}catch{throw Error('agent_continuation')}}
export function checkedContinuation(p){
 if(p.step===0)return [];
 const items=modelFrame(decode(p.continuation)).items;if(!Array.isArray(items)||items.length>30)throw Error('agent_continuation');
 let calls=0,outputs=0,last=null;const known=new Set(),answered=new Set();
 for(const item of items){
  if(item?.type==='reasoning'){
   if(Object.keys(item).some(k=>!['id','type','summary','encrypted_content','status'].includes(k))||typeof item.id!=='string'||item.id.length>200||!Array.isArray(item.summary)||item.summary.length||!(item.encrypted_content==null||typeof item.encrypted_content==='string'&&item.encrypted_content.length<=100000)||!(item.status==null||item.status==='completed'))throw Error('agent_reasoning');
  }else if(item?.type==='function_call'){
   if(Object.keys(item).some(k=>!['id','type','call_id','name','arguments','status'].includes(k))||known.has(item.call_id))throw Error('agent_call_item');
   if(last&&!answered.has(last.call_id))throw Error('agent_unanswered_call');checkedAgentCall(item,p.text);if((calls===0)!==(item.name==='interpret_request'))throw Error('agent_intent_sequence');known.add(item.call_id);last=item;calls++;
  }else if(item?.type==='function_call_output'){
   if(Object.keys(item).sort().join(',')!=='call_id,output,type'||!known.has(item.call_id)||answered.has(item.call_id)||item.call_id!==last?.call_id||typeof item.output!=='string'||!validAgentResult(JSON.parse(item.output)))throw Error('agent_tool_output');answered.add(item.call_id);outputs++;
  }else if(item?.type==='message'){
   if(item.role!=='assistant'||item.status!=='completed'||!Array.isArray(item.content)||item.content.length>2||!item.content.every(c=>c.type==='output_text'&&typeof c.text==='string'&&c.text.length<=6000&&Array.isArray(c.annotations)&&c.annotations.length===0))throw Error('agent_message');
  }else throw Error('agent_item');
 }
 if(calls!==p.step||outputs!==p.step-1||!last||p.result.callID!==last.call_id)throw Error('agent_call_sequence');
 items.push({type:'function_call_output',call_id:last.call_id,output:JSON.stringify(p.result.output)});return items;
}
export async function agentStep(p,userHash,env,send=fetch){
 if(env.ENVIRONMENT!=='production'||env.OWNER_VALIDATION_ENABLED!=='true'||env.LIVE_AI!=='true'||!env.OPENAI_API_KEY||env.ALLOW_RECONCILED_BUDGET!=='true')return json({error:'agent_disabled'},503);
 if(!/^[a-f0-9]{64}$/.test(userHash??'')||!validAgentPayload(p))return json({error:'invalid_agent_request'},400);
 let previous;try{previous=checkedContinuation(p)}catch{return json({error:'invalid_agent_continuation'},400)}
 const fingerprint=await digest(JSON.stringify({text:p.text,context:p.context,cities:p.cities,task:p.task,findings:p.findings}));
 const ledger=env.PRODUCTION_STATE.get(env.PRODUCTION_STATE.idFromName('production-validation-v1'));
 const accounting=new StageAccounting({root:p.requestID,userHash,fingerprint,startIndex:p.step,maxStages:6,invoke:(route,body)=>ledger.fetch(new Request('https://ledger'+route+'-v2',{method:'POST',body:JSON.stringify(body)}))});
 const model=continuationModel(p,decode),profile=agentProfile(model),policy=STAGE_POLICY[profile],body={model:policy.model,store:false,stream:false,service_tier:'default',reasoning:{effort:'medium'},max_output_tokens:policy.maxOutput,include:['reasoning.encrypted_content'],parallel_tool_calls:false,tools:agentTools(p.step===0),tool_choice:'required',instructions:agentInstructions(),input:[{role:'user',content:JSON.stringify({question:p.text,catalog:p.context.index,cities:p.cities,recentUserQuestions:p.context.recent,acceptedTask:p.task,acceptedPublicFindings:p.findings})},...previous]};
 const headers={Authorization:'Bearer '+env.OPENAI_API_KEY,'Content-Type':'application/json','OpenAI-Project':'proj_si0dRO6qKPoVOas0he2frPLO'};
 try{
  const count=await send('https://api.openai.com/v1/responses/input_tokens',{method:'POST',redirect:'manual',headers,body:JSON.stringify(productionInputCountBody(body)),signal:AbortSignal.timeout(20000)});
  if(!count.ok)throw await providerFailure(count,'agent_count');const counted=await boundedResponse(count);if(!Number.isSafeInteger(counted.input_tokens)||counted.input_tokens<0||counted.input_tokens>policy.maxInput)throw Error('agent_input_limit');
  await accounting.begin(profile);
  const reply=await send('https://api.openai.com/v1/responses',{method:'POST',redirect:'manual',headers,body:JSON.stringify(body),signal:AbortSignal.timeout(90000)});
  if(!reply.ok)throw await providerFailure(reply,'agent_provider');const value=await boundedResponse(reply);
  if(!['completed','incomplete'].includes(value.status)||!(value.model===policy.model||value.model?.startsWith(policy.model+'-')))throw Error('agent_incomplete');
  await accounting.complete({model:policy.model,inputTokens:value.usage?.input_tokens,outputTokens:value.usage?.output_tokens,webCalls:0});
  if(value.status!=='completed')throw Error('agent_incomplete');
  const calls=value.output?.filter(x=>x.type==='function_call');if(calls?.length!==1)throw Error('agent_call_count');
  const call=checkedAgentCall(calls[0],p.text);if((p.step===0)!==(call.name==='interpret_request'))throw Error('agent_intent_sequence');const next=[...previous,...value.output];
  const encoded=encode({version:1,model,items:next});if(encoded.length>350000)throw Error('agent_context_limit');
  return json({version:8,requestID:p.requestID,step:p.step,call,continuation:encoded,budget:accounting.lastBudget,model:policy.model});
 }catch(error){
  try{if(knownProviderRejection(error))await accounting.rejected(error.diagnostic.providerStatus,error.diagnostic.providerCode);else await accounting.uncertain()}catch{}
  return json({error:error.message?.startsWith('provider_')?error.message:error instanceof StageRefusal?'agent_reservation_refused':'agent_step_unverified',message:'This step stopped. Completed usage remains accounted; uncertain charges remain reserved. No automatic retry.'},error instanceof StageRefusal?error.status:503);
 }
}
