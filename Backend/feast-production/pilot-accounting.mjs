import {stageID} from './stage-accounting.mjs';
import {nativeUsageCost,nativeProfile} from './native-accounting.mjs';
import {PILOT_LIMITS,PILOT_ORDER,pilotAdmission,MODEL_PILOT_KIND,SOL_ONLY_KIND,CARRIED_PILOT,pilotDefinition,pilotCaseModel,checkedPilotDiagnostic} from './pilot-policy.mjs';
const json=(v,status=200)=>Response.json(v,{status}),uuid=x=>/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(x??'');
function validState(s){
 const kind=s.kind??'legacy-v1',def=pilotDefinition(kind);if(!def||s.version!==def.version)return false;
 const order=def.order;
 return Number.isInteger(s.nextCase)&&s.nextCase>=0&&s.nextCase<=order.length&&typeof s.stopRequested==='boolean'&&typeof s.failed==='boolean'&&Array.isArray(s.records)&&s.records.length<=32&&Array.isArray(s.cases)&&s.cases.length<=order.length&&s.cases.every((c,i)=>c.caseID===order[i]&&['pending','complete','failed'].includes(c.state)&&(s.version===1||c.model===pilotCaseModel(kind,c.caseID)))&&s.cases.length===s.nextCase+(s.active?1:0)&&(!s.active||uuid(s.active.lease)&&s.active.caseID===order[s.nextCase]&&Number.isFinite(s.active.deadline)&&(s.version===1||s.active.kind===kind&&s.active.model===pilotCaseModel(kind,s.active.caseID)))&&new Set(s.records.map(r=>r.id)).size===s.records.length&&s.records.every(r=>uuid(r.id)&&order.includes(r.caseID)&&['pending','settled','uncertain'].includes(r.state)&&Number.isInteger(r.webAllowance)&&r.webAllowance>=0&&r.webAllowance<=12&&(s.version===1||r.model===pilotCaseModel(kind,r.caseID))&&(r.state!=='settled'||Number.isSafeInteger(r.cost)&&r.cost>=0&&Number.isInteger(r.webCalls)&&r.webCalls>=0&&r.webCalls<=r.webAllowance));
}
async function carriedExposure(tx,userHash){
 const prior=await tx.get('research-pilot-v2:'+CARRIED_PILOT.runID);
 if(!prior||!validState(prior)||prior.userHash!==userHash||!prior.failed||!prior.stopRequested||prior.active||prior.nextCase!==1||prior.cases[0]?.caseID!=='museums:legacy'||prior.records.length!==1||prior.records[0].state!=='uncertain'||prior.records[0].model!=='gpt-6-astra')throw Error('pilot_carry_source');
 const root=await stageID(CARRIED_PILOT.runID,0),nativeRequestID=await stageID(root,0),record=await tx.get('production-validation-v2:request:'+nativeRequestID);
 if(!record||record.userHash!==userHash||record.profile!=='astraNativeUsageV1'||record.state!=='uncertain'||record.reservedMicroUSD!==CARRIED_PILOT.microUSD||record.rootRequestID!==root||record.stageIndex!==0)throw Error('pilot_carry_ledger');
 return {...CARRIED_PILOT,nativeRequestID,pilotRecordID:prior.records[0].id};
}
export async function pilotAccountingFetch(storage,request,env){
 const p=await request.json(),route=new URL(request.url).pathname;
 if(!p||!uuid(p.runID)||!/^[a-f0-9]{64}$/.test(p.userHash??''))return json({error:'pilot_disabled'},503);
 p.runID=p.runID.toLowerCase();
 return storage.transaction(async tx=>{
  const keys=['research-pilot-v1:','research-pilot-v2:','research-pilot-v3:'].map(prefix=>prefix+p.runID);
  const existing=await Promise.all(keys.map(k=>tx.get(k)));if(existing.filter(Boolean).length>1)return json({error:'pilot_namespace_collision'},409);
  const requestedKind=env.RESEARCH_PILOT_KIND??'legacy-v1';if(!pilotDefinition(requestedKind))return json({error:'pilot_kind'},503);
  const index=existing.findIndex(Boolean),prior=index>=0?existing[index]:null,kind=prior?.kind??(prior?'legacy-v1':requestedKind),def=pilotDefinition(kind);
  const key=index>=0?keys[index]:keys[def.version-1];
  const enabled=env.RESEARCH_PILOT_ENABLED==='true'&&p.runID===env.RESEARCH_PILOT_RUN_ID?.toLowerCase()&&kind===requestedKind;
  if(!prior&&!enabled)return json({error:'pilot_disabled'},503);
  let carry=null;if(kind===SOL_ONLY_KIND){try{carry=await carriedExposure(tx,p.userHash)}catch(e){return json({error:e.message},409)}}
  const state=prior??{version:def.version,...def.version>1?{kind}:{},runID:p.runID,userHash:p.userHash,limits:def.limits,...carry?{carriedExposure:carry}:{},nextCase:0,active:null,stopRequested:false,failed:false,records:[],cases:[]};
  if(!validState(state)||state.runID!==p.runID||state.userHash!==p.userHash||JSON.stringify(state.limits)!==JSON.stringify(def.limits)||kind===SOL_ONLY_KIND&&JSON.stringify(state.carriedExposure)!==JSON.stringify(carry))return json({error:'pilot_state'},409);
  if(route==='/pilot-status-v2')return json(state.version>1?{...state,version:1,stateVersion:state.version}:state);
  if(route==='/pilot-control-v2'){
   const needed=kind===SOL_ONLY_KIND?{'museums:candidate':'museums:legacy','menus:legacy':'menus:candidate'}[p.caseID]:null;
   if(!enabled||!needed||state.active||state.failed||state.stopRequested||state.records.some(r=>r.state!=='settled')||!state.cases.some(c=>c.caseID===needed&&c.state==='complete'))return json({error:'pilot_control_not_ready'},409);
   return json({skipped:true,providerCalls:0});
  }
  if(route==='/pilot-stop-v2'){state.stopRequested=true;await tx.put(key,state);return json({stopped:true})}
  if(route==='/pilot-case-begin-v2'){
   if(!enabled)return json({error:'pilot_disabled'},503);
   if(state.active||state.nextCase>=def.order.length||p.caseID!==def.order[state.nextCase])return json({error:'pilot_order_or_replay'},409);
   try{pilotAdmission(state,0,state.limits)}catch(e){return json({error:e.message},409)}
   const model=pilotCaseModel(kind,p.caseID);state.active={caseID:p.caseID,lease:crypto.randomUUID(),deadline:Date.now()+180000,...state.version>1?{kind,model}:{}};state.cases.push({caseID:p.caseID,state:'pending',...state.version>1?{model}:{}});await tx.put(key,state);return json(state.active);
  }
  if(!state.active||state.active.caseID!==p.caseID||state.active.lease!==p.lease||state.version>1&&(p.kind!==state.kind||p.model!==state.active.model))return json({error:'pilot_lease'},409);
  if(route==='/pilot-reserve-v2'){
   if(!enabled||Date.now()>state.active.deadline)return json({error:'pilot_disabled_or_deadline'},503);
   if(!Number.isInteger(p.webAllowance)||p.webAllowance<0||p.webAllowance>12||!uuid(p.id))return json({error:'pilot_request'},400);
   try{pilotAdmission(state,p.webAllowance,state.limits)}catch(e){return json({error:e.message},409)}
   state.records.push({id:p.id,caseID:p.caseID,state:'pending',webAllowance:p.webAllowance,...state.version>1?{model:state.active.model}:{}});await tx.put(key,state);return json({reserved:true});
  }
  if(route==='/pilot-settle-v2'||route==='/pilot-uncertain-v2'){
   const r=state.records.find(r=>r.id===p.id);if(!r||r.caseID!==p.caseID||r.state!=='pending')return json({error:'pilot_record'},409);
   const diagnostic=checkedPilotDiagnostic(p.diagnostic);if(diagnostic)r.diagnostic=diagnostic;
   if(route==='/pilot-uncertain-v2'){r.state='uncertain';state.failed=true}
   else {
    if(!Number.isSafeInteger(p.cost)||p.cost<0||!Number.isInteger(p.webCalls)||p.webCalls<0||p.webCalls>r.webAllowance||!Number.isSafeInteger(p.elapsedMS)||p.elapsedMS<0||p.elapsedMS>180000||!Number.isSafeInteger(p.inputTokens)||p.inputTokens<0||!Number.isSafeInteger(p.outputTokens)||p.outputTokens<0||p.outputTokens>8192)return json({error:'pilot_usage'},400);
    if(state.version>1){let expected;try{expected=nativeUsageCost([{model:r.model,inputTokens:p.inputTokens,outputTokens:p.outputTokens,webCalls:p.webCalls}],nativeProfile(r.model))}catch{return json({error:'pilot_usage'},400)}if(p.cost!==expected)return json({error:'pilot_usage_cost'},409)}
    Object.assign(r,{state:'settled',cost:p.cost,webCalls:p.webCalls,elapsedMS:p.elapsedMS,inputTokens:p.inputTokens,outputTokens:p.outputTokens});
   }
   await tx.put(key,state);return json({accepted:true});
  }
  if(route==='/pilot-case-finish-v2'){
   if(p.success===true&&state.records.some(r=>r.state!=='settled'))return json({error:'pilot_unsettled'},409);
   const c=state.cases.at(-1);c.state=p.success===true?'complete':'failed';state.failed ||= !p.success;state.active=null;state.nextCase++;await tx.put(key,state);return json({finished:true});
  }
  return json({error:'pilot_route'},400);
 });
}
export function pilotClient(env,userHash,runID){
 const ledger=env.PRODUCTION_STATE.get(env.PRODUCTION_STATE.idFromName('production-validation-v1'));
 return async(route,fields={})=>{const r=await ledger.fetch(new Request('https://ledger/pilot-'+route+'-v2',{method:'POST',body:JSON.stringify({runID,userHash,...fields})}));const v=await r.json();if(!r.ok)throw Error(v.error??'pilot_unavailable');return v};
}
