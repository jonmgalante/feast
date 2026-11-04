// Fixed public-only pilot. Never normal capability advertisement or client data.
import {nativeUsageCost,nativeProfile} from './native-accounting.mjs';
export const PILOT_LIMITS=Object.freeze({maxResponses:32,maxWebActions:24,stopSchedulingMicroUSD:5_000_000});
export const PILOT_WORKLOADS=Object.freeze({
 museums:"Use the museums’ official websites to verify which major museum in Oslo opened most recently. Compare the official opening dates of MUNCH and the National Museum, and explain any ambiguity in ‘new’.",
 menus:"Check official websites and compare the current tasting-menu format and booking arrangements at Geranium and Kadeau in Copenhagen. Link the official menu or booking pages, distinguish what is confirmed from what is unclear, and don’t make a booking."
});
export const PILOT_ORDER=Object.freeze(['museums:legacy','museums:candidate','menus:candidate','menus:legacy']);
export const MODEL_PILOT_KIND='sol-astra-v2';
export const SOL_ONLY_KIND='sol-only-v3';
export const CARRIED_PILOT=Object.freeze({runID:'8d577230-e49e-4274-b8c6-dd98cb81b5b8',microUSD:6800288});
const SOL_ONLY_ORDER=Object.freeze(['museums:legacy','menus:candidate']);
const SOL_ONLY_LIMITS=Object.freeze({...PILOT_LIMITS,stopSchedulingMicroUSD:10000000});
export function pilotDefinition(kind){return kind==='legacy-v1'?{version:1,order:PILOT_ORDER,limits:PILOT_LIMITS}:kind===MODEL_PILOT_KIND?{version:2,order:PILOT_ORDER,limits:PILOT_LIMITS}:kind===SOL_ONLY_KIND?{version:3,order:SOL_ONLY_ORDER,limits:SOL_ONLY_LIMITS}:null}

export function pilotCaseModel(kind,caseID){return kind===SOL_ONLY_KIND||kind===MODEL_PILOT_KIND&&caseID.endsWith(':candidate')?'gpt-6.1-sol':'gpt-6-astra'}
export function pilotBody(url,options,model='gpt-6-astra'){
 if(!['https://api.openai.com/v1/responses','https://api.openai.com/v1/responses/input_tokens'].includes(url)||options?.method!=='POST')throw Error('pilot_endpoint');
 const b=JSON.parse(options.body);if(!['gpt-6-astra','gpt-6.1-sol'].includes(model)||b.model!==model||b.reasoning?.effort!=='medium')throw Error('pilot_model');
 if(url.endsWith('/input_tokens'))return {countOnly:true,webAllowance:0};
 if(b.store!==false||b.service_tier!=='default'||b.stream===true||b.background===true)throw Error('pilot_model');
 const web=b.tools?.some(t=>t.type==='web_search')?(b.max_tool_calls??NaN):0;
 if(b.max_output_tokens!==8192||b.parallel_tool_calls!==false||!Number.isInteger(web)||web<0||web>12||b.tools?.some(t=>!['function','web_search'].includes(t.type)))throw Error('pilot_request');
 return {countOnly:false,webAllowance:web};
}
export function pilotBill(v,model='gpt-6-astra'){
 if(!['completed','incomplete'].includes(v.status)||!Array.isArray(v.output)||v.output.some(i=>!['reasoning','message','function_call','web_search_call'].includes(i.type))||v.output.some(i=>i.type==='web_search_call'&&i.status!=='completed'))throw Error('pilot_usage_unknown');
 if(!(v.model===model||v.model?.startsWith(model+'-')))throw Error('pilot_model');
 const webCalls=v.output.filter(i=>i.type==='web_search_call').length,inputTokens=v.usage?.input_tokens,outputTokens=v.usage?.output_tokens;
 return {cost:nativeUsageCost([{model,inputTokens,outputTokens,webCalls}],nativeProfile(model)),webCalls,inputTokens,outputTokens};
}
export function pilotAdmission(state,allowance,limits=PILOT_LIMITS){
 if(state.stopRequested||state.failed||state.records.some(r=>r.state!=='settled'))throw Error('pilot_stopped_or_unsettled');
 const cost=(state.carriedExposure?.microUSD??0)+state.records.reduce((n,r)=>n+r.cost,0),used=state.records.reduce((n,r)=>n+r.webCalls,0);
 if(!Number.isSafeInteger(cost)||cost>=limits.stopSchedulingMicroUSD||state.records.length>=limits.maxResponses||used+allowance>limits.maxWebActions)throw Error('pilot_limit');
}

// Content-free provider metadata only. Never body text, request payload or headers beyond request ID.
export function checkedPilotDiagnostic(d){
 if(!d||typeof d!=='object'||Array.isArray(d)||Object.keys(d).some(k=>!['httpStatus','requestID','responseID','responseStatus','providerCode','inputTokens','outputTokens','webCompleted','webIncomplete'].includes(k)))return null;
 for(const [k,v] of Object.entries(d)){
  if(['httpStatus','inputTokens','outputTokens','webCompleted','webIncomplete'].includes(k)){if(!Number.isSafeInteger(v)||v<0||v>100000000)return null}
  else if(typeof v!=='string'||v.length>200||!/^[A-Za-z0-9_-]+$/.test(v))return null;
 }
 return d;
}
