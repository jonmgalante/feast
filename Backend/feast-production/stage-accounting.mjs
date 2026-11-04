import {VALIDATION_CAP_MICRO_USD as CAP} from './budget-policy.mjs';
import {STAGE_HOLDS,stageCost} from './stage-policy.mjs';
const uuid=x=>/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(x??'');
export async function stageID(root,index){
 if(!uuid(root)||!Number.isSafeInteger(index)||index<0||index>=12)throw Error('stage_identity');
 const b=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode('feast-stage-v1:'+root+':'+index))).slice(0,16);b[6]=(b[6]&15)|80;b[8]=(b[8]&63)|128;
 const h=[...b].map(x=>x.toString(16).padStart(2,'0')).join('');return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);
}
function validBudget(p){return p?.protocol===1&&p.accountingVersion===2&&p.capMicroUSD===CAP&&p.halted===false&&Number.isSafeInteger(p.reservedMicroUSD)&&p.reservedMicroUSD>=0&&p.remainingMicroUSD===null}
// Server-owned lifecycle: one reservation/settlement per provider dispatch; never retries.
export class StageRefusal extends Error {constructor(status){super("stage_reservation_refused");this.status=status}}
export class StageAccounting {
 constructor({root,userHash,fingerprint,invoke,maxStages=6,startIndex=0}){
  if(!uuid(root)||!/^[a-f0-9]{64}$/.test(userHash??'')||!/^[a-f0-9]{64}$/.test(fingerprint??'')||!Number.isInteger(maxStages)||maxStages<1||maxStages>12||!Number.isSafeInteger(startIndex)||startIndex<0||startIndex>=maxStages)throw Error('stage_identity');
  this.root=root;this.userHash=userHash;this.fingerprint=fingerprint;this.invoke=invoke;this.maxStages=maxStages;this.count=startIndex;this.current=null;this.lastBudget=null;this.records=[];
 }
 async begin(profile){
  if(this.current||this.count>=this.maxStages||!Object.hasOwn(STAGE_HOLDS,profile))throw Error('stage_limit');
  const stageIndex=this.count++;this.current={preparing:true};
  const requestID=await stageID(this.root,stageIndex),amountMicroUSD=STAGE_HOLDS[profile];
  const current={requestID,profile,amountMicroUSD,reserved:false,dispatched:false,settlementAttempted:false};this.current=current;
  const response=await this.invoke('/reserve',{requestID,userHash:this.userHash,fingerprint:this.fingerprint,profile,amountMicroUSD,rootRequestID:this.root,stageIndex});
  if(!response.ok)throw new StageRefusal(response.status);current.reserved=true;
  const proof=await response.json();if(proof.protocol!==1||proof.requestID!==requestID||proof.reservedMicroUSD!==amountMicroUSD||proof.capMicroUSD!==CAP)throw Error('stage_reservation_unverified');
  current.dispatched=true;
 }
 async complete(usage){
  const c=this.current;if(!c?.reserved||!c.dispatched||c.settlementAttempted)throw Error('stage_state');
  const cost=stageCost([usage],c.profile);c.settlementAttempted=true;
  const response=await this.invoke('/complete',{requestID:c.requestID,userHash:this.userHash,usage:[usage]});
  if(!response.ok)throw Error('stage_settlement_unverified');const budget=await response.json();
  if(!validBudget(budget)||budget.requestReservedMicroUSD!==c.amountMicroUSD||budget.conservativeUsageMicroUSD!==cost)throw Error('stage_settlement_unverified');
  this.records.push({requestID:c.requestID,profile:c.profile,cost});this.lastBudget=budget;this.current=null;
 }
 async cancelUndispatched(){
  const c=this.current;if(!c?.reserved||c.settlementAttempted)throw Error('stage_state');c.settlementAttempted=true;
  const response=await this.invoke('/cancel-undispatched',{requestID:c.requestID,userHash:this.userHash});if(!response.ok)throw Error('stage_settlement_unverified');const budget=await response.json();if(!validBudget(budget)||budget.conservativeUsageMicroUSD!==0)throw Error('stage_settlement_unverified');this.lastBudget=budget;this.current=null;
 }
 async rejected(status,code){
  const c=this.current;if(!c?.reserved||c.settlementAttempted||!Number.isInteger(status)||status<400||status>=500)throw Error('stage_state');
  c.settlementAttempted=true;const response=await this.invoke('/complete',{requestID:c.requestID,userHash:this.userHash,providerRejectedStatus:status,providerRejectedCode:code});
  if(!response.ok)throw Error('stage_settlement_unverified');const budget=await response.json();if(!validBudget(budget)||budget.conservativeUsageMicroUSD!==0)throw Error('stage_settlement_unverified');this.lastBudget=budget;this.current=null;
 }
 async diagnostic(publicDiagnostic){
  const last=this.records.at(-1);if(!last)return;
  try{await this.invoke('/diagnostic',{requestID:last.requestID,userHash:this.userHash,publicDiagnostic})}catch{}
 }
 async uncertain(){
  const c=this.current;
  // A lost settlement acknowledgement is never repeated or overwritten. Reconcile separately.
  if(!c?.reserved||c.settlementAttempted)return;
  c.settlementAttempted=true;
  await this.invoke('/uncertain',{requestID:c.requestID,userHash:this.userHash});
 }
}
