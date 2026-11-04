// TEST-ONLY pilot guard. Never imported by Worker/app code; no network/credentials.
// The journal contains IDs and amounts only. An interrupted run never starts anew
// with a replenished budget. No hosted-search bound is claimed or registered.
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import {STAGE_HOLDS} from '../stage-policy.mjs';
export class BenchmarkBudget {
 constructor(path,maximumMicroUSD,{reconcileOnly=false}={}){
  if(!Number.isSafeInteger(maximumMicroUSD)||maximumMicroUSD<=0)throw Error('benchmark_maximum');
  this.path=path;this.reconcileOnly=reconcileOnly;
  this.transaction(state=>{
   if(state){if(state.maximumMicroUSD!==maximumMicroUSD)throw Error('benchmark_maximum_changed');for(const r of Object.values(state.records))if(r.state==='pending')r.state='uncertain';return state}
   return {version:1,runID:crypto.randomUUID(),maximumMicroUSD,records:{}};
  });
 }
 transaction(change){
  const lock=fs.openSync(this.path+'.lock','wx',0o600);let temporary;
  try{
   const current=fs.existsSync(this.path)?JSON.parse(fs.readFileSync(this.path,'utf8')):null;
   if(current&&(!current.records||current.version!==1||!Number.isSafeInteger(current.maximumMicroUSD)||Object.values(current.records).some(r=>!['pending','uncertain','settled'].includes(r.state)||!Number.isSafeInteger(r.hold)||r.hold<0||r.profile!=='astraAgentStepV1'||r.hold!==STAGE_HOLDS.astraAgentStepV1||r.state==='settled'&&(!Number.isSafeInteger(r.actual)||r.actual<0||r.actual>r.hold))))throw Error('benchmark_journal_corrupt');
   if(current){const exposure=Object.values(current.records).reduce((n,r)=>n+(r.state==='settled'?r.actual:r.hold),0);if(!Number.isSafeInteger(exposure)||exposure>current.maximumMicroUSD)throw Error('benchmark_journal_corrupt')}
   const next=change(current);if(!next)throw Error('benchmark_journal_state');
   temporary=this.path+'.'+crypto.randomUUID()+'.tmp';const file=fs.openSync(temporary,'wx',0o600);
   try{fs.writeFileSync(file,JSON.stringify(next)+'\n');fs.fsyncSync(file)}finally{fs.closeSync(file)}
   fs.renameSync(temporary,this.path);temporary=null;const directory=fs.openSync(path.dirname(this.path),'r');try{fs.fsyncSync(directory)}finally{fs.closeSync(directory)};
   return structuredClone(next);
  }finally{if(temporary&&fs.existsSync(temporary))fs.unlinkSync(temporary);fs.closeSync(lock);fs.unlinkSync(this.path+'.lock')}
 }
 snapshot(){return JSON.parse(fs.readFileSync(this.path,'utf8'))}
 reserve(key,profile){
  // Only ordinary non-hosted stages currently have a supplied verified envelope.
  // Native/legacy hosted web requests are refused until their billing bound is proved.
  if(profile!=='astraAgentStepV1')throw Error('benchmark_bound_unverified');
  if(!/^[a-f0-9-]{36}:[0-9]{1,2}$/i.test(key)||this.reconcileOnly)throw Error('benchmark_request');
  const hold=STAGE_HOLDS[profile];
  this.transaction(state=>{
   if(state.records[key])throw Error('benchmark_replay');
   if(Object.values(state.records).some(r=>r.state==='uncertain'))throw Error('benchmark_uncertain');
   const exposure=Object.values(state.records).reduce((n,r)=>n+(r.state==='settled'?r.actual:r.hold),0);
   if(!Number.isSafeInteger(exposure+hold)||exposure+hold>state.maximumMicroUSD)throw Error('benchmark_limit');
   state.records[key]={state:'pending',hold,profile};return state;
  });return hold;
 }
 settle(key,proof){
  this.transaction(state=>{const r=state.records[key];if(!r||!['pending','uncertain'].includes(r.state))throw Error('benchmark_settlement_state');
   if(proof?.verified!==true||!Number.isSafeInteger(proof.actualMicroUSD)||proof.actualMicroUSD<0||proof.actualMicroUSD>r.hold)throw Error('benchmark_settlement_unverified');
   r.state='settled';r.actual=proof.actualMicroUSD;return state;
  });
 }
 uncertain(key){this.transaction(state=>{const r=state.records[key];if(r?.state==='pending')r.state='uncertain';return state})}
 async runRequest(payload,send,reconcile){
  if(payload?.version!==9||!['conversationStep','authorizeChange'].includes(payload.mode)||!Number.isInteger(payload.step??0)||(payload.step??0)<0||(payload.step??0)>11||typeof payload.requestID!=='string')throw Error('benchmark_bound_unverified');
  return this.run(payload.requestID+':'+(payload.step??0),'astraAgentStepV1',()=>send(structuredClone(payload)),reconcile);
 }
 async run(key,profile,operation,reconcile){
  this.reserve(key,profile);
  try{const result=await operation();this.settle(key,await reconcile(result));return result}
  catch(error){this.uncertain(key);throw error}
 }
}
