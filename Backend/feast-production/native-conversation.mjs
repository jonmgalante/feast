import {nativeAccountingAdapter} from './native-accounting.mjs';
// Gated native execution. Provider-controlled spend: estimates are not dollar ceilings.
import {NATIVE_RESEARCH,nativeRequestModel,nativeContinuation,nativeBody,checkedNativeItem,encodeNativeFrame,nativeEvidence,nativeDigest} from './native-research.mjs';
import {checkedConversationCall} from './conversation.mjs';
import {productionInputCountBody} from './model-policy.mjs';
import {boundedResponse} from '../feast-proxy/openai.mjs';
import {providerFailure,knownProviderRejection} from './provider-errors.mjs';
import {PerformanceMeasurements} from './performance.mjs';
const json=(v,status=200)=>Response.json(v,{status,headers:{'Cache-Control':'no-store'}});
export const nativeResearchReady=(env={})=>env.NATIVE_RESEARCH_ENABLED==='true'&&env.ALLOW_PUBLIC_LOOKUP==='true'&&env.ALLOW_RECONCILED_BUDGET==='true';
export async function nativeConversationAnswer(p,userHash,env,send=fetch,dependencies={}){
 if(env.NATIVE_RESEARCH_ENABLED!=='true'||env.ENVIRONMENT!=='production'||env.OWNER_VALIDATION_ENABLED!=='true'||env.LIVE_AI!=='true'||env.ALLOW_RECONCILED_BUDGET!=='true'||!/^[a-f0-9]{64}$/.test(userHash??'')||!env.OPENAI_API_KEY)return json({error:'native_research_disabled'},503);
 let model;
 try{model=nativeRequestModel(p,dependencies.pilotExecutionModel)}catch{return json({error:'native_context_identity'},503)}
 // A pilot pins the entire run, including resumed frames. Ordinary traffic
 // instead preserves either supported historical continuation model.
 if(dependencies.pilotExecutionModel&&model!==dependencies.pilotExecutionModel)return json({error:'native_pilot_model_changed'},503);
 if(dependencies.pilotExecutionModel&&(!['gpt-6-astra','gpt-6.1-sol'].includes(model)||env.RESEARCH_PILOT_ENABLED!=='true'||!['legacy-v1','sol-astra-v2','sol-only-v3'].includes(env.RESEARCH_PILOT_KIND??'legacy-v1')||(env.RESEARCH_PILOT_KIND??'legacy-v1')==='legacy-v1'&&model!=='gpt-6-astra'||env.RESEARCH_PILOT_KIND==='sol-only-v3'&&model!=='gpt-6.1-sol'))return json({error:'native_pilot_model_disabled'},503);
 const accounting=dependencies.accounting??nativeAccountingAdapter(env,model);
 if(accounting.policy!=='provider_controlled'&&!(dependencies.testOnly===true&&accounting.proofKind==='fixture_only'))return json({error:'native_accounting_policy'},503);
 const metrics=new PerformanceMeasurements();let reservation=null,settlementAttempted=false,verifiedBill=null,dispatched=false;
 try {
  const state=await nativeContinuation(p,model);
  const allocation=await accounting.prepare({userHash,root:p.requestID,turnID:p.turnID,step:p.step,fingerprint:state.fingerprint,priorDigest:state.priorDigest,privateLatched:state.privateLatched,requestedWebActions:state.webAllowed?NATIVE_RESEARCH.maxWebActions-state.webActions:0});
  if(!allocation||typeof allocation.webAllowed!=='boolean'||!Number.isSafeInteger(allocation.remainingWebActions)||allocation.remainingWebActions<0||allocation.remainingWebActions>NATIVE_RESEARCH.maxWebActions-state.webActions)throw Error('native_allocation_unverified');
  state.privateLatched ||= allocation.privateLatched===true;
  state.webAllowed=state.webAllowed&&allocation.webAllowed&&env.ALLOW_PUBLIC_LOOKUP==='true';state.allowedWebActions=state.webAllowed?allocation.remainingWebActions:0;
  const body=nativeBody(p,state),remaining=state.allowedWebActions;
  const headers={Authorization:'Bearer '+env.OPENAI_API_KEY,'Content-Type':'application/json','OpenAI-Project':'proj_si0dRO6qKPoVOas0he2frPLO'};
  const {max_tool_calls,...countable}=body;
  const count=await metrics.measure('inputCount',async()=>{const r=await send('https://api.openai.com/v1/responses/input_tokens',{method:'POST',redirect:'manual',headers,body:metrics.serialize({...productionInputCountBody(countable),truncation:'disabled'}),signal:AbortSignal.timeout(20000)});if(!r.ok)throw await providerFailure(r,'input_count');return boundedResponse(r)});
  if(!Number.isSafeInteger(count.input_tokens)||count.input_tokens<0||count.input_tokens>NATIVE_RESEARCH.maxInitialInput)throw Error('native_input_limit');
  // Required adapter contract: atomic shared-ledger concurrency/exposure, durable
  // human-turn identity, sequential attempt stages, prior-frame attestation,
  // privacy latch and whole-turn native action allowance. An in-memory counter
  // is NOT a production implementation of this contract.
  reservation=await metrics.measure('ledger',()=>accounting.reserve({userHash,root:p.requestID,turnID:p.turnID,step:p.step,fingerprint:state.fingerprint,priorDigest:state.priorDigest,allocationRevision:allocation.revision,privateLatched:state.privateLatched,webAllowed:state.webAllowed,maxWebActions:remaining,maxOutput:NATIVE_RESEARCH.maxOutput}));
  if(!reservation||reservation.maxWebActions!==remaining||accounting.policy==='provider_controlled'&&reservation.accountingPolicy!=='provider_controlled')throw Error('native_reservation_unverified');
  dispatched=true;
  const r=await metrics.measure('provider',()=>send('https://api.openai.com/v1/responses',{method:'POST',redirect:'manual',headers,body:metrics.serialize(body),signal:AbortSignal.timeout(90000)}));if(!r.ok)throw await providerFailure(r,'provider');
  const value=await metrics.measure('decode',()=>boundedResponse(r));metrics.usage(value);
  const validUsage=(value.model===model||value.model?.startsWith(model+'-'))&&Number.isSafeInteger(value.usage?.input_tokens)&&value.usage.input_tokens>=0&&Number.isSafeInteger(value.usage?.output_tokens)&&value.usage.output_tokens>=0&&value.usage.output_tokens<=NATIVE_RESEARCH.maxOutput;
  const knownTypes=['reasoning','message','function_call','function_call_output','web_search_call'];
  const rawWeb=Array.isArray(value.output)?value.output.filter(i=>i?.type==='web_search_call'):[];
  if(validUsage&&['completed','incomplete'].includes(value.status)&&Array.isArray(value.output)&&value.output.every(i=>knownTypes.includes(i?.type))&&rawWeb.every(i=>i.status==='completed')&&rawWeb.length<=remaining)verifiedBill={model,inputTokens:value.usage.input_tokens,outputTokens:value.usage.output_tokens,webCalls:rawWeb.length};
  if(value.status!=='completed'||!validUsage||!Array.isArray(value.output)||value.output.length>NATIVE_RESEARCH.maxItems)throw Error('native_response_unverified');
  if(value.output.some(i=>i.type==='function_call_output'))throw Error('native_provider_tool_output');
  const output=value.output.map(item=>checkedNativeItem(item,p.text)),web=output.filter(i=>i.type==='web_search_call'),calls=output.filter(i=>i.type==='function_call');
  if(calls.length>1||web.length>remaining||(!state.webAllowed&&web.length)||new Set(web.map(x=>x.id)).size!==web.length)throw Error('native_tool_limit');
  const oldWeb=new Set(state.frame.records.filter(r=>r.item.type==='web_search_call').map(r=>r.item.id));if(web.some(x=>oldWeb.has(x.id)))throw Error('native_duplicate_web_action');
  const at=new Date().toISOString(),records=[...state.frame.records,...output.map(item=>({observedAt:at,item}))];if(records.length>NATIVE_RESEARCH.maxItems)throw Error('native_context_limit');
  const evidence=await metrics.measure('evidence',()=>nativeEvidence(records,state.privateLatched&&!state.frame.records.some(r=>r.item.type==='function_call_output'&&JSON.parse(r.item.output).localOnly),(key,value)=>metrics.count(key,value))),continuation=encodeNativeFrame({...state.frame,records});
  const messages=output.filter(i=>i.type==='message'),final=messages.filter(i=>i.phase==='final_answer');
  const selected=final.length?final:(calls.length?[]:messages.filter(i=>i.phase!=='commentary'));
  const text=selected.flatMap(i=>i.content.filter(c=>c.type==='output_text'||c.type==='refusal').map(c=>c.text??c.refusal)).join('\n');if(text.length>16000||!calls.length&&!text.trim()&&!state.frame.records.some(r=>r.item.type==='function_call_output'))throw Error('native_final_answer_shape');
  const finalCitations=[];for(const m of selected)for(const c of m.content)for(const a of c.annotations??[])if(!finalCitations.some(x=>x.url===a.url))finalCitations.push({title:a.title,url:a.url});
  if(finalCitations.length>20)throw Error('native_final_citation_limit');
  const call=calls.length?checkedConversationCall(calls[0],p.text):null;
  const frameDigest=await nativeDigest(continuation);
  settlementAttempted=true;
  const budget=await metrics.measure('ledger',()=>accounting.complete(reservation,{...verifiedBill,frameDigest,privateLatched:state.privateLatched,attemptWebActionsUsed:state.webActions+web.length}));
  const reply={version:10,requestID:p.requestID,step:p.step,kind:call?'tool':'answer',call,text,continuation,model,budget,finalCitations,nativeEvidence:evidence,performance:metrics.snapshot()};
  // Match the existing client's response budget. Known usage is already settled;
  // do not hide a reply-capacity failure as network/service unavailability.
  if(new TextEncoder().encode(JSON.stringify(reply)).byteLength>NATIVE_RESEARCH.maxReplyBytes)throw Error('native_reply_limit');
  return json(reply);
 }catch(error){
  if(reservation&&!settlementAttempted){settlementAttempted=true;try{if(!dispatched||error?.providerNotDispatched===true)await accounting.cancelUndispatched(reservation);else if(verifiedBill)await accounting.complete(reservation,{...verifiedBill,frameDigest:null,closed:true});else if(knownProviderRejection(error))await accounting.rejected(reservation,error.diagnostic);else await accounting.uncertain(reservation)}catch{}}
  return json({error:/^[a-z_]+$/.test(error.message)?error.message:'native_unverified',performance:metrics.snapshot()},503);
 }
}
