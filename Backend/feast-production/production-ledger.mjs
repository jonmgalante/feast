import {executionAlarm,recordGlobalHalt} from './execution-lifecycle.mjs';
import {knownProviderRejection} from './provider-errors.mjs';
import {VALIDATION_CAP_MICRO_USD} from './budget-policy.mjs';
import {reconciledFetch} from './reconciled-accounting.mjs';
import {phoneAccessFetch} from './phone-access.mjs';
// New production namespace only. Never use the development ledger/allowance.
export const VALIDATION_CAP=VALIDATION_CAP_MICRO_USD, REQUEST_HOLD=2_500_000;
const PREFIX='production-validation-v1:', MAX_INPUT=24576, MAX_OUTPUT=16384;
const json=(value,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store'}});
const integer=x=>Number.isSafeInteger(x)&&x>=0;
export class ProductionLedger {
 constructor(state,env={},dependencies={}){this.storage=state.storage;this.env=env;this.now=dependencies.now??Date.now}
 async alarm(){return executionAlarm(this.storage,this.now())}
 async fetch(request){
  try {
   const path=new URL(request.url).pathname;
   if(path.startsWith('/phone-access/'))return await phoneAccessFetch(this.storage,request,this.env);
   if(path.endsWith('-v2'))return this.env.ALLOW_RECONCILED_BUDGET==='true'||await this.storage.transaction(async tx=>await tx.get('production-validation-v2:execution-adopted:v1')===true||!!await tx.get('production-validation-v2:execution-cutover:v1'))&&!['/reserve-v2','/native-prepare-v2','/native-reserve-v2','/claim-v2','/native-claim-v2'].includes(path)&&!path.startsWith('/pilot-')?await reconciledFetch(this.storage,request,this.env.ALLOW_LEGACY_RECONCILIATION==='true',this.env,this.now()):json({error:'accounting_v2_disabled'},503);
   if(path==='/status'&&request.method==='GET')return await this.storage.transaction(async tx=>{
    const total=(await tx.get(PREFIX+'total'))??0,halted=(await tx.get(PREFIX+'halted'))??false;
    if(!integer(total)||typeof halted!=='boolean')return json({error:'accounting_unavailable'},503);
    return json({protocol:1,capMicroUSD:VALIDATION_CAP,reservedMicroUSD:total,remainingMicroUSD:null,halted});
   });
   if(request.method!=='POST'||!['/reserve','/complete','/uncertain'].includes(path))return json({error:'not_available'},503);
   const p=await request.json();
   if(!p||!/^[a-z0-9-]{36}$/i.test(p.requestID??'')||!/^[a-f0-9]{64}$/.test(p.userHash??''))return json({error:'invalid_accounting_request'},400);
   return await this.storage.transaction(async tx=>{
    const total=(await tx.get(PREFIX+'total'))??0,halted=(await tx.get(PREFIX+'halted'))??false;
    if(!integer(total)||typeof halted!=='boolean')return json({error:'accounting_unavailable'},503);
    const key=PREFIX+'request:'+p.requestID,prior=await tx.get(key);
    if(path==='/reserve'){
     if(this.env.ALLOW_RECONCILED_BUDGET==='true'||await tx.get('production-validation-v2:adopted')||await tx.get('production-validation-v2:execution-cutover:v1'))return json({error:'legacy_reservations_closed'},503);
     if(halted)return json({error:'validation_halted'},503);
     if(prior)return json({error:'already_reserved'},409);
     if(p.amountMicroUSD!==REQUEST_HOLD||!/^[a-f0-9]{64}$/.test(p.fingerprint??''))return json({error:'invalid_reservation'},400);
     if(await tx.get(PREFIX+'inflight:'+p.userHash))return json({error:'request_in_progress'},429);
     if(!Number.isSafeInteger(total+REQUEST_HOLD))return json({error:'accounting_unavailable'},503);
     const record={userHash:p.userHash,fingerprint:p.fingerprint,reservedMicroUSD:REQUEST_HOLD,state:'pending'};
     await tx.put(key,record);await tx.put(PREFIX+'total',total+REQUEST_HOLD);await tx.put(PREFIX+'inflight:'+p.userHash,p.requestID);
     return json({protocol:1,requestID:p.requestID,reservedMicroUSD:REQUEST_HOLD,totalReservedMicroUSD:total+REQUEST_HOLD,remainingMicroUSD:null});
    }
    if(!prior||prior.userHash!==p.userHash||prior.reservedMicroUSD!==REQUEST_HOLD||prior.state!=='pending')return json({error:'invalid_accounting_state'},409);
    if(path==='/complete'&&knownProviderRejection({diagnostic:{providerStatus:p.providerRejectedStatus,providerCode:p.providerRejectedCode}})){await tx.put(key,{...prior,state:'complete',calls:0,inputTokens:0,outputTokens:0,conservativeUsageMicroUSD:0,providerStatus:p.providerRejectedStatus,providerCode:p.providerRejectedCode});await tx.put(PREFIX+'inflight:'+p.userHash,null);return json({protocol:1,reservedMicroUSD:REQUEST_HOLD,conservativeUsageMicroUSD:0,totalReservedMicroUSD:total,remainingMicroUSD:null});}
    const valid=path==='/complete'&&integer(p.inputTokens)&&p.inputTokens<=MAX_INPUT&&integer(p.outputTokens)&&p.outputTokens<=MAX_OUTPUT&&Number.isInteger(p.calls)&&p.calls>=1&&p.calls<=3;
    if(!valid){await recordGlobalHalt(tx,PREFIX,'legacy_unverified_usage');await tx.put(key,{...prior,state:'uncertain'});return json({error:'validation_halted'},503)}
    const estimate=Math.ceil((p.inputTokens*20+p.outputTokens*100)*11/10);
    if(!integer(estimate)||estimate>REQUEST_HOLD){await recordGlobalHalt(tx,PREFIX,'legacy_unverified_usage');await tx.put(key,{...prior,state:'uncertain'});return json({error:'validation_halted'},503)}
    await tx.put(key,{...prior,state:'complete',calls:p.calls,inputTokens:p.inputTokens,outputTokens:p.outputTokens,conservativeUsageMicroUSD:estimate});
    await tx.put(PREFIX+'inflight:'+p.userHash,null);
    // Holds remain permanent. There is deliberately no refund/reset/renewal endpoint.
    return json({protocol:1,reservedMicroUSD:REQUEST_HOLD,conservativeUsageMicroUSD:estimate,totalReservedMicroUSD:total,remainingMicroUSD:null});
   });
  }catch{return json({error:'accounting_unavailable'},503)}
 }
}
