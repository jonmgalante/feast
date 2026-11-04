// Provider-controlled usage accounting. Allowances are estimates, NOT dollar ceilings.
import {stageID} from './stage-accounting.mjs';
import {knownProviderRejection} from './provider-errors.mjs';
export const NATIVE_PROFILE='astraNativeUsageV1';
export const NATIVE_ESTIMATE=6_800_288;
export const NATIVE_PROFILES=Object.freeze({astraNativeUsageV1:Object.freeze({model:'gpt-6-astra',estimate:NATIVE_ESTIMATE,inputRate:20,outputRate:100}),solNativeUsageV1:Object.freeze({model:'gpt-6.1-sol',estimate:1_400_288,inputRate:4,outputRate:20})});
export const nativeProfile=model=>Object.keys(NATIVE_PROFILES).find(k=>NATIVE_PROFILES[k].model===model);

const P='production-validation-v2:';
const integer=x=>Number.isSafeInteger(x)&&x>=0;
const uuid=x=>/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(x??'');
const digest=x=>/^[a-f0-9]{64}$/.test(x??'');
const json=(x,status=200)=>Response.json(x,{status});
export function nativeUsageCost(calls,profile=NATIVE_PROFILE){
 const policy=NATIVE_PROFILES[profile];if(!policy)throw Error('native_usage_shape');
 if(!Array.isArray(calls)||calls.length!==1)throw Error('native_usage_shape');const c=calls[0];
 if(!c||Object.keys(c).sort().join(',')!=='inputTokens,model,outputTokens,webCalls'||c.model!==policy.model||![c.inputTokens,c.outputTokens,c.webCalls].every(integer)||c.outputTokens>8192||c.webCalls>12)throw Error('native_usage_shape');
 const base=c.inputTokens*policy.inputRate+c.outputTokens*policy.outputRate+c.webCalls*10000;
 // Preserve historical Astra rounding; new Sol profile uses integer-ratio rounding.
 const cost=profile===NATIVE_PROFILE?Math.ceil(base*1.1):Math.ceil(base*11/10);if(!integer(cost))throw Error('native_usage_shape');return cost;
}
export async function nativeAccountingFetch(storage,request,view,rows){
 const path=new URL(request.url).pathname,p=await request.json();
 if(!p||!digest(p.userHash)||!uuid(p.root)||!uuid(p.turnID)||!Number.isInteger(p.step)||p.step<0||p.step>=12)return json({error:'native_accounting_request'},400);
 p.root=p.root.toLowerCase();p.turnID=p.turnID.toLowerCase();
 const profile=nativeProfile(p.model??'gpt-6-astra'),policy=NATIVE_PROFILES[profile];if(!policy)return json({error:'native_model'},400);
 return storage.transaction(async tx=>{
  const current=await view(tx),rootKey=P+'native-root:'+p.root,turnKey=P+'native-turn:'+p.userHash+':'+p.turnID;
  const root=await tx.get(rootKey),turn=(await tx.get(turnKey))??{responses:0,webActions:0,privateLatched:false,revision:0};
  const id=await stageID(p.root,p.step),recordKey=P+'request:'+id,record=await tx.get(recordKey);
  if(!integer(turn.responses)||turn.responses>12||!integer(turn.webActions)||turn.webActions>12||!integer(turn.revision)||typeof turn.privateLatched!=='boolean')return json({error:'native_accounting_corrupt'},503);
  if(root&&((root.model??'gpt-6-astra')!==policy.model))return json({error:'native_model_changed'},409);
  if(root&&root.userHash!==p.userHash)return json({error:'native_identity'},403);
  if(path==='/native-prepare-v2'||path==='/native-reserve-v2'){
   if(current.halted)return json({error:'validation_halted'},503);
   if(!digest(p.fingerprint)||!(p.priorDigest===null||digest(p.priorDigest))||typeof p.privateLatched!=='boolean'||!integer(p.requestedWebActions)||p.requestedWebActions>12)return json({error:'native_accounting_request'},400);
   if(await tx.get(P+'closed-root:'+p.root.toLowerCase()))return json({error:'attempt_closed'},409);
   if(p.step===0 ? root!=null : !root||root.fingerprint!==p.fingerprint||root.turnID!==p.turnID||root.nextStep!==p.step||root.frameDigest!==p.priorDigest||root.state!=='complete')return json({error:'native_order_or_replay'},409);
   if(!root&&p.step===0&&(p.priorDigest!==null||await tx.get(P+'stage-root:'+p.root)||await tx.get(P+'stage-root:'+p.root.toUpperCase())||await tx.get(P+'request:'+p.root)||await tx.get(P+'request:'+p.root.toUpperCase())||await tx.get('production-validation-v1:request:'+p.root)||await tx.get('production-validation-v1:request:'+p.root.toUpperCase())))return json({error:'native_order_or_replay'},409);
   const records=await rows(tx,P+'request:');
   if(records.some(r=>r.nativeTurnID===p.turnID&&r.userHash===p.userHash&&['pending','uncertain'].includes(r.state)))return json({error:'native_turn_unsettled'},409);
   if(turn.responses>=12)return json({error:'native_response_limit'},409);
   const privateLatched=turn.privateLatched||p.privateLatched;
   const remainingWebActions=privateLatched?0:Math.min(p.requestedWebActions,12-turn.webActions);
   const allocation={revision:turn.revision,privateLatched,webAllowed:!privateLatched,remainingWebActions};
   if(path==='/native-prepare-v2')return json(allocation);
   if(p.allocationRevision!==turn.revision||p.maxWebActions!==remainingWebActions||record)return json({error:'native_allocation_changed'},409);
   if(records.filter(r=>r.state==='pending').length>=4)return json({error:'request_in_progress'},429);
   await tx.put(recordKey,{userHash:p.userHash,fingerprint:p.fingerprint,profile,reservedMicroUSD:policy.estimate,state:'pending',rootRequestID:p.root,stageIndex:p.step,nativeTurnID:p.turnID,maxWebActions:remainingWebActions});
   await tx.put(rootKey,{userHash:p.userHash,turnID:p.turnID,fingerprint:p.fingerprint,model:policy.model,nextStep:p.step+1,state:'pending',frameDigest:null});
   // Also fence rollback into the old staged implementation.
   for(const alias of [p.root,p.root.toUpperCase()])await tx.put(P+'stage-root:'+alias,{userHash:p.userHash,fingerprint:p.fingerprint,nextIndex:p.step+1});
   await tx.put(turnKey,{...turn,responses:turn.responses+1,privateLatched,revision:turn.revision+1});
   await tx.put(P+'adopted',true);
   return json({requestID:id,maxWebActions:remainingWebActions,accountingPolicy:'provider_controlled',estimatedMicroUSD:policy.estimate});
  }
  if(!record||record.userHash!==p.userHash||record.state!=='pending'||record.nativeTurnID!==p.turnID||record.rootRequestID!==p.root||root?.state!=='pending')return json({error:'native_settlement_state'},409);
  if(path==='/native-uncertain-v2'){
   await tx.put(recordKey,{...record,state:'uncertain'});await tx.put(rootKey,{...root,state:'uncertain'});
   return json({...await view(tx),accountingPolicy:'provider_controlled'});
  }
  if(path!=='/native-complete-v2')return json({error:'not_available'},400);
  let cost=0,usage,state;
  if(p.undispatched===true||knownProviderRejection({diagnostic:p.diagnostic})){state='rejected'}
  else{usage=[p.usage];try{cost=nativeUsageCost(usage,record.profile)}catch{return json({error:'native_usage_unverified'},409)}if(p.usage.webCalls>record.maxWebActions)return json({error:'native_usage_unverified'},409);state='complete'}
  if(!(p.frameDigest===null||digest(p.frameDigest))||typeof p.closed!=='boolean')return json({error:'native_settlement_shape'},400);
  await tx.put(recordKey,{...record,state,...(usage?{usage}:p.undispatched===true?{undispatched:true}:{providerStatus:p.diagnostic.providerStatus,providerCode:p.diagnostic.providerCode}),conservativeUsageMicroUSD:cost});
  await tx.put(rootKey,{...root,state:p.closed?'closed':'complete',frameDigest:p.frameDigest});
  await tx.put(turnKey,{...turn,webActions:turn.webActions+(usage?.[0].webCalls??0),revision:turn.revision+1});
  return json({...await view(tx),accountingPolicy:'provider_controlled',conservativeUsageMicroUSD:cost});
 });
}
export function nativeAccountingAdapter(env,model='gpt-6-astra'){
 const ledger=env.PRODUCTION_STATE.get(env.PRODUCTION_STATE.idFromName('production-validation-v1'));
 const invoke=async(path,p)=>{const response=await ledger.fetch(new Request('https://ledger/native-'+path+'-v2',{method:'POST',body:JSON.stringify({...p,model})}));if(!response.ok){let error='native_accounting_unavailable';try{error=(await response.json()).error??error}catch{};throw Error(error)}return response.json()};
 return {policy:'provider_controlled',prepare:p=>invoke('prepare',p),reserve:async p=>({...p,...await invoke('reserve',{...p,requestedWebActions:p.maxWebActions})}),complete:(r,v)=>invoke('complete',{...r,usage:{model:v.model,inputTokens:v.inputTokens,outputTokens:v.outputTokens,webCalls:v.webCalls},frameDigest:v.frameDigest??null,closed:v.closed??false}),cancelUndispatched:r=>invoke('complete',{...r,undispatched:true,frameDigest:null,closed:true}),rejected:(r,diagnostic)=>invoke('complete',{...r,diagnostic,frameDigest:null,closed:true}),uncertain:r=>invoke('uncertain',r)};
}
