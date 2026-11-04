// TEST ONLY. No endpoint, credentials or approval are supplied by this module.
// A scheduling threshold is not a guaranteed final dollar maximum.
import fs from 'node:fs';import crypto from 'node:crypto';import path from 'node:path';
import {pilotBody,pilotBill,pilotAdmission} from '../pilot-policy.mjs';
export class ProviderBenchmarkGuard {
 constructor(file,limits){
  if(!Number.isSafeInteger(limits.stopSchedulingMicroUSD)||limits.stopSchedulingMicroUSD<=0||!Number.isInteger(limits.maxResponses)||limits.maxResponses<1||limits.maxResponses>72||!Number.isInteger(limits.maxWebActions)||limits.maxWebActions<1||limits.maxWebActions>48)throw Error('pilot_limits');
  this.file=file;this.limits=limits;
  this.change(s=>{if(s){if(JSON.stringify(s.limits)!==JSON.stringify(limits))throw Error('pilot_limits_changed');return s}return {version:1,runID:crypto.randomUUID(),limits,records:[]}});
 }
 change(fn){const lock=fs.openSync(this.file+'.lock','wx',0o600);let tmp;
  try{const old=fs.existsSync(this.file)?JSON.parse(fs.readFileSync(this.file,'utf8')):null;
   if(old&&(old.version!==1||!Array.isArray(old.records)||old.records.some(r=>!['pending','settled','uncertain'].includes(r.state)||!Number.isSafeInteger(r.webAllowance)||r.webAllowance<0||r.webAllowance>12||r.state==='settled'&&(!Number.isSafeInteger(r.cost)||r.cost<0||!Number.isSafeInteger(r.webCalls)||r.webCalls<0||r.webCalls>r.webAllowance))))throw Error('pilot_journal_corrupt');
   const next=fn(old);tmp=this.file+'.'+crypto.randomUUID()+'.tmp';const f=fs.openSync(tmp,'wx',0o600);try{fs.writeFileSync(f,JSON.stringify(next));fs.fsyncSync(f)}finally{fs.closeSync(f)}fs.renameSync(tmp,this.file);tmp=null;const d=fs.openSync(path.dirname(this.file),'r');try{fs.fsyncSync(d)}finally{fs.closeSync(d)}return structuredClone(next);
  }finally{if(tmp&&fs.existsSync(tmp))fs.unlinkSync(tmp);fs.closeSync(lock);fs.unlinkSync(this.file+'.lock')}
 }
 wrap(send){return async(url,options)=>{
  const config=pilotBody(url,options);if(config.countOnly)return send(url,options);const web=config.webAllowance;
  const id=crypto.randomUUID();this.change(s=>{
   try{pilotAdmission(s,web,s.limits)}catch(e){throw Error(e.message==='pilot_limit'?'pilot_stop':'pilot_unsettled')}
   s.records.push({id,state:'pending',webAllowance:web});return s;
  });
  try{
   const response=await send(url,options);const v=await response.clone().json();
   if(!response.ok)throw Error('pilot_usage_unknown');const {cost,webCalls}=pilotBill(v);
   if(webCalls>web)throw Error('pilot_usage_unknown');
   this.change(s=>{const r=s.records.find(r=>r.id===id);if(r?.state!=='pending')throw Error('pilot_state');Object.assign(r,{state:'settled',cost,webCalls});return s});return response;
  }catch(error){try{this.change(s=>{const r=s.records.find(r=>r.id===id);if(r?.state==='pending')r.state='uncertain';return s})}catch{}throw error}
 }}
}
